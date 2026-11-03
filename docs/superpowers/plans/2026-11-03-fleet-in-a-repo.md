# Fleet-in-a-Repo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a public, reproducible GitOps fleet: a kind management cluster running Cluster API (CAPD) and Flux that creates per-customer, per-environment workload clusters, delivers a 3-component demo app with promotion PRs, and verifies it all with `make smoke`.

**Architecture:** One monorepo (`fleet-in-a-repo/`). Flux on the management cluster reconciles `clusters/management/`, which creates workload clusters from Cluster API templates; each workload cluster syncs `clusters/<customer>-<env>/` which pulls shared `infrastructure/` and `apps/demo`. Promotion is a version-pin file per environment bumped by CI-opened PRs on GitHub Actions.

**Tech Stack:** kind, Cluster API (CAPD), Flux, Helm, Kustomize, cert-manager, NGINX Gateway Fabric (Gateway API), MetalLB, kube-prometheus-stack, Go (demo app), bash, GitHub Actions, GHCR, kubeconform, yamllint, bats-core.

**Spec:** `docs/superpowers/specs/2026-11-03-fleet-in-a-repo-design.md`

## Global Constraints

- Built from scratch, generic and public: no employer names, hostnames, charts or internal detail anywhere in the repo.
- Default run target is local Docker only (kind + CAPD); no cloud credentials needed. Local default is 2 customers × 2 environments (`acme-dev`, `acme-prod`, `globex-dev`, `globex-prod`); a documented "lite" profile is 1 customer × 2 environments.
- GitHub Actions is the CI platform; no long-lived PATs (use `GITHUB_TOKEN` or a GitHub App token); cloud auth, if ever added, is OIDC only.
- Flux only for GitOps; Argo CD appears only in an ADR.
- Monorepo, directory-per-environment, PR-based promotion; feature flags are plain Helm values.
- `make up` ≤ ~15 min on a laptop; `make up` is idempotent; `make down` leaves no kind clusters, containers or kubeconfig entries.
- All tool and chart versions live in one file, `versions.env`; container images pinned by digest where a digest exists.
- Repo root is the `fleet-in-a-repo/` directory (a new git repo; no files from outside it may be added). Copy the spec and this plan into its `docs/` in Task 1.

## Review Focus

- Customer or environment name that is not a valid DNS label (uppercase, underscore, >63 chars): validation must fail with the offending name, not produce a broken cluster.
- Re-running `make up` on a half-built or fully built fleet: no duplicate clusters, no errors.
- `make down` when nothing was ever brought up: exit 0, no error noise.
- Promotion run when the target environment already pins the same version: no commit, no PR.
- A HelmRelease that fails to reconcile: `make smoke` fails and names the object and cluster.
- Missing prerequisite tool (docker, kind, clusterctl, flux, helm, kubectl) or Docker with too little memory: `make up` stops early with an actionable message and points to the lite profile.

---

### Task 1: Repo bootstrap, tooling gate, lint

**Files:**
- Create: `fleet-in-a-repo/{Makefile,versions.env,LICENSE,.gitignore,.yamllint.yaml,scripts/preflight.sh,test/preflight.bats,docs/superpowers/specs/…,docs/superpowers/plans/…}`

**Interfaces:**
- Produces: `versions.env` (shell-sourceable `KEY=value` lines: `KIND_VERSION`, `CLUSTERCTL_VERSION`, `FLUX_VERSION`, `HELM_VERSION`, `KUBECONFORM_VERSION`, `CERT_MANAGER_VERSION`, `GATEWAY_API_VERSION`, `NGF_VERSION`, `METALLB_VERSION`, `KPS_VERSION`); `scripts/preflight.sh [--profile full|lite]` exits 0/1; Make targets `lint`, `test`, `up`, `smoke`, `down` (later tasks fill `up/smoke/down`).
- Produces: env var `FLEET_PROFILE` (`full` default, `lite`) read by all scripts; profile → customer list is defined only in `scripts/lib.sh` as `customers()` printing one name per line (`acme globex` / `acme`).

