# PostgreSQL MCP Server

基于 FastMCP 框架的 PostgreSQL MCP Server，为 Claude Code 提供 SQL 查询执行、数据库元数据、性能监控、执行计划分析四种工具能力。

## 安装依赖

```bash
pip3 install --break-system-packages fastmcp psycopg[binary] psycopg_pool
```

## 配置

### 连接参数

通过环境变量配置 PostgreSQL 连接：

| 环境变量 | 说明 | 默认值 |
|---------|------|--------|
| `PGHOST` | 主机地址 | `localhost` |
| `PGPORT` | 端口 | `5432` |
| `PGDATABASE` | 数据库名 | `postgres` |
| `PGUSER` | 用户名 | `postgres` |
| `PGPASSWORD` | 密码 | 空 |

### Claude Code 集成

在项目根目录创建 `.mcp.json`：

```json
{
  "mcpServers": {
    "pg-server": {
      "command": "python3",
      "args": ["-m", "pg_mcp_server.server"],
      "env": {
        "PGHOST": "127.0.0.1",
        "PGPORT": "5432",
        "PGDATABASE": "postgres",
        "PGUSER": "lcj"
      }
    }
  }
}
```

启动 Claude Code 后会自动加载 MCP Server。

### 手动启动

```bash
# 设置连接环境变量后直接运行
export PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=postgres PGUSER=lcj
python3 -m pg_mcp_server.server
```

## 工具列表

### 1. SQL 查询执行

#### `execute_query` — 执行只读查询

- **参数**: `sql` (SELECT/EXPLAIN/SHOW/WITH), `limit` (最大返回行数, 默认100, 上限1000), `format` (table|text)
- **安全**: 只允许 SELECT、EXPLAIN、SHOW、WITH 开头的 SQL
- **示例**: `SELECT version();`、`SELECT * FROM pgbench_accounts LIMIT 10;`

#### `execute_dml` — 执行写操作

- **参数**: `sql` (INSERT/UPDATE/DELETE), `dry_run` (默认 true)
- **安全**: `dry_run=true` 时仅用 EXPLAIN 验证语法不执行；需显式设 `dry_run=false` 才真正执行
- **示例**: `INSERT INTO test_table VALUES (1, 'hello')` — 默认 dry_run 验证语法

### 2. 数据库元数据

| 工具 | 参数 | 说明 |
|------|------|------|
| `list_tables` | schema (默认 public) | 列出所有表 |
| `describe_table` | table_name, schema | 列定义、索引、约束 |
| `list_indexes` | table_name (可选), schema | 索引信息 |
| `list_schemas` | 无 | 列出所有 schema |
| `get_table_stats` | table_name, schema | 行数、大小、analyze 时间 |

### 3. 性能监控

| 工具 | 参数 | 说明 |
|------|------|------|
| `get_active_queries` | 无 | 当前活跃/idle-in-transaction 查询 |
| `get_slow_queries` | min_duration_ms (默认5000), limit (默认20) | pg_stat_statements 慢查询 |
| `get_lock_waits` | 无 | 锁等待阻塞关系 |
| `get_connections_summary` | 无 | 连接统计 |
| `get_database_size` | 无 | 各数据库磁盘大小 |

### 4. 执行计划分析

| 工具 | 参数 | 说明 |
|------|------|------|
| `explain_plan` | sql, analyze (默认false), buffers (默认false) | EXPLAIN 输出 |
| `explain_plan_json` | sql, analyze (默认false) | JSON 格式执行计划 |
| `get_stats_info` | table_name, column_name (可选), schema | pg_stats 列级统计 |

## 文件结构

```
pg_mcp_server/
├── __init__.py          — 版本号
├── server.py            — MCP Server 主入口
├── db.py                — 连接池 + 辅助函数
├── tools/
│   ├── __init__.py
│   ├── query.py         — SQL 查询执行
│   ├── metadata.py      — 数据库元数据
│   ├── monitor.py       — 性能监控
│   └── explain.py       — 执行计划分析
└── requirements.txt     — 依赖清单
```