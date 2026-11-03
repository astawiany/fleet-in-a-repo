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

- **Dependency ordering and health gating.** Argo CD orders work with sync waves and hooks; Flux
  has `Kustomization.spec.dependsOn` and `wait: true` (see `clusters/*/apps.yaml`,
  `infrastructure/base/components.yaml`), which make "apps wait until the platform is healthy" a
  declarative property between objects. `HelmRelease` objects can depend on each other too.
- **Per-cluster variables.** Argo CD can template or inject values via ApplicationSet generators
  and go templates, Helm `valuesObject`/parameters, and plugins; Flux has `postBuild.substituteFrom`
  built in. Here it injects add-on versions and the MetalLB
  pool from the `cluster-vars` ConfigMap, so one `infrastructure/` tree serves every cluster.
- **Pull-based, one repo, many clusters.** Each cluster runs its own Flux pointed at
  `clusters/<name>/`; the reconciliation path has no central controller pushing to every cluster.
  This is not the whole credential picture: the management cluster still holds a kubeconfig for
  every workload cluster as a Cluster API Secret, and `scripts/sync-workloads.sh` uses exported
  kubeconfigs to install Flux.
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

- **Argo CD.** Strong UI, ApplicationSets, rich RBAC and SSO. Not chosen for this repo. Hub-and-spoke (one
  Argo CD instance with credentials for many clusters) is the common topology, though one instance
  per cluster is possible. Argo CD can do per-cluster value injection via ApplicationSet
  generators, Helm parameters or plugins where Flux has `postBuild.substituteFrom` built in, and
  orders per sync wave and per Application (waiting for health within a wave) where Flux expresses ordering as `dependsOn` between Kustomizations and HelmReleases, with `wait: true` health gating. The tilt toward
  Flux is a matter of fit and laptop footprint, not capability. For a team that wants a UI-first workflow it remains
  a sound choice.
- **Plain CI-driven `kubectl apply`/`helm upgrade`.** Rejected: push-based, no drift correction.
