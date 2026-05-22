# PostgreSQL 执行计划跳变应急预案 SOP

## 一、概述

执行计划跳变是指同一 SQL 在不同时间点产生不同执行计划，导致性能剧烈波动。
常见原因：统计信息变化、数据分布改变、优化器代价临界、参数调整。

本 SOP 覆盖：识别统计信息变化 → 重新收集统计信息 → 固定执行计划。

## 二、告警发现与问题确认

### 2.1 监控发现性能劣化

```sql
-- pg_stat_statements: 查找平均执行时间突然升高的 SQL
SELECT query_hash_value, query, calls, mean_exec_time, max_exec_time,
       stddev_exec_time, rows, shared_blks_hit
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;

-- PG16+: 检测同一 SQL 是否出现不同 plan_hash_value（计划跳变）
SELECT query_hash_value, plan_hash_value, calls, mean_exec_time, query
FROM pg_stat_statements
WHERE query_hash_value IN (
    SELECT query_hash_value
    FROM pg_stat_statements
    GROUP BY query_hash_value
    HAVING COUNT(DISTINCT plan_hash_value) > 1
)
ORDER BY query_hash_value, mean_exec_time DESC;
```

### 2.2 确认计划跳变

```sql
-- 保存当前执行计划（慢计划）
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) <问题SQL>;

-- 如果有历史好计划记录，对比差异
-- 关键对比项：扫描方式(SeqScan/IndexScan)、连接方式(NestLoop/HashJoin/MergeJoin)、连接顺序
```

### 2.3 快速确认是否统计信息导致

```sql
-- 检查最近是否有 autovacuum analyze 触发
SELECT relname, last_analyze, last_autoanalyze, vac_cnt, analyze_cnt
FROM pg_stat_all_tables
WHERE relname = '<问题表名>';

-- 检查统计信息是否准确
SELECT attname, n_distinct, correlation, null_frac,
       most_common_vals, most_common_freqs,
       histogram_bounds
FROM pg_stats
WHERE tablename = '<问题表名>';
```

## 三、应急止血 — 固定执行计划

### 3.1 方案 A：pg_hint_plan（推荐）

#### 安装与启用

```sql
-- 安装扩展（需 shared_preload_libraries 包含 pg_hint_plan）
CREATE EXTENSION pg_hint_plan;

-- 会话级启用
SET pg_hint_plan.enable_hint = on;
SET pg_hint_plan.debug_print = on;  -- 调试模式，确认 hint 生效
```

#### 常用 Hint 类型

| Hint 类型 | 语法 | 说明 |
|-----------|------|------|
| 扫描方式 | `SeqScan(t)` / `IndexScan(t idx_name)` / `BitmapScan(t idx_name)` | 强制扫描路径 |
| 连接方式 | `NestLoop(t1 t2)` / `HashJoin(t1 t2)` / `MergeJoin(t1 t2)` | 强制连接算法 |
| 连接顺序 | `Leading(t1 t2 t3)` | 强制驱动表顺序 |
| 行数修正 | `Rows(t1 #100)` / `Rows(t1 t2 +100)` | 修正行数估算 |
| 并行度 | `Parallel(t 4)` | 强制并行 workers 数 |
| GUC 临时修改 | `Set(random_page_cost 1.1)` | 临时调整规划器参数 |

#### 使用示例

```sql
-- 强制走索引扫描
/*+ IndexScan(users idx_users_email) */
SELECT * FROM users WHERE email = 'test@example.com';

-- 强制 Hash Join + 指定驱动表
/*+ HashJoin(orders customers) Leading(orders customers) */
SELECT * FROM orders o JOIN customers c ON o.cust_id = c.id;

-- 禁止全表扫描 + 修正行数
/*+ SeqScan(big_table) no IndexScan(big_table idx_big_status) Rows(big_table #10000) */
SELECT * FROM big_table WHERE status = 'active';
```

#### Hint 持久化（无需改 SQL）

