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
| -r ROWS | 行数 | 20000 |
| -w WIDTH | 每行数据宽度(字节) | 3000 |
| -R ROUNDS | 长事务 UPDATE 轮次 | 35 |
| -I INTERVAL | 扫描测量间隔(秒) | 5 |

## 测试流程

1. 创建 ustore 表（20000 行 × 3KB），插入初始数据
2. 测量基线扫描耗时（3 次采样取均值）
3. 启动后台 updater：`BEGIN` → 逐轮 `UPDATE val+1` → `pg_sleep` 保持事务 → `COMMIT`
4. 主脚本每轮 UPDATE 后测量全表扫描耗时
5. 扫描耗时从 ~2s 基线逐步增长到 ~10s+ 峰值（默认参数）
6. updater COMMIT 后 undo chain 截断，扫描恢复到基线
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
  Round 1/35:  scan=2331ms (2.3s) | base=1941ms (1.9s) | 1.2x
  Round 10/35: scan=6444ms (6.4s) | base=1941ms (1.9s) | 3.3x
  Round 14/35: scan=10957ms (10.9s) | base=1941ms (1.9s) | 5.6x
  Round 18/35: scan=13886ms (13.8s) | base=1941ms (1.9s) | 7.1x  ← 峰值
  Round 20 (COMMITTED): scan=13178ms (13.1s) ← undo chain 截断后首次扫描
  Post-commit: 2108ms (2.1s) ← 恢复到基线
  After cleanup: 2033ms (2.0s) ← 完全恢复
```

- **ratio**：当前扫描 / 基线均值，越大说明退化越严重
- **COMMITTED**：后台 updater 已提交，undo chain 截断，后续扫描将恢复
- **Post-commit / After cleanup**：确认恢复到基线水平

## 客户端自动选择

opengauss/gaussdb 类型自动检测客户端：
- 有 gsql 时使用 gsql（-W 传密码）
- 否则使用 psql（URL 编码连接字符串，兼容 PostgreSQL 协议）

## 等待事件检测

脚本自动适配不同数据库版本的等待事件视图：

- **OpenGauss**：查询 `pg_thread_wait_status`（有 `wait_event` 和 `db_name` 列）
- **GaussDB**：若 `pg_thread_wait_status` 无 `wait_event` 列，回退到 `pg_stat_activity` 查询
- 两种方式均检测 undo 相关等待事件和活跃阻塞会话

## 注意事项

- 本测试仅适用于 OpenGauss/GaussDB（PostgreSQL 无 undo 机制）
- 需要 `enable_ustore = on`，脚本会自动检查并设置
- 测试完成后自动清理测试表
- 长事务持续时间取决于 `-R × -I` 参数，默认 35 × 5 = 175 秒
- 测试期间数据库负载较高，建议在测试环境运行