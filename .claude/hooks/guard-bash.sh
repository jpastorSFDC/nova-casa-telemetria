#!/usr/bin/env bash
# PreToolUse guard for the Bash tool — enforces Nova Casa Telemetry deploy/test/attribution
# rules from CONTRIBUTING.md and AGENTS.md so they don't depend on an agent remembering them.
#
# Exit 0 = allow. Exit 2 + stderr message = block (Claude Code PreToolUse "command" hook contract).
#
# It reads the hook JSON from stdin and looks for the patterns anywhere in the command text, so a
# command that only mentions one of them (an echo, a commit message) is blocked too: rephrase it.
# Without jq it falls back to the raw JSON text instead of letting everything through.
set -euo pipefail

input="$(cat)"
command=""
if command -v jq > /dev/null 2>&1; then
  command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
fi
[ -n "$command" ] || command="$input"
flat="$(printf '%s' "$command" | tr '\n' ' ')"

block() {
  echo "BLOCKED by Nova Casa guard-bash.sh: $1" >&2
  exit 2
}

# Rule: Apex deploys never run RunLocalTests / RunAllTestsInOrg (production org; would also
# run the org's own demo-class tests). Always RunSpecifiedTests. `-l` is the short form of --test-level.
if printf '%s' "$flat" | grep -qE '(--test-level|(^|[[:space:]])-l)[= ]+["'"'"']?(RunLocalTests|RunAllTestsInOrg)'; then
  block "Apex test level must be RunSpecifiedTests only (never RunLocalTests/RunAllTestsInOrg) — nova-cdo is production. See CONTRIBUTING.md#apex-needs-tests."
fi

# Rule: the whole force-app only deploys from main; a branch deploys only its own story's files.
# Catches `--source-dir force-app`, `--source-dir=force-app/`, `-d ./force-app`, quoted or not.
if printf '%s' "$flat" | grep -qE 'sf (project deploy start|force:source:deploy)'; then
  if printf '%s' "$flat" | grep -qE '(--source-dir|-d)([[:space:]]+|=)["'"'"']?(\./)?force-app/?["'"'"']?([[:space:]]|$)'; then
    branch="$(git branch --show-current 2>/dev/null || echo "")"
    if [ "$branch" != "main" ]; then
      block "Deploying the whole force-app is only allowed from main (current branch: '$branch'). Deploy only this story's files from a branch — see CONTRIBUTING.md#deploying-to-the-shared-org."
    fi
  fi
fi

# Rule: no AI co-authorship in commits, ever.
if printf '%s' "$flat" | grep -qiE 'Co-Authored-By:[[:space:]]*[^"]*(Claude|Cursor|Anthropic|cursoragent)|Generated with[^"]*Claude Code'; then
  block "No AI co-authorship in commits — CONTRIBUTING.md forbids it, no exceptions."
fi

exit 0
