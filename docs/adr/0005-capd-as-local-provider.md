# ADR 5: Cluster API with Docker (CAPD) as the local stand-in for real infrastructure providers

Status: accepted

## Context

The fleet must be reproducible on a laptop at no cost, yet model how a real fleet is built:
clusters declared as objects, created from a template, configured by GitOps. Cluster API (CAPI)
does that against any infrastructure provider; its Docker provider (CAPD) runs clusters as
containers.

## Decision

- **CAPD behind a ClusterClass.** `capi/clusterclass/capd-clusterclass.yaml` defines the cluster
  shape once; `capi/customers/<customer>-<env>.yaml` are small `Cluster` objects that reference it
  (`topology.classRef`). Swapping CAPD for CAPA, CAPG or another provider means changing the
  class's infrastructure templates, not the customer definitions.
- **Management cluster:** a `kind` cluster (`kind/mgmt.yaml`) running CAPI and Flux, created by
  `scripts/mgmt-up.sh`. It syncs `clusters/management/<profile>/`, whose `workload-clusters`
  Kustomization applies `capi/`.
- **CNI:** kindnet, installed into each workload cluster by a `ClusterResourceSet`
  (`capi/cni/kindnet.yaml`), using the kindnetd image from `versions.env`.
- **Offline Flux source:** `make up` needs no GitHub. `mgmt-up.sh` pushes git HEAD to a bare repo
  and serves it read-only over HTTP from a container named `fleet-git` on the kind Docker network
  (`kind/git-server/`). Only committed changes sync; re-run after committing. Setting
  `FLEET_FLUX_GITHUB=owner/repo` (with `GITHUB_TOKEN`) instead bootstraps the management cluster
  from GitHub.
- **Flux in workload clusters:** `scripts/sync-workloads.sh` runs `flux install` in each workload
  cluster, writes the `cluster-vars` ConfigMap and applies `clusters/<name>/flux-system`. Chosen over
  a `ClusterResourceSet` (cannot run `flux install` or template per-cluster variables cleanly) and
  over a `mgmt-up` flag (would hide the step inside an already long script and break idempotent
  re-sync).
- **Ingress: NGINX Gateway Fabric (NGF) for 1a, with Gateway API CRDs.** The demo uses `Gateway`
  and `HTTPRoute`. Istio will serve the Gateway API in sub-project 1c, so NGF is a 1a-only choice and
  the routes carry over. The CRDs are installed from a version-pinned upstream tag
  (`GATEWAY_API_VERSION`). MetalLB (L2 mode) provides `LoadBalancer` addresses from the kind Docker
  network (`scripts/metallb-pool.sh`).
- **Profiles:** `FLEET_PROFILE=full` (default) is customers `acme` and `globex` x `dev`, `prod` =
  four clusters and needs at least 12 GiB for Docker. `lite` is `acme` x `dev`, `prod`
  (two clusters). The preflight floor is 6 GiB, but lite was only verified on a 7.7 GiB Docker VM
  with about 1 GiB spare (the author's observation: container peak about 5.1 GiB, swap in use); below that is untested.
  It sets `KPS_SCRAPE_APISERVER=false` so Prometheus fits: before this, Prometheus on `acme-prod`
  was OOM-killed.

## Consequences

- Versions reach clusters through ConfigMaps (`fleet-vars` on the management cluster, `cluster-vars`
  on workload clusters), written by scripts from `versions.env`. After a version bump, re-run
  `scripts/mgmt-up.sh` / `scripts/sync-workloads.sh` (`make up` does both) or the clusters keep the
  old values.
- Workload clusters sync only from the offline git server. GitHub mode bootstraps the management
  cluster only; pointing workload clusters at GitHub is not wired up in 1a.
- The demo image is built locally and loaded into each workload node (`kind load`); there is no
  registry in the offline path.
- CAPD is for development and demos; it is not a production provider and the kind nodes are not
  hardened (for example kube-proxy and kindnet run privileged).
- The first `make up` pulls many images and Helm charts and needs network access.

## Alternatives

- **Plain `kind` clusters without CAPI.** Faster and lighter, but no declarative cluster lifecycle,
  which is the part of a real fleet this repo is meant to show.
- **A real cloud provider (CAPA/EKS, GKE).** Closer to production, costs money and needs credentials;
  deferred to an optional overlay.
- **Ingress alternatives (Istio now, NGINX Ingress, Envoy Gateway).** Istio is the 1c subject;
  Ingress NGINX is not a Gateway API implementation.
