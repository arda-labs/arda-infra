# /// script
# requires-python = ">=3.12"
# dependencies = ["mcp<2", "psycopg[binary]"]
# ///
"""Read-only + optional write Postgres MCP server for Arda dev agents.

Modes (MCP_POSTGRES_MODE, default `ro`):
- `ro`: every tool is read-only. Uses role `arda_agent_ro`.
- `rw`: adds `execute_write` for cleaning up junk dev data. Uses role
  `arda_agent_rw` (DML grants only, not a table owner). The write tool blocks
  DDL, requires WHERE on UPDATE/DELETE, caps affected rows, defaults to
  dry-run, and cannot touch auth databases or `goose_db_version`.

Docs: arda-infra/docs/agent-access.md
"""

from __future__ import annotations

import json
import os
import re

import psycopg
from mcp.server.fastmcp import FastMCP

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
DEFAULT_DATABASES = [
    "ai", "capital", "crm", "deposit", "finance", "hrm", "iam", "loan", "mdm",
    "media", "noti", "platform", "statistical", "workflow",
    "hydra", "kratos", "rag", "zitadel",
]
DEFAULT_WRITE_DATABASES = [
    "ai", "capital", "crm", "deposit", "finance", "hrm", "iam", "loan", "mdm",
    "media", "noti", "platform", "statistical", "workflow",
]
MAX_CELL_CHARS = 2000

# execute_write: statement-level guardrails. The first keyword may only be
# INSERT/UPDATE/DELETE/WITH; the banned list is a fast-fail for DDL and
# maintenance statements (the role has no DDL grants either).
WRITE_KINDS = ("INSERT", "UPDATE", "DELETE", "WITH")
BANNED_WRITE_RE = re.compile(
    r"\b(CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE|VACUUM|REINDEX|CLUSTER|COPY|"
    r"CALL|DISCARD|LOCK|SECURITY)\b"
)
COMMENT_RE = re.compile(r"(/\*.*?\*/)|(--[^\n]*)", re.DOTALL)


def _csv(name: str, default: list[str]) -> list[str]:
    return [item.strip() for item in os.environ.get(name, ",".join(default)).split(",") if item.strip()]


MODE = os.environ.get("MCP_POSTGRES_MODE", "ro").lower()
# MetalLB VIP for the primary (database/loadbalancer); it follows failover.
HOST = os.environ.get("POSTGRES_HOST", "192.168.10.210")
PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
DATABASES = _csv("POSTGRES_DATABASES", DEFAULT_DATABASES)
WRITE_DATABASES = _csv("POSTGRES_WRITE_DATABASES", DEFAULT_WRITE_DATABASES)
RO_USER = os.environ.get("ARDA_AGENT_RO_USER", "arda_agent_ro")
RO_PASSWORD = os.environ.get("ARDA_AGENT_RO_PASSWORD", "")
RW_USER = os.environ.get("ARDA_AGENT_RW_USER", "arda_agent_rw")
RW_PASSWORD = os.environ.get("ARDA_AGENT_RW_PASSWORD", "")

if not RO_PASSWORD:
    raise SystemExit("mcp-postgres: ARDA_AGENT_RO_PASSWORD is not set (dev/mcp-postgres.env)")
if MODE == "rw" and not RW_PASSWORD:
    raise SystemExit("mcp-postgres: ARDA_AGENT_RW_PASSWORD is not set (dev/mcp-postgres.env)")

mcp = FastMCP("postgres")


def _connect(database: str, write: bool = False) -> psycopg.Connection:
    if database not in DATABASES:
        raise ValueError(f"unknown database {database!r}; available: {', '.join(DATABASES)}")
    if write and database not in WRITE_DATABASES:
        raise ValueError(
            f"database {database!r} is read-only for the agent; writable: {', '.join(WRITE_DATABASES)}"
        )
    user, password = (RW_USER, RW_PASSWORD) if MODE == "rw" else (RO_USER, RO_PASSWORD)
    conn = psycopg.connect(
        host=HOST,
        port=PORT,
        dbname=database,
        user=user,
        password=password,
        connect_timeout=5,
        application_name="arda-agent-write" if write else "arda-agent-read",
    )
    conn.read_only = not write
    return conn


def _cell(value):
    if isinstance(value, (bytes, bytearray)):
        value = value.hex()
    if isinstance(value, str) and len(value) > MAX_CELL_CHARS:
        value = value[:MAX_CELL_CHARS] + f"... [truncated {len(value) - MAX_CELL_CHARS} chars]"
    return value


def _rows(cur: psycopg.Cursor, limit: int) -> str:
    columns = [d.name for d in cur.description] if cur.description else []
    rows = cur.fetchmany(limit + 1)
    truncated = len(rows) > limit
    payload = {
        "columns": columns,
        "rows": [{c: _cell(v) for c, v in zip(columns, row)} for row in rows[:limit]],
        "truncated": truncated,
    }
    return json.dumps(payload, default=str, ensure_ascii=False)


@mcp.tool()
def list_databases() -> str:
    """List the service databases this MCP can query (and which accept writes in rw mode)."""
    return json.dumps({"databases": DATABASES, "writable": WRITE_DATABASES if MODE == "rw" else []})


@mcp.tool()
def list_schemas(database: str) -> str:
    """List non-system schemas in one database."""
    with _connect(database) as conn, conn.cursor() as cur:
        cur.execute(
            "select nspname as schema from pg_namespace "
            "where nspname not like 'pg_%' and nspname <> 'information_schema' "
            "order by 1"
        )
        return _rows(cur, 200)


