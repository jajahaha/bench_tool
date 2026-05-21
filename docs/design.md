# db_shell_bench 设计文档

## 项目定位

纯 shell 脚本实现的数据库基准测试工具，无编译依赖，适用于 PostgreSQL、OpenGauss、GaussDB。

## 架构设计

```
db_shell_bench.sh
├── 参数解析层 ─── 提取命令词(init/benchmark)，解析选项参数(-h/-p/-U/-W/-M 等)
├── 连接层 ──────── detect_client() → 自动选择 gsql/psql
│                   get_conn_str() → 密码通过 URL 编码的连接字符串传递
│                   db_exec() / db_exec_quiet() → SQL 执行(带输出/安静模式)
├── 初始化层 ────── init_database() → 建表、分批插入数据、建索引、VACUUM ANALYZE
└── 基准测试层 ──── build_txn_sql() → 根据模式生成事务 SQL
│                   run_benchmark_single() → 单客户端事务数模式
│                   run_benchmark_multi() → 多客户端事务数模式
│                   run_benchmark_time() → 多客户端时间模式
│                   print_progress() → 每 3 秒追加一行进度
```

## 数据模型

| 表 | 主键 | 数据量(scale=N) | 说明 |
|----|------|-----------------|------|
| {prefix}_branches | bid | N | 分行表 |
| {prefix}_tellers | tid | N×10 | 柜员表 |
| {prefix}_accounts | aid | N×100000 | 账户表（主表） |
| {prefix}_history | 无 | 动态增长 | 历史记录表 |

初始化时 accounts 表按 100000 行/批次分批插入，每批次显示进度和耗时。

## 事务模式设计

### tpcb（轻量模式）

经典 TPC-B 模型，每事务 5 条 SQL：

```
BEGIN;
  UPDATE accounts SET abalance += delta WHERE aid = ?;   -- 写
  SELECT abalance FROM accounts WHERE aid = ?;            -- 读
  UPDATE tellers SET tbalance += delta WHERE tid = ?;     -- 写
  UPDATE branches SET bbalance += delta WHERE bid = ?;    -- 写
  INSERT INTO history VALUES (...);                       -- 写
COMMIT;
```

特点：写密集、点查询、单行操作，适合测试基本事务吞吐。

### heavy（重量模式）

混合读写负载，每事务 10 条 SQL：

```
BEGIN;
  SELECT abalance, bid FROM accounts WHERE aid = ?;          -- 点查询
  SELECT bbalance FROM branches WHERE bid = ?;               -- 点查询
  SELECT tbalance, bid FROM tellers WHERE tid = ?;           -- 点查询
  SELECT abalance FROM accounts WHERE bid = ? ORDER BY aid LIMIT 10;  -- 范围扫描
  SELECT avg(abalance) FROM accounts WHERE bid = ?;          -- 聚合查询
  UPDATE accounts SET abalance += delta WHERE aid = ?;       -- 写
  UPDATE tellers SET tbalance += delta WHERE tid = ?;        -- 写
  UPDATE branches SET bbalance += delta WHERE bid = ?;       -- 写
  INSERT INTO history VALUES (...);                          -- 写
  SELECT delta, mtime FROM history WHERE aid = ? ORDER BY mtime DESC LIMIT 10;  -- 历史查询
COMMIT;
```

特点：5 读 + 3 写 + 2 历史查询，包含范围扫描和聚合，更贴近真实业务场景。

## 连接与认证

- PostgreSQL：使用 psql，密码通过 `postgresql://user:pass@host:port/db` 连接字符串传递
- OpenGauss/GaussDB：优先 gsql，回退 psql，密码同样通过连接字符串传递
- 密码中的特殊字符（@、:、/等）通过 URL 编码处理

## 进度显示

- 基准测试：每 3 秒追加一行进度（[秒数] txns: 已完成数, tps: 当前值）
- 初始化：每批次显示已完成行数、耗时、预估剩余时间、行/秒速率
- 各阶段（建索引、VACUUM ANALYZE）独立显示耗时

## Undo 测试（undo 目录）

