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

Run the Apex tests:

```bash
sf apex run test --test-level RunLocalTests --result-format human --wait 10
```

Still to document once it exists: the connection to the Heroku simulator and how to watch Platform Event processing.

## Discovery Definition of Done

The `entregables/` prototypes, per the "Entregables" section of `Sprint 2 - Nova Casa.md`, approved by the facilitator.