```sql
-- 将 hint 规则写入 hint_plan.hints 表，对所有匹配 SQL 自动生效
INSERT INTO hint_plan.hints (normal_query_string, application_name, hints)
VALUES (
    'SELECT * FROM users WHERE email = ?',
    '',                               -- 应用名（空=所有应用）
    'IndexScan(users idx_users_email)' -- hint 内容
);

-- 查看已注册的 hint 规则
SELECT id, normal_query_string, application_name, hints
FROM hint_plan.hints;

-- 删除 hint 规则
DELETE FROM hint_plan.hints WHERE id = <hint_id>;
```

#### 验证 hint 是否生效

```sql
-- 开启 debug 日志
SET pg_hint_plan.debug_print = on;
SET client_min_messages = LOG;

-- 执行目标 SQL，查看日志输出确认 hint 被应用
```

### 3.2 方案 B：调整规划器代价参数（临时干预）

```sql
-- 降低 random_page_cost 使优化器更倾向索引扫描（默认 4.0）
SET random_page_cost = 1.1;

-- 禁用特定连接方式
SET enable_nestloop = off;   -- 禁用嵌套循环
SET enable_hashjoin = on;    -- 偏向 Hash Join
SET enable_seqscan = off;    -- 禁止全表扫描（慎用）

-- 调整 CPU 代价参数
SET cpu_tuple_cost = 0.03;   -- 默认 0.01，增大后偏向少行数的计划
```

> **注意**：代价参数是全局/会话级，影响所有 SQL，仅作临时应急使用。

### 3.3 方案 C：强制使用特定索引

```sql
-- 临时禁用不想要的索引（让优化器无法选择）
-- 不可直接禁用索引，但可通过以下方式间接影响：
-- 1. 设置索引为无效（需要超级用户）
-- 2. 删除并重建索引（风险高，不建议）
-- 推荐使用 pg_hint_plan 方案 A
```

## 四、根因修复 — 统计信息治理

### 4.1 手动重新收集统计信息

```sql
-- 全表收集
ANALYZE <表名>;

-- 指定列收集
ANALYZE <表名>(<列名1>, <列名2>);

-- 收集所有关联表
ANALYZE <表名1>, <表名2>, <表名3>;
```

### 4.2 提高统计信息精度

```sql
-- 调高统计信息采样桶数（默认 100，最大 10000）
ALTER TABLE <表名> ALTER COLUMN <列名> SET STATISTICS 500;
ANALYZE <表名>;

-- 查看修改后效果
SELECT attname, n_distinct, correlation FROM pg_stats
WHERE tablename = '<表名>' AND attname = '<列名>';
```

### 4.3 创建扩展统计信息（多列相关性）

```sql
-- 创建多列 NDV + 函数依赖 + MCV 扩展统计
CREATE STATISTICS s1 (ndistinct, dependencies, mcv)
ON col1, col2 FROM <表名>;
ANALYZE <表名>;

-- 查看扩展统计信息
SELECT * FROM pg_stats_ext WHERE statistic_name = 's1';

-- 表达式统计（PG14+）
CREATE STATISTICS s2 (ndistinct, mcv) ON lower(email) FROM users;
ANALYZE users;
```

### 4.4 调整自动收集频率

```sql
-- 查看当前 autovacuum 配置
SELECT relname, reloptions FROM pg_class WHERE relname = '<表名>';

-- 调低 analyze 阈值使其更频繁收集
ALTER TABLE <表名> SET (autovacuum_analyze_threshold = 50);
ALTER TABLE <表名> SET (autovacuum_analyze_scale_factor = 0.02);

-- 查看全局 autovacuum 参数
SHOW autovacuum_analyze_threshold;    -- 默认 50
SHOW autovacuum_analyze_scale_factor; -- 默认 0.10
```

## 五、统计信息变化识别 — 预防性监控

### 5.1 建立统计信息快照基线