OpenGauss/GaussDB UStore undo 回收导致的 MVCC 快照损坏复现测试。

### 文件

- `undo/test_snapshot_too_old.sh` — UStore undo 回收测试用例

### 发现的问题

测试发现 OpenGauss 6.0 UStore 的 undo 回收机制存在比 "snapshot is stale" 更严重的问题：

1. **"snapshot is stale" 报错**（Oracle/GaussDB 的正确行为）— undo 记录被强制回收后，游标报错，用户知道数据不可用
2. **MVCC 快照静默损坏**（OpenGauss 实际行为）— undo 记录被回收后，普通 SELECT **不报错**，但静默返回当前版本而非快照版本的数据

### 触发原理

OpenGauss 的 undo 回收有两层机制：
1. **正常回收**：尊重 oldest_xmin，只回收已提交且无人引用的 undo 记录
2. **强制回收**：当 undo_used 超过 undo_threshold（undo_space_limit × 80%）时，**绕过 oldest_xmin** 强制回收

触发步骤：
1. 创建 ustore 表，插入 val=0 的数据
2. Session 1 开启长事务游标，FETCH 获取快照数据
3. N 个并发 "undo 压力事务"（BEGIN + UPDATE 全表 + pg_sleep + COMMIT），积累 undo_used 超过阈值
4. 强制回收触发，绕过 oldest_xmin 回收游标快照需要的 undo 记录
5. 游标继续 FETCH 时，undo 链已被截断 → 报 "snapshot is stale"（GaussDB）
6. 或普通 SELECT 静默返回当前值而非快照值（OpenGauss bug）

### 关键参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| -t TYPE | 数据库类型（gaussdb/opengauss） | gaussdb |
| -r ROWS | 初始行数 | 10000 |
| -w WIDTH | 数据列宽度（字节）| 3900 |
| -R ROUNDS | 快速更新轮次 | 100 |
| -C CLIENTS | 快速更新并发数 | 8 |
| -P PRESSURE | undo 压力事务并发数 | 20 |
| -S SLEEP | 压力事务 pg_sleep 秒数 | 5 |

### 客户端自动选择

gaussdb/opengauss 自动检测客户端：
- 有 gsql 时使用 gsql（gsql 用 -W 传递密码）
- 否则使用 psql（psql 用 URL 编码连接字符串传递密码）

脚本自动配置：
- `ALTER SYSTEM SET undo_space_limit_size = 102400`（降低到 800MB，阈值 640MB）
- 检查并启用 `undo_snapshot_stale_check = on`（控制 "snapshot is stale" 报错）

### 测试策略

两层并发产生 undo 压力：
1. **undo 压力事务**（主要）— 并发 N 个事务，每个做 BEGIN + UPDATE 全表 + pg_sleep(S) + COMMIT，积累 undo_used 超过阈值触发强制回收
2. **快速分区更新**（辅助）— 并发分区 UPDATE 立即提交，持续产生 undo 回收需求

同时运行两种长事务检测：
1. **游标模式** — DECLARE CURSOR + pg_sleep + FETCH，触发 "snapshot is stale" 报错
2. **SELECT 模式** — SELECT + pg_sleep + SELECT，检测 val 静默损坏

OpenGauss 6.0 的行为差异：
- 游标 FETCH：返回 val=0（正确快照数据）或报 "snapshot is stale"（undo 被强制回收）
- 普通 SELECT：返回 val≠0（静默返回当前值而非快照值，MVCC 损坏）
- undo_snapshot_stale_check=on 时，游标路径应正确报错；但普通 SELECT 不走 stale check

GaussDB 商业版预期行为：
- 游标 FETCH 应触发 "snapshot is stale" 报错
- 不应静默返回错误数据

### 注意事项

- 仅适用于 OpenGauss/GaussDB（PostgreSQL 无 undo 机制）
- 需要 `enable_ustore=on`
- 检测的是 MVCC 快照静默损坏，不仅限于 "snapshot is stale" 报错
- 错误信息搜索包含 "snapshot is stale" 和 "snapshot too old" 两种