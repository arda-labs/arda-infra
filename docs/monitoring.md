# Monitoring and logs

Operational notes for the `monitoring` namespace. Everything is plain
kustomize/YAML under `k8s/monitoring/` and is applied by the `arda-backend`
Argo CD Application (destination namespace `monitoring`), so changes go through
Git — `kubectl edit` gets reverted by `selfHeal`.

## Components

| Component | Image | Role | Manifest |
|---|---|---|---|
| VictoriaMetrics (`vmsingle`) | `victoriametrics/victoria-metrics:v1.152.0` | Scrapes every service `/metrics` (30s), stores 30 days, serves PromQL/MetricsQL; ships VMUI | `victoria-metrics.yaml` |
| Grafana | `grafana/grafana:13.2.2` | The single UI: dashboards, Grafana Alerting, Explore for logs | `grafana.yaml` |
| Loki | `grafana/loki:3.7.7` | Central log store, 14 days retention, 10Gi PVC (single binary) | `loki.yaml` |
| Alloy | `grafana/alloy:v1.19.2` | DaemonSet, tails container logs through the Kubernetes API, parses JSON, pushes to Loki | `alloy.yaml` |
| Gatus | `twinproduction/gatus:v5.36.0` | Black-box endpoint watchdog (20 checks) + status page + Telegram alerts | `gatus.yaml` |
| node-exporter | `prom/node-exporter:v1.12.1` | Node CPU / memory / disk / network | `cluster-metrics.yaml` |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0` | Pod phases, restarts, OOM reasons, deployment status | `cluster-metrics.yaml` |
| kubelet cAdvisor | — (scrape only) | Per-pod CPU / memory / network from `kubelet:10250/metrics/cadvisor` | `victoria-metrics.yaml` + `scrape-rbac.yaml` |

Scrape jobs (`vmsingle-scrape` ConfigMap): `arda-services` (15 services),
`monitoring` (vmsingle, Grafana, Loki, Gatus), `node-exporter` (3 nodes on
hostPort 9100), `kube-state-metrics`, `kubelet-cadvisor` (3 nodes, filtered to
the series the dashboards need). `vmalert` was retired — alert evaluation lives
in Grafana.

## UIs

| URL | What | Protection |
|---|---|---|
| `https://monitoring.arda.io.vn/vmui` | VictoriaMetrics VMUI + the "Arda overview" dashboard | Cloudflare Access |
| `https://grafana.arda.io.vn` | Grafana (dashboards, alerts, Explore → Loki) | Cloudflare Access + Grafana login (`admin`, password in the `grafana-admin` secret) |
| `https://gatus.arda.io.vn` | Gatus status page | Cloudflare Access |

Every host needs **both** a Cloudflare Tunnel public hostname (service
`http://traefik.kube-system.svc.cluster.local:80`) **and** an Access policy.
`grafana.arda.io.vn` served Grafana's login page directly during the first
rollout — check with
`curl -s -o /dev/null -w "%{http_code}" https://grafana.arda.io.vn/login`: a
`302` to `*.cloudflareaccess.com` is the desired answer, `200` means Access is
missing.

## Dashboards

Grafana folder **Arda**: *Arda Overview*, *Arda Services HTTP* (per-service
drilldown), *Arda AI Service* (all `arda_ai_*` families), *Arda Kubernetes /
Nodes*, *Arda Logs*.

Dashboard JSON is a real file in `k8s/monitoring/dashboards/`, turned into the
`grafana-dashboards` ConfigMap by the `configMapGenerator` in
`k8s/monitoring/kustomization.yaml`. To add one: drop the JSON in that
directory and list the file under the generator. Grafana reloads dashboard
provisioning on its own (60s).

VMUI custom dashboards come from `dashboards/arda-overview.json`, mounted at
`/etc/vmui-dashboards` and read through `-vmui.customDashboardsPath`. VMUI only
reads the directory at startup, so a vmsingle restart is needed after edits.

## Alert rules

