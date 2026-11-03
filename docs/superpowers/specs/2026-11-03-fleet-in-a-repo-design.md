# Fleet-in-a-Repo (portfolio sub-project 1a): Design

Date: 2026-11-03 · Status: draft for review

## 1. Purpose and context
Part of a public portfolio demonstrating Adrian Stawiany's GitOps / Kubernetes / Solutions Architecture skills. Audience: B2B clients, architect hiring managers and the open-source community. 1a is the foundation of the "reference platform" monorepo; later modules 1b (stateful DR) and 1c (Istio upgrades + Gateway API) plug into this fleet.

Constraints:
- Built from scratch, generic and public. It mirrors the patterns used in the author's professional work and contains no employer-specific detail.
- Default run target is free and local (Docker). Cloud is an optional later overlay.
- The author works mainly with GitLab; the project deliberately uses GitHub for learning value.

## 2. Goals and success criteria
- `make up` builds a management cluster, N workload clusters and a full Flux sync in about 15 minutes or less on a developer laptop.
- `make smoke` passes: all clusters `Ready`, all Flux `Kustomization`/`HelmRelease` objects reconciled, demo app responds in every cluster.
- `make down` removes everything.
- Promotion dev → test → prod works end to end through PRs, with automated PR creation.
- README contains an architecture diagram, the ADR index and a short recorded demo.

## 3. Architecture
- **Management cluster:** kind cluster running Cluster API (CAPD provider) and Flux. Bootstraps everything from this repo.
- **Workload clusters:** one per `customer × environment`, created from Cluster API templates (ClusterClass). Local default: 2 customers × 2 environments (e.g. `acme-dev`, `acme-prod`, `globex-dev`, `globex-prod`). The count is bounded by laptop resources.
- **Flux:** `clusters/<customer>-<env>/` holds each cluster's Flux `Kustomization`s, which reference `infrastructure/` and `apps/`.
- **Platform add-ons (`infrastructure/`):** cert-manager, Gateway API CRDs + an ingress implementation, MetalLB, Prometheus + Grafana.

## 4. Repository layout
```
clusters/        management/ and <customer>-<env>/ Flux entrypoints
infrastructure/  base/ + overlays/ (platform add-ons incl. observability)
apps/demo/       Helm chart + per-env, per-customer values
capi/            Cluster API templates (ClusterClass) and customer definitions
docs/adr/        architecture decision records
.github/         workflows, CODEOWNERS
Makefile         up / smoke / down
```

## 5. Demo app and per-customer config
- Generic 3-component app: web, API, worker. Independent of any employer product.
- Per-customer `HelmRelease` values override replicas, hostnames and feature flags.
- Feature flags are plain Helm values. At least one flag differs per customer, to demonstrate trunk-based development (code ships dark, enabled via a one-line PR).

## 6. CI/CD (GitHub Actions)
- `validate.yml` (on PR): `kustomize build`, `kubeconform`, `helm lint`, yamllint, and a smoke test on a throwaway kind cluster.
- `promote.yml` (on merge to `main` changing a chart version): opens the next-environment PR (dev → test → prod; `test` is a pin-file stage with no cluster in 1a) using `GITHUB_TOKEN` or a GitHub App token, with no long-lived PAT.
- `release.yml`: packages the demo chart and publishes it to GHCR (OCI).
- Governance as code: `CODEOWNERS`, branch protection with required status checks, GitHub Environments (`test`, `prod`) with required reviewers.
- Flux notification-controller reports reconciliation status to commits via the GitHub provider.
- Optional cloud stage: Actions authenticate to AWS/GCP via OIDC federation; no static cloud credentials.

## 7. Promotion flow
1. New chart version merged to `main` is deployed to `*-dev` automatically.
2. `promote.yml` opens a PR bumping the `test` pin file; after merge, another for `prod`. In 1a the `test` environment is a promotion stage only (a pin file plus a GitHub Environment gate) and has no cluster.
3. Each PR is gated by `validate.yml`. Human approval is the PR review (Environment reviewers for test/prod).

## 8. Observability
- Every workload cluster gets Prometheus + Grafana from the shared `infrastructure/` base.
- Dashboards: platform health (Flux reconciliation, node/pod capacity) and demo-app SLIs (latency, error rate).
- Alerts: a small set of SLO burn-rate rules.

## 9. ADRs to ship with 1a
1. Flux vs Argo CD (Flux chosen; Argo CD compared, not built).
2. Monorepo with directory-per-environment vs multi-repo/OCI promotion vs branch-per-environment (first chosen; others rejected with reasons).
3. Feature flags as Helm values for trunk-based development.
4. GitHub Actions vs GitLab CI: mapping table (pipelines, runners, environments, protected branches, OIDC).
5. Cluster API (CAPD) as the local stand-in for real infrastructure providers.

## 10. Testing
- Static: `kustomize build`, `kubeconform`, `helm lint`, yamllint on every PR.
- Integration: `make smoke` on kind/CAPD, run in CI on a throwaway cluster.
- Acceptance checks (inside `make smoke`, grouped by criterion): compliance (labels/policies present), performance (app latency SLI under a threshold under light load), resilience (a pod or node loss recovers), observability (Prometheus targets up, dashboards load) and security (NetworkPolicies applied, no privileged pods). Each criterion reports pass/fail separately.
- Promotion: a CI test that a chart-version change produces the expected next-environment PR diff.

## 11. Error handling and failure modes
- Failed reconciliation is surfaced by Flux status and commit statuses; smoke test fails fast with the offending object named.
- `make up` is idempotent and re-runnable; `make down` leaves no residue (containers, kubeconfigs, kind clusters).
- Resource exhaustion on small laptops is handled by a documented "lite" profile (1 customer × 2 environments).

## 12. Out of scope
- Real cloud providers (CAPA/EKS, GKE): optional overlay later.
- Stateful DR (1b), Istio upgrades and Gateway API traffic policy (1c).
- OCI-based promotion, image signing and supply-chain controls (project 4).
- Multi-tenancy hardening beyond namespace/cluster separation.

## 13. Open items
- Public repo name and license.
- Exact app implementation language (kept minimal; the focus is delivery, not the app).
- Which ingress/Gateway API implementation to use (decided in the implementation plan).
