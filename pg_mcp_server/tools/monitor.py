"""Performance monitoring tools."""

from typing import Annotated
from pydantic import Field

from pg_mcp_server.db import format_as_markdown_table


def register(mcp):
    """Register monitoring tools on the MCP server."""

    @mcp.tool()
    def get_active_queries() -> str:
        """Get currently running queries from pg_stat_activity. Shows query text, state, duration, and client info."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                rows = conn.execute(
                    """
                    SELECT
                        pid,
                        usename,
                        application_name,
                        client_addr,
                        state,
                        state_change,
                        NOW() - state_change AS duration,
                        query
                    FROM pg_stat_activity
                    WHERE state IN ('active', 'idle in transaction')
                      AND pid != pg_backend_pid()
                    ORDER BY (NOW() - state_change) DESC
                    """
                ).fetchall()
                if not rows:
                    return "No active or idle-in-transaction queries found."
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def get_slow_queries(
        min_duration_ms: Annotated[int, Field(gt=0, description="Minimum duration in milliseconds")] = 5000,
        limit: Annotated[int, Field(gt=0, le=50, description="Max queries to return")] = 20,
    ) -> str:
        """Find slow queries from pg_stat_statements. Requires pg_stat_statements extension to be enabled."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                # Check if pg_stat_statements is available
                ext = conn.execute(
                    "SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements'"
                ).fetchone()
                if ext["count"] == 0:
                    return "pg_stat_statements extension is not installed. Install it with: CREATE EXTENSION pg_stat_statements;"

                rows = conn.execute(
                    """
                    SELECT
                        calls,
                        round(total_exec_time::numeric, 2) AS total_ms,
                        round(mean_exec_time::numeric, 2) AS mean_ms,
                        round(max_exec_time::numeric, 2) AS max_ms,
                        round(stddev_exec_time::numeric, 2) AS stddev_ms,
                        rows,
                        shared_blks_hit + shared_blks_read AS total_blks,
                        query
                    FROM pg_stat_statements
                    WHERE mean_exec_time > %s
                    ORDER BY mean_exec_time DESC
                    LIMIT %s
                    """,
                    [min_duration_ms, limit],
                ).fetchall()
                if not rows:
                    return f"No queries found with mean duration > {min_duration_ms}ms."
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def get_lock_waits() -> str:
        """Find sessions waiting for locks and the sessions blocking them. Shows lock type, relation, and blocking query."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                rows = conn.execute(
                    """
                    SELECT
                        blocked.pid AS blocked_pid,
                        blocked.usename AS blocked_user,
                        blocked.query AS blocked_query,
                        blocking.pid AS blocking_pid,
                        blocking.usename AS blocking_user,
                        blocking.query AS blocking_query,
                        blocked_locks.mode AS blocked_mode,
                        blocking_locks.mode AS blocking_mode,
                        COALESCE(rel.relname, '') AS locked_table
                    FROM pg_locks blocked_locks
                    JOIN pg_stat_activity blocked ON blocked.pid = blocked_locks.pid
                    JOIN pg_locks blocking_locks
                        ON blocking_locks.locktype = blocked_locks.locktype
                        AND (blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
                             OR blocked_locks.database IS NULL)
                        AND (blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
                             OR blocked_locks.relation IS NULL)
                        AND blocking_locks.pid != blocked_locks.pid
                        AND NOT blocked_locks.granted
                        AND blocking_locks.granted
                    JOIN pg_stat_activity blocking ON blocking.pid = blocking_locks.pid
                    LEFT JOIN pg_class rel ON rel.oid = blocked_locks.relation
                    ORDER BY blocked.pid
                    """
                ).fetchall()
                if not rows:
                    return "No lock waits detected."
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def get_connections_summary() -> str:
        """Get connection statistics grouped by state and application_name."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                rows = conn.execute(
                    """
                    SELECT
                        state,
                        application_name,
                        usename,
                        count(*) AS connections,
                        max(NOW() - state_change) AS max_idle_duration
                    FROM pg_stat_activity
                    WHERE pid != pg_backend_pid()
                    GROUP BY state, application_name, usename
                    ORDER BY count(*) DESC
                    """
                ).fetchall()
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error: {e}"

    @mcp.tool()
    def get_database_size() -> str:
        """Get disk size for all databases."""
        pool = mcp._lifespan_context["db_pool"]
        try:
            with pool.connection() as conn:
                rows = conn.execute(
                    """
                    SELECT
                        datname AS database,
                        pg_size_pretty(pg_database_size(datname)) AS size,
                        pg_database_size(datname) AS size_bytes
                    FROM pg_database
                    WHERE datistemplate = false
                    ORDER BY pg_database_size(datname) DESC
                    """
                ).fetchall()
                return format_as_markdown_table(rows)
        except Exception as e:
            return f"Error: {e}"