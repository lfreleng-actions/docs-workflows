<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 📚 Documentation Workflows

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/docs-workflows) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/docs-workflows/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/docs-workflows)
<!-- prettier-ignore-end -->

Reusable workflows that check and publish Sphinx documentation through
ReadTheDocs, for projects using either GitHub or Gerrit as the source of
truth.

## Reusable workflows

<!-- markdownlint-disable MD013 -->

| Workflow                            | Purpose                                | Trigger style                   |
| ----------------------------------- | -------------------------------------- | ------------------------------- |
| `.github/workflows/docs-build.yaml` | Audit, build and publish documentation | Patchset, pull request or merge |
| `.github/workflows/docs-audit.yaml` | Configuration policy audit alone       | Any                             |

<!-- markdownlint-enable MD013 -->

## One workflow, two lanes

`docs-build.yaml` takes a `mode` input rather than splitting into two
files. The `verify` lane audits the configuration, builds the
documentation locally and probes ReadTheDocs without changing anything.
The `merge` lane audits, then publishes.

Until now the lanes lived in two workflows that shared most of their
body. They drifted, and in August 2026 the drift broke every
documentation merge across ONAP: the verify copy had moved off an
end-of-life Python while the merge copy had not. A single file removes
that class of failure.

Jobs in `{ }` run in parallel; `->` denotes sequence:

```text
verify:  audit -> { docs | linkcheck | readthedocs }
merge:   audit -> readthedocs
```

The audit resolves the documentation Python version and the location of
the tox file, then passes both to the jobs that follow. Both builds then
use the same interpreter, and the build runs from wherever the project
keeps its documentation environments: `docs/tox.ini` where one exists,
otherwise `tox.ini` at the root.

## Usage

Call from a thin caller workflow. See `examples/docs-build/` for a
GitHub-native caller, a Gerrit verify wrapper and a Gerrit merge wrapper.

<!-- markdownlint-disable MD046 -->

```yaml
jobs:
  docs:
    permissions:
      contents: read
    uses: lfreleng-actions/docs-workflows/.github/workflows/docs-build.yaml@<sha>
    with:
      mode: ${{ github.event_name == 'push' && 'merge' || 'verify' }}
    secrets:
      RTD_TOKEN: ${{ secrets.RTD_TOKEN }}
```

<!-- markdownlint-enable MD046 -->

## Gerrit projects

The workflows are Gerrit-aware for checkout: pass `gerrit_refspec`,
`gerrit_project`, `gerrit_branch` and `gerrit_url` and every
checkout-bearing job fetches the unmerged change rather than the branch.

**Voting stays in the caller.** The reusable workflows never receive a
Gerrit SSH key; the wrapper clears the vote, calls the workflow and votes
the conclusion. This matches the pattern the sibling `*-workflows`
repositories follow.

`examples/docs-build/gerrit.yaml` shows the verify wrapper and
`gerrit-merge.yaml` the merge wrapper. Copy them into
`.github/workflows/` with filenames `gerrit_to_platform` can discover:
one containing both `gerrit` and `verify`, the other both `gerrit` and
`merge`.

## Link checking

`linkcheck_advisory` defaults to `true`, so a failing link check reports
without blocking.

External sites increasingly refuse automated requests, classing them as
unwanted crawler traffic. A link check that fails the build on an
unreachable URL reports another site's bot policy as a fault in the
change under review, and the author can do nothing about it. In a sample
of 500 production runs, broken third-party links accounted for the
largest single group of documentation failures.

Set `linkcheck_advisory: false` to make link failures block, or
`linkcheck_enabled: false` to skip the check.

The audit reports separately when a project sets `-W` on its linkcheck
tox environment, which turns the same third-party unreliability into a
hard failure inside the project's own configuration.

## Runner hardening

Every job loads the organisation egress allow-list and runs
harden-runner in block mode, except the link-check job.

A link check contacts whichever hosts the documentation links to, which
no allow-list can list ahead of time, so that job runs in audit mode.
Blocking there would defeat the check rather than secure it.

