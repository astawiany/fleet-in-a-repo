# ADR 3: Feature flags as Helm values, trunk-based development

Status: accepted

## Context

Different customers need different features on the same code version, and the team wants to merge
to `main` continuously (trunk-based development) without releasing unfinished work to everyone.

## Decision

Feature flags are plain Helm values, set per customer and environment:

- `apps/demo/values/<customer>-<env>.yaml` (for example `features.newBanner: true` in
  `acme-dev.yaml`), delivered to Flux as the ConfigMap `demo-values-<customer>-<env>` and consumed
  through the `HelmRelease`'s `valuesFrom`.
- The chart turns a value into an environment variable of the app; `features.newBanner` becomes
  `FEATURE_NEW_BANNER` (`apps/demo/chart/templates/deployments.yaml`), read by
  `apps/demo/src/main.go` and visible on the demo's `/feature` endpoint.
- Code ships dark: a feature merges disabled for everyone, then a one-line PR flips the flag for one
  customer and environment. Rolling back is reverting that line.

## Consequences

- Enabling a feature is a reviewed, auditable Git change with the same promotion path as any other.
- A flag change rolls the pods (the value changes the pod environment), it is not a runtime toggle.
- No per-user or percentage rollouts; the unit of targeting is a cluster.
- Flags need cleanup: once a feature is on everywhere, delete the flag and the code branch.

## Alternatives

- **Runtime flag service (LaunchDarkly, Unleash, OpenFeature backend).** Supports instant toggles
  and gradual rollouts, at the cost of another system to run and secure. A good next step when
  targeting must go below cluster granularity.
- **Long-lived feature branches.** Rejected: merge pain and no way to ship one customer a feature
  ahead of others from the same trunk.
