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
| `https://grafana.arda.io.vn` | Grafana (dashboards, alerts, Explore → Loki) | Grafana login (`admin`, password in the `grafana-admin` secret); Cloudflare Access not required |
| `https://gatus.arda.io.vn` | Gatus status page | Cloudflare Access |

Every host needs a Cloudflare Tunnel public hostname (service
`http://traefik.kube-system.svc.cluster.local:80`). An Access policy is
**required** for the hosts without their own authentication — VMUI
(`monitoring.`) and Gatus. `grafana.arda.io.vn` deliberately does not use
Access: it ships its own login and unauthenticated API calls return `401`
(checked 2026-09-18). Verify with
`curl -s -o /dev/null -w "%{http_code}" https://<host>/`: a `302` to
`*.cloudflareaccess.com` means Access is enforced.

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

Loki logs its own queries under `app="loki"` and stores the query text in the
line, so a `|=` search that contains the searched string also matches those
entries. Add `app!="loki"` when counting real matches.

Labels per stream: `cluster`, `namespace`, `pod`, `container`, `app`, `node`,
`level` (only when the line is JSON with a `level` field). Retention is 14
days; when a tailer starts it re-reads the container log from the beginning and
Alloy drops everything older than 30 minutes, because Loki rejects entries that
fall too far behind the stream head.

## MCP for dev agents (read-only log/metric access)

Dev agents (OpenCode/Claude) query Loki and VictoriaMetrics through the
read-only `mcp-grafana` MCP server instead of the UI. No trace backend yet, so
"tracing" means grouping log lines by `trace_id`/`request_id`; `get_tempo_trace`
stays unusable until OTel/Tempo is added.

- OpenCode config: workspace `opencode.jsonc` (`mcp.servers.grafana`) calls the
  wrapper `arda-infra/dev/mcp-grafana.ps1`.
- Wrapper runs `uvx mcp-grafana --disable-write --disable-oncall
  --disable-incident`. Credentials come from `dev/mcp-grafana.env` (gitignored;
  copy `dev/mcp-grafana.env.example`) or the User environment variable
  `GRAFANA_SERVICE_ACCOUNT_TOKEN`.
- The token belongs to Grafana service account `mcp-dev` (role Viewer). Rotate at
  Grafana → Administration → Users and access → Service accounts, then update
  `dev/mcp-grafana.env`.
- Example calls: `query_loki_logs` with `{app="auth-gateway"} | trace_id="<id>"`
  (structured metadata, no `| json` needed), `query_prometheus` with datasource
  uid `vm`, `generate_deeplink` to open Grafana Explore.
- Grafana is not behind Cloudflare Access (its own login gates the API), so the
  MCP needs no Access service token today. If it is ever placed behind Access,
  add a service token and set `GRAFANA_EXTRA_HEADERS` in `dev/mcp-grafana.env`
  (see the example file); otherwise Access blocks the MCP server.

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
- **inotify limits on nodes.** Kubelet creates one inotify instance per
  log-follow stream (`kubectl logs -f`, Alloy's `loki.source.kubernetes`);
  containerd-shims hold ~2 per container and udev workers add more, so the
  default `fs.inotify.max_user_instances=128` ran out on the busiest node (163
  instances measured, shims alone 80). Kubelet then writes
  `failed to create fsnotify watcher: too many open files` **into the pod's log
  stream** — it looks like an app log but is not — Alloy enters a reconnect
  storm (9k opens/hour, ~5.5k noise lines/hour) and `kubectl logs -f` breaks.
  Every node keeps `/etc/sysctl.d/99-k8s-inotify.conf` with
  `max_user_instances=1024` and `max_user_watches=524288` (applied 2026-09-18).
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

- Tunnel hostname + Cloudflare Access for `gatus.arda.io.vn` (Grafana needs no
  Access: it has its own login).
- Telegram bot token/chat id (`telegram-alerts` secret) plus the Grafana
  contact point/notification policy.
- Trace spans (OTel) across AI service, tools and provider calls — Loki holds
  logs with `trace_id` metadata, but nothing emits traces yet.
