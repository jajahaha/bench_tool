"""Database metadata tools."""

from typing import Annotated
from pydantic import Field
from psycopg.rows import dict_row
from psycopg.sql import Identifier, SQL

from pg_mcp_server.db import format_as_markdown_table


def register(mcp):
    """Register metadata tools on the MCP server."""

    @mcp.tool()
    def list_tables(
        schema: Annotated[str, Field(description="Schema name to list tables from")] = "public",
    ) -> str:
        """List all tables in a schema."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection(row_factory=dict_row) as conn:
                rows = conn.execute(
                    SQL("""
                    SELECT table_name, table_type
                    FROM information_schema.tables
                    WHERE table_schema = %s
                    ORDER BY table_name
                    """),
                    [schema],
                ).fetchall()
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def describe_table(
        table_name: Annotated[str, Field(description="Table name to describe")],
        schema: Annotated[str, Field(description="Schema name")] = "public",
    ) -> str:
        """Get detailed table structure: columns, indexes, constraints, and partition info."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection(row_factory=dict_row) as conn:
                # Columns
                cols = conn.execute(
                    SQL("""
                    SELECT column_name, data_type, character_maximum_length,
                           is_nullable, column_default, numeric_precision, numeric_scale
                    FROM information_schema.columns
                    WHERE table_schema = %s AND table_name = %s
                    ORDER BY ordinal_position
                    """),
                    [schema, table_name],
                ).fetchall()

                # Indexes
                idxs = conn.execute(
                    SQL("""
                    SELECT indexname, indexdef
                    FROM pg_indexes
                    WHERE schemaname = %s AND tablename = %s
                    """),
                    [schema, table_name],
                ).fetchall()

                # Constraints
                constrs = conn.execute(
                    SQL("""
                    SELECT conname, contype, pg_get_constraintdef(c.oid) AS definition
                    FROM pg_constraint c
                    JOIN pg_class t ON c.conrelid = t.oid
                    JOIN pg_namespace n ON t.relnamespace = n.oid
                    WHERE n.nspname = %s AND t.relname = %s
                    """),
                    [schema, table_name],
                ).fetchall()

                result = f"## Columns\n{format_as_markdown_table(cols)}\n\n"
                if idxs:
                    result += f"## Indexes\n{format_as_markdown_table(idxs)}\n\n"
                else:
                    result += "## Indexes\nNo indexes found.\n\n"
                if constrs:
                    result += f"## Constraints\n{format_as_markdown_table(constrs)}"
                else:
                    result += "## Constraints\nNo constraints found."
                return result
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def list_indexes(
        table_name: Annotated[str, Field(description="Table name (optional, leave empty for all tables)")] = "",
        schema: Annotated[str, Field(description="Schema name")] = "public",
    ) -> str:
        """List indexes for a specific table or all tables in a schema."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection(row_factory=dict_row) as conn:
                if table_name:
                    rows = conn.execute(
                        SQL("""
                        SELECT indexname, indexdef
                        FROM pg_indexes
                        WHERE schemaname = %s AND tablename = %s
                        """),
                        [schema, table_name],
                    ).fetchall()
                else:
                    rows = conn.execute(
                        SQL("""
                        SELECT tablename, indexname, indexdef
                        FROM pg_indexes
                        WHERE schemaname = %s
                        ORDER BY tablename, indexname
                        """),
                        [schema],
                    ).fetchall()
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def list_schemas() -> str:
        """List all schemas in the database."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection(row_factory=dict_row) as conn:
                rows = conn.execute(
                    """
                    SELECT schema_name, schema_owner
                    FROM information_schema.schemata
                    WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                    ORDER BY schema_name
                    """
                ).fetchall()
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def get_table_stats(
        table_name: Annotated[str, Field(description="Table name")],
        schema: Annotated[str, Field(description="Schema name")] = "public",
    ) -> str:
        """Get table statistics: row count, disk size, last analyze time, dead tuples."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection(row_factory=dict_row) as conn:
                rows = conn.execute(
                    SQL("""
                    SELECT
                        relname AS table_name,
                        n_live_tup AS live_rows,
                        n_dead_tup AS dead_rows,
                        last_analyze,
                        last_autoanalyze,
                        last_vacuum,
                        last_autovacuum,
                        vacuum_count,
                        analyze_count
                    FROM pg_stat_user_tables
                    WHERE schemaname = %s AND relname = %s
                    """),
                    [schema, table_name],
                ).fetchall()

                size_rows = conn.execute(
                    SQL("""
                    SELECT
                        pg_relation_size(%s || '.' || %s) AS table_bytes,
                        pg_indexes_size(%s || '.' || %s) AS index_bytes,
                        pg_total_relation_size(%s || '.' || %s) AS total_bytes
                    """),
                    [schema, table_name, schema, table_name, schema, table_name],
                ).fetchall()

                result = f"## Statistics\n{format_as_markdown_table(rows)}\n\n"
                if size_rows:
                    for r in size_rows:
                        tb = int(r["table_bytes"] or 0)
                        ib = int(r["index_bytes"] or 0)
                        tot = int(r["total_bytes"] or 0)
                        result += f"## Disk Size\n| Type | Size |\n|---|---|\n"
                        result += f"| Table data | {tb / 1024:.1f} KB |\n"
                        result += f"| Indexes | {ib / 1024:.1f} KB |\n"
                        result += f"| Total | {tot / 1024:.1f} KB |\n"
                return result
        except Exception as e:
            return f"Error: {e}"