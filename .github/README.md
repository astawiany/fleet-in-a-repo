# GitHub setup

Run `scripts/protect-branch.sh --dry-run --repo owner/name --reviewers login1,login2` to preview the
branch protection and the `test` / `prod` Environments (drop `--dry-run` to apply). Replace `@OWNER` in
`CODEOWNERS` first.

## Promotion PRs (promote.yml)

1. Enable Settings > Actions > General > "Allow GitHub Actions to create and approve pull requests".
   Without it `gh pr create` fails.
2. PRs created with `GITHUB_TOKEN` do not trigger other workflows, so `validate.yml` does not run and
   the required checks stay pending. Either close and reopen the PR, or use a GitHub App token:
   - create a GitHub App with Contents and Pull requests write, install it on this repository;
   - add secrets `GITHUB_APP_ID` and `GITHUB_APP_PRIVATE_KEY`, and the repository variable
     `USE_APP_TOKEN=true`.
   `promote.yml` then mints the token with `scripts/app-token.sh` (openssl + curl, no third-party
   action) and uses it for `gh`, so the PR is opened by the App and the checks run.
3. Gating: PR review + `validate.yml` checks (branch protection), and Environment approval for the
   `test` / `prod` promote jobs.
