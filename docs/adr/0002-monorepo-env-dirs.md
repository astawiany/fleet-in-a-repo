# ADR 2: One monorepo, directory per cluster, promotion by pinned version

Status: accepted

## Context

Many clusters (customer x environment) share most of their configuration. The repo needs a layout
where a change is reviewable in one diff, an environment is a directory (not a long-lived branch),
and a new chart version moves dev -> test -> prod through reviewed steps.

## Decision

A single repository with a directory per concern:

- `clusters/<customer>-<env>/` is each workload cluster's Flux entrypoint;
  `clusters/management/{full,lite}/` is the management cluster's.
- `infrastructure/base` + `infrastructure/overlays/{dev,prod}` hold platform add-ons.
- `apps/demo/chart` is the Helm chart; `apps/demo/values/<customer>-<env>.yaml` and
  `apps/demo/flux/<customer>-<env>/` hold per-cluster configuration.
- **Promotion pins** are `promotion/versions/{dev,test,prod}.yaml`, each with one field,
  `chart.version`. A Kustomize `replacement` in `apps/demo/flux/<cluster>/release/kustomization.yaml`
  copies the pin into the `HelmRelease`'s `spec.values.image.tag` and `spec.chart.spec.version`.
  The chart sits in the same Git repo, so Flux ignores `chart.spec.version` (the chart is taken from
  the Git revision); the effective, observable effect of a pin is the image tag. Image tag and
  chart version therefore move in lockstep, and the image built for a version must exist before
  its pin is promoted.
- **The `test` pin is a staging gate.** There are no `*-test` clusters in 1a, so no cluster reads
  `promotion/versions/test.yaml`. It still exists so the flow is dev -> test -> prod: promoting to
  `test` needs a PR plus review in the `test` GitHub Environment, and `prod` is only promoted after
  that. A `test` cluster would consume the pin the same way `dev` and `prod` do.
- `scripts/promote.sh <from> <to>` copies a pin; `.github/workflows/promote.yml` runs it and opens
  the PR (see ADR 4).

## Consequences

- One PR shows exactly what changes where; CODEOWNERS can protect paths (`/promotion/`,
  `/infrastructure/`) differently from app paths.
- Environment drift is visible as a diff between directories. Shared code lives in `base/`, so a
  change to `base/` hits every cluster at once; the pins, not `base/`, are the controlled rollout
  mechanism for the app.
- The repo grows with the fleet; very large fleets would need generation tooling or splitting.
- Promotion is by Git commit, not by artifact: the repo records what was promoted when, but
  provenance of the image itself is out of scope (supply-chain controls are a later project).

## Alternatives

- **Multi-repo (app repo + config repo per environment) or OCI-artifact promotion.** Clean
  separation of duties and immutable artifacts, but more moving parts and cross-repo PR choreography
  than a demo needs. OCI-based promotion is explicitly out of scope for 1a.
- **Branch per environment.** Rejected: merges between long-lived branches drift, cherry-picks hide
  what differs, and "what is in prod" is no longer one directory listing.
