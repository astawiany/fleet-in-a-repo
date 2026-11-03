# ADR 4: GitHub Actions for CI, with a GitLab CI mapping

Status: accepted

## Context

The repository is public and hosted on GitHub, so its pipelines are GitHub Actions. This ADR is
written for GitLab practitioners: it maps the GitLab CI concepts they know onto GitHub's, and says
where this repo uses each. The workflows in `.github/workflows/` have been statically tested
(`test/workflows.bats`) but not yet executed against a live GitHub repository.

## Decision

Use GitHub Actions: `validate.yml` (pull requests), `promote.yml` (pushes to `main` that change
`promotion/versions/dev.yaml` or `test.yaml`), `release.yml` (tags `chart-v*`). Governance is set up
by `scripts/protect-branch.sh` and `.github/CODEOWNERS`; setup steps are in
[.github/README.md](../../.github/README.md).

| Concern | GitLab CI | GitHub Actions | In this repo |
|---|---|---|---|
| Pipeline definition | `.gitlab-ci.yml`, stages and jobs | `.github/workflows/*.yml`, one file per workflow, jobs run in parallel unless `needs:` | `validate.yml` jobs `lint`, `validate`, `test`, `smoke`; `promote.yml`; `release.yml` |
| Triggers | `rules:`, `workflow:rules` | `on:` (`pull_request`, `push` with `branches`/`paths`/`tags`, `workflow_dispatch`) | `promote.yml` uses a `paths:` filter on the pin files |
| Runners | Shared or group/project runners, tags | GitHub-hosted runners (`runs-on: ubuntu-latest`) or self-hosted | `ubuntu-latest`; the `smoke` job needs Docker and runs the lite profile |
| Reusable logic | `include:`, `extends:`, templates | Reusable workflows, composite actions | Shell scripts (`scripts/ci-install-tools.sh`) so the same commands run locally and in CI |
| Environments and approvals | `environment:` plus protected environments with approvers | `environment:` on a job; required reviewers on the Environment | Jobs in `promote.yml` run in Environments `test` and `prod`; reviewers are set by `protect-branch.sh` |
| Protected branches | Protected branch rules, merge request approvals, required pipelines | Branch protection or rulesets, required status checks, CODEOWNERS review | Required checks are the `validate.yml` job ids; CODEOWNERS (replace the `@OWNER` placeholder) |
| Merge request / PR | Merge request | Pull request | Promotion creates PRs with `gh pr create` |
| Secrets and variables | CI/CD variables (masked, protected) | Secrets and Variables at repo, org or Environment level | `APP_ID`, `APP_PRIVATE_KEY` secrets, `USE_APP_TOKEN` variable (optional) |
| Job token | `CI_JOB_TOKEN` | `GITHUB_TOKEN`, with per-workflow `permissions:` | Least-privilege `permissions:` per workflow and job |
| Registry | GitLab container/package registry | GHCR (`ghcr.io`) | `release.yml` pushes the chart (OCI) and the app image to GHCR |
| Cloud auth (OIDC) | `id_tokens:` with `aud`, trust configured in the cloud | `permissions: id-token: write`, cloud trusts the repo/environment claim | Not used in 1a (nothing deploys to a cloud); it is the intended path for a later cloud stage |

Two behaviours differ in ways that matter for promotion:

- **Events caused by `GITHUB_TOKEN` do not start workflows.** A PR opened by `promote.yml` with the
  default token does not trigger `validate.yml`, so the required checks stay pending. Either close
  and reopen the PR, or let `promote.yml` mint a GitHub App token (repository variable
  `USE_APP_TOKEN=true`, secrets `APP_ID` and `APP_PRIVATE_KEY`, `scripts/app-token.sh`); the PR is
  then opened by the App and checks run. The repo setting "Allow GitHub Actions to create and
  approve pull requests" must also be on.
- **Environment reviewers gate jobs, not merges.** A job with `environment: prod` waits for the
  Environment's reviewers before it starts; the PR it opens is additionally gated by branch
  protection and review.

## Consequences

- Pipelines are plain YAML plus shell scripts, which keeps local and CI behaviour identical.
- Setup that lives in the GitHub UI or API (branch protection, Environments, the App) is scripted or
  documented, not committed as state. It has to be applied once per repository.
- Action versions are pinned by tag with a note to switch to commit SHAs once online.

## Alternatives

- **GitLab CI.** Equally capable, and the author's primary day-to-day experience. Not used because
  the project is published on GitHub for visibility and as a learning exercise; the table above
  is the migration map in either direction.
- **No CI, local scripts only.** Rejected: promotion and branch protection are the point.
