# Sprint 2 — Nova Casa Telemetry

Development · since Sep 25, 2026 · Path `onboarding-csg` (MDSS)

Team: John Alejandro Pastor + Juan Diego Velásquez.

## What this repo is right now

We're in **Development**. The repo is a Salesforce DX project: code and metadata live in `force-app/`. The Discovery deliverables (Sep 15–26) are in `entregables/`; they guide the design but aren't the spec.

## Finding your way around

Each fact has one home. Other files link to it instead of repeating it.

**From MDSS (Spanish, verbatim, never paraphrased)**

| File | What it is | Edited by hand? |
|---|---|---|
| `Sprint 2 - Nova Casa.md` | **Source of truth**: brief, personas, Laura, formative frontier, BR-201 through 210, agreements, deliverables, the simulator contract, the user stories. Wins whenever another file disagrees. | Only to paste new content exactly as it arrives from MDSS. |
| `docs/br-201-210.md` | The 10 BRs, text identical to `Sprint 2 - Nova Casa.md`, split out for quick reference. | Only if the source text changes |
| `entregables/` | The Discovery deliverables as handed in, frozen. [`entregables/README.md`](entregables/README.md) says which file answers which MDSS deliverable and what changed since. | No, except its README |

**Ours**

| File | What it is | Edited by hand? |
|---|---|---|
| `AGENTS.md` | Instructions for AI agents: rules they can't contradict, the formative frontier, branch flow. | Yes |
| `CONTRIBUTING.md` | How to contribute: branches, commits, PRs, deploys to the shared org and the Apex test rules. | Yes |
| `docs/decisiones.md` | Deliverable 6, kept alive: every decision the pair made (ADR-lite), with the alternative we dropped, the trade-off and the risks. The only place that explains *why*. | Yes |
| `docs/entendimiento.md` | What happened to the open questions and assumptions of deliverable 1 (the PDF in `entregables/`). | Yes |
| `docs/contrato-mensaje.md` | Deliverable 5: the message contract as the simulator really sends it, and how each field lands in Salesforce. | Yes |
| `docs/acceso.md` | Access matrix (US-208): who sees and does what, and where each access comes from. | Yes |
| `docs/demo.md` | The demo script (T9.2). | Yes |
| `docs/evidencia-escenarios.md` | Evidence: recorded simulator runs and what proves each story (T9.3). | Yes |
| `docs/muestras/` | Real simulator responses captured on Sep 30 (`telemetry.json`, `catalog.json`). | No |
| `docs/best-practices.html` | General Git/GitHub primer for the team. Not project-specific. | Rarely |
| `scripts/org-check.sh` | Read-only org checks, plus the scenario runs and the org cleanup used for the evidence. Its header lists the commands. | Yes |
| `force-app/` | Salesforce code and metadata: objects, Apex, LWC, permission sets. | Yes |
| `sfdx-project.json` · `.forceignore` · `config/` | Salesforce DX project configuration. | Rarely |
| `.githooks/` | Hook that checks commit format. Turn it on once with `git config core.hooksPath .githooks`. | Rarely |

If a new doc would repeat MDSS content in different words, it doesn't get added — quote the verbatim instead.

**Language.** Everything we write is in English: docs, decisions, commits, PRs. The exceptions are the MDSS source (`Sprint 2 - Nova Casa.md`, `docs/br-201-210.md`), which stays verbatim in Spanish, and the approved `entregables/`, which we don't edit (see D014 for the points later decisions have superseded).

