"""SQL query execution tools."""

from typing import Annotated
from pydantic import Field

from pg_mcp_server.db import (
    is_read_query, is_dml_query, format_as_markdown_table, format_as_text,
)


def register(mcp):
    """Register query tools on the MCP server."""

    @mcp.tool()
    def execute_query(
        sql: Annotated[str, Field(description="SQL query to execute (SELECT/EXPLAIN/WITH only)")],
        limit: Annotated[int, Field(gt=0, le=1000, description="Max rows to return")] = 100,
        format: Annotated[str, Field(description="Output format: table or text", pattern="^(table|text)$")] = "table",
    ) -> str:
        """Execute a read-only SQL query and return results. Only SELECT, EXPLAIN, SHOW, and WITH queries are allowed."""
        if not is_read_query(sql):
            return "Error: Only SELECT, EXPLAIN, SHOW, WITH queries are allowed. Use execute_dml for write operations."

        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                # Add LIMIT if not already present and it's a SELECT
                stripped = sql.strip()
                if stripped.upper().startswith("SELECT") and "LIMIT" not in stripped.upper():
                    sql = stripped.rstrip(";") + f" LIMIT {limit};"

                rows = conn.execute(sql).fetchall()

                if format == "text":
                    return format_as_text(rows)
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error executing query: {e}"

    @mcp.tool()
    def execute_dml(
        sql: Annotated[str, Field(description="DML statement (INSERT/UPDATE/DELETE)")],
        dry_run: Annotated[bool, Field(description="If true, only validate syntax without executing")] = True,
    ) -> str:
        """Execute a write operation (INSERT/UPDATE/DELETE). By default dry_run=true only validates the SQL without executing it. Set dry_run=false to actually execute."""
        if not is_dml_query(sql):
            return "Error: Only INSERT, UPDATE, DELETE statements are allowed."

        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                if dry_run:
                    # Use EXPLAIN to validate syntax without executing
                    try:
                        conn.execute(f"EXPLAIN {sql}")
                        return f"Dry run: SQL syntax validated successfully.\nStatement: {sql.strip()}\n\nSet dry_run=false to actually execute this statement."
                    except Exception as ex:
                        return f"Dry run: SQL syntax error: {ex}"

                # Real execution with autocommit
                conn.autocommit = True
                result = conn.execute(sql)
                rowcount = result.rowcount if result else 0
                conn.autocommit = False
                return f"Executed successfully. Affected rows: {rowcount}\nStatement: {sql.strip()}"
        except Exception as e:
            return f"Error executing DML: {e}"