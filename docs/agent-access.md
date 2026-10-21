# Agent access (cluster, logs, databases)

Dev agents (OpenCode/Claude) read the cluster, the monitoring stack and the
Postgres databases; an opt-in `postgres-admin` MCP adds guarded data cleanup
(no schema changes). Everything here is LAN-only; credential files are
gitignored and never committed.

The workspace `opencode.jsonc` wires these stdio MCP servers:

| MCP server | Purpose | Wrapper | Credentials |
|---|---|---|---|
| `grafana` | Loki logs, VictoriaMetrics metrics, dashboards/alerts | `dev/mcp-grafana.ps1` | `dev/mcp-grafana.env` (service account `mcp-dev`, role Viewer) |
| `postgres` | Read-only SQL on every service database (tools take a `database` argument) | `dev/mcp-postgres.ps1` | `dev/mcp-postgres.env` (role `arda_agent_ro`) |
| `postgres-admin` | Adds `execute_write` for cleaning up junk dev data | `dev/mcp-postgres.ps1 -Write` | `dev/mcp-postgres.env` (role `arda_agent_rw`) |

Claude Code đọc cùng ba server từ `.mcp.json` ở workspace root (nội dung tương
đương `opencode.jsonc`; sửa một nơi phải sửa nơi kia). Lần đầu Claude Code hỏi
duyệt từng server, và cần khởi động lại session để tool xuất hiện. Quyền mặc
định: `grafana`/`postgres` được phép, `postgres-admin__execute_write` luôn hỏi.
Subagent `arda-debug` (chỉ đọc) và `arda-data-cleanup` (dry_run, chờ xác nhận)
nằm ở `.claude/agents/`.

## Kubernetes

`kubectl` works with the default kubeconfig (`~/.kube/config`, context
`default` -> `https://192.168.10.201:6443`): no `KUBECONFIG` override and no
Freelens kubeconfig path. Prefer `kubectl exec` inside pods; SSH only for
node-level work (sysctl, containerd, disk).

Node SSH uses the dev workstation's key (`hoanv@HoanPc`), which cloud-init
injects into each VM; no password is set or needed:

| Host | SSH | Notes |
|---|---|---|
| Proxmox `thinkcenter` | `root@192.168.10.200` | VMs 101-103 = `k3s-node1..3`, 104 = `aigiare-gw` (being decommissioned; its k8s namespace was removed) |
| `k3s-node1..3` | `hoan@192.168.10.201..203` | passwordless `sudo` |

The node VMs run qemu-guest-agent, so `qm guest exec <vmid> -- <cmd>` works
from Proxmox. A console password (noVNC) can be set without reboot with
`qm guest passwd <vmid> hoan`.

Recipes (pods, logs, events, port-forward) and safety rules live in the
workspace skill `.agents/skills/k3s-ops/SKILL.md`. The cluster is production
and GitOps-managed (`selfHeal: true`): agents only read; changes go through
`arda-infra` git.

## Postgres MCP

### Read-only role `arda_agent_ro`

- `GRANT pg_read_all_data` — SELECT on all tables/views, USAGE on schemas.
- `ALTER ROLE ... SET default_transaction_read_only = on` (plus
  `statement_timeout = '15s'`, `idle_in_transaction_session_timeout = '60s'`).
- `CONNECT` on the service databases and `hydra` / `kratos` / `rag` / `zitadel`.

`pg_read_all_data` does **not** bypass row-level security, so tenant-scoped
tables may return zero rows — that is intentional. Application DSNs
(`arda_*` roles from `arda-app-secrets`) can write and must never be used for
the MCP or ad-hoc queries.

Provisioning/rotation SQL is in `dev/mcp-postgres.env.example`. Run it on the
CNPG primary, e.g.:

```bash
kubectl -n database exec -i pg-main-1 -c postgres -- \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1
```

### Wrapper

