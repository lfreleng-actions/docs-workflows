<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Design Brief: Reusable Documentation Workflows

This document records the research phase that precedes the migration of
the Linux Foundation documentation pipeline from
`lfit/releng-reusable-workflows` into
`lfreleng-actions/docs-workflows`. It captures the goal, the evidence
gathered from production run histories, an overlap analysis of the
candidate workflows, and a proposed path forward.

No code migration has started. This brief exists to agree the shape of
the work first.

## Goal

Retire the documentation workflows in `lfit/releng-reusable-workflows`
and re-home them under `lfreleng-actions/docs-workflows`, matching the
conventions the organisation established in `python-workflows`,
`docker-workflows`, `go-workflows`, `node-workflows` and
`security-workflows`.

The migration must:

- Preserve the behaviour that ONAP and other Gerrit projects depend on.
- Fix the defects that production run histories expose.
- Move large shell blocks out of workflow YAML and into actions.
- Pass a Zizmor audit-persona scan with zero findings.
- Generalise the ONAP-specific documentation rules into a tunable,
  opt-in check.
- Replace legacy `lftools` with `lftools-uv`, run through `uvx`.
- Drop support for end-of-life Python releases.

## Source material consulted

- `onap/.github/.github/workflows/gerrit-required-merge.yaml`
- `onap/.github/.github/workflows/gerrit-required-bypassable-verify.yaml`
- `onap/.github/.github/workflows/gerrit-required-verify.yaml`
- `onap/.github/.github/workflows/gerrit-verify.yaml`
- `onap/.github/.github/workflows/doc-rules-compose.yaml`
- `lfit/releng-reusable-workflows` `gerrit-compose-required-rtdv3-verify.yaml`
- `lfit/releng-reusable-workflows` `gerrit-compose-required-rtdv3-merge.yaml`
- `lfreleng-actions/python-workflows` (`build-test.yaml`, `testing.yaml`,
  `docs/BRIEF.md`) as the convention reference.
- `lfreleng-actions/.github` (`profile/README.md`, the harden-runner
  allow-list).
- `lfreleng-actions/python-supported-versions-action`.
- `lfreleng-actions/lftools-uv` (`lftools_uv/cli/rtd.py`,
  `lftools_uv/api/endpoints/readthedocs.py`, `lftools_uv/config.py`).
- 1000 GitHub Actions runs from `onap/.github`, plus the job logs of 30
  failures.

## Current topology

ONAP drives four entry-point workflows through `gerrit_to_platform`.
Each one clears a Gerrit vote, calls one or more composed workflows,
then votes the result back:

```text
gerrit-required-merge.yaml            (merge)
  notify -> call-gerrit-rtdv3-merge -> report-status

gerrit-required-bypassable-verify.yaml (patchset)
  prepare -> { doc-rules-validation | rtd-validation } -> vote

gerrit-required-verify.yaml            (patchset)
  prepare -> change-isolation-verify -> vote

gerrit-verify.yaml                     (patchset)
  prepare -> repo-linting -> vote
```

The two documentation lanes are `call-gerrit-rtdv3-merge` (which calls
`gerrit-compose-required-rtdv3-merge.yaml`) and `rtd-validation` (which
calls `gerrit-compose-required-rtdv3-verify.yaml`). The
`doc-rules-validation` lane calls `doc-rules-compose.yaml`, which ONAP
hosts and maintains itself.

## The August incident

Commit `a59d2e4` on 2026-08-04 bumped all four call sites from `v0.7.2`
to `v0.10.1`. The commit message documents the trigger: `argcomplete`
3.7.1 reached PyPI at 15:03 UTC that day. That release declares
`requires_python >=3.8` but annotates with PEP 585 generics, so importing
it on Python 3.8 raises `TypeError`. `argcomplete` is a hard dependency
of `yq`, and the rtdv3 workflows call `yq` to parse `lftools` output.

The merge job pinned Python 3.8, an interpreter that reached end of life
in October 2024. That pin drove the ReadTheDocs API alone and never built
project documentation, so nothing a project declared justified it.
Version `v0.10.1` moved the merge job to Python 3.13 and added a
targeted `argcomplete<3.7.1` marker to the verify job for projects that
still select an old interpreter.

That marker becomes dead weight once the migration lands. The
organisation no longer supports end-of-life Python releases, and any
project still declaring 3.8 or 3.9 needs an update rather than a
workaround in shared tooling.

Runs 30923735831 (`cps`) and 30927237668 (`cps/ncmp-dmi-plugin`) show the
original signature:

```text
TypeError: 'ABCMeta' object is not subscriptable
##[error]Process completed with exit code 1.
```

