# Task 10 report: GitHub Actions and governance

RED: `bats test/workflows.bats` before any implementation: 13 tests, 13 `not ok` (after fixing a vacuous pass in the permissions test).
GREEN: 13/13 ok; `make test` 104 tests, no `not ok`; `make lint` (validate, yamllint, shellcheck) clean; `scripts/validate.sh` OK. actionlint not installed (skipped).
Bite proof (mutations, then reverted): unguarded `gh pr create` -> test 3 fails; `checkout@main` -> test 5 fails; dry-run branch disabled -> test 10 fails; removed timeout / added secrets.MY_PAT -> tests 1, 2 fail.

Files: .github/workflows/{validate,promote,release}.yml, .github/CODEOWNERS, scripts/protect-branch.sh, scripts/ci-install-tools.sh (new, installs pinned tools from versions.env; CI pins KUBECTL/KUSTOMIZE/YQ added to versions.env), infrastructure/base/flux-notifications/{kustomization,provider,alert}.yaml + README.md (opt-in, not referenced by any default kustomization), test/workflows.bats.

Notes
- Flux 2.2.3 `flux install --export`: Provider and Alert serve v1beta1/v1beta2/v1beta3; used v1beta3.
- Actions used: only actions/checkout@v4.2.2, a tag pin (NOT SHA-verified: no offline way). Everything else is plain CLI (docker, helm, gh). Tool downloads are checksum-verified for kind, flux, helm, kubectl, kustomize; kubeconform, clusterctl, yq are TLS-only (checksum files not confirmed offline). Download URLs were not exercised (no network use).
- GITHUB_TOKEN-created promotion PRs do not trigger validate.yml: documented in validate.yml and promote.yml comments (close/reopen the PR, or use a GitHub App token via GITHUB_APP_* secrets).
- CODEOWNERS uses the documented placeholder @OWNER; owner must replace it. protect-branch.sh real mode needs --repo and --reviewers; dry-run tested with a gh stub that records and fails on any call.
- Step 5 (manual GitHub push) skipped as instructed; nothing was pushed and no GitHub API was called. Workflows are statically checked only (never executed).

## Fix round 1
- I1: promote.yml split into detect + promote-test / promote-prod jobs. Stable branch promote/<to>, fetch then `git push --force-with-lease`, existing open PR is edited instead of creating a second, per-env job concurrency (cancel-in-progress false), changed files computed from github.event.before (env:), all-zero/unreachable before treated as "all changed".
- I2: promote-test / promote-prod declare `environment: test` / `prod`; header states exactly what gates what.
- I3: header and new .github/README.md document the "Allow GitHub Actions to create and approve pull requests" setting and the GITHUB_TOKEN no-trigger limitation. Optional step (`if: vars.USE_APP_TOKEN == 'true'`) mints an App token via new scripts/app-token.sh (openssl + curl; no new third-party action); never executed here.
- Minors: CODEOWNERS catch-all `* @OWNER` first; pairing test asserts dev>test and test>prod; protect-branch empty-array guard; yamllint pinned ==1.37.1 (latest 1.38.0 on PyPI; chose previous release); release.yml adds org.opencontainers.image.source label, job output `digest` and step summary. clusterctl checksum NOT added: could not verify the release's checksum asset name offline (left TLS-only).
- Tests: workflows.bats 18/18; bite proof: environment swap, --force instead of --force-with-lease, cancel-in-progress true, and removed catch-all each made tests fail. make test and make lint pass.
