# Shared GitHub workflows

`gem-release.yml` compares the effective gemspec version in each PR. A version
increase requires a nonempty matching section in `CHANGELOG.md`; decreases fail.
After a version-changing PR merges into `main`, it invokes
[`rubygems/release-gem@v1`](https://github.com/rubygems/release-gem) and creates the
GitHub release from that changelog section. An unchanged version skips publication.

To release, change the version in your gemspec or its required version file,
add notes under `## VERSION` or `## [VERSION] - YYYY-MM-DD`, and merge the PR after
its checks pass. Keep the normal `require "bundler/gem_tasks"` release task.
Required CI checks belong in the gem repository's branch protection or ruleset.

The official action handles authentication, runs `bundle exec rake release`, and
waits for RubyGems propagation. Bundler builds the gem, creates and pushes the
version tag, and publishes the gem. The publication job uses the default
`actions/checkout` behavior, which checks out the push's commit on `main`, so
Bundler can push the current branch. The shared workflow only detects version
changes, validates/extracts notes, invokes the action, and creates a GitHub release.

Add this caller as `.github/workflows/release.yml` in the gem repository,
replacing `SHARED_COMMIT_SHA` with the reviewed 40-character shared commit SHA.
The gemspec is loaded from `<gem>.gemspec` at the repository root:

```yaml
name: Release
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: write
  id-token: write
jobs:
  release:
    uses: rsanheim/.github/.github/workflows/gem-release.yml@SHARED_COMMIT_SHA
    with:
      gem: example
      ruby-version: '4.0.0'
```

PR validation has read-only permissions. Only the publication job receives
write/OIDC permissions. GitHub's
[`job.workflow_repository` and `job.workflow_sha` context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)
checks out the helper from the reusable workflow's pinned commit. These fields
require GitHub.com. Update the shared SHA in each consumer after reviewing a
shared workflow change.

Before the first release, configure a RubyGems trusted publisher for each gem:

| Field | Value |
| --- | --- |
| Repository owner | `rsanheim` |
| Repository name | The gem's repository, such as `backspin` or `deckard` |
| Workflow filename | `gem-release.yml` |
| Workflow Repository Owner | `rsanheim` |
| Workflow Repository Name | `.github` |
| Environment | Leave blank |

The workflow repository fields identify this reusable workflow; the repository
fields identify the calling gem repository. See the
[official RubyGems reusable workflow guide](https://guides.rubygems.org/trusted-publishing/#using-reusable-workflows).
The GitHub token must also be allowed to push version tags under repository rules.