That fix worked. A second, older defect remains.

## The merge lane still fails

Runs 31377825907 (2026-08-10) and 31495243438 (2026-08-11) both post-date
the fix and both fail:

```text
INFO: Checking if read the docs has seen branch maintenance/3.7.10
jq: error (at <stdin>:1): Cannot index string with string "active"
INFO: triggering onap-cps maintenance/3.7.10
INFO: Running build against branch maintenance/3.7.10
##[error]Process completed with exit code 5.
```

Every ongoing merge failure in the sample carries the same two
attributes: project `cps`, branch `maintenance/3.7.10`.

ReadTheDocs converts a slash in a branch name into a hyphen when it
builds a version slug. The live API confirms this:

```text
slug=maintenance-3.7.10  verbose_name=maintenance/3.7.10  active=False
slug=mr-879-126960-2     verbose_name=mr/879/126960/2     active=False
```

The workflow passes the raw branch name into the API path, so
`lftools rtd project-version-details onap-cps maintenance/3.7.10`
requests a path that does not resolve. The endpoint returns a string
body rather than an object, `jq '.active'` cannot index it, and the step
exits 5. The same fault then hits `watchbuild`, where `jq '.build.id'`
fails the same way.

Two defects compound here:

1. The workflow never converts a branch name to a ReadTheDocs slug.
2. The workflow never checks that `lftools` returned an object before
   piping it to `jq`, so an API error surfaces as a cryptic `jq` message
   rather than a diagnosis.

Any project with a slash in a branch name hits this. ONAP uses
`maintenance/*` branches, so this is not an edge case.

The `lftools-uv` signature names the parameter accurately, which
underlines the point:

```python
def project_version_details(ctx, project_slug, version_slug):
```

The API contract asks for a slug. The workflow hands it a verbose name.

## Moving to `lftools-uv`

The rtdv3 workflows install legacy `lftools` from PyPI into the job
interpreter. `lftools-uv` replaces it. PyPI carries version 0.5.2, which
declares `requires-python >=3.11,<3.15`.

Every ReadTheDocs subcommand the workflows call exists in `lftools-uv`
with an identical name:

| Command                       | Present |
| ----------------------------- | ------- |
| `rtd project-details`         | Yes     |
| `rtd project-version-details` | Yes     |
| `rtd project-version-update`  | Yes     |
| `rtd project-create`          | Yes     |
| `rtd project-update`          | Yes     |
| `rtd project-build-trigger`   | Yes     |
| `rtd project-build-details`   | Yes     |
| `rtd subproject-list`         | Yes     |
| `rtd subproject-create`       | Yes     |

The console script changes from `lftools` to `lftools-uv`, so each call
site needs a rename. The package name and the script name match, which
makes the `uvx` invocation direct:

```bash
uvx lftools-uv rtd project-build-trigger "$project_slug" "$version_slug"
```

Running through `uvx` keeps DevOps tooling out of the job interpreter.
That matters more here than in most pipelines: the verify lane installs
tooling into the same interpreter that tox uses to build a project's
documentation. `uvx` resolves its own interpreter, so the tooling
version and the documentation version stop interfering. **This removes
the structural cause of the August outage rather than the symptom.**

`lftools-uv` reads `lftools.ini` from the `platformdirs` user config
directory, falling back to `~/.config/lftools` and migrating the old
location when it finds one. The existing heredoc that writes the token
keeps working, though the new action should write to the current
location directly.

### A naive swap breaks the merge lane

`lftools-uv` ships two command-line implementations. The entry point
defaults to a Typer application and falls back to the legacy Click tree
when `LEGACY_CLI=1` appears in the environment:

```python
if os.environ.get("LEGACY_CLI") == "1":
    cli(obj={})
else:
    from lftools_uv.cli_app import app as typer_app
    typer_app()
```

The Typer `rtd` group covers four commands. The Click group covers
fourteen. Running the command the merge lane depends on confirms the gap:

```console
$ uvx lftools-uv rtd project-build-trigger onap-cps latest
No such command 'project-build-trigger'.
Did you mean 'project-update', 'project-list'?

$ LEGACY_CLI=1 uvx lftools-uv rtd --help
  project-build-details    Retrieve specific project build details.
  project-build-list       Retrieve a list of a project's builds.
  project-build-trigger    Trigger a new build.
  ...
```

