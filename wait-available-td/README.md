# wait-available-td — Ustore TD 等待与死锁复现

OpenGauss/GaussDB Ustore Transaction Directory (TD) 等待事件与死锁复现测试。

## 原理

Ustore 将 Astore 中每行 tuple 上的事务信息 (xmin/xmax) 统一移到页面级的 **Transaction Directory (TD)**。默认每页只有 **4 个 TD 槽位**。

| | Astore | Ustore |
|---|---|---|
| 事务信息位置 | 每 tuple 上存 xmin/xmax | 统一移到页面级 TD |
| 并发开销 | 每 tuple 独立，无争用 | 每 page 共享有限 TD 槽位 |
| TD 数量 | 无此概念 | 默认每页 **4 个**（可动态扩展） |

### TD 动态扩展

OpenGauss 6.0+ 支持 TD 动态扩展：当 4 个 TD 槽位不够时，从页面空闲空间分配更多 TD。
**"wait available td" 只在页面空闲空间耗尽、TD 扩展失败时出现**。

因此 "wait available td" 在正常条件下较难复现，需要页面几乎完全填满（无空闲空间供 TD 扩展）。

### 死锁 + TD 页面级饥饿

TD 的引入使死锁影响范围扩大：

| | Astore | Ustore (TD) |
|---|---|---|
| 同页行锁死锁影响 | 仅参与事务 | 参与事务 + **该页所有新事务** |
| 原因 | 每行独立事务信息 | 死锁事务占满 TD → 新事务无法获取 TD → 页面级饥饿 |

```
死锁场景:
T1 (占 TD0): UPDATE row_A → UPDATE row_B → 等待 T2 行锁
T2 (占 TD1): UPDATE row_B → UPDATE row_A → 等待 T1 行锁
→ 互相等待 → 死锁 (deadlock detector 中止其中一个)

TD 饥饿:
死锁事务 T1, T2 占 TD → T3, T4, T5 在同页新事务 → 无 TD → 页面级停滞
Astore 无此问题: 每行独立 xmin/xmax, 死锁只影响参与事务
```

## 快速开始

```bash
# OpenGauss
./test_wait_available_td.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'

# GaussDB
./test_wait_available_td.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'

# verbose 模式
./test_wait_available_td.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -V
```

## 参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| -t TYPE | 数据库类型 (opengauss/gaussdb) | opengauss |
| -h HOST | 数据库主机 | localhost |
| -p PORT | 端口 | 5433(opengauss) / 8000(gaussdb) |
| -d DB | 数据库名 | postgres |
| -U USER | 用户 | gaussdb(opengauss) / root(gaussdb) |
| -W PASS | 密码 | - |
| -T TABLE | 表名 | td_test |
| -V | verbose：打印每条 SQL | 关闭 |
| -H SECS | Phase 1 TD 持有时间(秒) | 30 |
| -D SECS | Phase 2 死锁检测超时(秒) | 15 |

## 测试流程

### Phase 1: TD contention

1. 创建 Ustore 表 (200 行，小宽度确保同页聚集)
2. 启动 4 个后台事务：各 UPDATE 同页不同行 + pg_sleep(HOLD_SECS) → 占满初始 4 个 TD
3. 第 5 个事务 UPDATE 同页另一行 → TD 动态扩展分配新 TD
4. 监测 "wait available td" 等待事件（仅在页面空闲空间耗尽时出现）
5. 若 FG5 快速完成 → TD 扩展成功；若 FG5 等待 → TD 扩展失败

**实测结论 (OpenGauss 6.0)：** TD 扩展非常高效，即使 100+ 并发事务也能通过扩展获取 TD。
"wait available td" 需要页面空闲空间耗尽的极端场景才能复现。

### Phase 2: Deadlock（已验证可复现）

1. T1: BEGIN → UPDATE row_A → pg_sleep(3) → UPDATE row_B
2. T2: BEGIN → UPDATE row_B → pg_sleep(3) → UPDATE row_A
3. T1 持有 row_A 行锁，等待 T2 的 row_B 行锁
4. T2 持有 row_B 行锁，等待 T1 的 row_A 行锁
5. 死锁！deadlock detector 中止其中一个事务
6. 死锁事务占住 TD → 同页新事务无法获取 TD → 页面级饥饿

## 客户端自动选择

opengauss/gaussdb 类型自动检测客户端：
- 有 gsql 时使用 gsql
- 否则使用 psql（兼容 PostgreSQL 协议）

## 输出解读

- Deadlock `REPRODUCED ✓` — 成功复现同页行锁死锁
- "wait available td" `NOT REPRODUCED ✗` / `TD expansion succeeded` — 页面有足够空闲空间支持 TD 动态扩展
- 要复现 "wait available td"：需创建大行宽 (STORAGE PLAIN) 表使页面几乎满载，令 TD 扩展无空间

## 许可证

MIT