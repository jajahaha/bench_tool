# db_shell_bench Release Note

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