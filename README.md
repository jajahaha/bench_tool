# db_shell_bench - v1

PostgreSQL 基准测试工具，纯 shell 脚本实现。

## 快速开始

```bash
# 初始化测试数据
./db_shell_bench.sh -h 127.0.0.1 -p 5432 -U postgres -d postgres init -s 1

# 运行基准测试
./db_shell_bench.sh -h 127.0.0.1 -p 5432 -U postgres -d postgres -c 4 -t 100 benchmark
```

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| -h HOST | 数据库主机 | localhost |
| -p PORT | 端口 | 5432 |
| -d DB | 数据库 | postgres |
| -U USER | 用户 | postgres |
| -P PREFIX | 表前缀 | dbbench |
| -s SCALE | 初始化缩放因子 | 1 |
| -c CLIENTS | 并发数 | 1 |
| -t TXNS | 事务数/客户端 | - |
| -T SECS | 持续时间(秒) | - |

## 测试

```bash
./test_db_shell_bench.sh
```

## 许可证

MIT