- [ ] **Step 1:** `git init` in `fleet-in-a-repo/`, add MIT `LICENSE` (confirm license with the user first; spec §13 leaves it open), `.gitignore` (kubeconfigs, `.work/`), copy spec and plan into `docs/superpowers/`.
- [ ] **Step 2: Write failing bats tests** in `test/preflight.bats`: `preflight fails naming "kind" when kind is missing from PATH`; `preflight fails and mentions "--profile lite" when Docker memory < 8 GiB (stub docker info)`; `preflight passes with all stubs present`.
- [ ] **Step 3: Run** `bats test/preflight.bats` — Expected: FAIL (script missing).
- [ ] **Step 4: Implement** `scripts/preflight.sh` (checks docker, kind, clusterctl, flux, helm, kubectl, kubeconform on PATH; docker memory via `docker info --format '{{.MemTotal}}'`; min 12 GiB for `full`, 6 GiB for `lite`; message names the missing tool or suggests lite) and `scripts/lib.sh` with `customers()`.
- [ ] **Step 5: Implement** `make lint` = `yamllint .` plus `shellcheck scripts/*.sh`; `make test` = `bats test/`.
- [ ] **Step 6: Run** `make lint test` — Expected: PASS.
- [ ] **Step 7: Commit** `chore: bootstrap repo, preflight and lint`.

### Task 2: Demo app (Go)

**Files:**
- Create: `apps/demo/src/{go.mod,main.go,server.go,server_test.go,worker.go}`, `apps/demo/src/Dockerfile`

**Interfaces:**
- Produces: binary `demo` with `--mode web|api|worker`, env `FEATURE_NEW_BANNER` (`true`/`false`), `PORT` (default 8080).
- Produces HTTP contract (web and api modes): `GET /healthz` → 200 `ok`; `GET /feature` → JSON `{"new_banner": bool}`; `GET /metrics` → Prometheus text including `http_requests_total{code}` and `http_request_duration_seconds` histogram. Worker mode exposes only `/healthz` and `/metrics` (counter `worker_jobs_total`).

- [ ] **Step 1: Write failing Go tests** in `server_test.go`: `TestHealthz` (200, body `ok`), `TestFeatureFlagOn` / `TestFeatureFlagOff` (env drives JSON), `TestMetricsExposeRequestHistogram` (after one request, body contains `http_request_duration_seconds_bucket`), `TestInvalidPortFallsBackTo8080`.
- [ ] **Step 2: Run** `cd apps/demo/src && go test ./...` — Expected: FAIL.
- [ ] **Step 3: Implement** `func NewHandler(mode string, newBanner bool) http.Handler` in `server.go` and `func RunWorker(ctx context.Context, interval time.Duration)` in `worker.go`; use `prometheus/client_golang`.
- [ ] **Step 4: Run** `go test ./...` — Expected: PASS.
- [ ] **Step 5:** Multi-stage `Dockerfile` (distroless, non-root, digest-pinned base); `docker build` succeeds.
- [ ] **Step 6: Commit** `feat(app): demo web/api/worker binary`.

### Task 3: Helm chart and per-customer values

**Files:**
- Create: `apps/demo/chart/{Chart.yaml,values.yaml,templates/*}`, `apps/demo/values/<customer>-<env>.yaml` (for the four default clusters), `test/chart.bats`

**Interfaces:**
- Consumes: image contract from Task 2.
- Produces: chart `demo` with values `{replicas: {web,api,worker}, hostname, image: {repository, tag}, features: {newBanner: bool}}`; templates for 3 Deployments, 2 Services, one `HTTPRoute` for `hostname` whose `parentRefs` name Gateway `fleet-gateway` in namespace `nginx-gateway` (the Gateway itself is created in Task 6 from `infrastructure/base/nginx-gateway-fabric/`, GatewayClass `nginx`), `NetworkPolicy` (default-deny ingress + allow web→api), `ServiceMonitor` for all three.

