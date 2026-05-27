# db_shell_bench Release Note

## v4 (2026-05-27)

### 新增功能

- **fetch undo record 等待事件复现** — 新增 fetch-undo-record 目录，端到端复现 OpenGauss/GaussDB Ustore "fetch undo record" 等待事件导致的查询性能退化
  - 长事务持续 UPDATE 扩展 undo chain，并发全表扫描必须遍历 undo chain 获取一致读
  - 每轮测量扫描耗时，展示从基线到逐步退化的趋势
  - 检测 pg_stat_activity 和 dbe_perf.wait_events 中的 "fetch undo record" 事件

## v3 (2026-05-26)

### 新增功能

- **PostgreSQL MCP Server** — 基于 FastMCP 框架的 MCP Server，为 Claude Code 提供 4 种数据库工具能力
  - SQL 查询执行：`execute_query`（只读 SELECT）、`execute_dml`（写操作，默认 dry_run）
  - 数据库元数据：`list_tables`、`describe_table`、`list_indexes`、`list_schemas`、`get_table_stats`
  - 性能监控：`get_active_queries`、`get_slow_queries`、`get_lock_waits`、`get_connections_summary`、`get_database_size`
  - 执行计划分析：`explain_plan`、`explain_plan_json`、`get_stats_info`
- **安全措施** — SELECT-only 白名单、DML 默认 dry_run、结果行数上限 1000
- **环境变量连接配置** — PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD
- **`.mcp.json` 配置** — Claude Code 自动加载 MCP Server

## v2 (2026-05-21)

### 新增功能

- **多数据库支持** — 支持 PostgreSQL、OpenGauss、GaussDB（`-t TYPE`）
- **密码参数** — 添加 `-W PASS` 参数，密码 URL 编码处理特殊字符
- **客户端自动选择** — opengauss/gaussdb 优先使用 gsql，回退 psql
- **heavy 测试模式** — 添加 `-M heavy` 模式，每事务 10 条 SQL（5 读 + 3 写 + 2 历史查询），包含范围扫描和聚合
- **初始化进度** — 分批插入数据（100000 行/批次），显示行数、耗时、预估剩余时间、速率
- **阶段耗时** — 建索引、VACUUM ANALYZE 各阶段独立计时
- **实时进度** — 基准测试每 3 秒追加一行进度（不再覆盖）
- **灵活参数顺序** — 支持 `init -s 10` 和 `-s 10 init` 两种格式
- **Ustore undo 回收测试** — 新增 undo 目录，复现 OpenGauss/GaussDB Ustore undo 回收导致的 MVCC 快照静默损坏问题（比 "snapshot too old" 更严重）
- **游标 FETCH 测试** — 使用 DECLARE CURSOR + pg_sleep + FETCH 触发 "snapshot is stale" 报错（GaussDB/OpenGauss），同时用普通 SELECT 检测静默损坏（OpenGauss）
- **undo 压力事务** — 新增 -P/-S 参数，并发 BEGIN+UPDATE+pg_sleep+COMMIT 事务积累 undo_used 超过阈值触发强制回收（绕过 oldest_xmin）
- **undo_snapshot_stale_check** — 自动检查并启用 undo_snapshot_stale_check 参数，确保 "snapshot is stale" 报错功能开启
- **双错误字符串检测** — 同时搜索 "snapshot is stale"（OpenGauss）和 "snapshot too old"（GaussDB/Oracle）两种错误信息
- **客户端自动选择** — undo 测试脚本自动选择 gsql（优先）或 psql，gsql 用 -W 传密码，psql 用 URL 编码连接字符串

### 变更

- 事务数参数从 `-t` 改为 `-n`（`-t` 用于数据库类型）
- 初始化操作使用 db_exec_quiet 抑制命令反馈，输出更整洁

## v1 (2026-05-20)

### 初始版本

- PostgreSQL 基准测试工具
- TPC-B 事务模式（5 条 SQL/事务）
- 单客户端和多客户端并发测试
- 事务数模式和时间模式
- 15 个测试用例