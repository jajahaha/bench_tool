# wait-available-td — Ustore TD 递增并发退化测试

OpenGauss/GaussDB Ustore Transaction Directory (TD) 递增并发退化测试。

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

### 行锁级联阻塞机制

STORAGE PLAIN + 大行宽 → 页面空闲空间极小 → TD 扩展受限。

FG 与部分 BG 共享同页同页同行（IDS[0]），形成行锁级联队列：

```
级联阻塞示意（HOLD_SECS=5, 5 个 BG row = 1 2 3 4 5）：

BG0 → UPDATE id=1 (IDS[0], 与 FG 共享) → pg_sleep(5) → COMMIT
BG1 → UPDATE id=2 → pg_sleep(5) → COMMIT
BG2 → UPDATE id=3 → pg_sleep(5) → COMMIT
BG3 → UPDATE id=4 → pg_sleep(5) → COMMIT
BG4 → UPDATE id=5 → pg_sleep(5) → COMMIT
BG5 → UPDATE id=1 (与 FG 共享) → 等行锁 → 拿锁 → pg_sleep(5) → COMMIT

FG → UPDATE id=1 → 等行锁 → BG0 释放 → BG5 拿锁 → FG 继续等 → BG5 释放 → FG 拿锁
FG 总耗时 ≈ 2 × HOLD_SECS = 10s

每 5 个 BG 有一波级联（BG0, BG5, BG10... 在 IDS[0] 上排队），
波数 = floor(并发数 / 页面行数) + 1
FG 延迟 ≈ 波数 × HOLD_SECS
```

实测退化曲线（OpenGauss 6.0, HOLD_SECS=5）：

| 并发数 | 级联波数 | FG 耗时 | 退化倍数 |
|--------|----------|---------|---------|
| 0      | 0        | ~1s     | 基线    |
| 1-5    | 1        | ~5s     | 5x      |
| 6-10   | 2        | ~10s    | 10x     |
| 11+    | 3        | ~15s    | 15x     |

## 快速开始

```bash
# OpenGauss
./test_wait_available_td.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123'

# GaussDB
./test_wait_available_td.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123'

# 自定义并发和持有时间
./test_wait_available_td.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Enmotech@123' -H 10 -C 16 -V
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
| -H SECS | BG 事务持有行锁秒数 | 5 |
| -C N | 最大并发数（测试轮次 0~N） | 12 |

## 测试流程

每轮递增并发（0 到 MAX_CONCURRENCY），每轮重建表保证条件一致：

1. **建表**：Ustore + STORAGE PLAIN + FILLFACTOR=100 + VARCHAR(2000) 1540 字节 data
2. **找 page 0 行**：通过 ctid 定位同页行（约 5 行/页）
3. **行锁级联**：FG 与 BG 共享 IDS[0]，BG 每 5 个一波共享 IDS[0]
4. **Round N**：启动 N 个 BG（UPDATE + pg_sleep(HOLD_SECS)) → 等 BG settle → 启动 FG（UPDATE IDS[0]) → 测量 FG 耗时 + 监控 "wait available td"
5. **每轮重建表**：清除前轮 TD 扩展残留

## 输出解读

退化报告示例：

```
  BG#  | FG Elapsed   | Casc# | wait avail td     | Max TD #
  ---- | ----------   | ------ | ---------------    | ----------
  0    | 1.023s       | 0      | NO                 | 0
  1    | 5.103s       | 1      | NO                 | 0
  5    | 5.100s       | 1      | NO                 | 0
  6    | 10.187s      | 2      | NO                 | 0
  10   | 10.192s      | 2      | NO                 | 0
  11   | 15.271s      | 3      | NO                 | 0
  12   | 15.282s      | 3      | NO                 | 0
```

- **Casc#**：级联波数（IDS[0] 上的排队 BG 数）
- **wait avail td**：是否观测到 "wait available td" 等待事件
- 退化里程碑：1s / 5s / 10s 阈值首次出现的轮次

## 客户端自动选择

opengauss/gaussdb 类型自动检测客户端：
- 有 gsql 时使用 gsql
- 否则使用 psql（兼容 PostgreSQL 协议）

## 关于 "wait available td"

OpenGauss 6.0 的 TD 动态扩展机制较为完善，在页面仍有 ~293 字节空闲空间时可成功扩展 TD。
因此 "wait available td" 在中等并发下不易出现。退化主要来自行锁级联阻塞。

如需观测 "wait available td"：
- 增大并发至 TD 扩展耗尽空闲空间（约 13+ 并发）
- 在 GaussDB 上测试（TD 扩展机制可能更受限）

## 许可证

MIT