| Command the workflows call | Click | Typer                    |
| -------------------------- | ----- | ------------------------ |
| `project-details`          | Yes   | Yes, different output    |
| `project-create`           | Yes   | Yes, different signature |
| `project-update`           | Yes   | Yes, different signature |
| `project-version-details`  | Yes   | Missing                  |
| `project-version-update`   | Yes   | Missing                  |
| `project-build-trigger`    | Yes   | Missing                  |
| `project-build-details`    | Yes   | Missing                  |
| `subproject-list`          | Yes   | Missing                  |
| `subproject-create`        | Yes   | Missing                  |

Six of the nine commands the pipeline needs exist in the legacy tree
alone. The Typer `project-create` takes two positional arguments and two
options where Click takes six positional arguments, and its
`project-details` prints labelled prose rather than a parsable structure.
A comment in the Typer source marks the state of the work:

```python
# Note: The actual API signature may differ - this is a placeholder implementation
```

Swapping `lftools` for `lftools-uv` without further work fails. Setting
`LEGACY_CLI=1` restores the commands but pins the pipeline to the
implementation the project intends to retire.

**The RTD refactor is a prerequisite for this migration, not an
optional improvement.**

### The output contract explains the outage

The workflows parse command output with two different tools, and the
reason repays study. `lftools_uv/api/endpoints/readthedocs.py` returns
JSON text from most endpoints:

```python
def project_version_details(self, project: str, version: str) -> str:
    ...
    return json.dumps(result, indent=2)
```

But `project_details` returns a dictionary, and the CLI layer prints it
with `pprint.pformat`:

```python
data = r.project_details(project_slug)
log.info(pformat(data))
```

Python renders a dictionary with single quotes, which `jq` rejects.
That one command forces the workflows to install `yq`, and every `yq`
call site targets `project-details`:

```bash
lftools rtd project-details "$rtdproject" | yq -r '.detail'
lftools rtd project-details "$rtdproject" | yq -r .default_version
```

The remaining calls use `jq`, because those endpoints emit real JSON.

The outage chain follows from that single formatting choice:

```text
project-details returns a dict -> CLI pformats it -> output is not JSON
  -> workflow installs yq -> yq depends on argcomplete
  -> argcomplete 3.7.1 breaks on Python 3.8 -> merge job dies
```

### The inconsistency runs through the whole command group

`project-details` is not an isolated case. Auditing all fourteen `rtd`
commands against their endpoints reveals five different output shapes:

<!-- markdownlint-disable MD013 -->

| Command                   | Endpoint returns       | CLI renders with     | Shape          |
| ------------------------- | ---------------------- | -------------------- | -------------- |
| `project-list`            | `list[str]`            | loop over `log.info` | Bare lines     |
| `project-details`         | `dict`                 | `pformat`            | Python literal |
| `project-version-list`    | `list[str]`            | loop over `log.info` | Bare lines     |
| `project-version-update`  | `ApiResponse`          | `log.info`           | Object repr    |
| `project-version-details` | `str` via `json.dumps` | `log.info`           | JSON           |
| `project-create`          | `dict`                 | `pformat`            | Python literal |
| `project-update`          | `tuple[bool, int]`     | `pformat`            | Python literal |
| `project-build-list`      | JSON **or** a sentence | `log.info`           | JSON or prose  |
| `project-build-details`   | `str` via `json.dumps` | `log.info`           | JSON           |
| `project-build-trigger`   | `str` via `json.dumps` | `log.info`           | JSON           |
| `subproject-list`         | `list[str]`            | loop over `log.info` | Bare lines     |
| `subproject-details`      | `dict`                 | `pformat`            | Python literal |
| `subproject-create`       | `ApiResponse`          | `pformat`            | Object repr    |
| `subproject-delete`       | `bool` or tuple        | English sentence     | Prose          |

<!-- markdownlint-enable MD013 -->

Three commands emit JSON. Four emit Python literals. Three emit bare
lines. Two emit an object repr. Two emit prose.

`project-build-list` deserves attention: it returns JSON when builds
exist and the sentence `There are no active builds.` when none do. A
parser that handles the happy path breaks on the empty one. The same
pattern as the `jq` failure ONAP hits today.

A second hazard sits in the logging configuration. The root logger holds
a single handler pointed at stdout:

```python
console_handler = logging.StreamHandler(sys.stdout)
```

INFO records format as bare `%(message)s`, so JSON survives the trip
today. But warnings and errors travel the same stream, as does any INFO
record from a library attached to the root logger. One `urllib3` warning
corrupts the output a caller is parsing.

### Recommendation: refactor the RTD stack, do not carry it forward

Carrying this inconsistency into new workflows repeats the mistake that
broke ONAP. The defects also sit deeper than the command layer, so a
cosmetic fix would leave the cause in place.

The stack has four layers, and each carries a different amount of debt:

