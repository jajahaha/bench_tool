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