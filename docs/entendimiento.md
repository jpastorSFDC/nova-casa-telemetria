# Understanding the problem (Deliverable 1)

Personas, the reference story (Laura) and the formative frontier: see `Sprint 2 - Nova Casa.md`, sections "Problema y personas" and "Historia de referencia". Not repeated here so we don't duplicate the verbatim source.

Everything below is the pair's own read on the problem, not MDSS text.

## Priority problem

**The building operator has no single, trustworthy source for the current state of their equipment, so they react late or duplicate interventions.**

Why this one and not one of the brief's other three risks:

- It's the risk facing the person in the reference story (Laura). The facilitator picked her as the demo's required path, not the other three.
- The other three risks are downstream of this one, not independent problems:
  - The coordinator duplicates work *because* the operator (or the system) doesn't recognize an alert as already handled.
  - The manager compares data too late *because* the signal never reached the operator in time in the first place.
  - The administrator can't explain a failure *because* there's no evidence of what happened to the signal when it arrived.
- Fixing the single trustworthy source also resolves most of BR-202 through BR-209 as a side effect.

## Prototype success signals

These aren't production outcomes — there's no production yet. They're what this Discovery prototype needs to demonstrate:

1. **Real reception, not simulated**: the documented architecture shows how a signal genuinely published by the simulator reaches Salesforce and shows up in the UI prototype, with no manual capture (evidence for BR-201).
2. **Severity and staleness visible without ambiguity**: for the contract example's four messages (MSG-000101 through MSG-000104), the low-fidelity prototype distinguishes each asset's current reading from one that arrived late.
3. **Both behaviors from Laura's story are explained in the design**: how a resend avoids opening a second intervention, and how a late reading doesn't overwrite current state — without needing code to prove it, just the model and the architecture.

## Open questions

The 4 questions already logged as pending in `docs/decisiones.md` (the `occurredAt` tie-break rule, threshold values, the intervention object, the sharing model) aren't repeated here. On top of those:

- The documented contract is a synchronous `GET /api/v1/telemetry`. The brief requires "Platform Events genuinely published by the simulator." Does the simulator publish the PE directly, or do we need a bridge (something that polls the endpoint and republishes it as a PE)? That decides half the architecture and it isn't settled yet.
- Do Building/Asset objects already exist in this org from an earlier sprint, or are we starting from a clean org for this domain?
- Are "Operator," "Coordinator," "Manager" and "Administrator" Profiles/Permission Sets MDSS already provisioned, or do we need to define them ourselves?

## Assumptions

- Building and Asset are new concepts for this org — no objects from earlier sprints model building maintenance (the previous sprint modeled unit sales, not assets).
- The simulator can be pointed at our target org (token, endpoint) with no extra work on our side — MDSS provides that.
- The 200-signal batch limit (BR-202) isn't arbitrary: it matches Salesforce's per-trigger-context limit, and the design should lean on that instead of fighting a different number.