<!-- markdownlint-disable MD013 -->

| Layer     | File                           | State                                   |
| --------- | ------------------------------ | --------------------------------------- |
| REST base | `api/client.py`                | Sound. Typed verbs, body helpers        |
| Endpoints | `api/endpoints/readthedocs.py` | Mixed return types, 13 tests            |
| Click CLI | `cli/rtd.py`                   | Complete, five output shapes            |
| Typer CLI | `typer_apps/rtd.py`            | Four of fourteen commands, prose output |

<!-- markdownlint-enable MD013 -->

`api/client.py` needs no work. The problem begins one layer up.
`project_version_details` returns `json.dumps(result, indent=2)`, a
serialised string, while `project_details` returns a `dict` and
`project_update` returns a `tuple[bool, int]`. An endpoint layer that
serialises for presentation forces every caller to guess a format.

#### Target shape

**Endpoints return typed data.** `dict` or `list[T]` throughout, never a
pre-serialised string, never an `ApiResponse`, never English prose.
`project_build_list` returns an empty list rather than
`There are no active builds.`, and a missing project raises rather than
returning a sentence a caller must string-match.

**Failures raise typed exceptions.** `api/exceptions.py` holds a single
class today. Adding `ReadTheDocsNotFound` and a status-carrying error
lets callers test a condition instead of comparing prose, and removes the
divergent `Not found.` and `No Project matches the given query.` checks
the two lanes use now.

**One command tree, with a machine-readable mode.** Complete the Typer
`rtd` group to fourteen commands on the refactored endpoints, and give it
the `--json` treatment the Zulip app already established:

```python
def emit_json(payload: Any) -> None:
    """Print a JSON payload to stdout with indent=2 (FR-008)."""
    typer.echo(json.dumps(payload, indent=2, sort_keys=False, default=str))
```

`typer_apps/zulip.py` places `--json` on the group callback and on each
command, renders a table for humans, and routes errors through a typed
handler. That is the current house pattern, and `rtd` should match it
rather than invent a third convention.

**Payloads to stdout, diagnostics to stderr.** The Typer app already
uses `typer.echo(..., err=True)` for errors, which the Click app does
not.

#### Handling backwards compatibility

Three routes, with the trade-offs that matter here:

<!-- markdownlint-disable MD013 -->

| Route                                               | Compatibility | Cost                      |
| --------------------------------------------------- | ------------- | ------------------------- |
| A. Complete Typer, keep Click behind `LEGACY_CLI`   | Full          | Two trees to maintain     |
| B. Complete Typer, deprecate then remove Click      | Windowed      | One tree after the window |
| C. Add a parallel `readthedocs` group, freeze `rtd` | Full          | Two names forever         |

<!-- markdownlint-enable MD013 -->

**Route B suits this case.** The usual argument for preserving legacy
behaviour is weak here: anyone calling `lftools-uv rtd
project-build-trigger` today already fails, because the default CLI lacks
the command. Preserving a path that nobody can reach by default protects
nothing.

A workable sequence:

1. Refactor the endpoint layer to typed returns and typed exceptions.
   Update the 13 existing tests, which already cover every method.
2. Build the Typer `rtd` group to full parity on the new endpoints, with
   `--json` and stderr diagnostics. Match the Click argument signatures
   to keep the command surface familiar.
3. Keep the Click group working against the same endpoints for one
   release, emitting a deprecation warning.
4. Remove `cli/rtd.py` in the following release.

Step 2 delivers what the workflows need. Steps 3 and 4 can follow at
whatever pace suits the wider `lftools-uv` roadmap, so the documentation
migration does not wait on them.

#### What this buys the pipeline

With `--json` on every command, the documentation pipeline parses
everything with `jq`. `yq` leaves the dependency tree, `argcomplete`
leaves with it, and `niet` goes too. The pipeline installs `tox` and
nothing else beyond the `uvx`-managed `lftools-uv`.

The slug conversion and the status checks belong in the endpoint layer
rather than in shell, which means unit tests cover them and no future
workflow can forget them.

### Two further defects in the same code

The workflows install `niet~=1.4.2` and never call it. The dependency
can go.

The two lanes test different sentinel strings for the same condition:

```bash
# merge
if [[ "$(... | yq -r '.detail')" == "No Project matches the given query." ]]
# verify
if [[ "$(... | yq -r '.detail')" == "Not found." ]]
```

One of these no longer matches what the API returns. Comparing prose
from an error body is fragile in any case; the new action should test the
HTTP status instead.

## Failure taxonomy from production

Sample of 500 runs per workflow, taken 2026-08-13.

