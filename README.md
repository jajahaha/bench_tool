# pgbench-like - PostgreSQL 基准测试工具

一个使用 shell 脚本和 psql 实现的 PostgreSQL 性能测试工具，类似于 pgbench。

## 功能特点

- **初始化模式**: 创建测试表并填充数据（支持 scale factor）
- **基准测试模式**: 执行 TPC-B 类似的事务测试
- **并发测试**: 支持多客户端并发测试
- **性能报告**: 输出 TPS（每秒事务数）指标

## 测试表结构

初始化时会创建以下表：
- `pgbench_branches`: 分行表
- `pgbench_tellers`: 柜员表
- `pgbench_accounts`: 账户表（主表，数据量最大）
- `pgbench_history`: 历史记录表

## 使用方法

```bash
./pgbench_like.sh [OPTIONS] [COMMAND]
```

### 命令

| 命令 | 说明 |
|------|------|
| init | 初始化数据库，创建测试表并填充数据 |
| benchmark | 运行基准测试（默认） |

### 选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| -h HOST | 数据库主机 | localhost 或 $PGHOST |
| -p PORT | 数据库端口 | 5432 或 $PGPORT |
| -d DB | 数据库名称 | postgres 或 $PGDATABASE |
| -U USER | 数据库用户 | postgres 或 $PGUSER |
| -s SCALE | 初始化的缩放因子 | 1 |
| -c CLIENTS | 并发客户端数量 | 1 |
| -t TXNS | 每个客户端的事务数 | 10 |

## 使用示例

### 1. 初始化数据库（scale factor = 10，约 100 万账户记录）

```bash
./pgbench_like.sh init -s 10
```

### 2. 运行单客户端测试

```bash
./pgbench_like.sh benchmark -t 100
```

### 3. 运行多客户端并发测试

```bash
./pgbench_like.sh benchmark -c 4 -t 100
```

### 4. 使用环境变量配置连接

```bash
export PGHOST=192.168.1.100
export PGPORT=5432
export PGDATABASE=testdb
export PGUSER=testuser

./pgbench_like.sh init -s 5
./pgbench_like.sh benchmark -c 8 -t 1000
```

## 测试事务说明

每个事务执行以下操作（TPC-B 模型）：

1. 更新账户余额（UPDATE pgbench_accounts）
2. 查询账户余额（SELECT）
3. 更新柜员余额（UPDATE pgbench_tellers）
4. 更新分行余额（UPDATE pgbench_branches）
5. 插入历史记录（INSERT pgbench_history）

## 性能基准

在典型配置下的参考性能：

| 配置 | Scale | 客户端 | 事务数/客户端 | TPS 参考 |
|------|-------|--------|---------------|----------|
| 本地开发 | 1 | 1 | 100 | 50-100 |
| 本地开发 | 10 | 4 | 100 | 200-500 |
| 生产环境 | 100 | 16 | 1000 | 5000+ |

*注：实际性能取决于硬件、配置和网络延迟*

## 环境变量支持

支持标准 PostgreSQL 环境变量：
- `PGHOST`
- `PGPORT`
- `PGDATABASE`
- `PGUSER`
- `PGPASSWORD`

## 依赖

- `psql` (PostgreSQL 客户端工具)
- `bc` (计算器，用于浮点运算)

## 与 pgbench 的差异

此脚本与官方 pgbench 的主要差异：

1. **性能**: 使用多个 psql 连接，性能略低于原生 pgbench
2. **功能**: 仅实现基本的 TPC-B 测试模式
3. **初始化**: 数据生成速度较慢，适合小规模测试
4. **兼容性**: 纯 shell 脚本，无编译依赖

## 许可证

MIT License# bench_tool
