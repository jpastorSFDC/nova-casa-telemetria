# Sprint 2 — Nova Casa Telemetry

Current phase: **Development**, opened in MDSS on Sep 25. Discovery & Design (Sep 15–26) delivered the prototypes in `entregables/`. QA & Delivery is still locked.

Team: John Alejandro Pastor + Juan Diego Velásquez. Respond in English.

## Source of truth

Read this before designing or implementing anything. Don't invent PE fields or BR wording. Don't paraphrase MDSS content into a new doc — quote it verbatim if you need to reference it.

- `Sprint 2 - Nova Casa.md` — **verbatim** copy of the MDSS platform: brief, personas, Laura, the formative frontier, BR-201 through 210, agreements, deliverables, the simulator contract. This is the doc that wins if something doesn't match elsewhere. Only edited by hand to paste new content exactly as it arrives from MDSS.
- `docs/br-201-210.md` — the same BR-201 through 210, split into its own file for quick reference. Text identical to `Sprint 2 - Nova Casa.md`.
- `docs/decisiones.md` — decisions the pair made ourselves (not MDSS's), each with the alternative we dropped and the trade-off.

## Decision makers and flow

The MDSS facilitator approves each deliverable; an agreement between the two of us doesn't close it on its own. Before proposing an alternative to a closed agreement, log it in `docs/decisiones.md` with justification and test criteria — don't just apply it.

Branches, commits and PRs follow `CONTRIBUTING.md`, the same rules for us and for agents: one branch per story (`feat/us-201-receive-signals`), commits in Conventional Commits English with the story as scope, merged with squash after the other person approves. **`main` never takes a direct commit from an agent** — an agent's work lives on its branch until John or Juan Diego reviews it. PRs opened by an agent count as John's, so Juan Diego reviews them. Never add AI co-authorship to commits.

Remote: `origin` → github.com/jpastorSFDC/nova-casa-telemetria, **public**. Don't assume something reached GitHub until you've confirmed it on the remote. Never push anything with credentials, tokens or org data.

## Agreements the agent can't contradict

- Latest reading = **asset + measurement type**. Temperature doesn't overwrite pressure.
- Asset severity = **the highest** of its latest valid readings (a different policy only if it's justified, documented and tested).
- Identity = `source` + `messageId`. A resend shares that identity.
- Same key: doesn't update state or open an intervention. Same key with **different content** is a conflict, not a fresh alert.
- Baseline: **one intervention per unique critical message**. Consolidating different keys into one open incident is extra scope.
- A late-arriving signal: keep it as evidence; it **doesn't** overwrite current state and **doesn't** open a critical intervention. An alternative only if it separates historical from current state and has tests to back it.
- Same `occurredAt`: needs a **deterministic** tie-break (still to be defined in decisions). Don't let arrival order decide it.
- Thresholds **live outside code** (Custom Metadata or equivalent). Exact operators and values are still to be agreed.
- Publishing a PE isn't the same as processing it. The log keeps both moments separate.
- Ingestion doesn't depend on operator/admin permissions. Query-side LWC/Apex uses a different authorization path (BR-208).

## Formative frontier (mandatory in Development)

Real Platform Events from the simulator · a programmatic, bulkified Apex subscriber (up to 200) · an operator LWC · FLS/CRUD enforced in UI and server · tests that fail if the behavior they check breaks.

Prefer standard objects when they're enough. Custom objects need to earn their place in the data model.

## Development

Code and metadata live in `force-app/` (Salesforce DX project, API 67.0). We share one org, `nova-cdo`.

- Everything deployed comes from the repo. From a branch, only that story's files; the full `force-app` deploys only from `main`, after merging. Nothing gets created by hand in the org without ending up versioned.
- Validate with a dry run (`--dry-run`) before deploying, and say what you're about to push.
- Don't delete metadata or org data without explicit confirmation from John or Juan Diego.
- The prototypes in `entregables/` guide the design, but they aren't the spec — if the code departs from them, log it in `docs/decisiones.md`.
