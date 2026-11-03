# Task 8 report
Status: DONE_WITH_CONCERNS
- RED: bats test/observability.bats -> 7 not ok (files missing). GREEN: 7/7 ok; `make lint test` exit 0 (79 tests, 0 failures, includes validate).
- Bite proofs: unbalanced paren in rule -> test 6 fails via promtool ("unclosed left parenthesis"); replacing metric name -> test 5 fails.
- Layout deviation: new files live in infrastructure/base/monitoring/config/ (own kustomization, configMapGenerator for the two dashboard JSONs with grafana_dashboard: "1", ns monitoring), wired by new Flux Kustomization `monitoring-config` (components.yaml) dependsOn `monitoring`, because PodMonitor/PrometheusRule CRDs come from the HelmRelease.
- Added flux-podmonitor.yaml (PodMonitor flux-controllers, port http-prom).
- Dashboards: uid platform-health "Platform health"; uid demo-slis "Demo SLIs". Demo metric only has label `code`; errors = code=~"5..".
- Alerts: SLO 99.9%, fast 14.4x (1h&5m), slow 6x (6h&30m).
- PROMTOOL_IMAGE added to versions.env: prom/prometheus:v3.15.1@sha256:fa33... (KPS 92.17.1 ships Prometheus v3.15.1; non-distroless has promtool). Test uses promtool on PATH else docker, else fails.
- Concern: Grafana admin password left at chart default (prom-operator); Service stays ClusterIP. Not cheap: cluster-vars is regenerated on each sync-workloads run, so a random password would rotate/desync with Grafana's DB. Controller should decide (e.g. Secret + admin.existingSecret).
