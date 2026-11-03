# ADR 1: Flux instead of Argo CD

Status: accepted

## Context

The fleet needs a GitOps engine that reconciles one repository into many clusters: a management
cluster plus one workload cluster per customer and environment. Both Flux and Argo CD are mature,
CNCF-graduated options. The author holds an Argo certification and has used Argo CD together with
Cluster API for development environments, so Argo CD is a credible alternative here, not a straw
man. It was compared, not built.

## Decision

Use Flux (pinned in `versions.env` as `FLUX_VERSION`). The deciding properties for this repo:

- **Dependency ordering and health gating.** `Kustomization.spec.dependsOn` and `wait: true`
  (see `clusters/*/apps.yaml`, `infrastructure/base/components.yaml`) make "apps wait until the
  platform is healthy" a declarative property. `HelmRelease` objects can depend on each other too.
- **Per-cluster variables.** `postBuild.substituteFrom` injects add-on versions and the MetalLB
  pool from the `cluster-vars` ConfigMap, so one `infrastructure/` tree serves every cluster.
- **Pull-based, one repo, many clusters.** Each cluster runs its own Flux pointed at
  `clusters/<name>/`; there is no central controller holding credentials for every cluster.
- **Notifications.** notification-controller can post Kustomization results as commit statuses
  (opt-in manifests in `infrastructure/base/flux-notifications/`, disabled by default because they
  need a token Secret).
- **Footprint.** Four small controllers per cluster, which matters when four clusters share a
  laptop's Docker VM.

## Consequences

- Flux runs inside every workload cluster, so something has to install it there
  (`scripts/sync-workloads.sh`, see ADR 5).
- No built-in UI; the "UI" is Grafana (the `Platform health` dashboard shows Flux objects) and
  `flux get` / `kubectl`.
- Helm charts from a `GitRepository` are versioned by Git revision. Flux ignores
  `chart.spec.version` for such charts, so the promotion pin also sets the image tag (ADR 2).
- Argo CD concepts (ApplicationSet, app-of-apps) do not carry over one to one; a reader coming
  from Argo CD should map `ApplicationSet` generators to the per-cluster directories under
  `clusters/` and `apps/demo/flux/`.

## Alternatives

- **Argo CD.** Strong UI, ApplicationSets, rich RBAC and SSO. Rejected for this repo because the
  hub-and-spoke model needs a central instance with credentials for every cluster, there is no
  native equivalent of `postBuild.substituteFrom` (it needs a plugin or Helm parameters), and the
  control plane is heavier for a laptop demo. For a team that wants a UI-first workflow it remains
  a sound choice.
- **Plain CI-driven `kubectl apply`/`helm upgrade`.** Rejected: push-based, no drift correction.
