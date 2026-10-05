# Sprint 2 — Nova Casa Telemetry

Development · since Sep 25, 2026 · Path `onboarding-csg` (MDSS)

Team: John Alejandro Pastor + Juan Diego Velásquez.

## What this repo is right now

We're in **Development**. The repo is a Salesforce DX project: code and metadata live in `force-app/`. The Discovery prototypes (Sep 15–26) are in `entregables/` and guide the design.

## Finding your way around

| File | What it is | Edited by hand? |
|---|---|---|
| `Sprint 2 - Nova Casa.md` | **Source of truth**, verbatim from MDSS: brief, personas, Laura, formative frontier, BR-201 through 210, agreements, deliverables, the simulator contract. | Only to paste new content exactly as it arrives from MDSS. Never paraphrased. |
| `AGENTS.md` | Instructions for AI agents: rules they can't contradict, the formative frontier, branch flow. | Yes |
| `CONTRIBUTING.md` | How to contribute: branches, commits, PRs and deploys to the shared org. | Yes |
| `docs/br-201-210.md` | The 10 BRs, text identical to `Sprint 2 - Nova Casa.md`, split out for quick reference. | Only if the source text changes |
| `docs/decisiones.md` | Decisions the pair made ourselves (ADR-lite): the alternative we dropped, the trade-off, the risks. This one's genuinely ours. | Yes |
| `docs/entendimiento.md` | Deliverable 1, written as the pair's own working notes: priority problem, success signals, open questions, assumptions. | Yes |
| `entregables/` | Facilitator-facing versions: `01` understanding (PDF), `02` prototype, `03` architecture (interactive guide and diagram), `04` data model. The HTML files are self-contained and open without a server. | Yes |
| `force-app/` | Salesforce code and metadata: objects, Apex, LWC, permission sets. | Yes |
| `sfdx-project.json` · `.forceignore` · `config/` | Salesforce DX project configuration. | Rarely |
| `.githooks/` | Hook that checks commit format. Turn it on once with `git config core.hooksPath .githooks`. | Rarely |

If a new doc would repeat MDSS content in different words, it doesn't get added — quote the verbatim instead.

## How we work

- **Contributing**: branches, commits, PRs and deploys follow [CONTRIBUTING.md](CONTRIBUTING.md), the same rules for us and for agents. Short version: one branch per story (`feat/us-201-receive-signals`), Conventional Commits in English, a PR approved by the other person, merged with squash.
- **`main` takes no direct commits**, ours or an agent's — everything comes in through a PR.
- **Deliverable approval**: the MDSS facilitator approves each of the 6 deliverables; an agreement between the two of us doesn't close it on its own.
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

The full `force-app` deploys only from `main`, after merging. Full rules are in [CONTRIBUTING.md](CONTRIBUTING.md#deploying-to-the-shared-org).

The org is production (Enterprise Edition, not a sandbox): Apex can't be edited in the browser, and every deploy that includes Apex runs tests that must cover at least 75% of each class. Each class ships with its test in the same PR and deploys running only our tests, with `--test-level RunSpecifiedTests --tests <ClassTest>`, never with `RunLocalTests`, which also runs the tests of the demo classes. Details are in [CONTRIBUTING.md](CONTRIBUTING.md#apex-needs-tests).

Run one class's tests without deploying:

```bash
sf apex run test --class-names <ClassTest> --code-coverage --result-format human --wait 10
```

Still to document once it exists: how to watch Platform Event processing.

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

Admins can also start it from the operator screen: **Traer señales** (needs the `Nova_Casa_Traer_Senales` custom permission and `Nova_Casa_Simulator_Integration`). It refuses to start while another run is queued or running, and shows the log rows written by result.

Follow it in Setup > Apex Jobs. The run ends on `hasMore = false`, an empty page or the page cap. Processing is the subscriber's job; a row stays `Publicada` until it has handled the event. The simulator token lives only in Setup; the session cursor is never logged or stored (see D013).

## Discovery Definition of Done

The `entregables/` prototypes, per the "Entregables" section of `Sprint 2 - Nova Casa.md`, approved by the facilitator.
