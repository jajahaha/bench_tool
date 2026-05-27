# OpenGauss 执行计划跳变应急预案 SOP

## 一、概述

OpenGauss 执行计划跳变是指同一 SQL 在不同时间产生不同执行计划，导致性能剧烈波动。
常见原因：统计信息变化、数据分布改变、优化器代价临界、autoanalyze 触发。

本 SOP 覆盖：识别统计信息变化 → 重新收集统计信息 → 固定执行计划。

OpenGauss 与 PostgreSQL 的关键差异：
- OpenGauss 使用 **gs_sql_patch**（SQL 补丁）在不改 SQL 的情况下绑定执行计划
- OpenGauss 使用 **plan_hint_mode** 控制 Hint 语法是否生效
- OpenGauss 通过 **unique_query_id** 标识 SQL，而非 query_hash_value

## 二、告警发现与问题确认

### 2.1 监控发现性能劣化

```sql
-- 通过 WLM 视图查找慢 SQL
SELECT unique_query_id, query, start_time, duration,
       plan_node_name, execution_time
FROM dbe_perf.statement_history
WHERE duration > 5000  -- 执行时间 > 5秒
ORDER BY duration DESC
LIMIT 20;

-- 通过 gs_wlm_session_info 查找历史慢 SQL
SELECT unique_query_id, query, duration
FROM gs_wlm_session_info
WHERE query LIKE '%问题表%'
ORDER BY duration DESC
LIMIT 10;

-- 查看 Top SQL
SELECT unique_query_id, query, calls, total_elapse_time, avg_elapse_time
FROM dbe_perf.statement_history
ORDER BY avg_elapse_time DESC
LIMIT 20;
```

### 2.2 确认计划跳变

```sql
-- 获取当前执行计划（慢计划）
EXPLAIN (ANALYZE, VERBOSE, COSTS, BUFFERS, FORMAT TEXT) <问题SQL>;

-- 如果有历史好计划，对比差异
-- 关键对比项：扫描方式、连接方式、连接顺序、代价估算

-- 对比不同时间的执行计划
-- 可通过 statement_history 中同一 unique_query_id 的不同执行记录
-- 或手动保存 EXPLAIN 输出后对比
```

### 2.3 快速确认是否统计信息导致

```sql
-- 检查最近是否有 autoanalyze 触发
SELECT relname, last_analyze, last_autoanalyze,
       analyze_cnt, autoanalyze_cnt, vac_cnt, autovac_cnt
FROM pg_stat_all_tables
WHERE relname = '<问题表名>';

-- 检查统计信息内容
SELECT attname, n_distinct, correlation, null_frac,
       most_common_vals, most_common_freqs,
       histogram_bounds
FROM pg_stats
WHERE tablename = '<问题表名>';

-- OpenGauss: 检查统计信息操作记录
SELECT operation, object_name, object_type, operation_time
FROM pg_stat_operations
WHERE object_name = '<问题表名>'
ORDER BY operation_time DESC
LIMIT 10;
```

## 三、应急止血 — 固定执行计划

### 3.1 方案 A：gs_sql_patch（推荐，不改 SQL）

gs_sql_patch 是 OpenGauss 的 **SQL 补丁** 功能，通过 unique_query_id 匹配 SQL，
在不修改业务代码的情况下注入 Hint，固定执行计划。

#### 前置条件

```sql
-- 检查 enable_sql_patch 是否开启
SHOW enable_sql_patch;
-- 如果为 off：
ALTER SYSTEM SET enable_sql_patch = on;
SELECT pg_reload_conf();
```

#### Step 1：获取问题 SQL 的 unique_query_id

```sql
-- 从 statement_history 获取
SELECT unique_query_id, query, duration
FROM dbe_perf.statement_history
WHERE query LIKE '%<问题SQL关键词>%'
  AND duration > 5000
ORDER BY duration DESC
LIMIT 5;

-- 从 gs_wlm_session_info 获取
SELECT unique_query_id, query
FROM gs_wlm_session_info
WHERE query = '<精确SQL文本>'
LIMIT 1;
```

#### Step 2：创建 SQL 补丁绑定 Hint

