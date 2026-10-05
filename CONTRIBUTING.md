# Contributing

How we work on this repo: branches, commits, pull requests and deploys to the org we share. The same rules apply to John, Juan Diego and any AI agent working for us.

## The short version

1. One branch per story, created from an up-to-date `main`.
2. Commits follow Conventional Commits, in English, with the story as scope.
3. Every change reaches `main` through a pull request approved by the other person, merged with squash.
4. In the shared org, deploy only your story's files from your branch. The full `force-app` is deployed only from `main`.
5. Every Apex class ships with its test class: the org is production and rejects Apex deploys without coverage.

## Branches

One branch per story: a US from MDSS or one of our HP stories. If two stories can only be tested together, they share a branch named after the first one.

Name branches `type/story-short-description`, in lowercase with hyphens:

- `feat/us-201-receive-signals`
- `feat/hp-03-data-model`
- `docs/contributing`, for work that does not belong to a story

`type` uses the same list as commits. Always start from an up-to-date `main`:

```bash
git switch main
git pull
git switch -c feat/us-204-thresholds
```

`main` is protected: nobody pushes to it directly, admins included. Branches are not deleted automatically; after the merge, the author deletes the branch on GitHub and locally with `git branch -D <branch>`. It has to be `-D`: after a squash merge, Git does not find the branch's commits in `main`, so `-d` refuses to delete it.

## Commits

