#!/bin/bash
# Checks and scenario runs for the Nova Casa sprint against the shared org (alias nova-cdo, or ORG=<alias>).
# Run it from the repo root, with the "!" prefix inside Claude Code or in a terminal. It prints no tokens, cursors,
# Ids or org usernames, except `queries` (persona usernames) and `tests` (its output FILE has the username).
#
#   Read-only:
#     org-check.sh queries                       counts, personas, buildings and classes in the org
#     org-check.sh logs                          log rows and Cases by day and Resultado__c
#     org-check.sh tests                         all our test classes: summary and coverage
#     org-check.sh drift                         retrieve into a throwaway worktree and show what differs from origin/main
#     org-check.sh clean                         preview of what a clean deletes and what stays
#     org-check.sh wait <since>                  wait until the run started at <since> is fully processed
#     org-check.sh evidence [SCENARIO] [since]   markdown for docs/evidencia-escenarios.md
#   Writes org data (announce it, one person at a time, see docs/demo.md):
#     org-check.sh clean confirm=<org>:<n>       delete the telemetry rows; <n> = Log_Senial__c rows in the preview
#     org-check.sh run <SCENARIO> [pages=10] [seed=42] [batch=200]
#                                                start one ingestion, on a clean org, with a fresh simulator session
#
# macOS ships bash 3.2: no mapfile, no associative arrays, and no set -e (a failed query must not abort half-way).
ORG="${ORG:-nova-cdo}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
SCENARIOS="MIXED QA_200 BOUNDARIES CRITICAL_BURST LATE_MESSAGES DUPLICATES CONFLICT INVALID_DATA CAMERA_OUTAGE"
JOB_ACTIVE="'Queued','Preparing','Processing','Holding'" # same statuses as IngestaController.hayIngestaEnCurso
PURGE_CHUNK=2000 # rows per object per delete pass: 3 objects stay well under the 10,000 DML rows of a transaction
PURGE_PASSES=10
WORK=""

set -o pipefail
trap 'if [ -n "$WORK" ]; then rm -rf "$WORK"; fi' EXIT

# ---------------------------------------------------------------- helpers

usage() {
  cat >&2 <<EOF
usage: org-check.sh queries | logs | tests | drift
       org-check.sh clean [confirm=<org>:<log rows>]
       org-check.sh run <SCENARIO> [pages=10] [seed=42] [batch=200]
       org-check.sh wait <since>
       org-check.sh evidence [SCENARIO] [since]
SCENARIO: $SCENARIOS
since: UTC, like 2026-10-13T15:04:05Z (printed by "run"). ORG=<alias> picks another org (now: $ORG).
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

is_int() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; return 0; }
in_range() { is_int "$1" && [ "${#1}" -le 9 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
valid_scenario() { [ -n "$1" ] && case " $SCENARIOS " in *" $1 "*) return 0 ;; esac; return 1; }
valid_since() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
  esac
  return 1
}

# sf output as JSON; a fake error object when sf prints nothing, so jq always gets valid input.
soqlj() {
  local out
  out=$(sf data query -o "$ORG" -q "$1" --json 2>/dev/null)
  if [ -n "$out" ]; then echo "$out"; else echo '{"status":1,"message":"no answer from sf (login expired or wrong org alias?)"}'; fi
}

# count "SELECT COUNT() ...": prints the number, or returns 1 after a message on stderr.
count() {
  local n
  n=$(soqlj "$1" | jq -r 'if .status == 0 then (.result.totalSize | tostring) else "ERR" end' 2>/dev/null)
  case "$n" in '' | *[!0-9]*) echo "ERROR: query failed: ${1:0:80}" >&2; return 1 ;; esac
  echo "$n"
}

# One flat row per record: relationship fields are flattened in query order, nulls are "-", datetimes lose ".000+0000".
JQ_ROW='walk(if type == "object" then del(.attributes) else . end)
        | [.. | scalars | if . == null then "-" elif type == "string" then sub("\\.[0-9]{3}\\+0000$"; "Z") else tostring end]'

q() { # q "title" "SOQL": one tab-separated line per record
  echo "## $1"
  soqlj "$2" | jq -r 'if .status != 0 then "ERROR: " + (.message // "query failed")
    elif (.result.records | length) == 0 then "totalSize=" + (.result.totalSize | tostring)
    else .result.records[] | '"$JQ_ROW"' | @tsv end'
  echo
}

