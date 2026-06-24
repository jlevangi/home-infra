# Observability

The integrated observability path in this repo is:

- Prometheus and Grafana from `kube-prometheus-stack`
- Loki for cluster log aggregation
- Promtail for log shipping
- Blackbox Exporter for Prometheus-native network probes
- Gatus for application endpoint checks
- Alertmanager -> `ntfy` for notifications (with parallel n8n LLM enrichment for both warning and critical alerts)

`Smokeping` is retired from the active observability path in this repository.

- It is not part of the validated stage observability path.
- It is not wired into Prometheus, Grafana, or Alertmanager in the same way as Blackbox Exporter.
- New dashboards, alerts, and probes should be built on `blackbox-exporter`, not Smokeping.
- Prod should reconcile on `main` without the legacy Smokeping ArgoCD application.

Grafana dashboards for the integrated path are managed through `argocd/manifests/monitoring-config/base` as labeled `ConfigMap` resources so they are provisioned alongside the matching scrape and alert definitions.