```sql
-- 单 Hint：强制索引扫描
SELECT create_sql_patch(
    'patch_force_idx_orders',     -- 补丁名（建议有业务含义）
    'A8F3B2C1D4E5',              -- unique_query_id
    'IndexScan(orders idx_orders_status)'  -- Hint 内容（不需要 /*+ */ 包裹）
);

-- 多 Hint：强制 Hash Join + 索引扫描
SELECT create_sql_patch(
    'patch_force_hashjoin_idx',
    'A8F3B2C1D4E5',
    'HashJoin(t1 t2) IndexScan(t1 idx_t1_key)'
);

-- 指定连接顺序 + 连接方式
SELECT create_sql_patch(
    'patch_leading_hash',
    'A8F3B2C1D4E5',
    'Leading(t2 t1) HashJoin(t1 t2) IndexScan(t2 idx_t2_id)'
);
```

#### 支持的 Hint 类型

| Hint 类型 | 语法 | 说明 |
|-----------|------|------|
| 扫描方式 | `SeqScan(t)` / `IndexScan(t idx)` / `IndexOnlyScan(t idx)` / `BitmapScan(t idx)` | 强制扫描路径 |
| 连接方式 | `NestLoop(t1 t2)` / `HashJoin(t1 t2)` / `MergeJoin(t1 t2)` | 强制连接算法 |
| 连接顺序 | `Leading(t1 t2 t3)` | 强制驱动表顺序 |
| 行数修正 | `Rows(t #100)` / `Rows(t1 t2 +100)` | 修正行数估算 |
| 并行度 | `Parallel(t 4)` | 强制并行 workers |
| 禁用方式 | `NoSeqScan(t)` / `NoHashJoin(t1 t2)` | 禁用特定路径 |

#### Step 3：验证补丁生效

```sql
-- 再次执行目标 SQL，查看执行计划
EXPLAIN ANALYZE <目标SQL>;
-- 确认执行计划中出现补丁注入的算子

-- 查看补丁信息
SELECT patch_name, unique_query_id, hint_string, enable, status, creation_time
FROM gs_sql_patch;
```

#### Step 4：管理补丁

```sql
-- 查看所有补丁
SELECT * FROM gs_sql_patch;

-- 禁用补丁（部分版本支持）
-- 临时禁用后补丁不生效，但不删除
UPDATE gs_sql_patch SET enable = false WHERE patch_name = 'patch_force_idx_orders';

-- 删除补丁（问题解决后清理）
SELECT drop_sql_patch('patch_force_idx_orders');
```

### 3.2 方案 B：plan_hint_mode + SQL 内嵌 Hint

适用于可以修改 SQL 的场景，或需要快速测试某个 Hint 是否有效。

#### 启用 plan_hint_mode

```sql
-- 会话级启用
SET plan_hint_mode = on;

-- 全局启用（需 SIGHUP）
ALTER SYSTEM SET plan_hint_mode = on;
SELECT pg_reload_conf();
```

#### 使用示例

```sql
-- 开启 hint 模式后，在 SQL 中嵌入 Hint
SET plan_hint_mode = on;

SELECT /*+ IndexScan(users idx_users_email) */
    * FROM users WHERE email = 'test@example.com';

SELECT /*+ HashJoin(orders customers) Leading(orders customers) */
    * FROM orders o JOIN customers c ON o.cust_id = c.id;

-- 禁用特定路径
SELECT /*+ NoSeqScan(big_table) HashJoin(t1 t2) */
    * FROM big_table t1 JOIN t2 ON t1.id = t2.id;
```

> **注意**：`plan_hint_mode` 为 off 时 Hint 注释被忽略，不会报错。

### 3.3 方案 C：abort_sql_patch（直接终止问题 SQL）

当某个 SQL 导致严重性能问题且无法快速修复时，可直接屏蔽该 SQL。

```sql
-- 创建终止补丁，匹配到该 SQL 时直接报错终止
SELECT abort_sql_patch(
    'patch_kill_bad_sql',       -- 补丁名
    'A8F3B2C1D4E5'             -- unique_query_id
);

-- 执行该 SQL 时会报错：ERROR: sql patch abort query

-- 问题解决后删除终止补丁
SELECT drop_sql_patch('patch_kill_bad_sql');
```

### 3.4 方案 D：调整优化器参数（临时干预）

```sql
-- 调整 random_page_cost（默认 4.0），降低后更倾向索引扫描
SET random_page_cost = 1.1;

-- 禁用/启用特定连接方式
SET enable_nestloop = off;
SET enable_hashjoin = on;
SET enable_seqscan = off;     -- 慎用，影响全局

-- 调整 CPU 代价参数
SET cpu_tuple_cost = 0.03;

-- 临时关闭 autoanalyze 防止统计信息突变（应急临时）
-- OpenGauss:
SET autoanalyze = off;         -- 仅会话级
```

