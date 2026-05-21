# db_shell_bench

数据库基准测试工具，纯 shell 脚本实现。支持 PostgreSQL、OpenGauss、GaussDB。

## 快速开始

```bash
# PostgreSQL
./db_shell_bench.sh init -s 1 -h localhost -p 5432 -U postgres
./db_shell_bench.sh -h localhost -p 5432 -U postgres -c 4 -n 100 benchmark

# OpenGauss / GaussDB
./db_shell_bench.sh -t opengauss init -s 1 -h localhost -p 5433 -U gaussdb -W 'Pass@123'
./db_shell_bench.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -c 4 -T 60 benchmark

# Heavy 模式（更复杂的混合读写测试）
./db_shell_bench.sh -M heavy -c 4 -T 60 benchmark
```

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| -t TYPE | 数据库类型 (postgres/opengauss/gaussdb) | postgres |
| -h HOST | 数据库主机 | localhost |
| -p PORT | 端口 | 5432 |
| -d DB | 数据库 | postgres |
| -U USER | 用户 | postgres |
| -W PASS | 密码 | - |
| -P PREFIX | 表前缀 | dbbench |
| -s SCALE | 初始化缩放因子 | 1 |
| -M MODE | 测试模式 (tpcb/heavy) | tpcb |
| -c CLIENTS | 并发数 | 1 |
| -n TXNS | 事务数/客户端 | - |
| -T SECS | 持续时间(秒) | - |

## 测试模式

### tpcb（轻量模式）

每事务 5 条 SQL，经典 TPC-B 模型：
- 3 条 UPDATE（账户、柜员、分行余额）
- 1 条 SELECT（查询账户余额）
- 1 条 INSERT（插入历史记录）

### heavy（重量模式）

每事务 10 条 SQL，混合读写负载：
- 5 条读操作：点查询、范围扫描（LIMIT 10）、聚合查询（AVG）
- 3 条写操作：UPDATE 余额 + INSERT 历史记录
- 2 条历史查询：按时间倒序查询最近记录

适合更贴近真实业务场景的压力测试。

## 客户端自动选择

opengauss/gaussdb 类型自动检测客户端：
- 有 gsql 时使用 gsql
- 否则使用 psql（兼容 PostgreSQL 协议）

## 初始化进度

init 命令分批插入数据，实时显示进度：
- 每批次 100,000 行，显示已完成行数、耗时、预估剩余时间、速率
- 各阶段（建索引、VACUUM ANALYZE）独立显示耗时

## 测试

```bash
./test_db_shell_bench.sh
```

## 许可证

MIT

## Undo 测试

OpenGauss/GaussDB UStore undo 回收测试，复现 "snapshot too old" 报错和 MVCC 快照静默损坏：

```bash
# GaussDB（自动使用 gsql，应触发 "snapshot too old" 报错）
./undo/test_snapshot_too_old.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'

# OpenGauss（自动使用 gsql 或回退 psql，检测静默 MVCC 损坏）
./undo/test_snapshot_too_old.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'

# 更多参数加大 undo 压力
./undo/test_snapshot_too_old.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -r 50000 -R 200 -C 8
```

测试同时运行游标和普通 SELECT 两种长事务：
- **游标 FETCH**（主要）：在 GaussDB 上触发 "snapshot too old" 报错
- **普通 SELECT**（回退）：在 OpenGauss 上检测 MVCC 静默损坏（返回当前值而非快照值）

OpenGauss 6.0 的行为差异：游标返回正确快照数据，但普通 SELECT 静默返回错误数据且不报错。