`harden_runner_egress: audit` relaxes the remaining jobs when a project
needs to observe its egress before committing to a block list.

## Inputs

`docs-build.yaml` requires `mode` alone. Every other input carries a
default that suits a project following the Linux Foundation
documentation layout.

<!-- markdownlint-disable MD013 -->

| Group       | Inputs                                                                                                                                                                               |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Lane        | `mode`                                                                                                                                                                               |
| Checkout    | `repository`, `ref`                                                                                                                                                                  |
| Gerrit      | `gerrit_refspec`, `gerrit_project`, `gerrit_branch`, `gerrit_url`                                                                                                                    |
| Layout      | `path_prefix`, `tox_dir`, `docs_tox_env`, `linkcheck_tox_env`                                                                                                                        |
| Build       | `docs_enabled`, `linkcheck_enabled`, `linkcheck_advisory`                                                                                                                            |
| Audit       | `audit_enabled`, `audit_required_files`, `audit_forbidden_files`, `audit_build_os`, `audit_python_version`, `audit_eol_behaviour`, `audit_linkcheck_policy`, `audit_fail_on_warning` |
| ReadTheDocs | `rtd_enabled`, `rtd_project`, `rtd_parent_project`, `rtd_parent_suffix`, `rtd_project_overrides`, `rtd_default_version`, `rtd_default_branch`, `lftools_version`                     |
| Hardening   | `harden_runner_egress`, `harden_runner_allowlist`                                                                                                                                    |
| Timeouts    | `docs_timeout_minutes`, `rtd_timeout_minutes`                                                                                                                                        |

<!-- markdownlint-enable MD013 -->

Secrets: `RTD_TOKEN`, required when `rtd_enabled` stays true.

Outputs: `docs_python`, `audit_passed`, `documentation_url`.

## ReadTheDocs naming

The workflow supplies `gerrit_project` and `gerrit_url` to
[`rtd-build-action`][rtd-build], which derives the ReadTheDocs slugs from
them. A project needs no naming configuration in the common case.

Set `rtd_project` or `rtd_parent_project` to bypass derivation, or
`rtd_project_overrides` for a project following no derivable rule.

## Composition

The workflows carry no shell beyond input validation. The work lives in
actions, so tests cover it without a workflow run:

<!-- markdownlint-disable MD013 -->

| Action                                           | Role                                                                  |
| ------------------------------------------------ | --------------------------------------------------------------------- |
| [rtd-config-audit-action][rtd-audit]             | Parses `.readthedocs.yaml`, resolves the documentation Python version |
| [rtd-build-action][rtd-build]                    | Drives the ReadTheDocs API for both lanes                             |
| [tox-run-action][tox-run]                        | Runs the documentation and link-check environments                    |
| [checkout-gerrit-change-action][checkout-gerrit] | Fetches an unmerged Gerrit change                                     |
| [harden-runner-block-action][harden-block]       | Loads the organisation egress allow-list                              |

<!-- markdownlint-enable MD013 -->

## Testing

`.github/workflows/testing.yaml` exercises both workflows against a real
documentation project by local path, so a pull request validates the
branch under review.

The ReadTheDocs legs stay disabled there. Reaching the API needs a token
a fork may not hold, and the merge lane would create and build real
ReadTheDocs projects, which a test run has no business doing.
`rtd-build-action` covers that behaviour with its own suite against an
in-memory double.

[rtd-audit]: https://github.com/lfreleng-actions/rtd-config-audit-action
[rtd-build]: https://github.com/lfreleng-actions/rtd-build-action
[tox-run]: https://github.com/lfreleng-actions/tox-run-action
[checkout-gerrit]: https://github.com/lfreleng-actions/checkout-gerrit-change-action
[harden-block]: https://github.com/lfreleng-actions/harden-runner-block-action

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/docs-workflows/main
<!-- markdownlint-disable-next-line MD013 -->
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/docs-workflows/main.svg