> **注意**：优化器参数是全局/会话级，影响所有 SQL，仅作临时应急。

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
```

### 4.4 调整自动收集频率

```sql
-- OpenGauss autovacuum/autoanalyze 配置
ALTER TABLE <表名> SET (autovacuum_analyze_threshold = 50);
ALTER TABLE <表名> SET (autovacuum_analyze_scale_factor = 0.02);

-- 查看全局参数
SHOW autovacuum_analyze_threshold;
SHOW autovacuum_analyze_scale_factor;

-- 查看表级配置
SELECT relname, reloptions FROM pg_class WHERE relname = '<表名>';
```

### 4.5 OpenGauss 统计信息操作追踪

```sql
-- pg_stat_operations 查看表的统计信息操作历史
SELECT operation, object_name, object_type, operation_time
FROM pg_stat_operations
WHERE object_name IN ('<表名1>', '<表名2>')
  AND operation IN ('ANALYZE', 'AUTOANALYZE')
ORDER BY operation_time DESC;
```

## 五、统计信息变化识别 — 预防性监控

### 5.1 建立统计信息快照基线

```sql
-- 创建统计信息快照表
CREATE TABLE IF NOT EXISTS stats_baseline (
    snap_time    TIMESTAMP DEFAULT now(),
    tablename    NAME,
    attname      NAME,
    n_distinct   FLOAT,
    correlation  FLOAT,
    null_frac    FLOAT,
    avg_width    INTEGER
);

-- 保存当前统计信息基线（定期执行，如每天一次）
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
       prev.correlation AS prev_corr
FROM stats_baseline cur
JOIN stats_baseline prev
  ON cur.tablename = prev.tablename AND cur.attname = prev.attname
WHERE cur.snap_time = (SELECT MAX(snap_time) FROM stats_baseline)
  AND prev.snap_time = (SELECT MAX(snap_time) FROM stats_baseline
                        WHERE snap_time < (SELECT MAX(snap_time) FROM stats_baseline))
  AND (ABS(cur.n_distinct - prev.n_distinct) > 0.1
    OR ABS(cur.correlation - prev.correlation) > 0.2);
```

### 5.3 执行计划变化监控

```sql
-- 创建执行计划历史记录表
CREATE TABLE IF NOT EXISTS plan_history (
    snap_time        TIMESTAMP DEFAULT now(),
    unique_query_id  TEXT,
    query            TEXT,
    plan_text        TEXT,    -- EXPLAIN 输出
    duration         BIGINT,  -- 执行时间 ms
    source           TEXT     -- 'manual' / 'wlm'
);

-- 定期记录关键 SQL 的执行计划
-- 可通过脚本定时执行 EXPLAIN 并 INSERT
```

## 六、完整 SOP 流程

```
┌────────────────────────────────────────────────────────────────┐
│          OpenGauss 执行计划跳变应急 SOP 流程                     │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  【L0 告警发现】                                                │
│  WLM 监控发现 SQL 执行时间突增 > 2 倍                           │
│  或 statement_history 出现同一 unique_query_id 多次慢执行       │
│  ↓                                                             │
│  【L1 问题确认】                                                │
│  EXPLAIN (ANALYZE, VERBOSE, COSTS) 获取当前计划                │
│  与历史好计划对比，确认计划确实跳变                               │
│  ↓                                                             │
│  【L2 根因定位】                                                │
│  ┌─ 检查 pg_stat_all_tables.last_analyze/autoanalyze 时间     │
│  ├─ 检查 pg_stat_operations 统计信息操作记录                    │
│  ├─ 检查 pg_stats 统计信息是否变化                              │
│  ├─ 检查 stats_baseline 快照对比                               │
│  ├─ 检查数据量/分布是否显著变化                                  │
│  └─ 检查优化器参数是否被修改                                    │
│  ↓                                                             │
│  【L3 应急止血】（选择一种）                                     │
│  ┌─ 方案A：gs_sql_patch 绑定 Hint（推荐，不改 SQL）            │
│  │  ┌─ create_sql_patch(补丁名, unique_query_id, hint串)      │
│  │  └─ 优势：对业务透明，批量生效同类 SQL                       │
│  ├─ 方案B：plan_hint_mode + SQL 内嵌 Hint（可改 SQL 时）       │
│  ├─ 方案C：abort_sql_patch 直接终止问题 SQL（极端场景）        │
│  ├─ 方案D：调整优化器参数 SET random_page_cost 等              │
│  └─ 方案E：提高统计精度 + 立即 ANALYZE                         │
│  ↓                                                             │
│  【L4 根因修复】                                                │
│  ┌─ ANALYZE 重新收集统计信息                                   │
│  ├─ ALTER TABLE SET STATISTICS 提高采样精度                    │
│  ├─ CREATE STATISTICS 创建扩展统计（多列相关性）                │
│  ├─ 调整 autovacuum_analyze_threshold 频率                    │
│  └─ 删除临时 sql_patch 补丁（根因修复后）                       │
│  ↓                                                             │
│  【L5 验证恢复】                                                │
│  EXPLAIN (ANALYZE) 确认执行计划恢复正常                         │
│  statement_history 确认执行时间回落                              │
│  确认补丁不再需要后删除                                         │
│  ↓                                                             │
│  【L6 预防监控】                                                │
│  ┌─ 建立统计信息快照基线（定期 INSERT stats_baseline）          │
│  ├─ 建立执行计划历史（定期记录 EXPLAIN 输出）                   │
│  ├─ 关键高频 SQL 预留 create_sql_patch 规则模板                │
│  ├─ 监控 statement_history 慢 SQL 告警                        │
│  └─ 监控 pg_stat_operations analyze 操作记录                  │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## 七、关键 SQL 速查表

