"""PostgreSQL MCP Server — main entry point."""

from contextlib import asynccontextmanager
from fastmcp import FastMCP

from pg_mcp_server.db import create_pool
from pg_mcp_server.tools.query import register as register_query
from pg_mcp_server.tools.metadata import register as register_metadata
from pg_mcp_server.tools.monitor import register as register_monitor
from pg_mcp_server.tools.explain import register as register_explain


@asynccontextmanager
async def lifespan(server: FastMCP):
    """Manage connection pool lifecycle."""
    pool = create_pool(min_size=2, max_size=10)
    server._lifespan_context = {"db_pool": pool}
    try:
        yield {"db_pool": pool}
    finally:
        pool.close()


mcp = FastMCP("PostgreSQL MCP Server", lifespan=lifespan)

# Register all tool groups
register_query(mcp)
register_metadata(mcp)
register_monitor(mcp)
register_explain(mcp)


if __name__ == "__main__":
    mcp.run()