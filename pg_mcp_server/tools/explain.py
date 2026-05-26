"""Execution plan analysis tools."""

from typing import Annotated
from pydantic import Field
from psycopg.rows import dict_row

from pg_mcp_server.db import format_as_markdown_table, format_as_text


def register(mcp):
    """Register explain tools on the MCP server."""

    @mcp.tool()
    def explain_plan(
        sql: Annotated[str, Field(description="SQL query to analyze execution plan for")],
        analyze: Annotated[bool, Field(description="Run EXPLAIN ANALYZE to get actual execution times")] = False,
        buffers: Annotated[bool, Field(description="Include buffer usage statistics")] = False,
    ) -> str:
        """Get the execution plan for a SQL query. Use analyze=true for actual execution times (the query WILL be executed). Use buffers=true to see I/O statistics."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                options = []
                if analyze:
                    options.append("ANALYZE")
                if buffers:
                    options.append("BUFFERS")
                options.append("VERBOSE")
                options.append("COSTS")

                opt_str = ", ".join(options)
                explain_sql = f"EXPLAIN ({opt_str}) {sql}"

                result = conn.execute(explain_sql)
                lines = [row[0] for row in result.fetchall()]
                return "\n".join(lines)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def explain_plan_json(
        sql: Annotated[str, Field(description="SQL query to analyze")],
        analyze: Annotated[bool, Field(description="Include actual execution statistics")] = False,
    ) -> str:
        """Get the execution plan in JSON format for structured analysis. Returns a JSON object with plan tree, costs, and (optionally) actual timings."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                options = ["FORMAT JSON", "VERBOSE", "COSTS"]
                if analyze:
                    options.append("ANALYZE")
                    options.append("BUFFERS")

                opt_str = ", ".join(options)
                explain_sql = f"EXPLAIN ({opt_str}) {sql}"

                result = conn.execute(explain_sql)
                plan_json = result.fetchone()[0]

                import json
                return json.dumps(plan_json, indent=2, ensure_ascii=False)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def get_stats_info(
        table_name: Annotated[str, Field(description="Table name")],
        column_name: Annotated[str, Field(description="Column name (optional, leave empty for all columns)")] = "",
        schema: Annotated[str, Field(description="Schema name")] = "public",
    ) -> str:
        """Get pg_stats statistics for a table/column. Shows n_distinct, correlation, null_frac, MCV, histogram_bounds — key inputs to the query planner."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection(row_factory=dict_row) as conn:
                if column_name:
                    rows = conn.execute(
                        """
                        SELECT attname, n_distinct, correlation, null_frac,
                               avg_width, most_common_vals, most_common_freqs,
                               histogram_bounds
                        FROM pg_stats
                        WHERE schemaname = %s AND tablename = %s AND attname = %s
                        """,
                        [schema, table_name, column_name],
                    ).fetchall()
                else:
                    rows = conn.execute(
                        """
                        SELECT attname, n_distinct, correlation, null_frac,
                               avg_width, most_common_vals, most_common_freqs,
                               histogram_bounds
                        FROM pg_stats
                        WHERE schemaname = %s AND tablename = %s
                        ORDER BY attname
                        """,
                        [schema, table_name],
                    ).fetchall()

                if not rows:
                    return f"No statistics found for {schema}.{table_name}. Run ANALYZE first."

                # Simplify MCV/histogram for readability
                result_lines = [f"## Statistics for {schema}.{table_name}\n"]
                for row in rows:
                    mcv = row.get("most_common_vals")
                    mcf = row.get("most_common_freqs")
                    hist = row.get("histogram_bounds")
                    nd = row.get("n_distinct")
                    corr = row.get("correlation")

                    result_lines.append(f"### Column: {row['attname']}")
                    result_lines.append(f"- n_distinct: {nd}")
                    result_lines.append(f"- correlation: {corr}")
                    result_lines.append(f"- null_frac: {row.get('null_frac')}")
                    result_lines.append(f"- avg_width: {row.get('avg_width')}")
                    if mcv and mcf:
                        result_lines.append(f"- most_common_vals: {mcv}")
                        result_lines.append(f"- most_common_freqs: {mcf}")
                    if hist:
                        result_lines.append(f"- histogram_bounds: {hist}")
                    result_lines.append("")

                return "\n".join(result_lines)
        except Exception as e:
            return f"Error: {e}"