# GitHub setup

Run `scripts/protect-branch.sh --dry-run --repo owner/name --reviewers login1,login2` to preview the
branch protection and the `test` / `prod` Environments (drop `--dry-run` to apply). Replace `@OWNER` in
`CODEOWNERS` first.

Defaults: one approving code-owner review, `validate.yml` checks required, rules not enforced on
admins. Options:

- `--approvals N` (0-6, default 1): approving reviews required. With 1 or more, a code-owner review
  is required too.
- `--enforce-admins`: apply the rules to admins as well (off by default).

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