| 场景 | SQL |
|------|-----|
| 查看 analyze 时间 | `SELECT relname, last_analyze, last_autoanalyze FROM pg_stat_all_tables WHERE relname = '表名';` |
| 查看操作记录 | `SELECT operation, object_name, operation_time FROM pg_stat_operations WHERE object_name = '表名';` |
| 获取 unique_query_id | `SELECT unique_query_id, query FROM dbe_perf.statement_history WHERE query LIKE '%关键词%';` |
| 查看列统计信息 | `SELECT attname, n_distinct, correlation FROM pg_stats WHERE tablename = '表名';` |
| 手动收集统计 | `ANALYZE 表名;` 或 `ANALYZE 表名(列名);` |
| 提高统计精度 | `ALTER TABLE 表名 ALTER COLUMN 列名 SET STATISTICS 500; ANALYZE 表名;` |
| 创建扩展统计 | `CREATE STATISTICS s1 (ndistinct, dependencies, mcv) ON col1, col2 FROM 表名; ANALYZE 表名;` |
| 开启 sql_patch | `ALTER SYSTEM SET enable_sql_patch = on; SELECT pg_reload_conf();` |
| 创建 sql_patch | `SELECT create_sql_patch('补丁名', 'unique_query_id', 'Hint串');` |
| 查看 sql_patch | `SELECT * FROM gs_sql_patch;` |
| 删除 sql_patch | `SELECT drop_sql_patch('补丁名');` |
| 创建终止补丁 | `SELECT abort_sql_patch('补丁名', 'unique_query_id');` |
| 开启 hint 模式 | `SET plan_hint_mode = on;` |

## 八、PostgreSQL vs OpenGauss 方案对比

| 维度 | PostgreSQL | OpenGauss |
|------|-----------|-----------|
| **固定计划方式** | pg_hint_plan（SQL注释 + hint_plan.hints 表） | gs_sql_patch（SQL补丁，不改SQL）+ plan_hint_mode（SQL注释） |
| **SQL标识** | query_hash_value（PG16+ 有 plan_hash_value） | unique_query_id |
| **终止问题SQL** | 无原生功能 | abort_sql_patch 直接终止 |
| **统计信息追踪** | pg_stat_all_tables | pg_stat_all_tables + pg_stat_operations |
| **扩展统计** | PG14+ 支持 ndistinct/dependencies/mcv | 支持（兼容 PG 语法） |
| **慢SQL查找** | pg_stat_statements | statement_history + gs_wlm_session_info |
| **Hint生效条件** | pg_hint_plan.enable_hint = on | plan_hint_mode = on |
| **不改SQL绑定** | hint_plan.hints 表（按 query 模式匹配） | gs_sql_patch（按 unique_query_id 匹配） |

Sources:
- [OpenGauss gs_sql_patch 官方文档](https://docs.opengauss.org/)
- [pg_hint_plan 官方文档](https://pghintplan.osdn.jp/pg_hint_plan.html)