<!-- markdownlint-disable MD013 -->

| Workflow                            | Success | Failure | Cancelled | Failure rate |
| ----------------------------------- | ------- | ------- | --------- | ------------ |
| `gerrit-required-merge`             | 477     | 21      | 2         | 4.2%         |
| `gerrit-required-bypassable-verify` | 452     | 31      | 17        | 6.2%         |

<!-- markdownlint-enable MD013 -->

### Merge lane failures (21)

<!-- markdownlint-disable MD013 -->

| Cause                                           | Count | Verdict                   |
| ----------------------------------------------- | ----- | ------------------------- |
| Slash in branch name (`jq` index error, exit 5) | 7     | Defect, open              |
| `argcomplete` on Python 3.8                     | 4     | Fixed in `v0.10.1`        |
| Runner `Set up job` failure                     | 2     | Infrastructure            |
| Gerrit vote or notify step                      | 8     | Credential or replication |

<!-- markdownlint-enable MD013 -->

### Verify lane failures (31)

<!-- markdownlint-disable MD013 -->

| Cause                                           | Count | Verdict                         |
| ----------------------------------------------- | ----- | ------------------------------- |
| `docs-linkcheck` reports a broken external link | 14    | Content, but brittle            |
| `dpkg` lock contention under parallel tox       | 3     | Defect, addressed by `PARALLEL` |
| Remote constraints URL returns an HTTP error    | 3     | Defect, no retry                |
| Sphinx configuration error                      | 1     | Content                         |
| Runner `Set up job` failure                     | 4     | Infrastructure                  |
| Gerrit vote step                                | 2     | Credential or replication       |
| Other tox failure                               | 4     | Mixed                           |

<!-- markdownlint-enable MD013 -->

### What the taxonomy tells us

**Broken external links dominate.** Fourteen of 31 verify failures come
from `sphinx-build -W -b linkcheck` treating an unreachable third-party
URL as a hard error. Run 31620519039 fails on three GitHub URLs; run
31046081548 fails on a `cert-manager.io` documentation page. A change
author gains nothing from a `-1` vote caused by an unrelated website. The
new workflow should let a project soften link checking, either by
downgrading `docs-linkcheck` to advisory or by retrying before the job
votes.

**The `PARALLEL` input has a concrete origin.** Run 30391046034 shows
`docs` and `docs-linkcheck` both running `sudo apt-get install -y
graphviz` at the same time:

```text
E: Could not get lock /var/lib/dpkg/lock-frontend.
docs-linkcheck: exit 100 (0.01 seconds)
```

The `v0.10.1` `PARALLEL` input lets a project serialise its way out of
this. A better fix removes the cause: the workflow already installs
graphviz through `tlylt/install-graphviz` before tox starts, so the
project-side `apt-get` is redundant. The migrated workflow should install
system packages once, ahead of tox, and document that projects can drop
the step from `tox.ini`.

**Remote constraint fetches have no retry.** Run 31503654544 raises a
tox internal error inside `urlopen` while reading a remote `-c`
constraints URL. One HTTP hiccup against a constraints host fails the
whole job.

**Gerrit voting accounts for 10 of 52 failures.** The notify, clear and
vote steps repeat verbatim across all four ONAP workflows. Consolidating
that boilerplate reduces both the duplication and the blast radius of a
credential problem.

## Overlap between the verify and merge lanes

The two rtdv3 workflows share most of their body:

<!-- markdownlint-disable MD013 -->

| Stage                                        | Verify                                          | Merge                       |
| -------------------------------------------- | ----------------------------------------------- | --------------------------- |
| Checkout                                     | Gerrit change (`checkout-gerrit-change-action`) | Branch (`actions/checkout`) |
| Resolve docs Python version                  | Yes, from `tox.ini` and `.readthedocs.yaml`     | No, hardcoded 3.13          |
| Install graphviz                             | Yes                                             | Yes                         |
| Detect `.readthedocs.yaml`                   | Yes                                             | Yes                         |
| Install `lftools`, `niet`, `yq`, `tox`       | Yes                                             | Yes                         |
| Run tox (`docs`, `docs-linkcheck`)           | Yes                                             | No                          |
| Write `lftools.ini` from `RTD_TOKEN`         | Yes                                             | Yes                         |
| Derive umbrella, project and master names    | Yes, identical code                             | Yes, identical code         |
| ONAP naming exception (`onap-doc` to `onap`) | Yes                                             | Yes                         |
| `watchbuild` helper                          | Declared, unused                                | Yes                         |
| Query project details                        | Probe without writing                           | Create when absent          |
| Create subproject relationship               | No                                              | Yes                         |
| Set default version                          | No                                              | Yes                         |
| Trigger and watch a build                    | No                                              | Yes                         |
| Activate a discovered branch                 | No                                              | Yes                         |

