# snapshot-too-old — UStore undo 回收导致的快照损坏复现

OpenGauss/GaussDB UStore undo 回收测试，复现 "snapshot is stale" 报错和 MVCC 快照静默损坏。

## 快速开始

```bash
# GaussDB（自动使用 gsql，应触发 "snapshot is stale" 报错）
./test_snapshot_too_old.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'

# OpenGauss（自动使用 gsql 或回退 psql，检测静默 MVCC 损坏或 "snapshot is stale"）
./test_snapshot_too_old.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'

# 更多参数加大 undo 压力
./test_snapshot_too_old.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -r 50000 -R 200 -C 16 -P 30 -S 10
```

## 参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| -t TYPE | 数据库类型 (gaussdb/opengauss) | gaussdb |
| -h HOST | 数据库主机 | localhost |
| -p PORT | 端口 | 8000(gaussdb) / 5433(opengauss) |
| -d DB | 数据库名 | postgres |
| -U USER | 用户 | root(gaussdb) / gaussdb(opengauss) |
| -W PASS | 密码 | - |
| -r ROWS | 初始行数 | 10000 |
| -w WIDTH | 数据列宽度(字节) | 3900 |
| -R ROUNDS | 更新轮次 | 100 |
| -C CLIENTS | 并发更新客户端 | 8 |
| -P PRESSURE | undo 压力事务并发数 | 20 |
| -S SLEEP | undo 压力事务 pg_sleep 秒数 | 5 |

## 原理

并发 "undo 压力事务"（BEGIN+UPDATE+pg_sleep+COMMIT）积累 undo_used 超过阈值触发强制回收（绕过 oldest_xmin），截断游标快照的 undo 链。同时运行两种长事务：
- **游标 FETCH**（主要）：触发 "snapshot is stale" 报错
- **普通 SELECT**（回退）：检测 MVCC 静默损坏（返回当前值而非快照值）

OpenGauss 6.0 的行为：undo_snapshot_stale_check=on 时游标路径可报错；普通 SELECT 不走 stale check，静默返回错误数据。