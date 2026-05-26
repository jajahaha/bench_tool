"""Database connection pool management and helper functions."""

import os
from psycopg_pool import ConnectionPool
from psycopg.rows import dict_row

ALLOWED_READ_PREFIXES = ("SELECT", "EXPLAIN", "SHOW", "WITH")
ALLOWED_DML_PREFIXES = ("INSERT", "UPDATE", "DELETE")


def build_conninfo() -> str:
    """Build PostgreSQL connection string from environment variables."""
    host = os.environ.get("PGHOST", "localhost")
    port = os.environ.get("PGPORT", "5432")
    dbname = os.environ.get("PGDATABASE", "postgres")
    user = os.environ.get("PGUSER", "postgres")
    password = os.environ.get("PGPASSWORD", "")
    parts = [f"host={host}", f"port={port}", f"dbname={dbname}", f"user={user}"]
    if password:
        parts.append(f"password={password}")
    return " ".join(parts)


def create_pool(min_size: int = 2, max_size: int = 10) -> ConnectionPool:
    """Create a connection pool."""
    return ConnectionPool(conninfo=build_conninfo(), min_size=min_size, max_size=max_size, open=True)


def is_read_query(sql: str) -> bool:
    """Check if SQL is a safe read-only query."""
    stripped = sql.strip().upper()
    return any(stripped.startswith(p) for p in ALLOWED_READ_PREFIXES)


def is_dml_query(sql: str) -> bool:
    """Check if SQL is a DML (write) query."""
    stripped = sql.strip().upper()
    return any(stripped.startswith(p) for p in ALLOWED_DML_PREFIXES)


def format_as_markdown_table(rows: list[dict]) -> str:
    """Format query result rows as a Markdown table."""
    if not rows:
        return "No rows returned."

    columns = list(rows[0].keys())
    header = "| " + " | ".join(columns) + " |"
    separator = "| " + " | ".join("---" for _ in columns) + " |"
    body_lines = []
    for row in rows:
        vals = []
        for col in columns:
            v = row.get(col)
            if v is None:
                vals.append("NULL")
            elif isinstance(v, (list, dict)):
                vals.append(str(v))
            else:
                vals.append(str(v))
        body_lines.append("| " + " | ".join(vals) + " |")

    return header + "\n" + separator + "\n" + "\n".join(body_lines)


def format_as_text(rows: list[dict]) -> str:
    """Format query result rows as key-value text blocks."""
    if not rows:
        return "No rows returned."

    lines = []
    for i, row in enumerate(rows, 1):
        lines.append(f"[Row {i}]")
        for k, v in row.items():
            lines.append(f"  {k}: {v}")
        lines.append("")
    return "\n".join(lines)