<!-- markdownlint-enable MD013 -->

Close to 70% of the two files match line for line. The `watchbuild`
function sits in the verify workflow despite no caller. The umbrella
derivation, the ONAP exception and the `lftools.ini` heredoc appear
twice, the two lanes test different sentinel strings for a missing
project, and the Python-version drift between them caused the August
outage: the verify lane moved off Python 3.8 while the merge lane stayed
behind.

**Recommendation: merge the two into one workflow with a `mode` input**
(`verify` or `merge`). A single file removes the drift that caused the
incident. The differences reduce to three gates:

- Checkout style follows the presence of a Gerrit refspec, which the
  workflow can already detect.
- The tox run gates on `mode == 'verify'`.
- The ReadTheDocs mutations gate on `mode == 'merge'`.

## The ONAP documentation rules

`doc-rules-compose.yaml` runs 278 lines of inline shell across seven
steps. It checks that a project provides `docs/index.rst`, `docs/conf.py`,
`docs/requirements-docs.txt`, `docs/_static/css/ribbon.css`,
`.readthedocs.yaml` and `docs/tox.ini`; that `docs/conf.yaml` has gone;
that `ribbon.css` sets `max-width: 800px`; that `sphinx-build` carries
`-W`; and that `.readthedocs.yaml` avoids obsolete keys.

Three problems stand out.

**The checks bake in ONAP policy.** The `ribbon.css` rule, the
`max-width: 800px` value, the ONAP wiki URLs and the required file list
suit ONAP alone. No other project can adopt the workflow unchanged.

**The ReadTheDocs checks use fragile string matching.** The Python
version check greps for any line starting with `python:` and tests
whether the result contains a literal version:

```bash
buildtoolspython=$(grep '^[ \t]*python:' $filename | ...)
if [[ ! $buildtoolspython == *\"3.13\"* ]]; then
```

A `python:` key under `build.tools` and a `python:` key elsewhere both
match. The obsolete `version: 3.7` check greps for any `version:` key
anywhere in the file. The `submodules:` check rejects a key that current
ReadTheDocs configurations use legitimately.

**The version policy is a hardcoded constant.** `RTD_PYTHON_VERSION:
'3.13'` and `RTD_BUILD_UBUNTU: 'ubuntu-24.04'` live in the workflow `env`
block. Each Python release forces an edit here, in every consumer, and
the file already carries the scars of the last transition: two checks
print `log_failure_msg "⚠️ Warning: ..."` while a comment explains that
versions no longer count as errors. The workflow reports a failure string
for a non-failure.

The rules deserve to survive, but not in this form.

**Recommendation: extract the rules into a
`readthedocs-config-audit-action`**, a composite action that parses
`.readthedocs.yaml` as YAML rather than by grep, and takes the policy as
input:

<!-- markdownlint-disable MD013 -->

| Input                               | Purpose                                       | Default        |
| ----------------------------------- | --------------------------------------------- | -------------- |
| `path_prefix`                       | Project root                                  | `.`            |
| `required_files`                    | Newline list of files a project must ship     | Empty          |
| `forbidden_files`                   | Newline list of files a project must not ship | Empty          |
| `build_os`                          | Expected `build.os` value                     | Empty (skip)   |
| `python_version`                    | Expected `build.tools.python` value           | Empty (derive) |
| `python_eol_behaviour`              | `warn`, `strip` or `fail`                     | `warn`         |
| `require_sphinx_warnings_as_errors` | Enforce `-W` in `docs/tox.ini`                | `false`        |
| `fail_on_warning`                   | Turn warnings into a non-zero exit            | `false`        |

<!-- markdownlint-enable MD013 -->

With empty defaults the action checks the parts of a configuration that
every project shares, and ONAP supplies its own file list and CSS rule
through inputs.

## Auditing ReadTheDocs Python versions

`python-supported-versions-action` already solves the hard part of the
version policy. It queries `https://endoflife.date/api/python.json`,
falls back to an internal list when the network fails, and exposes an
`eol_behaviour` input with `warn`, `strip` and `fail` modes. It emits
`build_python`, `matrix_json`, `supported_versions` and
`versions_source`.

The action reads `requires-python` from `pyproject.toml`, with fallbacks
to `setup.cfg` and `setup.py` classifiers. It does not read
`.readthedocs.yaml`, and it reports a supported set rather than judging a
supplied version string.

Two routes forward:

