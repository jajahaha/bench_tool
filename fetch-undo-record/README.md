# fetch undo record 等待事件复现工具

OpenGauss/GaussDB Ustore "fetch undo record" 等待事件端到端复现，演示长事务导致查询性能逐步退化。

## 原理

Ustore 引擎采用 undo-based MVCC，每次 UPDATE 产生一条 undo record，形成 undo chain。当一个会话开启长事务并不断更新同一批行时，undo chain 越来越长。其他会话全表扫描必须沿 undo chain 逐条 fetch undo record 来重构一致读视图，遍历开销随 undo chain 增长而增加，导致：

1. 查询逐步变慢（从基线 ~2s 退化到 ~10s+）
2. 出现 "fetch undo record" 等待事件
3. COMMIT 后 undo chain 截断，扫描性能恢复到基线

## 快速开始

```bash
# OpenGauss（默认端口 5433，用户 gaussdb）
./test_fetch_undo_record.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'

# GaussDB（默认端口 8000，用户 root）
./test_fetch_undo_record.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'
```

## 参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| -t TYPE | 数据库类型 (gaussdb/opengauss) | opengauss |
| -h HOST | 数据库主机 | localhost |
| -p PORT | 端口 | 8000(gaussdb) / 5433(opengauss) |
| -d DB | 数据库名 | postgres |
| -U USER | 用户 | root(gaussdb) / gaussdb(opengauss) |
| -W PASS | 密码 | - |
| -V | 打印执行的每条 SQL（调试模式） | off |
| -r ROWS | 行数 | 20000 |
| -w WIDTH | 每行数据宽度(字节) | 3000 |
| -R ROUNDS | 长事务 UPDATE 轮次 | 35 |
| -I GAP | 扫描测量间隔(秒) | 2 |

## 测试流程

1. 创建 ustore 表（20000 行 × 3KB），插入初始数据
2. 测量基线扫描耗时（3 次采样取均值）
3. 启动后台 updater：`BEGIN` → `UPDATE val+1` × N 轮（每轮 pg_sleep 间隔） → `COMMIT`
4. 主脚本紧凑循环测量全表扫描耗时（间隔 2 秒）
5. 扫描耗时从基线逐步增长，突破 10s 后继续退化
6. updater COMMIT 后 undo chain 截断，扫描立即恢复到基线
7. 检测 undo 相关等待事件

## 增强效果

默认参数（20000 行 × 3KB × 35 轮）可从 ~2s 退化到 ~10s+。如需更强退化或更大数据集：

```bash
# 更多行数和更新轮次
./test_fetch_undo_record.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -r 50000 -R 50

# 更宽数据行
./test_fetch_undo_record.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -w 5000 -R 30
```

## 输出解读

典型输出示例：

```
  #1 (3s):   scan=3517ms (3.5s) | base=1647ms (1.6s) | 2.0x
  #2 (12s):  scan=5898ms (5.8s) | base=1647ms (1.6s) | 3.5x
  #3 (23s):  scan=8363ms (8.3s) | base=1647ms (1.6s) | 5.0x
  #4 (36s):  scan=10640ms (10.6s) | base=1647ms (1.6s) | 6.4x ← 首次突破 10s
  #12 (231s): scan=30476ms (30.4s) | base=1647ms (1.6s) | 18.1x ← 峰值
  Post-commit: 1708ms (1.7s) ← 恢复到基线
  After cleanup: 1715ms (1.7s) ← 完全恢复
```

- **elapsed**：从测试开始的累计秒数，真实时间线
- **ratio**：当前扫描 / 基线均值，越大说明退化越严重
- **COMMITTED**：后台 updater 已提交，undo chain 截断，后续扫描将恢复
- **Post-commit / After cleanup**：确认恢复到基线水平

## 客户端自动选择

opengauss/gaussdb 类型自动检测客户端：
- 有 gsql 时使用 gsql（-W 传密码）
- 否则使用 psql（URL 编码连接字符串，兼容 PostgreSQL 协议）

## 等待事件检测

脚本自动检测可用的等待事件视图，按优先级尝试：

1. **`pg_thread_wait_status`（有 `wait_event` 列）** — OpenGauss 优先使用，查询 undo 相关等待和非 none 等待
2. **`pg_stat_activity`（有 `wait_event` 列）** — GaussDB/PostgreSQL 回退，查询 undo 和活跃等待事件
3. **`pg_stat_activity`（仅 `waiting` 列）** — OpenGauss/GaussDB 最简回退，查询阻塞会话
4. **无可用视图** — 显示检测到的列结构信息，不报错不卡死

所有 SQL 查询遇到错误时，显示函数名、行号和出错 SQL，不会卡死。

## 错误处理

- psql/gsql 添加 `ON_ERROR_STOP=1`，遇到 SQL 错误立即退出，不会卡死在交互模式
- `db_exec`/`db_query` 分离 stdout 和 stderr，错误信息带函数名和行号
- 等待事件检测不依赖任何固定列名，全部动态探测

## 注意事项

- 本测试仅适用于 OpenGauss/GaussDB（PostgreSQL 无 undo 机制）
- 需要 `enable_ustore = on`，脚本会自动检查并设置
- 测试完成后自动清理测试表
- updater 连续执行 UPDATE（无 pg_sleep），总测试时间约 3-4 分钟
- 测试期间数据库负载较高，建议在测试环境运行