```sql
-- 创建统计信息快照表（定期执行，如每天一次）
CREATE TABLE IF NOT EXISTS stats_baseline (
    snap_time    TIMESTAMP DEFAULT now(),
    tablename    NAME,
    attname      NAME,
    n_distinct   FLOAT,
    correlation  FLOAT,
    null_frac    FLOAT,
    avg_width    INTEGER,
    mcv_vals     TEXT,   -- most_common_vals 简化存储
    mcv_freqs    TEXT,   -- most_common_freqs 简化存储
    hist_bounds  TEXT    -- histogram_bounds 简化存储
);

-- 保存当前统计信息基线
INSERT INTO stats_baseline (tablename, attname, n_distinct, correlation, null_frac, avg_width)
SELECT tablename, attname, n_distinct, correlation, null_frac, avg_width
FROM pg_stats
WHERE schemaname = 'public';
```

### 5.2 比对统计信息变化

```sql
-- 对比最近两次快照，识别关键统计信息变化
SELECT cur.tablename, cur.attname,
       cur.n_distinct   AS cur_ndistinct,
       prev.n_distinct  AS prev_ndistinct,
       cur.correlation  AS cur_corr,
       prev.correlation AS prev_corr,
       cur.null_frac    AS cur_null,
       prev.null_frac   AS prev_null
FROM stats_baseline cur
JOIN stats_baseline prev
  ON cur.tablename = prev.tablename AND cur.attname = prev.attname
WHERE cur.snap_time = (SELECT MAX(snap_time) FROM stats_baseline)
  AND prev.snap_time = (SELECT MAX(snap_time) FROM stats_baseline
                        WHERE snap_time < (SELECT MAX(snap_time) FROM stats_baseline))
  AND (ABS(cur.n_distinct - prev.n_distinct) > 0.1
    OR ABS(cur.correlation - prev.correlation) > 0.2);
```

### 5.3 执行计划变化监控（PG16+）

```sql
-- 定期保存 pg_stat_statements 的 plan_hash_value
CREATE TABLE IF NOT EXISTS plan_history (
    snap_time        TIMESTAMP DEFAULT now(),
    query_hash_value BIGINT,
    plan_hash_value  BIGINT,
    calls            BIGINT,
    mean_exec_time   DOUBLE PRECISION,
    query            TEXT
);

INSERT INTO plan_history (query_hash_value, plan_hash_value, calls, mean_exec_time, query)
SELECT query_hash_value, plan_hash_value, calls, mean_exec_time, query
FROM pg_stat_statements;

-- 检测 plan_hash_value 变化
SELECT cur.query_hash_value,
       prev.plan_hash_value AS old_plan,
       cur.plan_hash_value  AS new_plan,
       prev.mean_exec_time  AS old_mean_time,
       cur.mean_exec_time   AS new_mean_time,
       ROUND(cur.mean_exec_time / prev.mean_exec_time, 2) AS time_ratio,
       cur.query
FROM plan_history cur
JOIN plan_history prev
  ON cur.query_hash_value = prev.query_hash_value
WHERE cur.snap_time = (SELECT MAX(snap_time) FROM plan_history)
  AND prev.snap_time <> cur.snap_time
  AND cur.plan_hash_value <> prev.plan_hash_value
  AND cur.mean_exec_time > prev.mean_exec_time * 2;  -- 性能下降超过2倍
```

## 六、完整 SOP 流程