1. **Reuse as a data source.** The new audit action calls
   `python-supported-versions-action` with `offline_mode` matching its
   own, reads `supported_versions`, and compares the parsed
   `build.tools.python` value against that set. This keeps one EOL data
   source for the organisation and needs no change upstream.
2. **Extend the existing action.** Teach it to read `.readthedocs.yaml`
   as another metadata source, and add an input that validates a caller
   supplied version.

Route 1 keeps the responsibilities apart and avoids growing a 39k action
file further. This brief recommends route 1.

The same approach retires the hardcoded `RTD_PYTHON_VERSION`. Rather
than asserting Python 3.13, the audit reports whether the configured
version has reached end of life, so the check stays correct without
edits as releases age.

## Convention gaps

The `lfit` workflows predate the current organisation standards. The
migration must close these gaps:

<!-- markdownlint-disable MD013 -->

| Convention        | `lfit` today                           | `lfreleng-actions` standard                |
| ----------------- | -------------------------------------- | ------------------------------------------ |
| SPDX header       | Present                                | Present, with the current year             |
| Workflow name     | `Compose rtdv3 Verify`                 | `[R] Documentation Build` style            |
| Input naming      | `SCREAMING_SNAKE_CASE`                 | `snake_case`                               |
| Job names         | Absent (Zizmor flags this)             | Explicit `name:` on every job              |
| `permissions`     | Absent at workflow and job level       | `permissions: {}` plus per-job grants      |
| `timeout-minutes` | Absent                                 | Required by a `check-jsonschema` hook      |
| harden-runner     | Absent                                 | Every job, block mode, central allow-list  |
| Shell code        | 250 inline lines                       | Composite actions                          |
| Tooling install   | `pip install` into the job interpreter | `uvx`, isolated from the project           |
| RTD tooling       | Legacy `lftools`                       | `lftools-uv`                               |
| Testing           | Absent                                 | `testing.yaml` against live consumers      |
| Examples          | Absent                                 | `examples/` with Gerrit and GitHub callers |

<!-- markdownlint-enable MD013 -->

The harden-runner pattern from `python-workflows` gives the target shape:

<!-- markdownlint-disable MD013 -->

```yaml
- name: 'Load harden-runner allow-list'
  uses: lfreleng-actions/harden-runner-block-action@6db537b3e6d060c3287c5a3ce2c28b55b0af330d  # v0.2.1
  with:
    config: ${{ inputs.harden_runner_allowlist }}
- name: 'Harden runner (block)'
  if: inputs.harden_runner_egress != 'audit'
  uses: step-security/harden-runner@9af89fc71515a100421586dfdb3dc9c984fbf411  # v2.19.4
  with:
    egress-policy: 'block'
    allowed-endpoints: >
      ${{ env.CONNECTION_ALLOW_LIST }}
```

<!-- markdownlint-enable MD013 -->

The allow-list default points at a pinned path in the organisation
`.github` repository:

```text
lfreleng-actions//.github/harden-runner/lfreleng-actions/allow_list.txt@18d9c4446bea555d0783e850f6d295f844fe8f67
```

That file holds 514 lines. A documentation pipeline reaches
`readthedocs.org`, PyPI and every host a project links to during
`docs-linkcheck`, so the allow-list needs review before block mode goes
live. Link checking against arbitrary hosts and egress blocking pull in
opposite directions. The `docs-linkcheck` job may need `audit` mode while
the rest of the pipeline blocks.

## Zizmor baseline

Audit-persona scans of the three candidate files:

<!-- markdownlint-disable MD013 -->

| File                                        | Findings | High | Medium | Low | Info |
| ------------------------------------------- | -------- | ---- | ------ | --- | ---- |
| `gerrit-compose-required-rtdv3-verify.yaml` | 10       | 3    | 2      | 4   | 1    |
| `gerrit-compose-required-rtdv3-merge.yaml`  | 14       | 6    | 3      | 4   | 1    |
| `doc-rules-compose.yaml`                    | 13       | 0    | 2      | 10  | 1    |

<!-- markdownlint-enable MD013 -->

Categories across all three:

- `template-injection` — the dominant finding. Expressions such as
  `${{ inputs.GERRIT_PROJECT }}` and `${{ inputs.GERRIT_CHANGE_URL }}`
  expand into `run:` blocks. Moving shell into composite actions with
  `env:` bindings resolves most of these, and matches the organisation
  policy on inline shell.
- `excessive-permissions` — no `permissions` block anywhere.
- `artipacked` — the merge workflow leaves credentials in the checkout.
- `anonymous-definition` — jobs carry no `name:`.

