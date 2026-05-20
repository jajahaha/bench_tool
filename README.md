# db_shell_bench - v2

数据库基准测试工具，纯 shell 脚本实现。支持 PostgreSQL、OpenGauss、GaussDB。

## 快速开始

```bash
# PostgreSQL
./db_shell_bench.sh -h localhost -p 5432 -U postgres init -s 1
./db_shell_bench.sh -h localhost -p 5432 -U postgres -c 4 -n 100 benchmark

# OpenGauss / GaussDB
./db_shell_bench.sh -t opengauss -h localhost -p 5433 -U gaussdb -W 'Pass@123' init -s 1
./db_shell_bench.sh -t gaussdb -h localhost -p 8000 -U root -W 'Pass@123' -c 4 -T 60 benchmark
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
| -c CLIENTS | 并发数 | 1 |
| -n TXNS | 事务数/客户端 | - |
| -T SECS | 持续时间(秒) | - |

## 客户端自动选择

opengauss/gaussdb 类型自动检测客户端：
- 有 gsql 时使用 gsql
- 否则使用 psql（兼容 PostgreSQL 协议）

## 测试

```bash
./test_db_shell_bench.sh
```

## 许可证

MIT