**Backlog and board.** Task-level status lives outside the repo: the Slack list "Nova Casa Sprint 2 · Backlog MVP" in `#novacasa_sprint_2`, and the story cards on the MDSS board (see the "Board and backlog" section of [CONTRIBUTING.md](CONTRIBUTING.md#board-and-backlog)).

**Searching.** Agent worktrees under `.claude/worktrees/` hold full copies of every doc. Exclude them when searching, e.g. `rg PATTERN --glob '!.claude/worktrees'`.

## How we work

- **Contributing**: branches, commits, PRs and deploys follow [CONTRIBUTING.md](CONTRIBUTING.md), the same rules for us and for agents. Short version: one branch per story (`feat/us-201-receive-signals`), Conventional Commits in English, a PR approved by the other person, merged with squash.
- **`main` takes no direct commits**, ours or an agent's — everything comes in through a PR.
- **Approval**: the MDSS facilitator approves each deliverable; an agreement between the two of us doesn't close it on its own.
- **GitHub**: [jpastorSFDC/nova-casa-telemetria](https://github.com/jpastorSFDC/nova-casa-telemetria), public. Don't assume something's pushed until you've checked the remote.

## Working with the org

Needs the [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`). We both work in the same org, each with our own user:

```bash
sf org login web -a nova-cdo --instance-url https://<org-domain>.my.salesforce.com
sf config set target-org nova-cdo
```

From a branch, deploy only that story's files, always validating first:

```bash
sf project deploy start --source-dir <story-files> --dry-run
sf project deploy start --source-dir <story-files>
```

The full `force-app` deploys only from `main`, after merging. The org is production, so Apex deploys need tests: the deploy rules are in [CONTRIBUTING.md](CONTRIBUTING.md#deploying-to-the-shared-org) and the test rules in [CONTRIBUTING.md](CONTRIBUTING.md#apex-needs-tests).

To watch Platform Event processing: the run itself shows up in Setup > Apex Jobs, but the events are handled by `SenialSensorTrigger` asynchronously. Open the **Todas las señales** list view of `Log_Senial__c` (`/lightning/o/Log_Senial__c/list?filterName=Todas_las_senales`): each message appears as `Publicada` (`Publicado_At__c`) and moves to `Procesada`, `Rechazada`, `Atrasada`, etc. (`Procesado_At__c`) once the subscriber handles it. Publishing and processing are separate moments (D013, D031).

The ingestion continues the simulator session between runs (D025): a second run brings new messages instead of the same ones. Use **Reiniciar sesión** on the screen (or the 5-argument `TelemetriaIngesta.iniciar(escenario, semilla, tamanoLote, maxPaginas, true)`) to start the stream again.

## Loading the building/asset catalog

`CatalogoService.loadCatalog()` calls `GET /catalog` on the simulator (via the `Nova_Casa_Simulator` Named Credential) and upserts one `Account` per building and one `Asset` per asset, keyed by `External_Id__c`. Run it from Execute Anonymous after deploying the class:

```apex
CatalogoService.loadCatalog();
```

It's safe to run more than once: a building or asset already in the org (matched by `External_Id__c`) gets updated, not duplicated. Sensor and measurement details from the catalog aren't stored on `Asset` — they only drive `Umbral__c` seeding (T3.2).

## Running the ingestion

`TelemetriaIngesta` opens a simulator session, pages `GET /telemetry` and, for each page, writes a `Log_Senial__c` row as `Publicada` and then publishes `Senial_Sensor__e`. Run it from Execute Anonymous, one person at a time (it creates real records):

```apex
TelemetriaIngesta.iniciar('QA_200', 5); // scenario, max pages (default 25, cap 100)
```

To repeat a sequence or use smaller pages, pass a seed and a batch size (1 to 200, default 200; anything else is refused before anything is enqueued):

```apex
TelemetriaIngesta.iniciar('QA_200', 42, 50, 5); // scenario, seed, batch size, max pages
```

Both go in the `POST /session` body (`seed`, `batchSize`) and the batch size is also the `limit` of every page; a reopened session or a retry asks for the same seed. The simulator decides whether it honors them: `QA_200` was seen returning 200 per page whatever the session asked.

Admins can also start it from the operator screen: **Traer señales** (needs the `Nova_Casa_Traer_Senales` custom permission and `Nova_Casa_Simulator_Integration`). It refuses to start while another run is queued or running, and shows the log rows written by result.

Follow it in Setup > Apex Jobs. The run ends on `hasMore = false`, an empty page or the page cap. Processing is the subscriber's job; a row stays `Publicada` until it has handled the event. The simulator token lives only in Setup; the session cursor is never logged or stored (see D013). What the simulator sends and how it maps to `Senial_Sensor__e` is in [docs/contrato-mensaje.md](docs/contrato-mensaje.md).

## Cleaning the org before a demo or a recorded run

The simulator reuses `messageId` across sessions. If `Log_Senial__c` rows from earlier runs are still in the org, a new run comes out almost entirely as `Conflicto` or resend (on 2026-10-06 the org had 400 log rows, all `Conflicto`). Before a demo or a run you want to record as evidence, delete the `Log_Senial__c` rows, the `Lectura_Vigente__c` rows and the `Case` rows with `Origin = 'Telemetria'`.

Deleting data needs John and Juan Diego to agree, and runs one person at a time, announced in Slack ([CONTRIBUTING.md](CONTRIBUTING.md#deploying-to-the-shared-org)). `scripts/org-check.sh clean` previews what would be deleted and what stays; `clean confirm=<org>:<n>` deletes it.