@mcp.tool()
def list_objects(database: str, schema: str, name_contains: str | None = None, limit: int = 200) -> str:
    """List tables/views/sequences in a schema, optionally filtered by name."""
    if not IDENT.match(schema):
        raise ValueError("invalid schema name")
    pattern = f"%{name_contains}%" if name_contains else None
    with _connect(database) as conn, conn.cursor() as cur:
        cur.execute(
            """
            select c.relname as name,
                   case c.relkind
                     when 'r' then 'table' when 'p' then 'partitioned table'
                     when 'v' then 'view' when 'm' then 'materialized view'
                     when 'S' then 'sequence' when 'f' then 'foreign table'
                     else c.relkind::text end as kind
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = %s
              and c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
              and (%s::text is null or c.relname ilike %s)
            order by 1
            limit %s
            """,
            (schema, name_contains, pattern, max(1, min(limit, 1000))),
        )
        return _rows(cur, max(1, min(limit, 1000)))


@mcp.tool()
def get_object_details(database: str, schema: str, name: str) -> str:
    """Columns, indexes and constraints of one table/view."""
    if not IDENT.match(schema) or not IDENT.match(name):
        raise ValueError("invalid schema or object name")
    qualified = f'"{schema}"."{name}"'
    result: dict[str, list] = {"columns": [], "indexes": [], "constraints": []}
    with _connect(database) as conn, conn.cursor() as cur:
        cur.execute(
            """
            select a.attname as column_name,
                   format_type(a.atttypid, a.atttypmod) as data_type,
                   a.attnotnull as not_null,
                   pg_get_expr(d.adbin, d.adrelid) as default_expr
            from pg_attribute a
            left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
            where a.attrelid = %s::regclass and a.attnum > 0 and not a.attisdropped
            order by a.attnum
            """,
            (qualified,),
        )
        result["columns"] = [dict(zip([d.name for d in cur.description], row)) for row in cur.fetchall()]
        cur.execute(
            "select indexname, indexdef from pg_indexes where schemaname = %s and tablename = %s order by 1",
            (schema, name),
        )
        result["indexes"] = [dict(zip([d.name for d in cur.description], row)) for row in cur.fetchall()]
        cur.execute(
            "select conname, contype::text as kind, pg_get_constraintdef(oid) as definition "
            "from pg_constraint where conrelid = %s::regclass order by conname",
            (qualified,),
        )
        result["constraints"] = [dict(zip([d.name for d in cur.description], row)) for row in cur.fetchall()]
    return json.dumps(result, default=str, ensure_ascii=False)


@mcp.tool()
def execute_sql(database: str, sql: str, limit: int = 200) -> str:
    """Run a read-only SQL query (SELECT/SHOW/EXPLAIN) and return rows as JSON."""
    if not sql or not sql.strip():
        raise ValueError("empty sql")
    with _connect(database) as conn, conn.cursor() as cur:
        cur.execute(sql)
        if cur.description is None:
            return json.dumps({"columns": [], "rows": [], "note": "statement returned no result set"})
        return _rows(cur, max(1, min(limit, 1000)))


@mcp.tool()
def explain_query(database: str, sql: str) -> str:
    """EXPLAIN (text plan) for a SELECT/WITH/VALUES/TABLE query."""
    if re.match(r"^\s*(select|with|values|table)\b", sql, re.IGNORECASE) is None:
        raise ValueError("only SELECT/WITH/VALUES/TABLE can be explained")
    with _connect(database) as conn, conn.cursor() as cur:
        cur.execute("EXPLAIN " + sql)
        return "\n".join(row[0] for row in cur.fetchall())


if MODE == "rw":

    def _validate_write_sql(sql: str) -> None:
        stripped = COMMENT_RE.sub(" ", sql)
        normalized = " ".join(stripped.split()).upper()
        kind = normalized.split(" ", 1)[0].rstrip(";") if normalized else ""
        if kind not in WRITE_KINDS:
            raise ValueError("execute_write only accepts INSERT/UPDATE/DELETE (WITH ... allowed)")
        banned = BANNED_WRITE_RE.search(normalized)
        if banned:
            raise ValueError(f"statement contains forbidden keyword {banned.group(0)!r}")
        if kind in ("UPDATE", "DELETE") and not re.search(r"\bWHERE\b", normalized):
            raise ValueError(f"{kind} without WHERE is not allowed")

    @mcp.tool()
    def execute_write(database: str, sql: str, dry_run: bool = True, max_rows: int = 50) -> str:
        """Apply INSERT/UPDATE/DELETE to fix dev data. Runs a dry-run by default.

        DDL, goose_db_version and auth databases are blocked. UPDATE/DELETE
        require a WHERE clause; if more than `max_rows` rows match, the whole
        transaction is rolled back.
        """
        if not sql or not sql.strip():
            raise ValueError("empty sql")
        _validate_write_sql(sql)
        cap = max(1, min(max_rows, 1000))
        with _connect(database, write=True) as conn, conn.cursor() as cur:
            cur.execute("SET LOCAL statement_timeout = '15s'")
            cur.execute(sql)
            affected = cur.rowcount
            returning = _rows(cur, cap) if cur.description is not None else None
            if affected > cap:
                conn.rollback()
                raise ValueError(
                    f"{affected} rows match but max_rows={cap}; nothing was applied. "
                    "Add a tighter WHERE or raise max_rows explicitly."
                )
            if dry_run:
                conn.rollback()
            else:
                conn.commit()
            return json.dumps(
                {
                    "database": database,
                    "rowcount": affected,
                    "dry_run": dry_run,
                    "committed": not dry_run,
                    "returning": json.loads(returning) if returning else None,
                },
                default=str,
                ensure_ascii=False,
            )

if __name__ == "__main__":
    mcp.run()