```
┌────────────────────────────────────────────────────────────────┐
│          PostgreSQL 执行计划跳变应急 SOP 流程                    │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  【L0 告警发现】                                                │
│  监控发现 SQL 平均执行时间突增 > 2 倍                            │
│  或 pg_stat_statements 出现不同 plan_hash_value                │
│  ↓                                                             │
│  【L1 问题确认】                                                │
│  EXPLAIN (ANALYZE, BUFFERS) 获取当前计划                        │
│  与历史好计划对比，确认计划确实跳变                               │
│  ↓                                                             │
│  【L2 根因定位】                                                │
│  ┌─ 检查 pg_stat_all_tables.last_analyze/autoanalyze 时间     │
│  ├─ 检查 pg_stats 统计信息是否变化                              │
│  ├─ 检查 stats_baseline 快照对比                               │
│  ├─ 检查数据量/分布是否显著变化（COUNT, NDV）                   │
│  └─ 检查规划器参数是否被修改（SHOW random_page_cost 等）        │
│  ↓                                                             │
│  【L3 应急止血】（选择一种）                                     │
│  ┌─ 方案A：pg_hint_plan 注入 Hint（推荐，精准控制）             │
│  │  ┌─ 会话级：SQL 注释 /*+ Hint */                           │
│  │  └─ 持久化：INSERT INTO hint_plan.hints                    │
│  ├─ 方案B：调整规划器代价参数 SET random_page_cost 等           │
│  └─ 方案C：提高统计信息精度 + 立即 ANALYZE                      │
│  ↓                                                             │
│  【L4 根因修复】                                                │
│  ┌─ ANALYZE 重新收集统计信息                                   │
│  ├─ ALTER TABLE SET STATISTICS 提高采样精度                    │
│  ├─ CREATE STATISTICS 创建扩展统计（多列相关性）                │
│  └─ 调整 autovacuum_analyze_threshold 频率                    │
│  ↓                                                             │
│  【L5 验证恢复】                                                │
│  EXPLAIN (ANALYZE) 确认执行计划恢复正常                         │
│  pg_stat_statements 确认 mean_exec_time 回落                   │
│  ↓                                                             │
│  【L6 预防监控】                                                │
│  ┌─ 建立统计信息快照基线（定期 INSERT stats_baseline）          │
│  ├─ 建立执行计划历史（定期 INSERT plan_history）                │
│  ├─ 关键高频 SQL 预埋 pg_hint_plan 规则                        │
│  └─ 监控 plan_hash_value 变化 + 性能下降告警                   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## 七、关键 SQL 速查表

| 场景 | SQL |
|------|-----|
| 查看最近 analyze 时间 | `SELECT relname, last_analyze, last_autoanalyze FROM pg_stat_all_tables WHERE relname = '表名';` |
| 查看列统计信息 | `SELECT attname, n_distinct, correlation FROM pg_stats WHERE tablename = '表名';` |
| 手动收集统计 | `ANALYZE 表名;` 或 `ANALYZE 表名(列名);` |
| 提高统计精度 | `ALTER TABLE 表名 ALTER COLUMN 列名 SET STATISTICS 500; ANALYZE 表名;` |
| 创建扩展统计 | `CREATE STATISTICS s1 (ndistinct, dependencies, mcv) ON col1, col2 FROM 表名; ANALYZE 表名;` |
| pg_hint_plan 启用 | `SET pg_hint_plan.enable_hint = on;` |
| pg_hint_plan 持久化 | `INSERT INTO hint_plan.hints (...) VALUES (...);` |
| 查看已注册 hint | `SELECT * FROM hint_plan.hints;` |
| 检测计划跳变(PG16+) | `SELECT query_hash_value, COUNT(DISTINCT plan_hash_value) FROM pg_stat_statements GROUP BY query_hash_value HAVING COUNT(*) > 1;` |

## 八、版本差异说明

| PostgreSQL 版本 | 关键特性 |
|-----------------|---------|
| PG 12 | 基础 pg_hint_plan 支持 |
| PG 14+ | `track_planning` 统计; 扩展统计增强; 表达式统计 |
| PG 16+ | `plan_hash_value` 执行计划指纹; 可直接检测计划跳变 |
| PG 12 以下 | 需手动 EXPLAIN 对比或第三方工具 |

Sources:
- [pg_hint_plan 官方文档](https://pghintplan.osdn.jp/pg_hint_plan.html)
- [Percona - Fix PostgreSQL Query Plan Instability](https://www.percona.com/blog/how-to-fix-postgresql-query-plan-instability/)
- [阿里云RDS Plan Management](https://help.aliyun.com/document_detail/161823.html)