mdrows() { # mdrows "SOQL": one markdown table row per record, "|" escaped
  soqlj "$1" | jq -r 'if .status != 0 then "| ERROR: " + ((.message // "query failed") | gsub("\\|"; "/")) + " |"
    else .result.records[] | '"$JQ_ROW"' | map(gsub("\\|"; "\\|")) | "| " + join(" | ") + " |" end'
}

window() { # window "SOQL with minp and maxp": "first to last, N s"
  soqlj "$1" | jq -r 'def secs: sub("\\.[0-9]+"; "") | sub("\\+0000$"; "Z") | fromdateiso8601;
    def shown: sub("\\.[0-9]{3}\\+0000$"; "Z");
    if .status != 0 then "ERROR: " + (.message // "query failed")
    else .result.records[0] as $r
      | if ($r.minp == null or $r.maxp == null) then "n/a"
        else "\($r.minp | shown) to \($r.maxp | shown), \(($r.maxp | secs) - ($r.minp | secs)) s" end end'
}

# apex < source: runs anonymous Apex and prints the lines the source logged as System.debug('NC|...') without the
# marker. The echoed source, USER_INFO and the rest of the debug log are dropped. Returns 1 on a compile or runtime
# error, printing it with Id-shaped words masked.
apex() {
  local out ok
  cat > "$WORK/run.apex"
  out=$(sf apex run -o "$ORG" -f "$WORK/run.apex" --json 2>/dev/null)
  rm -f "$WORK/run.apex"
  [ -n "$out" ] || { echo "ERROR: no answer from sf apex run (login expired or wrong org alias?)" >&2; return 1; }
  ok=$(echo "$out" | jq -r '.result.success // false' 2>/dev/null)
  if [ "$ok" != "true" ]; then
    echo "$out" | jq -r 'def mask: gsub("\\b(?=[A-Za-z]*[0-9])[0-9A-Za-z]{15}(?:[0-9A-Za-z]{3})?\\b"; "<id>");
      if (.result.compiled // true) == false then "ERROR: Apex did not compile: " + ((.result.compileProblem // "?") | mask)
      elif .result.success == false then "ERROR: Apex failed: " + ((.result.exceptionMessage // "?") | mask)
      else "ERROR: " + ((.message // "apex run failed") | mask) end' >&2
    return 1
  fi
  echo "$out" | jq -r '(.result.logs // "") | split("\n")[] | select(contains("|USER_DEBUG|"))
    | sub("^.*\\|USER_DEBUG\\|\\[[0-9]+\\]\\|DEBUG\\|"; "") | select(startswith("NC|")) | .[3:]'
}

# ---------------------------------------------------------------- guards

inflight() { # number of TelemetriaIngesta jobs still queued or running
  count "SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta' AND Status IN ($JOB_ACTIVE)"
}

# Has the Apex trigger on Senial_Sensor__e processed everything published? Prints caught-up | behind | unknown,
# plus "last-error" when the subscriber has one (the text itself is never printed).
subscriber_state() {
  soqlj "SELECT Position, Tip, LastError FROM EventBusSubscriber WHERE Topic = 'Senial_Sensor__e' AND Type = 'ApexTrigger'" | jq -r '
    if .status != 0 or (.result.records | length) == 0 then "unknown"
    else .result.records as $r
      | (if any($r[]; ((.Position // 0) | tonumber) < ((.Tip // 0) | tonumber)) then "behind" else "caught-up" end)
        + (if any($r[]; (.LastError // "") != "") then " last-error" else "" end)
    end' 2>/dev/null || echo unknown
}

require_idle() { # dies unless nothing is running and the subscriber has caught up
  local jobs state
  jobs=$(inflight) || die "could not check for running ingestion jobs"
  [ "$jobs" = "0" ] || die "$jobs TelemetriaIngesta job(s) still queued or running. Wait for them (wait <since>) and try again."
  state=$(subscriber_state)
  case "$state" in
    behind*) die "the Senial_Sensor__e trigger has not caught up with the published events. Wait a minute and try again." ;;
  esac
  case "$state" in
    *last-error*) echo "WARN: the trigger subscriber reports a LastError (Setup > Platform Events > Senial_Sensor__e > Subscriptions)." >&2 ;;
  esac
}

# Sets LOGS READS CASES (what clean deletes) and STAYS (what it must not touch); dies when a query fails.
telemetry_counts() {
  local acc ast umb umbact cases_all
  LOGS=$(count "SELECT COUNT() FROM Log_Senial__c") || die "could not count Log_Senial__c"
  READS=$(count "SELECT COUNT() FROM Lectura_Vigente__c") || die "could not count Lectura_Vigente__c"
  CASES=$(count "SELECT COUNT() FROM Case WHERE Origin = 'Telemetria'") || die "could not count telemetry Cases"
  cases_all=$(count "SELECT COUNT() FROM Case") || die "could not count Cases"
  acc=$(count "SELECT COUNT() FROM Account WHERE External_Id__c LIKE 'BLD-%'") || die "could not count buildings"
  ast=$(count "SELECT COUNT() FROM Asset") || die "could not count Assets"
  umb=$(count "SELECT COUNT() FROM Umbral__c") || die "could not count Umbral__c"
  umbact=$(count "SELECT COUNT() FROM Umbral__c WHERE Activo__c = true") || die "could not count active Umbral__c"
  STAYS="buildings=$acc assets=$ast umbrales=$umb (active $umbact) other-Cases=$((cases_all - CASES))"
  CATALOG_OK=no
  if [ "$acc" -gt 0 ] && [ "$ast" -gt 0 ] && [ "$umbact" -gt 0 ]; then CATALOG_OK=yes; fi
}

# ---------------------------------------------------------------- Apex sources

# One delete pass, logs first (they point at Cases), then Cases, then readings. Status codes only: no messages.
src_purge() {
  cat <<APEX
Integer ok; Integer bad; StatusCode sc;
List<Log_Senial__c> logs = [SELECT Id FROM Log_Senial__c LIMIT $PURGE_CHUNK];
ok = 0; bad = 0; sc = null;
for (Database.DeleteResult r : Database.delete(logs, false)) {
    if (r.isSuccess()) { ok++; } else { bad++; sc = r.getErrors()[0].getStatusCode(); }
}
System.debug('NC|Log_Senial__c deleted=' + ok + ' failed=' + bad + (sc == null ? '' : ' code=' + sc));
List<Case> cases = [SELECT Id FROM Case WHERE Origin = 'Telemetria' LIMIT $PURGE_CHUNK];
ok = 0; bad = 0; sc = null;
for (Database.DeleteResult r : Database.delete(cases, false)) {
    if (r.isSuccess()) { ok++; } else { bad++; sc = r.getErrors()[0].getStatusCode(); }
}
System.debug('NC|Case deleted=' + ok + ' failed=' + bad + (sc == null ? '' : ' code=' + sc));
List<Lectura_Vigente__c> reads = [SELECT Id FROM Lectura_Vigente__c LIMIT $PURGE_CHUNK];
ok = 0; bad = 0; sc = null;
for (Database.DeleteResult r : Database.delete(reads, false)) {
    if (r.isSuccess()) { ok++; } else { bad++; sc = r.getErrors()[0].getStatusCode(); }
}
System.debug('NC|Lectura_Vigente__c deleted=' + ok + ' failed=' + bad + (sc == null ? '' : ' code=' + sc));
APEX
}

src_run() { # needs SCEN SEED BATCH PAGES, all validated before this runs
  cat <<APEX
Boolean canPublish = Schema.sObjectType.Senial_Sensor__e.isCreateable();
Integer withSet = [SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSet.Name = 'Nova_Casa_Simulator_Integration'];
System.debug('NC|can-create-Senial_Sensor__e=' + canPublish);
System.debug('NC|Nova_Casa_Simulator_Integration-assigned-directly=' + (withSet > 0));
if (canPublish) {
    Datetime t = System.now();
    TelemetriaIngesta.iniciar('$SCEN', $SEED, $BATCH, $PAGES, true);
    System.debug('NC|since=' + t.formatGmt('yyyy-MM-dd') + 'T' + t.formatGmt('HH:mm:ss') + 'Z');
}
APEX
}

src_summary() {
  cat <<'APEX'
System.debug('NC|' + SesionSimulador.leerResumen());
APEX
}

# ---------------------------------------------------------------- modes

mode_clean() {
  local tok tok_org tok_n pass before before_snap
  telemetry_counts
  if [ -z "$1" ]; then
    echo "## Preview of clean on $ORG (nothing was changed)"
    echo "To delete: Log_Senial__c=$LOGS Lectura_Vigente__c=$READS Case(Origin = 'Telemetria')=$CASES"
    echo "Stays:     $STAYS"
    [ "$CATALOG_OK" = "yes" ] || echo "WARN: the catalog looks empty (buildings, assets or active thresholds = 0). Load it first (docs/demo.md, step 3)."
    echo "Jobs in flight: $(inflight || echo '?')   Trigger subscriber: $(subscriber_state)"
    echo
    echo "To delete these rows, John and Juan Diego both agree first, then: scripts/org-check.sh clean confirm=$ORG:<the Log_Senial__c number above>"
    return 0
  fi
  case "$1" in confirm=*:*) ;; *) usage; exit 2 ;; esac
  tok="${1#confirm=}"
  tok_org="${tok%:*}"
  tok_n="${tok##*:}"
  is_int "$tok_n" || die "the number in confirm=<org>:<n> must be the Log_Senial__c count"
  [ "$tok_org" = "$ORG" ] || die "confirm names org '$tok_org' but this run targets '$ORG'"
  [ "$tok_n" = "$LOGS" ] || die "confirm says $tok_n log rows but the org has $LOGS now. Run clean again and read the preview."
  if [ "$LOGS/$READS/$CASES" = "0/0/0" ]; then echo "Nothing to delete."; return 0; fi
  require_idle
  echo "Deleting on $ORG: Log_Senial__c=$LOGS Lectura_Vigente__c=$READS Case=$CASES. Stays: $STAYS"
  before="$STAYS"
  before_snap="$LOGS/$READS/$CASES"
  pass=1
  while [ "$pass" -le "$PURGE_PASSES" ]; do
    echo "-- pass $pass"
    src_purge | apex || die "a delete pass failed"
    telemetry_counts
    echo "   left: Log_Senial__c=$LOGS Lectura_Vigente__c=$READS Case=$CASES"
    [ "$LOGS/$READS/$CASES" = "0/0/0" ] && break
    [ "$LOGS/$READS/$CASES" != "$before_snap" ] || die "a pass deleted nothing (see the codes above). Stopping."
    before_snap="$LOGS/$READS/$CASES"
    pass=$((pass + 1))
  done
  if [ "$STAYS" != "$before" ]; then
    echo "ALERT: what must stay changed. Before: $before. Now: $STAYS" >&2
    exit 1
  fi
  if [ "$LOGS/$READS/$CASES" != "0/0/0" ]; then
    echo "Not finished after $PURGE_PASSES passes. Run clean again: it needs a new preview and a new confirm."
    exit 1
  fi
  echo "Clean. Unchanged: $STAYS"
  echo "The rows went to the recycle bin. After the first run, evidence must show yaExistentes=0 and about 0 Conflicto."
}

mode_run() {
  local out since
  SCEN="$1"; PAGES="${2:-10}"; SEED="${3:-42}"; BATCH="${4:-200}"
  valid_scenario "$SCEN" || { usage; die "unknown scenario '$SCEN'"; }
  in_range "$PAGES" 1 25 || die "pages must be a whole number from 1 to 25 (the operator screen has the same cap)"
  in_range "$SEED" 0 999999999 || die "seed must be a whole number from 0 to 999999999"
  in_range "$BATCH" 1 200 || die "batch must be a whole number from 1 to 200"
  telemetry_counts
  if [ "$LOGS/$READS/$CASES" != "0/0/0" ]; then
    die "the org is not clean (Log_Senial__c=$LOGS Lectura_Vigente__c=$READS Case=$CASES). The simulator repeats messageId across sessions, so old rows would turn into Conflicto. Run: clean"
  fi
  [ "$CATALOG_OK" = "yes" ] || die "the catalog looks empty ($STAYS). Load it first (docs/demo.md, step 3)."
  require_idle
  echo "Starting $SCEN on $ORG: pages=$PAGES seed=$SEED batch=$BATCH, new simulator session."
  out=$(src_run | apex) || die "the run did not start"
  echo "$out"
  since=$(echo "$out" | sed -n 's/^since=//p')
  if ! valid_since "$since"; then
    die "nothing was started: the running user cannot create Senial_Sensor__e. Use a user with Nova_Casa_Admin and Nova_Casa_Simulator_Integration."
  fi
  case "$out" in
    *"Nova_Casa_Simulator_Integration-assigned-directly=false"*)
      echo "WARN: that permission set is not assigned directly (a group may cover it). If the jobs fail on the first callout, that is why." ;;
  esac
  echo
  echo "Started. Next:"
  echo "  scripts/org-check.sh wait $since"
  echo "  scripts/org-check.sh evidence $SCEN $since"
}

mode_wait() {
  local since="$1" polls=0 stable=0 started active pub state failed
  valid_since "$since" || { usage; die "wait needs <since> like 2026-10-13T15:04:05Z"; }
  echo "Waiting for the run started at $since (checks every 30 s, up to 20 min)."
  while [ "$polls" -lt 40 ]; do
    started=$(count "SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta' AND CreatedDate >= $since")
    active=$(inflight)
    pub=$(count "SELECT COUNT() FROM Log_Senial__c WHERE Resultado__c = 'Publicada'")
    state=$(subscriber_state)
    echo "$(date +%T) jobs since: ${started:-?}  in flight: ${active:-?}  Publicada: ${pub:-?}  trigger: $state"
    if [ -n "$started" ] && [ -n "$active" ] && [ -n "$pub" ] \
       && [ "$started" -ge 1 ] && [ "$active" = "0" ] && [ "$pub" = "0" ] && [ "${state#behind}" = "$state" ]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    if [ "$stable" -ge 2 ]; then
      failed=$(count "SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta' AND CreatedDate >= $since AND Status = 'Failed'")
      echo "Done: $started job(s), $failed failed, nothing left Publicada."
      [ "$failed" = "0" ] || echo "FINDING: $failed job(s) Failed. Report it with the evidence; do not hide it."
      return 0
    fi
    polls=$((polls + 1))
    sleep 30
  done
  echo "NOT finished after 20 minutes. Run wait again with the same <since>; if it never settles, report it as a finding." >&2
  exit 2
}

mode_evidence() {
  local scen="" since="" a rows logs reads cases lvl label n lote vigente atr
  for a in "$@"; do
    if valid_since "$a"; then since="$a"
    elif valid_scenario "$a"; then scen="$a"
    else usage; die "'$a' is neither a scenario nor a since time"; fi
  done
  {
    echo "### Evidence: ${scen:-all rows}${since:+, run started $since}, captured $(date -u +%F)"
    echo
    logs=$(count "SELECT COUNT() FROM Log_Senial__c") || logs="?"
    reads=$(count "SELECT COUNT() FROM Lectura_Vigente__c") || reads="?"
    cases=$(count "SELECT COUNT() FROM Case WHERE Origin = 'Telemetria'") || cases="?"
    echo "| Scenario | Log rows | Readings | Cases | Breakdown of logs |"
    echo "|---|---|---|---|---|"
    echo "| \`${scen:-all}\` | $logs | $reads | $cases | $(soqlj "SELECT Resultado__c, COUNT(Id) n FROM Log_Senial__c GROUP BY Resultado__c ORDER BY COUNT(Id) DESC" \
      | jq -r 'if .status != 0 then "ERROR: query failed" elif (.result.records | length) == 0 then "none" else [.result.records[] | "\(.n) \(.Resultado__c)"] | join(", ") end') |"
    echo
    if [ -n "$since" ]; then
      echo "Jobs (\`TelemetriaIngesta\`) created since $since:"
      echo
      echo "| Status | Jobs |"
      echo "|---|---|"
      mdrows "SELECT Status, COUNT(Id) n FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta' AND CreatedDate >= $since GROUP BY Status"
      echo
      echo "- Errors (sum of \`NumberOfErrors\`): $(soqlj "SELECT SUM(NumberOfErrors) e FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta' AND CreatedDate >= $since" | jq -r 'if .status != 0 then "?" else (.result.records[0].e // 0) end' 2>/dev/null)"
      echo "- First job created to last job completed: $(window "SELECT MIN(CreatedDate) minp, MAX(CompletedDate) maxp FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta' AND CreatedDate >= $since")"
    fi
    echo "- First \`Publicado_At__c\` to last \`Procesado_At__c\`: $(window "SELECT MIN(Publicado_At__c) minp, MAX(Procesado_At__c) maxp FROM Log_Senial__c")"
    echo "- Still \`Publicada\` (published, not processed): $(count "SELECT COUNT() FROM Log_Senial__c WHERE Resultado__c = 'Publicada'")"
    echo "- Resent (\`Reenvios__c\` > 0): $(count "SELECT COUNT() FROM Log_Senial__c WHERE Reenvios__c > 0")"
    echo
    echo "Latest readings by severity level (\`Severidad_Nivel__c\`):"
    echo
    echo "| Level | Readings |"
    echo "|---|---|"
    for lvl in "2|2 Crítica" "1|1 Advertencia" "0|0 Normal" "null|none"; do
      label="${lvl#*|}"
      n=$(count "SELECT COUNT() FROM Lectura_Vigente__c WHERE Severidad_Nivel__c = ${lvl%%|*}") || n="?"
      echo "| $label | $n |"
    done
    echo
    echo "Cases with \`Origin = 'Telemetria'\`:"
    echo
    echo "| Status | Priority | Cases |"
    echo "|---|---|---|"
    mdrows "SELECT Status, Priority, COUNT(Id) n FROM Case WHERE Origin = 'Telemetria' GROUP BY Status, Priority ORDER BY Status, Priority"
    echo
    echo "Log rows that point to a Case, by \`Resultado__c\`:"
    echo
    echo "| Resultado__c | Rows |"
    echo "|---|---|"
    mdrows "SELECT Resultado__c, COUNT(Id) n FROM Log_Senial__c WHERE Caso__c != null GROUP BY Resultado__c ORDER BY COUNT(Id) DESC"
    echo
    atr=$(count "SELECT COUNT() FROM Log_Senial__c WHERE Resultado__c = 'Atrasada'") || atr="?"
    lote=$(count "SELECT COUNT() FROM Log_Senial__c WHERE Resultado__c = 'Atrasada' AND Motivo__c LIKE '%(el lote)'") || lote="?"
    vigente=$(count "SELECT COUNT() FROM Log_Senial__c WHERE Resultado__c = 'Atrasada' AND Motivo__c LIKE '%(la lectura vigente)'") || vigente="?"
    echo "\`Atrasada\` rows ($atr), by what they lost to (D011 h): the same batch (\`(el lote)\`) $lote, the stored reading (\`(la lectura vigente)\`) $vigente."
    echo
    echo "Most common \`Rechazada\` reasons (US-202, D032):"
    echo
    echo "| Motivo__c | Rows |"
    echo "|---|---|"
    mdrows "SELECT Motivo__c, COUNT(Id) n FROM Log_Senial__c WHERE Resultado__c = 'Rechazada' GROUP BY Motivo__c ORDER BY COUNT(Id) DESC LIMIT 10"
    echo
    echo "Run summary kept by \`SesionSimulador\` (counters only):"
    echo
    src_summary | apex | jq -Rr --arg since "$since" '
      def keep: ["paginas","recibidos","logsCreados","yaExistentes","logsFallidos","noPublicadosPorLog","publicados","fallosPublicacion",
                 "rechazados","descartados","reintentos","sesionesReabiertas","sesionContinuada","sesionReiniciada","cacheNoDisponible",
                 "flujoTerminado","cursorSinAvanzar","interrumpidaPorEstado","actualizadoEn"];
      (fromjson? // null) as $s
      | if $s == null then "- No summary in the cache (expired, or no run since the last cache clear)."
        else "- " + ($s | with_entries(select(.key as $k | keep | index($k))) | to_entries | map("\(.key)=\(.value)") | join(", "))
          + (if ($since != "" and ($s.actualizadoEn | type) == "string" and ($s.actualizadoEn[0:19] < $since[0:19]))
             then "\n- WARNING: this summary is older than the run started at " + $since + ": do not use it." else "" end) end'
    echo
    echo "Trace rows (US-201): one \`Procesada\` with a Case and one without."
    echo
    echo "| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Resultado__c | Case status | Case priority |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
    for rows in "Caso__c != null" "Caso__c = null"; do
      soqlj "SELECT Identidad__c, Asset__r.Name, Occurred_At__c, Publicado_At__c, Procesado_At__c, Retraso_Publicacion_Seg__c, Latencia_Procesamiento_Seg__c, Resultado__c, Caso__r.Status, Caso__r.Priority FROM Log_Senial__c WHERE Resultado__c = 'Procesada' AND $rows ORDER BY Occurred_At__c, Identidad__c LIMIT 1" \
        | jq -r 'def t: if type == "string" then sub("\\.[0-9]{3}\\+0000$"; "Z") else . end;
          if .status != 0 then "| ERROR: " + (.message // "query failed" | gsub("\\|"; "/")) + " |"
          elif (.result.records | length) == 0 then "| none | - | - | - | - | - | - | - | - | - |"
          else .result.records[0] | [.Identidad__c, .Asset__r.Name, (.Occurred_At__c | t), (.Publicado_At__c | t), (.Procesado_At__c | t),
                 .Retraso_Publicacion_Seg__c, .Latencia_Procesamiento_Seg__c, .Resultado__c, .Caso__r.Status, .Caso__r.Priority]
               | map(if . == null then "-" else tostring | gsub("\\|"; "\\|") end) | "| " + join(" | ") + " |" end'
    done
  } | tee "$WORK/evidence.md"
  if grep -Eq '@[A-Za-z0-9._-]+\.[A-Za-z]{2,}|(^|[^A-Za-z0-9])(00D|005|0Af|707)[A-Za-z0-9]{12}([A-Za-z0-9]{3})?([^A-Za-z0-9]|$)|Bearer |force://' "$WORK/evidence.md"; then
    echo "WARNING: the output above looks like it has an Id, a username or a token. Do not paste it anywhere before you check." >&2
  fi
}

# ---------------------------------------------------------------- dispatch

MODE="${1:-}"
case "$MODE" in
  '' | -h | --help | help) usage; exit 2 ;;
  queries | logs | tests | drift | clean | run | wait | evidence) ;;
  *) usage; exit 2 ;;
esac
command -v sf > /dev/null 2>&1 || die "sf (Salesforce CLI) is not in PATH"
command -v jq > /dev/null 2>&1 || die "jq is not in PATH"
WORK=$(mktemp -d "$TMP_ROOT/org-check.XXXXXX") || die "could not create a temp directory" # removed by the EXIT trap

case "$MODE" in
queries)
  q "Org: trial expiry / type" "SELECT Name, OrganizationType, IsSandbox, TrialExpirationDate FROM Organization"
  q "Cases from telemetry by Status" "SELECT Status, COUNT(Id) n FROM Case WHERE Origin = 'Telemetria' GROUP BY Status"
  q "Log rows by Resultado__c" "SELECT Resultado__c, COUNT(Id) n FROM Log_Senial__c GROUP BY Resultado__c"
  q "Log rows that were resent (Reenvios__c > 0)" "SELECT COUNT() FROM Log_Senial__c WHERE Reenvios__c > 0"
  q "Lectura_Vigente__c total" "SELECT COUNT() FROM Lectura_Vigente__c"
  q "Umbral__c by Activo__c (expect 21 active)" "SELECT Activo__c, COUNT(Id) n FROM Umbral__c GROUP BY Activo__c"
  q "Async jobs, last 7 days, by Status" "SELECT Status, COUNT(Id) n FROM AsyncApexJob WHERE CreatedDate = LAST_N_DAYS:7 GROUP BY Status"
  q "Persona users: role, active, last login" "SELECT Username, IsActive, UserRole.Name, LastLoginDate FROM User WHERE Username LIKE 'novacasa.%' ORDER BY Username"
  q "Persona users: permission sets / groups" "SELECT Assignee.Username, PermissionSet.Name FROM PermissionSetAssignment WHERE Assignee.Username LIKE 'novacasa.%' AND PermissionSet.IsOwnedByProfile = false ORDER BY Assignee.Username"
  q "Buildings: owner" "SELECT External_Id__c, Name, Owner.Username FROM Account WHERE External_Id__c LIKE 'BLD-%' ORDER BY External_Id__c"
  q "Assets per building" "SELECT Account.External_Id__c, COUNT(Id) n FROM Asset GROUP BY Account.External_Id__c"
  q "Apex classes in the org (no namespace)" "SELECT Name, Status, ApiVersion FROM ApexClass WHERE NamespacePrefix = null ORDER BY Name"
  q "Apex triggers in the org" "SELECT Name, Status, TableEnumOrId FROM ApexTrigger WHERE NamespacePrefix = null ORDER BY Name"
  ;;
logs)
  q "Log rows by day CREATED and Resultado__c" "SELECT DAY_ONLY(CreatedDate) d, Resultado__c, COUNT(Id) n FROM Log_Senial__c GROUP BY DAY_ONLY(CreatedDate), Resultado__c"
  q "Log rows by day LAST MODIFIED and Resultado__c" "SELECT DAY_ONLY(LastModifiedDate) d, Resultado__c, COUNT(Id) n FROM Log_Senial__c GROUP BY DAY_ONLY(LastModifiedDate), Resultado__c"
  q "Conflicto rows by Source__c" "SELECT Source__c, COUNT(Id) n FROM Log_Senial__c WHERE Resultado__c = 'Conflicto' GROUP BY Source__c"
  q "Telemetry Cases by day created and Status" "SELECT DAY_ONLY(CreatedDate) d, Status, COUNT(Id) n FROM Case WHERE Origin = 'Telemetria' GROUP BY DAY_ONLY(CreatedDate), Status"
  q "Cases with Procesada log vs total (Cases whose log row is no longer Procesada)" "SELECT Resultado__c, COUNT(Id) n FROM Log_Senial__c WHERE Caso__c != null GROUP BY Resultado__c"
  ;;
tests)
  OUT="$TMP_ROOT/test-run-$(date +%F).txt"
  ARGS=()
  for f in "$REPO"/force-app/main/default/classes/*Test.cls; do ARGS+=(--class-names "$(basename "$f" .cls)"); done
  sf apex run test -o "$ORG" "${ARGS[@]}" --code-coverage --result-format human --wait 30 > "$OUT" 2>&1
  echo "Full output saved to $OUT (it has the org username and the run id: do NOT commit it)."
  echo "## Summary"
  grep -E 'Tests Ran|Pass Rate|Fail Rate|Skip Rate|Outcome|Test Execution Time|Org Wide Coverage' "$OUT" | head -12
  echo "## Failures"
  grep -nE ' Fail | CompileFail ' "$OUT" | head -20
  echo "## Coverage by class"
  grep -E '^[A-Za-z_]+ +[0-9]+%' "$OUT" | head -40
  ;;
drift)
  ROOT="$(cd "$(git -C "$REPO" rev-parse --git-common-dir)/.." && pwd)" # the main clone, even from a worktree
  WT="$ROOT/.claude/worktrees/org-check"
  git -C "$REPO" fetch origin -q
  [ -d "$WT" ] || git -C "$REPO" worktree add --detach "$WT" origin/main
  cd "$WT" || exit 1
  echo "## worktree at: $(git rev-parse --short HEAD)"
  sf project retrieve start -o "$ORG" \
    -m "ApexClass" -m "ApexTrigger" -m "LightningComponentBundle" \
    -m "CustomApplication:Nova_Casa" -m "PermissionSet:Nova_Casa_*" \
    -m "CustomObject:Log_Senial__c" -m "CustomObject:Lectura_Vigente__c" -m "CustomObject:Umbral__c" \
    -m "CustomObject:Senial_Sensor__e" 2>&1 | tail -8
  echo "## Files that differ from main (M) or exist only in the org (??)"
  git status --short | head -60
  echo "## Diff summary"
  git diff --stat | tail -5
  echo "Leave the worktree in place to read it, then run: git restore . && git clean -fd"
  ;;
clean)
  [ "$#" -le 2 ] || { usage; exit 2; }
  mode_clean "$2"
  ;;
run)
  [ "$#" -ge 2 ] && [ "$#" -le 5 ] || { usage; exit 2; }
  mode_run "$2" "$3" "$4" "$5"
  ;;
wait)
  [ "$#" -eq 2 ] || { usage; exit 2; }
  mode_wait "$2"
  ;;
evidence)
  [ "$#" -le 3 ] || { usage; exit 2; }
  shift
  mode_evidence "$@"
  ;;
esac