A forklift migration fails the zero-findings bar. The fixes
align with work the migration needs regardless.

## Proposed path forward

### Deliverables

<!-- markdownlint-disable MD013 -->

| File                                | Purpose                                           |
| ----------------------------------- | ------------------------------------------------- |
| `.github/workflows/docs-build.yaml` | Consolidated verify and merge lanes, `mode` input |
| `.github/workflows/docs-audit.yaml` | Configuration policy audit, callable alone        |
| `examples/docs-build/gerrit.yaml`   | Gerrit caller                                     |
| `examples/docs-build/github.yaml`   | GitHub-native caller                              |
| `.github/workflows/testing.yaml`    | Exercises both against live consumers             |
| `docs/DOCS_WORKFLOWS_BRIEF.md`      | This brief                                        |

<!-- markdownlint-enable MD013 -->

### New actions

<!-- markdownlint-disable MD013 -->

| Action                            | Responsibility                                          |
| --------------------------------- | ------------------------------------------------------- |
| `readthedocs-config-audit-action` | Parse and police `.readthedocs.yaml`                    |
| `readthedocs-build-action`        | Drive the ReadTheDocs API, replacing inline rtdv3 shell |
| `docs-python-version-action`      | Reconcile `tox.ini` and `.readthedocs.yaml` versions    |

<!-- markdownlint-enable MD013 -->

Splitting the rtdv3 shell into `readthedocs-build-action` removes the
largest `template-injection` surface, gives the slug conversion a home,
and lets tests cover the API interaction without a workflow run.

### Defects to fix during migration

1. Convert branch names to ReadTheDocs slugs before any API call.
2. Check command output before piping to `jq`, and report the API
   response on failure.
3. Test HTTP status rather than error prose when probing for a project.
4. Install system packages once, before tox, and drop the redundant
   project-side `apt-get`.
5. Retry remote constraint and dependency fetches.
6. Offer an advisory mode for `docs-linkcheck`.
7. Drop the unused `watchbuild` function from the verify path.
8. Drop the unused `niet` dependency.
9. Drop the `argcomplete` marker, along with end-of-life Python support.
10. Replace `log_failure_msg "⚠️ Warning: ..."` with a warning that reads
    as a warning.

### Upstream change required

The `lftools-uv` RTD stack needs the refactor described above before the
migration can rely on it: typed endpoint returns, typed exceptions, a
complete Typer `rtd` group, and `--json` output. The Typer group lacks
six of the nine commands the pipeline calls, so this work gates the
migration rather than merely improving it.

### Sequencing

1. Refactor the `lftools-uv` RTD stack: typed endpoints, typed
   exceptions, complete Typer group, `--json` output. Ship to PyPI.
2. Land the three actions with tests, built against that release.
3. Land `docs-workflows` with the consolidated workflow and examples.
4. Point `onap/.github` at the new workflows behind a pinned SHA, one
   lane at a time, starting with the merge lane that fails today.
5. Retire the `lfit` documentation workflows once ONAP runs clean.
6. Remove the legacy Click `rtd` group after its deprecation window.

Step 1 gates step 2. The slug fix that unblocks ONAP lands in step 1,
which gives the failing merge lane its repair ahead of the wider work.

## Open questions

1. **Vote boilerplate.** The notify, clear and vote jobs repeat across
   all four ONAP entry points. Does that pattern belong in
   `docs-workflows`, or in a shared Gerrit workflow that every lane
   calls?
2. **ONAP naming exception.** The `onap-doc` to `onap` rewrite sits in
   shared code. An input such as `rtd_project_override` would generalise
   it. Do other projects carry similar exceptions?
3. **Egress policy for link checking.** Does `docs-linkcheck` run in
   `audit` mode, or does the allow-list grow to cover project links?
4. **`mode` input versus two files.** This brief recommends one file with
   a `mode` input. The `python-workflows` precedent kept build and
   release apart because their job graphs differ. The documentation lanes
   overlap far more, which argues for consolidation. Confirm the call.
5. **Adoption beyond ONAP.** Which other Gerrit projects consume the
   rtdv3 workflows, and do their branch names or configurations differ in
   ways this brief has not covered?
6. **Other `lftools` RTD callers.** Jenkins jobs in the legacy estate may
   call `lftools rtd`. Confirm the consumer list before the Click group
   reaches removal, since route B assumes the documentation workflows are
   the main caller.
7. **Scope of the endpoint refactor.** This brief covers the RTD
   endpoints alone. The same mixed-return pattern may affect the Nexus
   and Gerrit endpoint classes. Worth a look, though not in this effort.
