# GitHub setup

Run `scripts/protect-branch.sh --dry-run --repo astawiany/fleet-in-a-repo --reviewers login1,login2` to preview the
branch protection, the `test` / `prod` / `release` Environments and the `chart-v*` tag ruleset
(drop `--dry-run` to apply). Run it before the first release.

Defaults: one approving code-owner review, `validate.yml` checks required, rules not enforced on
admins. Options:

- `--approvals N` (0-6, default 1): approving reviews required. With 1 or more, a code-owner review
  is required too.
- `--enforce-admins`: apply the rules to admins as well (off by default).
- Tag ruleset `release-tags` (Settings > Rules > Rulesets), created by default: only repository
  admins may create, move or delete `chart-v*` tags, which trigger `release.yml`. Re-running updates
  the existing ruleset. `--no-protect-tags` skips it (prints a warning); do not use it on a
  repository that publishes. Rulesets need a plan that supports them (public repositories, or a paid
  plan for private ones); where they are unavailable the script stops at the ruleset lookup before
  changing anything, and the signing guarantee does not hold.

Solo owner: GitHub never lets authors approve their own PR, so with one maintainer use
`--approvals 0` (merges are still gated by the required checks; code-owner review is then off) and
leave `--enforce-admins` off, or you lock yourself out of `main`. You can still be the Environment
reviewer: GitHub lets you approve your own deployment unless the Environment's "Prevent
self-review" option is enabled.

## Promotion PRs (promote.yml)

1. Enable Settings > Actions > General > "Allow GitHub Actions to create and approve pull requests".
   Without it `gh pr create` fails.
2. PRs created with `GITHUB_TOKEN` do not trigger other workflows, so `validate.yml` does not run and
   the required checks stay pending. Either close and reopen the PR, or use a GitHub App token:
   - create a GitHub App with Contents and Pull requests write, install it on this repository;
   - add secrets `APP_ID` and `APP_PRIVATE_KEY`, and the repository variable
     `USE_APP_TOKEN=true`.
   `promote.yml` then mints the token with `scripts/app-token.sh` (openssl + curl, no third-party
   action) and uses it for `gh` and for the push of `promote/<env>`, so the branch is updated and
   the PR opened by the App and the checks run (also on later force-pushes to an open PR).
3. Gating: PR review + `validate.yml` checks (branch protection), and Environment approval for the
   `test` / `prod` promote jobs.

## Releases (release.yml)

- The `release` Environment gets the same required reviewers as `test` / `prod` and only accepts
  deployments from `chart-v*` tags (a deployment tag policy). The `image` and `chart` jobs both run
  in it, so a release needs two approvals, one per job.
- A half-finished release (a job failed after pushing) is not re-run: re-runs stop at the
  "version already exists" check. Bump the version and tag again
  ([docs/security.md](../docs/security.md#release-procedure)).
- The tag ruleset is the control that matters. A `chart-v*` tag runs the `release.yml` of the
  tagged commit, so a writer could push a branch with a modified `release.yml` (no `verify`, no
  Environment), tag it, and get a signature that matches the documented identity. The `verify` job
  and the Environment are procedural gates that only the reviewed `release.yml` on `main` calls.
  Release signatures are trustworthy only while the ruleset limits `chart-v*` tags to admins.
- With a single reviewer, the person who pushes the tag can approve their own release. With more
  than one reviewer, enable "Prevent self-review" on the `release` Environment
  (`prevent_self_review`).
- The `security` job of `validate.yml` is not a required check (`OPTIONAL_JOBS` in
  `scripts/protect-branch.sh`): it depends on vulnerability databases downloaded at run time.
  `release.yml` runs the same gate as a hard stop before publishing.
- Making the published packages public is a manual step after the first release:
  [docs/security.md](../docs/security.md#ghcr-packages).
