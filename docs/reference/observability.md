# Observability

The integrated observability path in this repo is:

- Prometheus and Grafana from `kube-prometheus-stack`
- Loki for cluster log aggregation
- Promtail for log shipping
- Blackbox Exporter for Prometheus-native network probes
- Gatus for application endpoint checks
- Alertmanager -> `ntfy` for notifications

`Smokeping` is now considered legacy-only in this repository.

- It is not part of the validated stage observability path.
- It is not wired into Prometheus, Grafana, or Alertmanager in the same way as Blackbox Exporter.
- New dashboards, alerts, and probes should be built on `blackbox-exporter`, not Smokeping.
- The existing prod Smokeping deployment can be retired later once the Blackbox replacement is considered fully sufficient.

Grafana dashboards for the integrated path are managed through `argocd/manifests/monitoring-config/base` as labeled `ConfigMap` resources so they are provisioned alongside the matching scrape and alert definitions.
