# Shared GitHub workflows

`gem-release.yml` checks the effective gemspec version in each PR. A version
increase requires a nonempty matching section in `CHANGELOG.md`; decreases fail.
When the PR merges into `main`, the workflow waits for the configured external
CI statuses on that exact commit, creates `vVERSION` at the same commit, runs
the official `rubygems/release-gem@v1` action, and publishes the matching changelog
section as the GitHub release. Merges without a version change stop after the
version check.

To release, change the version in your gemspec or its required version file,
add release notes under `## VERSION` or `## [VERSION] - YYYY-MM-DD`, and merge
the PR after its checks pass. There are no release labels or post-merge version
commits. Keep your gem's normal `require "bundler/gem_tasks"` release task.

Add this thin caller as `.github/workflows/release.yml` in the gem repository,
replacing `SHARED_COMMIT_SHA` with the same reviewed 40-character shared commit
SHA in every consumer. Only the four inputs vary by gem:

```yaml
name: Release
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: write
  pull-requests: read
  statuses: read
  id-token: write
jobs:
  release:
    uses: rsanheim/.github/.github/workflows/gem-release.yml@SHARED_COMMIT_SHA
    with:
      gem: example
      gemspec: example.gemspec
      ruby-version: '4.0.0'
      required-statuses: '["external/test"]'
```

The shared workflow reduces permissions for its PR/version-check job to read
only. OIDC and write access are granted only to its publication job. GitHub's
[`job.workflow_repository` and `job.workflow_sha` context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)
checks out the helper from exactly the reusable workflow's pinned commit.
These fields require GitHub.com; GitHub Enterprise Server is unsupported.
Updating a shared workflow means reviewing and updating the single SHA in each
consumer; no implementation is copied into gem repositories.

Before the first release, configure a RubyGems trusted publisher for **each gem**.
For the Backspin and Deckard integrations, use these fields:

| Field | Value |
| --- | --- |
| Repository owner | `rsanheim` |
| Repository name | `backspin` or `deckard`, matching the gem's repository |
| Workflow filename | `gem-release.yml` |
| Workflow Repository Owner | `rsanheim` |
| Workflow Repository Name | `.github` |
| Environment | Leave blank |

The extra workflow repository fields identify this reusable workflow; the
repository fields still identify the calling gem repository. See the
[official RubyGems reusable workflow guide](https://guides.rubygems.org/trusted-publishing/#using-reusable-workflows).
This repository does not configure or verify the RubyGems account settings.
The GitHub token must also be allowed to push version tags under repository rules.

Re-run a failed release workflow after fixing its cause. An existing version tag
must point to the original merged commit. If RubyGems already has the version,
the rebuilt gem must match its registered SHA256 before publication is skipped
and any missing GitHub release is completed. Builds use the merged commit's
timestamp (`SOURCE_DATE_EPOCH`) so retry comparison is reproducible. Conflicting
tags or gem bytes fail for manual investigation; tags and published versions are
never replaced. Publication jobs queue without canceling active releases (up to
GitHub's 100 pending-job limit). Direct version-changing pushes are rejected;
merge commits, squash merges, and rebased PR merges are resolved by their exact
GitHub merge SHA.

Run `ruby script/gem_release_test.rb` to test version detection, changelog rules,
exact commit selection, CI failures, tag conflicts, and publication retries.
The tests use disposable local Git fixtures and mock all network operations;
they never push a tag, upload a gem, or create a GitHub release.
`actionlint` 1.7.12 needs the two narrow exclusions shown in the test workflow
because it predates `job.workflow_*` and `concurrency.queue`. Those fields are
documented GitHub.com features, not custom workflow syntax.