`k8s/monitoring/grafana-alerting.yaml` provisions 7 rules into Grafana
Alerting (folder *Arda*, groups `arda-ai`, `arda-endpoints`, `arda-platform`):
publish failures, model unavailable, embedding p95, prompt budget, endpoint
down (Gatus metric), pod crash-looping, node disk > 85%.

**File provisioning is read at startup.** After editing the ConfigMap, either
restart Grafana or hot-reload:

```bash
curl -u admin:<password> -X POST \
  https://grafana.arda.io.vn/api/admin/provisioning/alerting/reload
```

Notification delivery: the rules already carry `severity`/`service` labels but
only appear in the UI until a Telegram contact point exists (Alerting →
Contact points, using the same bot as Gatus). Gatus alerts independently —
`alerts: [{type: telegram}]` per endpoint — and activates as soon as the
cluster-local secret exists:

```bash
kubectl -n monitoring create secret generic telegram-alerts \
  --from-literal=bot-token=<token> --from-literal=chat-id=<chat id>
kubectl -n monitoring rollout restart deploy/gatus   # Grafana: set contact point in the UI
```

The secret is referenced with `optional: true` everywhere, so its absence never
blocks a rollout; the providers just stay inert.

## Logs

Alloy promotes the JSON `level` field to a label (Arda services log
`{"time","level","msg",...}`) and exposes `request_id`, `trace_id` and `actor`
as **structured metadata**, so filtering does not need `| json` at query time:

```logql
{app="ai-service", level="ERROR"}
{namespace="arda-app"} |= "deadline exceeded"
{app="auth-gateway"} | trace_id="<trace id>"
sum by (app) (count_over_time({cluster="arda", level=~"ERROR|WARN"}[5m]))
```

Labels per stream: `cluster`, `namespace`, `pod`, `container`, `app`, `node`,
`level` (only when the line is JSON with a `level` field). Retention is 14
days; when a tailer starts it re-reads the container log from the beginning and
Alloy drops everything older than 30 minutes, because Loki rejects entries that
fall too far behind the stream head.

## Operational notes (learned the hard way)

- **Probe timeouts.** A 1s liveness timeout (the Kubernetes default) killed
  Grafana once under load after a major upgrade. Give stateful UIs a
  `startupProbe` plus 5s timeouts and several failure thresholds.
- **Argo project scope.** `k8s/monitoring` now needs ClusterRole /
  ClusterRoleBinding (Alloy, kube-state-metrics, cAdvisor scrape). Those are
  cluster-scoped, so `argocd/project.yaml` whitelists
  `rbac.authorization.k8s.io` kinds — a sync otherwise fails validation.
- **node-exporter 1.12** no longer serves `/-/healthy`; the DaemonSet uses TCP
  probes.
- **Alloy configuration** comments use `//`, not `#`. The DaemonSet is
  node-scoped on purpose (each instance tails only pods on its own node) —
  without that filter Loki receives one copy per node.
- **kubelet cAdvisor scrape** needs the `nodes/metrics` resource grant (plus
  `nodes/stats`, `nodes/proxy`) on the `vmsingle` ServiceAccount; the kubelet
  authorizer checks resources, not non-resource URLs.
- **Image bumps.** Verify flags still exist before jumping versions (e.g.
  `-vmui.customDashboardsPath` was checked on VM 1.152 with a throwaway
  `-help` pod) and read the Grafana release notes for provisioning changes.
- **Provisioned datasources** also need
  `POST /api/admin/provisioning/datasources/reload` (or a restart) after an
  edit to `grafana-datasources`.
- **Footprint.** vmsingle 5Gi/256Mi, Grafana 1Gi/256Mi (768Mi limit), Loki
  10Gi/256Mi, Alloy 128Mi per node, node-exporter 48Mi per node,
  kube-state-metrics 64Mi, Gatus 32Mi.

## Still open

- Cloudflare Access for `grafana.arda.io.vn`, and the Tunnel hostname + Access
  for `gatus.arda.io.vn`.
- Telegram bot token/chat id (`telegram-alerts` secret) plus the Grafana
  contact point/notification policy.
- Trace spans (OTel) across AI service, tools and provider calls — Loki holds
  logs with `trace_id` metadata, but nothing emits traces yet.