`dev/mcp-postgres.ps1` reads `dev/mcp-postgres.env` (gitignored), defaults
`POSTGRES_HOST`/`POSTGRES_PORT` to the LAN NodePort, then runs the custom
server `dev/mcp-postgres.py`:

```
uv run --python 3.12 --no-project dev/mcp-postgres.py
```

The script carries PEP 723 metadata, so `uv` resolves `mcp<2` and
`psycopg[binary]` itself. `mcp<2` matters because the server imports
`mcp.server.fastmcp`, renamed in mcp 2.x; Python 3.12 keeps parity with the
tested setup (the upstream `postgres-mcp` fallback additionally needs it —
`pglast` has no 3.14 wheel). The MetalLB VIP `192.168.10.210:5432` (`database/loadbalancer`) routes to
the primary and follows failover; NetworkPolicy
`allow-ingress-from-dev-workstation` admits only the workstation `/32` (remote agents come in through the Tailscale subnet router `192.168.10.220`, see `allow-ingress-from-tailscale-router`); read-only is enforced in three layers: the role grants/settings above,
psycopg `read_only` mode, and the server only exposing SELECT/SHOW/EXPLAIN
tools.

Tools: `list_databases`, `list_schemas`, `list_objects`,
`get_object_details`, `execute_sql`, `explain_query`. Every tool takes the
database name, so all service databases are reachable through the single
`postgres` entry in `opencode.jsonc` — no per-DB process. The default
allowlist is all 18 databases (14 service DBs plus `hydra`, `kratos`, `rag`,
`zitadel`); override it with `POSTGRES_DATABASES=a,b,c` in
`dev/mcp-postgres.env`.

Index-tuning/health tools from upstream `postgres-mcp` are not included; if
they are ever needed, run it ad hoc against one DSN with
`uvx --python 3.12 --with "mcp<2" postgres-mcp --access-mode=restricted`.

### Verify

Call the MCP tool `execute_sql` with `database: iam` and:

```sql
select current_user, current_database(),
       current_setting('default_transaction_read_only') as read_only;
```

Expected: `arda_agent_ro`, the target DB, `on`.

## Fixing junk data (writes)

There is no separate dev cluster, so data created while testing has to be
cleaned up in place. The `postgres-admin` MCP (wrapper `-Write`) adds one tool,
`execute_write`, backed by role `arda_agent_rw`:

- DML grants only (`SELECT/INSERT/UPDATE/DELETE` on existing tables and
  sequences; default privileges cover new tables) — it is **not** a table
  owner, so DDL fails at the database even if a guardrail is bypassed.
- Only `INSERT`/`UPDATE`/`DELETE` (`WITH ...` allowed) are accepted;
  `UPDATE`/`DELETE` must contain `WHERE`; DDL/maintenance keywords are
  rejected before execution.
- `dry_run` defaults to **true**: the statement runs and is rolled back.
  Call again with `dry_run: false` to commit.
- If the statement touches more than `max_rows` (default 50) rows, the whole
  transaction is rolled back and the tool asks for a tighter `WHERE` or an
  explicit higher cap.
- Auth databases (`hydra`, `kratos`, `zitadel`) are not writable, and
  `goose_db_version` is revoked so migration state cannot be corrupted.
- Include `RETURNING *` when you want the changed rows echoed back for review.

Typical flow: find the junk with the read-only `postgres` server → run the
cleanup through `execute_write` with `dry_run: true` → check `rowcount` →
repeat with `dry_run: false`. Schema changes still go through Goose migrations
in `arda-be`, never through this tool.

## Security notes

- Never point the MCP at application DSNs from `arda-app-secrets`.
- `dev/mcp-postgres.env` is gitignored; do not paste its values into issues,
  chat or commit messages.
- The Cloud VM cannot reach the `192.168.10.201` LAN — the Postgres MCP only
  works from the LAN workstation.
- Ad-hoc `psql` through the CNPG pod (`kubectl exec ... psql -U postgres`) is
  a superuser path: SELECT/SHOW/EXPLAIN only.