We use [Conventional Commits](https://www.conventionalcommits.org/), written in English:

```
type(scope): subject

Optional body: why the change was needed.

Refs: T4.1, T4.3
```

| Type | Use it for |
|---|---|
| `feat` | New behavior: objects, fields, Apex, LWC, permission sets |
| `fix` | Correcting behavior that already existed |
| `docs` | Documentation only |
| `chore` | Project setup, tooling or configuration that does not change behavior |
| `refactor` | Code changes that keep the same behavior |
| `test` | Adding or changing tests |
| `ci` | Continuous integration |

**Scope** is the story ID in uppercase: `US-201`, `HP-03`. It is required for `feat` and `fix` and optional for the other types. If a commit covers two stories of the same branch, list both: `feat(US-205,US-206): ...`.

**Subject** uses the imperative mood, names exactly what changed (the class, object, field or component) and has no period at the end. Aim for 72 characters; the hook rejects headers longer than 100.

**Footer** lists the backlog tasks the commit covers: `Refs: T4.1`.

Good:

```
feat(US-201): add SimuladorClient to page through /telemetry

Refs: T4.1
```

```
fix(US-203): keep the most severe reading when two share occurredAt

Refs: T5.4
```

```
docs: explain the shared org deploy rules
```

Not like this:

- `update stuff`: no type, and it says nothing.
- `feat: add client`: `feat` needs the story, and "client" is too vague.
- `feat(US-201): Added the simulator client.`: past tense, and it ends with a period.

Commits never carry `Co-authored-by` lines for AI tools.

### Commit hook

`.githooks/commit-msg` checks the header format and removes Cursor's co-author lines. Turn it on once per clone:

```bash
git config core.hooksPath .githooks
```

It lets merge, revert, `fixup!` and `squash!` commits through.

## Pull requests

- **Title**: the same format as a commit. With squash it becomes the commit on `main`, and GitHub does not run our hook, so check it by hand.
- **Description**: the story and tasks it covers, and how to try it, for example which simulator scenario to run.
- **Review**: the other person reviews and approves, and the author merges after the approval. PRs opened by an AI agent count as John's: Juan Diego reviews them and John merges.
- **New pushes** after an approval dismiss it, so ask for the review again.
- **Merge** with Squash and merge, the only option enabled.
- **After merging**: delete the branch, deploy `main` and move the card.

## Board and backlog

Each story is a card on the MDSS board, and each task is a row in our backlog list. They move with the work:

| Moment | MDSS card | Backlog task |
|---|---|---|
| Branch created | In Progress | En curso |
| PR opened | Code Review | En revisión |
| Merged and tested in the org | QA | Hecha |
| Evidence saved | Ready | Hecha |

Important agreements go as comments on the MDSS card.

## Deploying to the shared org

We both work on the same org, `nova-cdo`. The org keeps a single version of each component: the last one deployed. Git keeps both branches safe, but in the org one deploy can overwrite the other person's work. These steps prevent it.

1. Bring `main` into your branch before deploying, so you don't deploy old versions of what the other person already merged:

   ```bash
   git pull origin main
   ```

2. Validate first. `--dry-run` checks the deploy without changing anything:

   ```bash
   sf project deploy start --source-dir force-app/main/default/classes/Umbrales.cls --source-dir force-app/main/default/objects/Umbral__c --dry-run
   ```

3. Deploy only your story's files, with the same command and without `--dry-run`. Never deploy the whole `force-app` from a branch: it carries old copies of the other person's files.

4. After the merge, the author deploys `main` in full, so the org matches the repo again:

   ```bash
   git switch main
   git pull
   sf project deploy start --source-dir force-app --dry-run
   sf project deploy start --source-dir force-app
   ```

Shared files are changed by one person at a time: permission sets, page layouts, the app and `Case` (the intervention object, [D001](docs/decisiones.md#d001--objeto-de-intervención-case)). Whoever needs one says so in Slack, and the other waits until that PR is merged before changing it.

Nothing is changed by hand in Setup. Anything created by clicking exists only in the org, and the next deploy does not know about it. If you try something in Setup, bring it into your branch the same day:

```bash
sf project retrieve start --metadata CustomField:Log_Senial__c.Caso__c
```

Changes that are hard to undo go in their own PR, need both of us to agree and are deployed only from `main`: deleting fields or objects, changing a field's type, changing org-wide sharing, removing picklist values, deleting data.

The ingestion creates real records: readings, log entries and cases. Run it one person at a time, say so in Slack, and don't delete records the other person created.

### Apex needs tests

`nova-cdo` is a production org (Enterprise Edition, not a sandbox). Apex cannot be edited in the browser, and every deploy that includes Apex must run tests that cover at least 75% of each class and trigger in it.

- Every Apex class or trigger ships with its test class in the same PR.
- Tests use `@isTest`, check results with `Assert` and never call the simulator: `HttpCalloutMock` stands in for it.
- Deploy Apex running only our tests:

  ```bash
  sf project deploy start --source-dir force-app/main/default/classes/CatalogoService.cls --source-dir force-app/main/default/classes/CatalogoServiceTest.cls --test-level RunSpecifiedTests --tests CatalogoServiceTest --dry-run
  ```

- When deploying `main` in full, list every one of our test classes in `--tests`.
- Never use `RunLocalTests`: it also runs the tests of the demo classes that came with the org, and one failure there blocks our deploy.

To run tests without deploying:

```bash
sf apex run test --class-names CatalogoServiceTest --code-coverage --result-format human --wait 10
```

### Why a deploy shows 0 passed, 0 failed

In `nova-cdo` a deploy or `--dry-run` reports `Running Tests - Skipped` and `Passing: 0, Failing: 0, Total: 0`, even with `--test-level RunSpecifiedTests --tests ...` and even when an Apex class changed. We checked this with a dry-run that changed `CatalogoService`: still 0 tests. The org is a trial Enterprise Edition org (`IsSandbox=false`), and we believe it does not run tests on deploy, but Salesforce has not confirmed that.

So the deploy result proves only that the metadata compiles and is valid. It says nothing about the tests or the 75% coverage. After every real deploy with Apex, run the tests yourself and put that result in the PR:

```bash
sf apex run test --class-names ActivosOperadorControllerTest --code-coverage --result-format human --wait 10
```

The test summary (`Tests Ran`, `Pass Rate`) and the per-class coverage from that command are the evidence. Keep passing `--test-level RunSpecifiedTests --tests ...` on deploys anyway: if the org ever starts enforcing tests, the deploy will then run only ours.

## Decisions and secrets

- A change that departs from a sprint agreement or from the Discovery prototypes is recorded in `docs/decisiones.md` before it is merged.
- The repo is public. Never commit tokens, credentials or org data. The simulator token lives only in Setup.
