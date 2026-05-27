# plan-jump — 执行计划跳变应急预案

PostgreSQL / OpenGauss 执行计划跳变导致性能剧烈波动的排查与应急 SOP。

## 内容

- [PostgreSQL 执行计划跳变 SOP](sop_pg_plan_jump.md) — 统计信息变化 → 重新收集 → 固定执行计划
- [OpenGauss 执行计划跳变 SOP](sop_opengauss_plan_jump.md) — 同上，适配 OpenGauss 语法

## 适用场景

同一 SQL 在不同时间点产生不同执行计划，导致性能剧烈波动。常见原因：统计信息变化、数据分布改变、优化器代价临界、参数调整。