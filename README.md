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
| `docs/simulador.md` | What we learned connecting to the simulator that the MDSS contract doesn't say: session and cursor, Named Credential auth, real samples (`docs/muestras/`). | Yes |
| `entregables/` | Facilitator-facing versions: `01` understanding (PDF), `02` prototype, `03` architecture (interactive guide and diagram), `04` data model. The HTML files are self-contained and open without a server. | Yes |
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

The org is production: every Apex class ships with its test and deploys with `RunSpecifiedTests`, never `RunLocalTests`. The rules and commands are in [CONTRIBUTING.md](CONTRIBUTING.md#apex-needs-tests).

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

## Discovery Definition of Done

The `entregables/` prototypes, per the "Entregables" section of `Sprint 2 - Nova Casa.md`, approved by the facilitator.