- [ ] **Step 1: Write failing bats tests** (`helm template` + grep/yq): `acme-dev renders FEATURE_NEW_BANNER=true and globex-dev renders false`; `prod renders replicas 2 for web and dev renders 1`; `every Deployment has non-root securityContext and no privileged container`; `a NetworkPolicy exists`; `hostname from values appears in the HTTPRoute`.
- [ ] **Step 2: Run** `bats test/chart.bats` — Expected: FAIL.
- [ ] **Step 3: Implement** chart and the four values files (hostnames `demo.<customer>-<env>.fleet.test`; at least one flag differs between customers).
- [ ] **Step 4: Run** `helm lint apps/demo/chart` and `bats test/chart.bats` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(chart): demo chart with per-customer values`.

### Task 4: Validation script (`make validate`)

**Files:**
- Create: `scripts/validate.sh`, `test/validate.bats`, `test/fixtures/bad-name/…`

**Interfaces:**
- Produces: `scripts/validate.sh [path…]` — runs `kustomize build` on every dir containing `kustomization.yaml`, pipes to `kubeconform -strict -ignore-missing-schemas`, `helm lint`; also asserts every `clusters/<name>/` directory and every `capi/customers/*.yaml` name matches `^[a-z][a-z0-9-]{0,62}$` (error message includes the offending name). Make target `validate`.

- [ ] **Step 1: Write failing bats tests:** `validate fails naming "Acme_Prod" for an invalid cluster dir name` (fixture), `validate fails on a manifest with an unknown field`, `validate passes on the repo`.
- [ ] **Step 2: Run** `bats test/validate.bats` — Expected: FAIL.
- [ ] **Step 3: Implement** `validate.sh`; wire `make validate`; include it in `make lint`.
- [ ] **Step 4: Run** `bats test/validate.bats` — Expected: PASS (the "passes on the repo" case may stay skipped until Task 6; mark with `skip` and remove the skip in Task 6).
- [ ] **Step 5: Commit** `feat: manifest validation with name rules`.

### Task 5: Cluster API templates and management cluster

**Files:**
- Create: `capi/clusterclass/capd-clusterclass.yaml`, `capi/customers/<customer>-<env>.yaml` (one `Cluster` per workload cluster referencing the ClusterClass), `capi/kustomization.yaml`, `scripts/mgmt-up.sh`, `scripts/mgmt-down.sh`, `kind/mgmt.yaml`

**Interfaces:**
- Consumes: `scripts/lib.sh customers()`, `versions.env`.
- Produces: `scripts/mgmt-up.sh` (idempotent): create kind cluster `fleet-mgmt` if absent, `clusterctl init --infrastructure docker` at `CLUSTERCTL_VERSION` if not initialized, install Flux and bootstrap it against the repo (`flux bootstrap github` when `GITHUB_REPOSITORY` is set, otherwise an in-cluster git source pointing at a local `.work/` bare repo for offline runs). `scripts/mgmt-down.sh` deletes `fleet-mgmt` and any CAPD leftovers; exit 0 when nothing exists. Kubeconfigs for workload clusters written by Cluster API are exported to `.work/kubeconfigs/<name>.yaml`.

- [ ] **Step 1: Write failing bats tests** with stubbed `kind`/`clusterctl`/`flux` recording calls: `mgmt-up twice calls kind create once`; `mgmt-down with no cluster exits 0 and prints nothing to stderr`; `mgmt-up with FLEET_PROFILE=lite only references the acme cluster`.
- [ ] **Step 2: Run** `bats test/mgmt.bats` — Expected: FAIL.
- [ ] **Step 3: Implement** scripts and templates; `kubectl kustomize capi/` renders one `Cluster` per customer×env.
- [ ] **Step 4: Run** `bats test/mgmt.bats` and `scripts/validate.sh capi` — Expected: PASS.
- [ ] **Step 5: Real run (manual verification):** `scripts/mgmt-up.sh` then `kubectl --context kind-fleet-mgmt get clusters -A` shows the clusters reaching `Provisioned`.
- [ ] **Step 6: Commit** `feat(capi): ClusterClass, customer clusters, management bootstrap`.

### Task 6: Flux layout and platform add-ons

**Files:**
- Create: `clusters/management/`, `clusters/<customer>-<env>/{flux-system,infrastructure.yaml,apps.yaml}`, `infrastructure/base/{cert-manager,gateway-api-crds,nginx-gateway-fabric,metallb,monitoring}/…`, `infrastructure/overlays/<env>/kustomization.yaml`

**Interfaces:**
- Consumes: Cluster names from Task 5; versions from `versions.env`.
- Produces: each workload cluster has two Flux `Kustomization`s — `infrastructure` (path `infrastructure/overlays/<env>`, `wait: true`) and `apps` (path `apps/demo/flux/<customer>-<env>`, `dependsOn: infrastructure`). The `gateway-api-crds` component (Gateway API standard-channel CRDs at `GATEWAY_API_VERSION`) must reconcile before `nginx-gateway-fabric` (`dependsOn` between their Flux Kustomizations). `nginx-gateway-fabric` also creates Gateway `fleet-gateway` (GatewayClass `nginx`, HTTP listener on port 80, routes allowed from namespace `demo`). Namespaces: `cert-manager`, `nginx-gateway`, `metallb-system`, `monitoring`, `demo`.
- Produces: management cluster Kustomization `workload-clusters` reconciling `capi/`, and a per-cluster Flux bootstrap step that points the new cluster at its `clusters/<name>/` path (a `ClusterResourceSet` or `flux bootstrap` run from `mgmt-up.sh --sync-workloads`; choose one and record in ADR 5).

- [ ] **Step 1:** Remove the `skip` in `test/validate.bats` "passes on the repo"; run `bats test/validate.bats` — Expected: FAIL (layout absent).
- [ ] **Step 2: Implement** the directories as HelmRepository/HelmRelease pairs per add-on (MetalLB address pool derived from the kind docker network, via a small `scripts/metallb-pool.sh <cluster>` that prints a CIDR slice).
- [ ] **Step 3: Run** `make validate` — Expected: PASS.
- [ ] **Step 4: Real run (manual verification):** `flux get kustomizations -A --context kind-fleet-mgmt` and per-workload-cluster `flux get helmreleases -A` all `Ready=True`.
- [ ] **Step 5: Commit** `feat(flux): cluster entrypoints and platform add-ons`.

### Task 7: App delivery and promotion pins

**Files:**
- Create: `apps/demo/flux/<customer>-<env>/{kustomization.yaml,helmrelease.yaml}`, `promotion/versions/{dev,test,prod}.yaml`, `scripts/promote.sh`, `test/promote.bats`

**Interfaces:**
- Produces: `promotion/versions/<env>.yaml` containing `chart: {version: X.Y.Z}`; each HelmRelease reads its version via Kustomize replacement from the env's pin file and values from `apps/demo/values/<customer>-<env>.yaml` (`valuesFrom` ConfigMap).
- Produces: `scripts/promote.sh <from-env> <to-env>` — copies the pinned version from `<from>` to `<to>`; exits 0 and prints `no change` when equal; otherwise modifies only `promotion/versions/<to>.yaml` and prints `bumped <to> to <version>`.

- [ ] **Step 1: Write failing bats tests:** `promote dev→test changes only test.yaml`; `promote when versions equal prints "no change" and leaves the tree clean`; `promote with unknown env exits non-zero naming the env`; `HelmRelease for acme-prod renders chart version from prod.yaml` (kustomize build + yq).
- [ ] **Step 2: Run** `bats test/promote.bats` — Expected: FAIL.
- [ ] **Step 3: Implement** script and Flux manifests.
- [ ] **Step 4: Run** `bats test/promote.bats` and `make validate` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(apps): HelmRelease delivery and promotion pins`.

### Task 8: Observability

**Files:**
- Create: `infrastructure/base/monitoring/{dashboards/platform.json,dashboards/demo-slis.json,dashboards-configmap.yaml,slo-rules.yaml}`, `test/observability.bats`

**Interfaces:**
- Consumes: metrics from Task 2 (`http_requests_total`, `http_request_duration_seconds`); `ServiceMonitor`s from Task 3.
- Produces: Grafana dashboards `Platform health` (Flux reconcile status, node/pod capacity) and `Demo SLIs` (p95 latency, error rate) loaded via sidecar label `grafana_dashboard: "1"`; `PrometheusRule` `demo-slo` with two burn-rate alerts (`DemoErrorBudgetBurnFast`, `DemoErrorBudgetBurnSlow`).

- [ ] **Step 1: Write failing bats tests:** `dashboard JSON files parse`; `PrometheusRule contains alerts DemoErrorBudgetBurnFast and DemoErrorBudgetBurnSlow`; `every alert expr references http_requests_total`; `promtool check rules passes` (extract rules, run `promtool`).
- [ ] **Step 2: Run** `bats test/observability.bats` — Expected: FAIL.
- [ ] **Step 3: Implement** dashboards and rules.
- [ ] **Step 4: Run** `bats test/observability.bats` and `make validate` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(observability): dashboards and SLO burn-rate alerts`.

### Task 9: `make up`, `make down`, and `make smoke` with acceptance checks

**Files:**
- Create: `scripts/up.sh`, `scripts/down.sh`, `scripts/smoke.sh`, `scripts/smoke.d/{10-compliance,20-performance,30-resilience,40-observability,50-security}.sh`, `test/smoke.bats`

**Interfaces:**
- Consumes: kubeconfigs in `.work/kubeconfigs/`, `customers()`.
- Produces: `scripts/up.sh` = preflight → mgmt-up → wait for clusters `Ready` → wait for all Flux objects ready; `scripts/down.sh` = mgmt-down, remove `.work/`, remove stale kubeconfig contexts. `scripts/smoke.sh` runs each `smoke.d/*.sh` per cluster, prints `PASS|FAIL <criterion> <cluster> [object]`, exits non-zero if any FAIL. Criteria: compliance (required labels on demo workloads, NetworkPolicy present), performance (p95 of `/feature` over 200 requests < 200 ms), resilience (delete one api pod; Deployment back to desired replicas within 60 s), observability (Prometheus targets up; both dashboards present), security (no privileged pods; default-deny policy applied). Also asserts every Flux Kustomization/HelmRelease `Ready`, naming any that are not.

- [ ] **Step 1: Write failing bats tests** with stubbed `kubectl`/`flux`: `smoke fails and names HelmRelease demo/acme-prod when it is not Ready`; `smoke prints one PASS/FAIL line per criterion per cluster`; `up stops at preflight failure before creating anything`; `down on an empty machine exits 0`.
- [ ] **Step 2: Run** `bats test/smoke.bats` — Expected: FAIL.
- [ ] **Step 3: Implement** scripts; point Make `up`/`smoke`/`down` at them.
- [ ] **Step 4: Real run (manual verification):** `time make up && make smoke && make down` on a clean Docker; `make up` finishes ≤ ~15 min, smoke all PASS, `kind get clusters` empty after down. Repeat `make up` twice in a row (idempotence).
- [ ] **Step 5: Commit** `feat: up/down/smoke with acceptance checks`.

### Task 10: GitHub Actions and governance

**Files:**
- Create: `.github/workflows/{validate.yml,promote.yml,release.yml}`, `.github/CODEOWNERS`, `scripts/protect-branch.sh`, `test/workflows.bats`

**Interfaces:**
- Consumes: `make validate`, `make test`, `make up/smoke/down` (lite profile in CI), `scripts/promote.sh`.
- Produces: `validate.yml` (on PR: lint, validate, test; then a kind/CAPD lite smoke job); `release.yml` (on tag `chart-v*`: `helm package` + `helm push` to `oci://ghcr.io/<owner>/charts`, build/push app image by digest); `promote.yml` (on push to `main` touching `promotion/versions/dev.yaml` or `promotion/versions/test.yaml`: run `promote.sh dev test` / `test prod`, open PR via `gh pr create` with `GITHUB_TOKEN`, skip when script prints `no change`). `scripts/protect-branch.sh` applies branch protection (required checks, review), GitHub Environments `test`/`prod` with required reviewers via `gh api`. Flux `Provider`/`Alert` for GitHub commit status in `infrastructure/base/flux-notifications/`.

- [ ] **Step 1: Write failing bats tests:** `workflow YAML parses and every job has timeout-minutes` (yq); `no workflow references a secret other than GITHUB_TOKEN or GITHUB_APP_*` (grep); `promote.yml skips PR creation on "no change"` (structural check of the step condition).
- [ ] **Step 2: Run** `bats test/workflows.bats` — Expected: FAIL.
- [ ] **Step 3: Implement** workflows, CODEOWNERS (platform paths vs apps paths), protect script (dry-run flag prints the API calls without executing), Flux notification manifests.
- [ ] **Step 4: Run** `bats test/workflows.bats` and `make validate` — Expected: PASS.
- [ ] **Step 5: Manual verification:** push to GitHub, open a PR, confirm `validate` runs; merge a dev version bump and confirm the test-promotion PR opens.
- [ ] **Step 6: Commit** `ci: GitHub Actions pipelines and governance`.

### Task 11: ADRs and README

**Files:**
- Create: `docs/adr/{0001-flux-vs-argocd,0002-monorepo-env-dirs,0003-feature-flags-as-helm-values,0004-github-actions-vs-gitlab-ci,0005-capd-as-local-provider}.md`, `docs/architecture.md` (Mermaid diagram), `README.md`, `test/docs.bats`

**Interfaces:**
- Consumes: all prior decisions (ingress choice NGINX Gateway Fabric, used for 1a only since Istio serves Gateway API in 1c: record this in ADR 5; workload sync mechanism chosen in Task 6).
- Produces: ADRs with sections Context / Decision / Consequences / Alternatives; ADR 4 contains a GitLab CI → GitHub Actions mapping table (pipelines, runners, environments, protected branches, OIDC).

- [ ] **Step 1: Write failing bats tests:** `five ADR files exist with Decision and Consequences headings`; `README links every ADR`; `README contains the quickstart commands make up, make smoke, make down`; `repo contains no employer names` (grep guard).
- [ ] **Step 2: Run** `bats test/docs.bats` — Expected: FAIL.
- [ ] **Step 3: Write** docs; README includes architecture diagram, profiles (full/lite), cost note (none locally),.
- [ ] **Step 4: Run** `bats test/docs.bats` — Expected: PASS.
- [ ] **Step 5: Commit** `docs: ADRs, architecture, README`.

### Task 12: End-to-end verification and demo

- [ ] **Step 1:** On a clean machine/Docker: `make up && make smoke && make down`; record time and results in the README.
- [ ] **Step 2:** `FLEET_PROFILE=lite make up && make smoke && make down` passes.
- [ ] **Step 3:** Walk the promotion flow once for real (bump dev pin → test PR → prod PR), record a short screen capture, link it in the README.
- [ ] **Step 4:** Tag `v0.1.0`; confirm the repo contains no CV or personal files (`git ls-files`).
- [ ] **Step 5: Commit** `docs: record verification and demo`.

---

## Self-review (spec coverage)

- §3 architecture → Tasks 5, 6; §4 layout → Tasks 1–8; §5 app → Tasks 2, 3; §6 CI/CD → Task 10; §7 promotion → Tasks 7, 10; §8 observability → Task 8; §9 ADRs → Task 11; §10 testing incl. acceptance checks → Tasks 4, 7, 9, 10; §11 failure modes → Review Focus lines mapped to Tasks 1, 4, 5, 7, 9; §12 out of scope respected (no cloud, no Istio, no signing); §13 open items: ingress chosen (NGINX Gateway Fabric), app language chosen (Go), license confirmed in Task 1 step 1, repo name = `fleet-in-a-repo` (rename before publishing if desired).
- Note: the promotion test "expected next-environment PR diff" from spec §10 is covered by `test/promote.bats` (diff limited to the target pin file).
