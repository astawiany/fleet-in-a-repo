# Fleet-in-a-Repo

A GitOps fleet in one repository: a Cluster API management cluster creates one Kubernetes cluster per
customer and environment, Flux configures each of them from the same Git source, and versions move
dev -> test -> prod through reviewed pull requests. Everything runs locally in Docker, at no cost.

Status: the local flow (`make up`, `make smoke`, `make down`) has been run end to end. The GitHub
workflows in `.github/workflows/` are statically tested but have not yet been executed against a live
GitHub repository.

## Architecture

```mermaid
flowchart TB
  git["fleet-git (offline git server)"]
  subgraph mgmt["kind: fleet-mgmt"]
    capi["Cluster API + CAPD"]
    mflux["Flux"]
  end
  subgraph wl["CAPD workload clusters: customer x environment"]
    c1["acme-dev"]
    c2["acme-prod"]
    c3["globex-dev (full profile)"]
    c4["globex-prod (full profile)"]
  end
  git --> mflux --> capi --> wl
  git -->|"each cluster runs its own Flux"| wl
```

Details, Flux layering and the promotion diagram: [docs/architecture.md](docs/architecture.md).

## Quickstart

Prerequisites: Docker, `kind`, `clusterctl`, `flux`, `helm`, `kubectl`, `yq`, `kubeconform`, `bats`
(`scripts/preflight.sh` checks them and Docker memory). Versions are pinned in `versions.env`.

```sh
FLEET_PROFILE=lite make up      # management cluster + workload clusters, Flux everywhere
FLEET_PROFILE=lite make smoke   # acceptance checks, one PASS/FAIL line each
FLEET_PROFILE=lite make down    # removes clusters, containers, kubeconfigs
```

Drop `FLEET_PROFILE=lite` for the full profile. `make up` is idempotent. Only committed changes are
synced to the clusters (the offline git server serves git HEAD), so commit before re-running.

Measured on a 7.7 GiB Docker Desktop with the lite profile: `make up` about 7 to 8 minutes
(after the first image pulls), `make smoke` about 1.5 minutes, 12/12 checks PASS.

### Profiles

| Profile | Clusters | Docker memory | Notes |
|---|---|---|---|
| `full` (default) | acme and globex x dev and prod = 4 | at least 12 GiB | |
| `lite` | acme x dev and prod = 2 | at least 6 GiB | API-server metrics scraping disabled so Prometheus fits |

## Repository layout

| Path | Content |
|---|---|
| `capi/` | Cluster API: ClusterClass, CNI, one `Cluster` per customer x environment |
| `clusters/` | Flux entrypoint per cluster (`management/{full,lite}`, `<customer>-<env>`) |
| `infrastructure/` | Platform add-ons: cert-manager, Gateway API CRDs, NGINX Gateway Fabric, MetalLB, Prometheus + Grafana |
| `apps/demo/` | Demo app (web, api, worker): source, Helm chart, per-customer values, Flux delivery |
| `promotion/` | Version pins per environment |
| `kind/` | Management cluster config and offline git server |
| `scripts/` | `make` targets, smoke checks, promotion, CI helpers |
| `test/` | bats tests |
| `docs/` | Architecture and ADRs |
| `.github/` | Workflows, CODEOWNERS, setup notes |

## How promotion works

1. A chart version is released (`release.yml`, tag `chart-v*`) and the dev pin
   `promotion/versions/dev.yaml` is bumped by PR. After merge, the `*-dev` clusters pick it up.
2. `promote.yml` opens a PR copying the pin to `test.yaml`, then another from `test` to `prod`
   (`scripts/promote.sh <from> <to>` does the copy). Each PR needs the `validate.yml` checks and
   review; the job that opens it runs in the `test` or `prod` GitHub Environment, which has
   required reviewers.
3. There are no `*-test` clusters in 1a, so the `test` pin is a staging gate that no cluster reads yet.
4. A pin sets the `HelmRelease` image tag (and the chart version, which Flux ignores for charts from
   a Git source), so image and chart move in lockstep.

Per-customer behaviour is Helm values (`apps/demo/values/<customer>-<env>.yaml`), including feature
flags such as `FEATURE_NEW_BANNER`: code ships dark and a one-line PR enables it for one customer.

## Observability

Each workload cluster runs Prometheus and Grafana. Dashboards: `Platform health` (Flux objects,
nodes, pods, capacity) and `Demo SLIs` (latency, errors). SLO burn-rate alerts:
`DemoErrorBudgetBurnFast` and `DemoErrorBudgetBurnSlow`.

Grafana is a ClusterIP Service with the chart's default admin credentials. That is acceptable only
for this local demo. Reach it with `kubectl port-forward` and never expose it through the gateway.
For anything real, supply the admin credentials from an existing Secret.

```sh
KUBECONFIG=.work/kubeconfigs/acme-dev.yaml kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

## Acceptance checks

`make smoke` prints one `PASS|FAIL <criterion> <cluster>` line per criterion and cluster: `flux`
plus the five below (`scripts/smoke.d/`). With the lite profile that is 2 clusters x 6 = 12 lines.

| Criterion | Asserts | Honest limits |
|---|---|---|
| flux | Every Flux Kustomization and HelmRelease is Ready; a FAIL names the object | |
| compliance | demo Deployments carry the required labels, and every pod template is selected by a NetworkPolicy | demo namespace only |
| performance | p95 of 200 `GET /feature` requests is under 200 ms and all return 200 | Measured through `kubectl port-forward`, so it is an upper bound of in-cluster latency |
| resilience | After deleting one api pod, the Deployment returns to its desired Ready replicas within 60 s | Pod loss only, not node loss |
| observability | All active Prometheus targets are up and Grafana serves both dashboards | |
| security | No privileged container in the demo namespace; a default-deny ingress NetworkPolicy selects every pod | Demo namespace only: kind's kube-proxy and kindnet are privileged by design |

## CI and governance

`validate.yml` (lint, validate, test, lite smoke on a throwaway kind cluster), `promote.yml`,
`release.yml`; branch protection and Environments via `scripts/protect-branch.sh`; CODEOWNERS.
Setup steps and the `GITHUB_TOKEN` limitation: [.github/README.md](.github/README.md).
`.github/CODEOWNERS` uses the placeholder `@OWNER`; replace it with real handles before enabling
code-owner review. Flux commit-status notifications are provided as opt-in manifests in
`infrastructure/base/flux-notifications/`.

## Cost

None locally: everything runs in Docker. There is no cloud account or paid service involved.

## Demo recording

TODO (Task 12): link to the recorded demo.

## Decisions (ADRs)

1. [Flux instead of Argo CD](docs/adr/0001-flux-vs-argocd.md)
2. [Monorepo with a directory per environment](docs/adr/0002-monorepo-env-dirs.md)
3. [Feature flags as Helm values](docs/adr/0003-feature-flags-as-helm-values.md)
4. [GitHub Actions vs GitLab CI](docs/adr/0004-github-actions-vs-gitlab-ci.md)
5. [CAPD as the local provider](docs/adr/0005-capd-as-local-provider.md)

## License

[MIT](LICENSE)
