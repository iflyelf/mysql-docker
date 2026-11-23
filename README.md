# mysql-docker

基于 **Percona Server for MySQL 8.4 LTS** 的容器镜像，采用**多阶段构建**，
内置生产级 `my.cnf`，并原生支持 **MGR（Group Replication，组复制）3 节点集群**。

- 构建阶段（builder）= `iflyelf/ubuntu:latest`：只做官方 deb 下载/解包/裁剪，不重装庞大工具链
- 运行阶段（runtime）= `iflyelf/ubuntu:lite`：仅拷贝 mysqld、客户端、插件、字符集，并安装运行所需共享库

支持 `linux/amd64` 与 `linux/arm64` 多架构，标签为 `latest` 与当前版本号（如 `8.4.11-12`）。

---

## 目录

- [镜像获取](#镜像获取)
- [多阶段构建](#多阶段构建)
- [快速开始（单机）](#快速开始单机)
- [MGR 3 节点集群部署](#mgr-3-节点集群部署)
- [my.cnf 参数说明](#mycnf-参数说明)
- [环境变量](#环境变量)
- [自动构建与版本更新](#自动构建与版本更新)
- [目录结构](#目录结构)
- [备份与恢复](#备份与恢复)
- [常见问题](#常见问题)

---

## 镜像获取

```bash
# Docker Hub（国外）
docker pull iflyelf/mysql:latest

# 华为云 SWR（国内推荐）
docker pull swr.cn-east-3.myhuaweicloud.com/iflyelf/mysql:latest

# 指定版本（Percona Server 版本号）
docker pull iflyelf/mysql:8.4.11-12
```

| 项目 | 说明 |
| --- | --- |
| 数据库版本 | Percona Server for MySQL 8.4 LTS（当前 `8.4.11-12`） |
| 基础镜像 | 运行阶段 `iflyelf/ubuntu:lite`（Ubuntu 26.04 / resolute） |
| 架构 | `linux/amd64`、`linux/arm64` |
| 端口 | `3306`（MySQL 协议）、`33060`（X Protocol）、`33061`（MGR 组通信） |
| 用户 | 容器内 `mysql` 用户，**UID/GID = 1001**（与 Percona 官方镜像、k8s 部署一致） |
| 配置目录 | `/etc/mysql/my.cnf` + `/etc/mysql/conf.d/*.cnf` |
| 数据目录 | `/var/lib/mysql`（`VOLUME`） |

---

## 多阶段构建

| 阶段 | 基础镜像 | 作用 |
| --- | --- | --- |
| builder | `iflyelf/ubuntu:latest` | 按 `MYSQL_VERSION` 下载 Percona 官方 `common/client/server` deb，`dpkg-deb -x` 解包（不执行 maintainer 脚本，避免二次初始化/启动服务），并裁剪调试二进制、测试插件、文档 |
| runtime | `iflyelf/ubuntu:lite` | 仅拷贝 `mysqld`/客户端/插件/字符集/gosu，安装运行所需共享库，创建 UID 1001 的 `mysql` 用户，构建期做 `ldd` + `--validate-config` 自检 |

裁剪内容：`mysqld-debug`、`plugin/debug`、`component_test_*.so`、`test_udf_wrappers.so`、`/usr/share/doc`、`/usr/share/man`、`/usr/include`、systemd/apparmor 集成文件。

运行阶段安装的运行库（按 `DT_NEEDED` 精确选取）：

`libaio1t64`、`libatomic1`、`libcurl4t64`、`libfido2-1`、`libgssapi-krb5-2`、`libkrb5-3`、`libldap2`、
`libmecab2`、`libnuma1`、`libpam0g`、`libsasl2-2`、`libssl3t64`、`libstdc++6`、`libtinfo6`、`libtirpc3t64`、`xz-utils`。

> 说明：运行库**逐个安装**（个别包在新基础镜像中改名时只告警），最终以
> `ldd /usr/sbin/mysqld` 出现 `not found` 即构建失败的方式兜底，避免"镜像构建成功但起不来"。

运行阶段环境变量：`TZ=Asia/Shanghai`、`LANG=zh_CN.UTF-8`、`MYSQL_MAJOR`、`MYSQL_VERSION`、
`MYSQL_DIR=/var/lib/mysql`、`MYSQL_DATA=/var/lib/mysql`、`GOSU_VERSION`；入口使用 `tini` 处理信号与僵尸进程。

构建参数：

| ARG | 默认值 | 说明 |
| --- | --- | --- |
| `MYSQL_SERIES` | `8.4` | MySQL 系列（决定 Percona 仓库 `ps-84-lts`） |
| `MYSQL_VERSION` | `8.4.11-12` | 完整 deb 版本（不含 `-1.<distro>` 后缀），由脚本自动跟进 |
| `PERCONA_DISTRO` | `resolute` | Percona deb 发行版代号，**必须与运行基础镜像一致**（lite 当前为 Ubuntu 26.04） |
| `GOSU_VERSION` | `1.20` | gosu 版本 |
| `DOWNLOAD_PROXY` | 空 | 可选下载代理，如 `https://down.xiaonuo.live`（按 `?url=<原始地址>` 拼装） |

---

## 快速开始（单机）

```bash
# 1) 准备环境变量（务必修改密码）
cd /xiaonuo/workspace/docker/mysql-docker
cp .env_vars/.env_db_mysql .env_vars/.env_db_mysql.local   # 可选
vi .env_vars/.env_db_mysql

# 2) 启动
docker compose up -d

# 3) 查看日志 / 状态
docker compose logs -f mysql
docker compose ps
```

不使用 compose：

```bash
docker run -d --name mysql \
  -p 3306:3306 -p 33060:33060 \
  -e MYSQL_ROOT_PASSWORD='ysyh!9Sky' \
  -e MYSQL_DATABASE=xiaonuo \
  -e MYSQL_USER=xiaonuo \
  -e MYSQL_PASSWORD='ysyh!9Sky' \
  -e MYSQL_REPL_USER=repl \
  -e MYSQL_REPL_PASSWORD='ysyh!9Sky' \
  -e TZ=Asia/Shanghai \
  -v "$PWD/data/mysql:/var/lib/mysql" \
  --ulimit nofile=65535:65535 \
  iflyelf/mysql:latest
```

连接：

```bash
# 容器内 socket 连接
docker exec -it mysql mysql -uroot -p

# 宿主机 TCP 连接
mysql -h127.0.0.1 -P3306 -uroot -p
```

初始化脚本：任意 `*.sh` / `*.sql` / `*.sql.gz` / `*.sql.xz` 放入 `/docker-entrypoint-initdb.d/`
（可挂载宿主机目录），仅**首次初始化**数据目录时执行。

---

## MGR 3 节点集群部署

> 设计参考 `workspace/k8s/mysql-cluster`（Percona Operator + MGR 单主模式 + 3 副本），
> 这里的 compose 版本把同样的参数与架构搬到单机 Docker 环境，便于开发/测试/小规模生产。

### 架构

```
        ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
        │ mysql-mgr-1  │   │ mysql-mgr-2  │   │ mysql-mgr-3  │
        │ 172.30.8.11  │   │ 172.30.8.12  │   │ 172.30.8.13  │
        │  host:13306  │   │  host:13307  │   │  host:13308  │
        └──────┬───────┘   └──────┬───────┘   └──────┬───────┘
               └──────── 33061 组通信(XCom) ─────────┘
                  单主模式：自动选举 Primary / Secondary
```

- 网络：独立 bridge 网络 `172.30.8.0/24`，固定 IP 保证 `group_replication_local_address` 稳定
- 数据：`./data/mgr/mysql-mgr-{1,2,3}`
- 配置：`conf/mysql/my.cnf`（基础，只读挂载）+ 镜像内 `conf/mysql/conf.d/mgr.cnf`（组复制）
  + 入口脚本在**容器内**生成的 `/etc/mysql/conf.d/zz-mgr-auto.cnf`（节点差异化参数：
  `server_id` / `local_address` / `group_seeds`）。该文件不落宿主机，避免三节点共用目录互相覆盖。

### 步骤

```bash
cd /xiaonuo/workspace/docker/mysql-docker

# 1) 检查 MGR 公共参数（组名、种子列表、密码）
vi .env_vars/.env_db_mgr

# 2) 启动三个节点
docker compose -f docker-compose-mgr.yml up -d

# 3) 观察初始化（首次会初始化数据目录 → 引导组 → 加入组，约 1~2 分钟）
docker logs -f mysql-mgr-1
```

首次启动日志关键行：

```
[Entrypoint]: MGR 配置已生成: server_id=1 local_address=172.30.8.11:33061 bootstrap=ON seeds=...
[Entrypoint]: MGR: 配置分布式恢复通道 (repl)
[Entrypoint]: MGR: 首次启动, 本次将引导新组(bootstrap=ON)
```

引导逻辑：

- `MYSQL_MGR_BOOTSTRAP=1` 且数据目录中无标记文件时，入口脚本生成 `bootstrap=ON` 的配置，
  **由正式的 mysqld 进程直接引导新组并持续在线**（不会先起临时服务器再重启，避免重启瞬时无同伴可加入）
- 同时写入标记 `/var/lib/mysql/.mgr_bootstrapped`，**重启不会再引导**（避免脑裂）
- 其他节点启动前会先探测 `MYSQL_MGR_GROUP_SEEDS` 中同伴的 33061 端口（最多 `MYSQL_MGR_WAIT_TIMEOUT` 秒），
  避免"同时启动时引导节点尚未就绪 → 成员停在 OFFLINE"
- 首次初始化结束时执行 `RESET BINARY LOGS AND GTIDS`，清除时区表导入等初始化事务产生的本机 GTID，
  否则加入组时会报 `This member has more executed transactions than those present in the group`
- 若首次引导异常（例如启动即崩溃）：删除 `.mgr_bootstrapped` 后重启该节点即可重新引导；
  重建整个集群则清空三个节点数据目录后按序启动

### 验证

```bash
# 查看成员状态
docker exec -it mysql-mgr-1 mysql -uroot -p -e "
  SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;"
```

期望结果（单主模式）：

| MEMBER_HOST | MEMBER_PORT | MEMBER_STATE | MEMBER_ROLE |
| --- | --- | --- | --- |
| mysql-mgr-1 | 3306 | ONLINE | PRIMARY |
| mysql-mgr-2 | 3306 | ONLINE | SECONDARY |
| mysql-mgr-3 | 3306 | ONLINE | SECONDARY |

```bash
# 组复制通道 / 事务一致性
docker exec -it mysql-mgr-1 mysql -uroot -p -e "
  SELECT CHANNEL_NAME, SERVICE_STATE FROM performance_schema.replication_connection_status;
  SHOW STATUS LIKE 'group_replication_primary_member';"
```

### 故障切换验证

```bash
# 停掉主库，观察是否自动选出新主
docker stop mysql-mgr-1
docker exec -it mysql-mgr-2 mysql -uroot -p -e "
  SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE
  FROM performance_schema.replication_group_members;"

# 重新启动，自动以 SECONDARY 身份重新加入
docker start mysql-mgr-1
```

### 增加/减少节点

1. 在 `docker-compose-mgr.yml` 中复制一个服务，修改 `MYSQL_SERVER_ID`、`MYSQL_MGR_LOCAL_ADDRESS`、
   `ipv4_address`、端口与数据目录；
2. 把新地址加入 `.env_vars/.env_db_mgr` 的 `MYSQL_MGR_GROUP_SEEDS`（所有节点保持一致），
   并同步更新 `conf/mysql/conf.d/mgr.cnf` 之外的 `ip_allowlist`（如已启用）；
3. `docker compose -f docker-compose-mgr.yml up -d` 只重启/新增受影响节点。

> MGR 要求成员数为奇数（3/5/7）以保证多数派仲裁；2 节点无容错能力。

### 与 k8s 集群的对应关系

| 能力 | k8s（mysql-cluster） | 本仓库（docker-compose-mgr.yml） |
| --- | --- | --- |
| 集群类型 | `clusterType: group-replication` | `mgr.cnf` + 环境变量 |
| 单主/多主 | Operator 管理 | `MYSQL_MGR_SINGLE_PRIMARY` |
| 组成员发现 | Pod 域名:33061 | 固定 IP:33061 |
| 数据持久化 | CephFS 静态 PV | 宿主机目录 `./data/mgr/*` |
| 账号 | Secret 统一注入 | `.env_vars/.env_db_mgr` |
| 备份 | XtraBackup + S3 | 见[备份与恢复](#备份与恢复) |

---

## my.cnf 参数说明

配置文件：

- `conf/mysql/my.cnf`：基础配置（客户端/服务端/InnoDB/binlog/慢查询等）
- `conf/mysql/conf.d/mgr.cnf`：MGR 组复制（全部 `loose_` 前缀，单机部署不生效也不报错）
- `/etc/mysql/conf.d/zz-mgr-auto.cnf`（容器内）：**运行时自动生成**（`server_id`/`local_address`/`seeds`），不要手工改

### 相对旧配置的清理（MySQL 8.4 已移除/废弃）

| 旧参数 | 状态 | 8.4 替代方案 |
| --- | --- | --- |
| `query_cache_*` | 8.0 已移除 | 无（改用 `innodb_buffer_pool_size`） |
| `innodb_log_files_in_group` / `innodb_log_file_size` | 8.4 已移除 | `innodb_redo_log_capacity` |
| `slave_parallel_type` / `slave_parallel_workers` / `slave_preserve_commit_order` | 8.4 已移除 | `replica_parallel_*` |
| `slave_net_timeout` / `sync_master_info` / `sync_relay_log*` | 8.4 已移除 | 由 `replica_*` / 内部机制接管 |
| `relay_log_recovery` | 8.4 已移除 | 默认始终开启 |
| `log_slave_updates` | 8.4 已移除 | `log_replica_updates`（默认开启，未显式设置） |
| `log_slow_slave_statements` | 8.4 已移除 | `log_slow_replica_statements` |
| `skip-federated` / `symbolic_links` | 已移除 | 通过 `disabled_storage_engines` 禁用引擎 |
| `explicit_defaults_for_timestamp` | 8.4 已移除（恒为 ON） | 无需设置 |
| `innodb_status_file` / `innodb_log_files_in_group` | 已移除 | 使用 `information_schema.innodb_metrics` |
| MyISAM 系列（`key_buffer_size`、`bulk_insert_buffer_size`、`myisam_*`） | 引擎已禁用 | 删除 |
| `host_cache_size` / `skip_host_cache` | 已废弃/移除 | 由 `skip_name_resolve` 覆盖 |
| `[mysqld_safe] malloc_lib=libjemalloc.so.1` | 路径与库均已不存在 | 删除（如需 jemalloc 用 `LD_PRELOAD`） |

### 关键参数取值（与 k8s MGR 集群对齐）

| 分类 | 参数 | 取值 | 说明 |
| --- | --- | --- | --- |
| 字符集 | `character_set_server` / `collation_server` | `utf8mb4` / `utf8mb4_0900_ai_ci` | 8.0+ 默认排序规则，MGR 各成员必须一致 |
| 隔离级别 | `transaction_isolation` | `READ-COMMITTED` | 减少间隙锁，MGR 常用 |
| 表名 | `lower_case_table_names` | `1` | **仅初始化时生效**，集群内必须一致 |
| 连接 | `max_connections` | `10000` | k8s 参考值为 100000，容器内按内存下调 |
| 连接 | `wait_timeout` / `interactive_timeout` | `28800` | k8s 参考值为 2880000（33 天），此处按连接池习惯收敛 |
| 包大小 | `max_allowed_packet` | `1G` | k8s 参考值为 5G，按常规业务收敛 |
| binlog | `binlog_row_image` | `FULL` | MGR 强制要求（8.4 起 `binlog_format` 已废弃，仅支持 ROW） |
| binlog | `binlog_checksum` | `NONE` | MGR 要求 |
| binlog | `sync_binlog` | `1` | 崩溃不丢事务 |
| GTID | `gtid_mode` / `enforce_gtid_consistency` | `ON` | MGR/主从基础 |
| InnoDB | `innodb_buffer_pool_size` | `2G` | 建议为容器内存 50%~75%，大内存请上调 |
| InnoDB | `innodb_redo_log_capacity` | `4G` | 替代旧 `innodb_log_file_size` |
| InnoDB | `innodb_flush_log_at_trx_commit` | `1` | 最安全；追求吞吐可改 `2`（最多丢 1 秒） |
| InnoDB | `innodb_flush_method` | `O_DIRECT` | 避免双缓冲 |
| InnoDB | `innodb_numa_interleave` | `OFF` | k8s 参考值为 ON；容器默认无 `SYS_NICE` 权限会产生大量 mbind 告警，需要时用启动参数覆盖 |
| 慢查询 | `long_query_time` / `log_queries_not_using_indexes` | `1` / `ON` | 默认开启慢日志 |
| MGR | `group_replication_single_primary_mode` | `ON` | 单主自动选主 |
| MGR | `group_replication_exit_state_action` | `READ_ONLY` | 被驱逐后只读，防数据分叉 |
| MGR | `group_replication_consistency` | `BEFORE_ON_PRIMARY_FAILOVER` | 切换期间不读旧数据 |
| MGR | `group_replication_autorejoin_tries` | `10` | 网络抖动自动重连 |
| MGR | `group_replication_clone_threshold` | `1G` | 超过阈值用 clone 做全量恢复 |
| MGR | `sql_require_primary_key` | `ON` | MGR 写入要求（仅 `mgr.cnf` 生效） |

> 调优建议：根据宿主机内存修改 `innodb_buffer_pool_size`；根据云盘 IOPS 修改 `innodb_io_capacity`；
> 修改后 `docker restart` 生效（`my.cnf` 为只读挂载时，请修改宿主机文件）。

---

## 环境变量

入口脚本兼容官方 MySQL 镜像的变量，并新增 MGR 相关变量。

### 通用

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MYSQL_ROOT_PASSWORD` | 无（首次必须） | root 密码；也支持 `MYSQL_ROOT_PASSWORD_FILE` |
| `MYSQL_ROOT_HOST` | `%` | root 允许来源 |
| `MYSQL_DATABASE` | 空 | 初始化创建的库 |
| `MYSQL_USER` / `MYSQL_PASSWORD` | 空 | 初始化创建的业务账号（对该库全权限） |
| `MYSQL_REPL_USER` | `repl` | 复制/MGR 恢复账号 |
| `MYSQL_REPL_PASSWORD` | 空 | 复制账号密码（MGR 必填） |
| `MYSQL_ALLOW_EMPTY_PASSWORD` | 空 | 允许空密码（不推荐） |
| `MYSQL_RANDOM_ROOT_PASSWORD` | 空 | 随机生成 root 密码并打印到日志 |
| `MYSQL_ONETIME_PASSWORD` | 空 | root 密码首次登录需修改 |
| `MYSQL_INITDB_SKIP_TZINFO` | 空 | 跳过导入时区表（不推荐） |
| `TZ` | `Asia/Shanghai` | 时区 |

所有 `*_PASSWORD` 变量均支持 `*_PASSWORD_FILE`（Docker secrets）形式。

### MGR（设置 `MYSQL_MGR_GROUP_SEEDS` 后才启用）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MYSQL_MGR_GROUP_SEEDS` | 空 | 成员地址列表 `ip:33061,...`，集群内所有节点一致 |
| `MYSQL_MGR_LOCAL_ADDRESS` | `<hostname>:33061` | 本节点组通信地址，**每个节点不同** |
| `MYSQL_SERVER_ID` | `1` | 本节点 `server_id`，**集群内唯一** |
| `MYSQL_MGR_GROUP_NAME` | 内置 UUID | 组名，集群内一致；新建集群建议用 `uuidgen` 重新生成 |
| `MYSQL_MGR_BOOTSTRAP` | `0` | `1`=首次初始化时引导新组（仅首个节点首次启动） |
| `MYSQL_MGR_SINGLE_PRIMARY` | `ON` | `ON`=单主，`OFF`=多主 |
| `MYSQL_MGR_WAIT_TIMEOUT` | `180` | 非引导节点等待同伴 33061 可达的最长秒数 |

> 注意：MySQL 8.4 起 `mysql_native_password` 默认禁用，复制账号统一使用 `caching_sha2_password`，
> 配合 `group_replication_recovery_get_public_key=ON` 完成 MGR 分布式恢复认证。

---

## 自动构建与版本更新

### 构建工作流：`.github/workflows/docker-publish.yml`

触发条件：

- `push`：`Dockerfile`、`conf/**`、`scripts/**`、`ps-entry.sh`、工作流文件变更
- `workflow_dispatch`：手动触发
- `schedule`：每天 UTC 21:00（北京时间 05:00）
- `watch.started`：点 Star 触发

流程：

1. `prepare`：执行 `scripts/update-version.sh` 同步最新版本号，有变更则提交（`[skip ci]`）
2. `build`：**双架构原生并行构建**（`ubuntu-latest` = amd64、`ubuntu-24.04-arm` = arm64），
   分别推送 `<tag>-amd64` / `<tag>-arm64`
3. `merge`：`docker manifest` 合并为多架构清单（Docker v2 manifest list，兼容华为云 SWR），
   校验清单，并把 SWR 仓库设为公开
4. 清理历史 workflow 运行记录

并发控制（同一分支只保留最新一次构建，避免 QEMU/多架构任务互相拖慢）：

```yaml
concurrency:
  group: publish-${{ github.ref }}
  cancel-in-progress: true
```

### 版本更新工作流：`.github/workflows/update-version.yml`

每天 UTC 20:00（北京时间 04:00）检查并提交：

- `MYSQL_VERSION`：解析 Percona 官方 apt 索引
  （`https://repo.percona.com/ps-84-lts/apt/dists/<distro>/main/binary-amd64/Packages.gz`）中
  `percona-server-server` 的最新 8.4 版本
- `GOSU_VERSION`：GitHub API `tianon/gosu` 最新 release

> 说明：Percona Server 的 GitHub tag（`Percona-Server-8.4.x-y`）与实际 deb 版本号
> （`8.4.x-y-1.<distro>`）不完全一致，且仓库包含多个历史分支，因此版本号以**官方 apt 索引**为准，
> 而不是 GitHub API。

### 所需 Secrets

| Secret | 说明 |
| --- | --- |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | Docker Hub 凭据 |
| `SWR_USERNAME` / `SWR_PASSWORD` | 华为云 SWR 登录凭据（`cn-east-3@<AK>` / 登录密钥） |
| `SWR_AK` / `SWR_SK` | 华为云账号 AK/SK，用于把 SWR 仓库设为公开（可选） |

配置方式：仓库 `Settings → Secrets and variables → Actions → New repository secret`。

### 手动触发

```bash
export GITHUB_TOKEN=<你的 token>
export GH_USER=iflyelf
export GH_REPO=mysql-docker
export GH_BRANCH=main

curl -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GH_USER}/${GH_REPO}/actions/workflows/docker-publish.yml/dispatches" \
  -d '{"ref":"'"${GH_BRANCH}"'","inputs":{"build":"build mysql"}}'
```

---

## 目录结构

```
mysql-docker/
├── Dockerfile                    # 多阶段构建(builder: ubuntu:latest / runtime: ubuntu:lite)
├── ps-entry.sh                   # 入口脚本(初始化账号 + MGR 自动配置/引导)
├── conf/mysql/
│   ├── my.cnf                    # 基础配置(8.4 生产级)
│   └── conf.d/mgr.cnf            # MGR 组复制配置(loose_ 前缀)
├── .env_vars/
│   ├── .env_db_mysql             # 单机环境变量
│   └── .env_db_mgr               # MGR 集群公共环境变量
├── docker-compose.yml            # 单机部署
├── docker-compose-mgr.yml        # 3 节点 MGR 集群
├── scripts/update-version.sh     # 版本号自动同步
├── .github/workflows/
│   ├── docker-publish.yml        # 构建并推送(Docker Hub + 华为云 SWR)
│   └── update-version.yml        # 定时同步版本号
├── LICENSE
└── README.md
```

---

## 备份与恢复

```bash
# 逻辑备份(单库 / 全库)
docker exec mysql sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" \
  --single-transaction --source-data=2 --set-gtid-purged=ON xiaonuo' > xiaonuo-$(date +%F).sql

# 物理备份(需要 Percona XtraBackup 8.4 镜像, 与 Percona Server 版本对应)
docker run --rm --volumes-from mysql \
  -v "$PWD/backup:/backup" \
  percona/percona-xtrabackup:8.4 \
  xtrabackup --backup --target-dir=/backup/full --user=root --password='ysyh!9Sky'

# 恢复
docker exec -i mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < xiaonuo-2026-01-01.sql
```

MGR 场景建议：备份在 **SECONDARY** 节点执行，避免影响主库；`xtrabackup` 备份可用于成员全量恢复（clone/xtrabackup）。

---

## 常见问题

**1. 启动报 `Different lower_case_table_names settings for server ('1') and data dictionary ('0')`**

`lower_case_table_names` 只能在初始化数据目录时确定。修改 `my.cnf` 后必须删除旧数据目录重新初始化，
或保持该值与初始化时一致（集群内所有成员也必须一致）。

**2. MGR 节点一直 `RECOVERING` 或报认证失败**

- 确认三个节点的 `MYSQL_REPL_USER` / `MYSQL_REPL_PASSWORD` 一致；
- 8.4 已禁用 `mysql_native_password`，本镜像使用 `caching_sha2_password` +
  `group_replication_recovery_get_public_key=ON`；
- 确认 `MYSQL_MGR_GROUP_SEEDS` 中地址可达（`docker exec mysql-mgr-2 ping -c1 172.30.8.11`）。

**3. 第二个节点把第一个节点的组"抢"了 / 出现两个组**

只有首个节点首次初始化允许 `MYSQL_MGR_BOOTSTRAP=1`；引导成功后数据目录会写 `.mgr_bootstrapped` 标记。
若误配，删除两个节点的数据目录后重新按顺序启动。

**4. 容器内 `mysql` 用户 UID 与宿主机目录不一致导致无法启动**

本镜像固定 `mysql` 用户 UID/GID = **1001**。宿主机目录授权：

```bash
chown -R 1001:1001 ./data/mysql
```

**5. 华为云 SWR 拉取报 manifest 解析错误**

SWR 不支持 OCI media types / attestation，本仓库工作流已关闭 `provenance`、`sbom`
并指定 `oci-mediatypes=false`，多架构清单使用 `docker manifest` 生成（Docker v2）。

**6. 想改用 Ubuntu 24.04 / 22.04 基础镜像**

把 `Dockerfile` 中 `PERCONA_DISTRO` 改为 `noble` / `jammy`，并同步替换
`iflyelf/ubuntu:latest`、`iflyelf/ubuntu:lite` 为对应版本镜像即可（deb 版本号不变）。

---

## 参考

- [Percona Server for MySQL 8.4 文档](https://docs.percona.com/percona-server/8.4/)
- [MySQL 8.4 已移除/废弃参数](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)
- [Group Replication 官方文档](https://dev.mysql.com/doc/refman/8.4/en/group-replication.html)
- 本项目参考集群配置：`workspace/k8s/mysql-cluster`（Percona Operator + MGR）
