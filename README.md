# db_shell_bench

数据库基准测试与运维工具集，纯 shell 脚本 + Python MCP Server 实现。支持 PostgreSQL、OpenGauss、GaussDB。

## 功能列表

| 功能 | 目录 | 简介 |
|------|------|------|
| 基准测试 | [benchmark/](benchmark/) | TPC-B / Heavy 模式数据库性能基准测试 |
| MCP Server | [pg_mcp_server/](pg_mcp_server/) | PostgreSQL MCP Server，为 Claude Code 提供 SQL 查询、元数据、监控、执行计划分析 |
| snapshot too old | [snapshot-too-old/](snapshot-too-old/) | 复现 OpenGauss/GaussDB UStore undo 回收导致的快照损坏 |
| fetch undo record | [fetch-undo-record/](fetch-undo-record/) | 复现 UStore undo chain 遍历导致的查询性能退化 |
| 执行计划跳变 | [plan-jump/](plan-jump/) | PostgreSQL / OpenGauss 执行计划跳变应急 SOP |
| wait available td | [wait-available-td/](wait-available-td/) | 复现 Ustore TD 槽位不足导致的行锁级联阻塞与 SQL 退化（ms→10s+） |

各功能的使用说明、参数、原理详见各自目录下的 README。

## 新增功能规范

每个功能独立目录，目录名用连字符（Shell 模块）或下划线（Python 模块），目录下必须包含：
- 功能脚本/代码
- README.md（使用说明、参数表、原理、示例）

## 许可证

MIT