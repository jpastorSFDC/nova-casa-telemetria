# Simulator connection notes (HP-01)

What we learned about the simulator while connecting to it. The verbatim contract is in `Sprint 2 - Nova Casa.md`; this file only holds what that contract doesn't say. Never put the Bearer token or any live `X-Simulator-Cursor` value in this file.

## Session and cursor

The simulator needs a session bootstrap before paging: `POST /session` returns a `cursor`. That value must be sent as the `X-Simulator-Cursor` header on every `GET /telemetry` call. Each response's `pagination.nextCursor` is the cursor to send on the next page.

`GET /catalog` does NOT need the cursor header — it works with just the Bearer token.

This isn't in the contract example in `Sprint 2 - Nova Casa.md` — worth flagging to the MDSS facilitator as a gap, not just noting it here.

## Named Credential authentication (T1.4)

The callout was failing auth because the External Credential's Authentication Parameter name has to be exactly `BearerToken` (case-sensitive). It has to match the merge field `$Credential.Nova_Casa_Simulator.BearerToken` used in the Named Credential's Authorization header formula. Fixed; the connection authenticates correctly now. The component names are explained in D002 (`docs/decisiones.md`).

The token itself lives only in Setup, on the External Credential's principal.

## Real samples (T1.5/T1.6)

- `docs/muestras/telemetry.json`: 200 measurement records, captured via session bootstrap + cursor.
- `docs/muestras/catalog.json`: asset/scenario catalog, captured without a cursor.
