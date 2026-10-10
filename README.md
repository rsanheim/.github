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

## Set up a public gem repository

This workflow targets public repositories on GitHub.com with a `main` branch,
one root-level `<gem>.gemspec`, and Bundler's standard `vVERSION` tags. Keep this
shared repository public so callers can both invoke the workflow and check out
its helper without extra credentials.

1. Commit the gemspec, its version file, `Gemfile`, and `Rakefile` before adding
   the caller. The gemspec must load from tracked source files with Ruby alone;
   version validation runs before dependencies are installed.
2. Keep `require "bundler/gem_tasks"` in `Rakefile`, and ensure
   `bundle exec rake build` works. Do not add another publishing action or custom
   tagging task. The official action runs Bundler's release task.
3. In the gem repository's **Settings → Environments**, create `release`.
   Allow deployments from `main`. Leave required reviewers and wait timers off
   for automatic publication after merge; enabling them adds a release gate.
4. Configure the RubyGems trusted publisher using the fields below. No RubyGems
   API key, personal access token, or `secrets: inherit` is required.
5. Add the caller below. GitHub Actions policies must permit this reusable
   workflow and its actions. Repository rules must allow the workflow token to
   push version tags. Require your normal CI and `release / prepare` before
   merging version bumps; this workflow does not wait for CI on `main`.

Add this caller as `.github/workflows/release.yml` in the gem repository,
replacing `SHARED_COMMIT_SHA` with the reviewed 40-character shared commit SHA.
The gemspec is loaded from `<gem>.gemspec` at the repository root:

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      previous-ref:
        description: Tag or commit before the version increase (for retrying an unpublished release)
        required: true
        type: string
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

Replace `example` with the gem name and choose a Ruby version supported by its
dependencies. The shared code currently used by both Backspin and Deckard is
`4ced52859dd60019b930a3f2023424e77b37ee2a`; use the same reviewed pin for new
callers. Documentation-only changes do not require updating this pin.

PR validation has read-only permissions. Only the publication job receives
write/OIDC permissions. GitHub's
[`job.workflow_repository` and `job.workflow_sha` context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)
checks out the helper from the reusable workflow's pinned commit. These fields
require GitHub.com. Update the shared SHA in each consumer after reviewing a
shared workflow change.

### RubyGems trusted publisher

For an existing gem, open its **Trusted publishers** page on RubyGems.org as a
gem owner. For a gem that has never been published, create a
[pending trusted publisher](https://guides.rubygems.org/trusted-publishing/#pushing-a-new-gem-with-a-trusted-publisher)
from your RubyGems profile and also enter the intended gem name.

| Field | Value |
| --- | --- |
| Repository owner | The calling repository's owner, such as `rsanheim` |
| Repository name | The gem's repository, such as `backspin` or `deckard` |
| Workflow filename | `gem-release.yml` |
| Workflow Repository Owner | `rsanheim` |
| Workflow Repository Name | `.github` |
| Environment | `release` |

The workflow repository fields identify this reusable workflow; the repository
fields identify the calling gem repository. Use `gem-release.yml`, **not** the
caller's `release.yml`, and keep Environment exactly `release`. Save the form
and confirm the publisher appears in the list. See the
[official RubyGems reusable workflow guide](https://guides.rubygems.org/trusted-publishing/#using-reusable-workflows).
The GitHub token must also be allowed to push version tags under repository rules.

## Verify setup and release

1. Merge the caller with the gem version unchanged. The prepare job should pass
   and publication should be skipped. Both compared commits must contain a
   loadable gemspec; the initial repository commit is not a release trigger.
2. Open a version-bump PR. Without a matching changelog section, `release /
   prepare` should fail. Add real notes under `## VERSION` or
   `## [VERSION] - YYYY-MM-DD` and confirm it passes. PRs never publish.
3. Synchronize the gem's own version in committed lockfiles, including fixture
   lockfiles and any PATH/CHECKSUMS entries. Do not update unrelated dependencies.
   Run the normal tests and `BUNDLE_FROZEN=true bundle exec rake build`.
4. Review and merge. The push to `main` publishes the gem and creates a published
   GitHub release using the matching changelog body. No label, draft-release
   approval, manual tag, or release button is needed. For a brand-new gem, use
   an unpublished baseline version in the initial source, then bump to the
   intended first release in this PR.
5. Confirm the Release run passed, the `vVERSION` tag points to the merge commit,
   the GitHub release notes match the changelog, and a fresh install from
   RubyGems reports the expected version. PR validation cannot verify the
   RubyGems trust configuration; the publishing job exercises OIDC.

Backspin [0.14.0](https://github.com/rsanheim/backspin/actions/runs/38084027394)
and Deckard [0.3.1](https://github.com/rsanheim/deckard/actions/runs/38087513924)
are verified examples using this shared workflow and environment.

## Recover a failed release

If a release fails before gem publication, fix the cause and run the caller
workflow manually on `main`, with `previous-ref` set to the tag or commit before
the version increase (for example, `v0.13.0`). The normal version and changelog
checks still run. Confirm the target gem version is unpublished before retrying.

If the gem is already published and only GitHub release creation failed, finish
the GitHub release for the existing tag using the changelog notes; do not rerun
gem publication. For a trusted-publisher mismatch, compare all six saved fields
above with the workflow, especially the environment and shared repository.
