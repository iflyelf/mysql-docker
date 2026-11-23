#!/usr/bin/env bash
#=================================================
# https://github.com/iflyelf/mysql-docker
# Percona Server for MySQL 配置动态调优脚本
#
# 功能：按容器 CPU / 内存限制自动计算 MySQL 容量类参数，并生成带中文注释的配置。
#
# 资源来源（优先级从高到低）：
#   1. 环境变量手动指定：MYSQL_MEMORY_LIMIT / MYSQL_CPU_LIMIT（支持 8Gi/4/500m 等 K8s 格式）
#   2. 自动探测容器 cgroup 限制（v2 优先，回退 v1）
#   3. 回退宿主机 /proc/meminfo 与 nproc
#
# 用法：
#   mysql-config-tuner.sh [conf|summary]
#     conf      输出 my.cnf 片段（默认，每项参数带中文注释与计算公式）
#     summary   仅输出资源探测与关键参数摘要
#
# 可覆盖的环境变量：
#   MYSQL_MEMORY_LIMIT     内存上限（如 8Gi / 8192Mi / 8589934592）
#   MYSQL_CPU_LIMIT        CPU 上限（如 4 / 2.5 / 500m）
#   MYSQL_MAX_CONNECTIONS  直接指定 max_connections（默认按内存/CPU 自动计算）
#   MYSQL_IOPS             磁盘 IOPS 基准（默认 4000，对应 SSD；云盘按实际值调整）
#=================================================

set -euo pipefail

# ==============================================================================
# 0. K8s 资源格式解析（8Gi/4096Mi/500m/4 → 字节 / 核数）
# ==============================================================================
parse_memory_to_bytes() {
    local s="$1"
    case "$s" in
        *Ki) echo "$(( ${s%Ki} * 1024 ))" ;;
        *Mi) echo "$(( ${s%Mi} * 1024 * 1024 ))" ;;
        *Gi) echo "$(( ${s%Gi} * 1024 * 1024 * 1024 ))" ;;
        *Ti) echo "$(( ${s%Ti} * 1024 * 1024 * 1024 * 1024 ))" ;;
        *K)  echo "$(( ${s%K} * 1000 ))" ;;
        *M)  echo "$(( ${s%M} * 1000 * 1000 ))" ;;
        *G)  echo "$(( ${s%G} * 1000 * 1000 * 1000 ))" ;;
        *T)  echo "$(( ${s%T} * 1000 * 1000 * 1000 * 1000 ))" ;;
        *)   echo "$s" ;;
    esac
}

parse_cpu_to_cores() {
    local s="$1"
    if [[ "$s" == *m ]]; then
        local milli="${s%m}"
        echo "$(( (milli + 999) / 1000 ))"
    else
        local intpart="${s%%.*}"
        [ -z "$intpart" ] && intpart=0
        [ "$intpart" -lt 1 ] && intpart=1
        echo "$intpart"
    fi
}

# clamp 值 下限 上限：把 $1 限制在 [$2, $3]
clamp() {
    local v="$1" lo="$2" hi="$3"
    [ "$v" -lt "$lo" ] && v="$lo"
    [ "$v" -gt "$hi" ] && v="$hi"
    echo "$v"
}

# ==============================================================================
# 1. 探测容器可用内存（字节）
#    优先 cgroup v2，其次 cgroup v1，最后回退宿主机 /proc/meminfo
# ==============================================================================
detect_memory_bytes() {
    local mem_bytes=""

    if [ -f /sys/fs/cgroup/memory.max ]; then
        local v
        v="$(cat /sys/fs/cgroup/memory.max)"
        [ "$v" != "max" ] && mem_bytes="$v"
    fi

    if [ -z "$mem_bytes" ] && [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        local v
        v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
        # cgroup v1 无限制时是一个极大值，需过滤
        if [ "$v" -lt 9223372036854770000 ]; then
            mem_bytes="$v"
        fi
    fi

    if [ -z "$mem_bytes" ]; then
        local kb
        kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
        mem_bytes="$((kb * 1024))"
    fi

    echo "$mem_bytes"
}

# ==============================================================================
# 2. 探测容器可用 CPU 核数
#    优先 cgroup v2 cpu.max，其次 cgroup v1，最后 nproc
# ==============================================================================
detect_cpu_count() {
    local cpus=""

    if [ -f /sys/fs/cgroup/cpu.max ]; then
        local quota period
        quota="$(awk '{print $1}' /sys/fs/cgroup/cpu.max)"
        period="$(awk '{print $2}' /sys/fs/cgroup/cpu.max)"
        if [ "$quota" != "max" ] && [ "$period" -gt 0 ]; then
            cpus="$(( (quota + period - 1) / period ))"
        fi
    fi

    if [ -z "$cpus" ] && [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        local quota period
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
        if [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
            cpus="$(( (quota + period - 1) / period ))"
        fi
    fi

    if [ -z "$cpus" ] || [ "$cpus" -lt 1 ]; then
        cpus="$(nproc)"
    fi

    echo "$cpus"
}

# ==============================================================================
# 3. 采集资源（内存 / CPU / 磁盘基准 IOPS）
# ==============================================================================
HOST_FALLBACK=0
HOST_AVAIL_MB=0
if [ -n "${MYSQL_MEMORY_LIMIT:-}" ]; then
    MEM_BYTES="$(parse_memory_to_bytes "${MYSQL_MEMORY_LIMIT}")"
    MEM_SOURCE="手动指定 MYSQL_MEMORY_LIMIT=${MYSQL_MEMORY_LIMIT}"
else
    # 判断是否真的探测到了 cgroup 限制(容器未设置 --memory 时会回退到宿主机 /proc/meminfo)
    if { [ -f /sys/fs/cgroup/memory.max ] && [ "$(cat /sys/fs/cgroup/memory.max)" != "max" ]; } || \
       [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        MEM_SOURCE="自动探测(cgroup)"
    else
        MEM_SOURCE="自动探测(宿主机总内存: 未设置容器内存限制)"
        HOST_FALLBACK=1
    fi
    MEM_BYTES="$(detect_memory_bytes)"
    if [ "$HOST_FALLBACK" = "1" ]; then
        HOST_AVAIL_MB="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    fi
fi

if [ -n "${MYSQL_CPU_LIMIT:-}" ]; then
    CPU_COUNT="$(parse_cpu_to_cores "${MYSQL_CPU_LIMIT}")"
    CPU_SOURCE="手动指定 MYSQL_CPU_LIMIT=${MYSQL_CPU_LIMIT}"
else
    CPU_COUNT="$(detect_cpu_count)"
    CPU_SOURCE="自动探测(cgroup/宿主机)"
fi

MEM_MB="$((MEM_BYTES / 1024 / 1024))"
[ "$MEM_MB" -lt 256 ] && MEM_MB=256      # 兜底：异常探测值按 256MB 处理
[ "$CPU_COUNT" -lt 1 ] && CPU_COUNT=1

IOPS="${MYSQL_IOPS:-4000}"
case "$IOPS" in
    ''|*[!0-9]*) IOPS=4000 ;;
esac
[ "$IOPS" -lt 100 ] && IOPS=100

# ==============================================================================
# 4. 计算参数
#    公式来源：
#      - MySQL 8.4 官方手册「Server System Variables」中的推荐取值
#      - 本项目 k8s MGR 生产集群(workspace/k8s/mysql-cluster)的实测配置
#    原则：内存型参数按内存比例，会话型参数按内存推导，缓存/线程型按 CPU 推导
# ==============================================================================

# ---------- 连接数 ----------
# max_connections 自动计算：
#   内存侧上限 = 内存(MB) / 16        （每 16MB 内存支撑 1 个连接）
#   CPU 侧上限 = CPU 核数 × 400 + 100 （每核约 400 个连接，另加 100 个空闲连接）
#   取两者较小值，限制在 [100, 10000]；有连接池(ProxySQL/MySQL Router)时可手动调小
CONN_BY_MEM="$((MEM_MB / 16))"
CONN_BY_CPU="$((CPU_COUNT * 400 + 100))"
if [ -n "${MYSQL_MAX_CONNECTIONS:-}" ]; then
    MAX_CONNECTIONS="$MYSQL_MAX_CONNECTIONS"
    CONN_SOURCE="手动指定 MYSQL_MAX_CONNECTIONS=${MYSQL_MAX_CONNECTIONS}（自动计算值 min(${CONN_BY_MEM}, ${CONN_BY_CPU}) 被覆盖）"
else
    MAX_CONNECTIONS="$CONN_BY_MEM"
    [ "$CONN_BY_CPU" -lt "$MAX_CONNECTIONS" ] && MAX_CONNECTIONS="$CONN_BY_CPU"
    MAX_CONNECTIONS="$(clamp "$MAX_CONNECTIONS" 100 10000)"
    CONN_SOURCE="自动计算(min(内存/16, CPU×400+100), 限制 100~10000)"
fi

# ---------- InnoDB 内存 ----------
# innodb_buffer_pool_size = 内存 70%（MySQL 建议物理内存 50%~75%）
BUFFER_POOL_MB="$(clamp "$((MEM_MB * 70 / 100))" 128 131072)"

# innodb_log_buffer_size = 缓冲池 ÷ 16（限制 16MB~256MB）
LOG_BUFFER_MB="$(clamp "$((BUFFER_POOL_MB / 16))" 16 256)"

# innodb_redo_log_capacity = 缓冲池 25%（限制 512MB~8GB）
REDO_CAPACITY_MB="$(clamp "$((BUFFER_POOL_MB / 4))" 512 8192)"

# ---------- 内存预算校验 ----------
# mysqld 自身 + 连接线程栈 + 临时空间等保留约 256MB（小内存容器按 15% 折算）
RESERVE_MB="$((MEM_MB * 15 / 100))"
[ "$RESERVE_MB" -lt 128 ] && RESERVE_MB=128
AVAIL_MB="$((MEM_MB - RESERVE_MB - LOG_BUFFER_MB))"
[ "$AVAIL_MB" -lt 256 ] && AVAIL_MB=128

# 宿主机回退场景: 若宿主当前可用内存明显低于计算预算, 按可用内存的 85% 再收敛一次,
# 避免与同机其它容器/业务争抢导致 OOM(专用数据库主机建议仍显式设置 --memory 或 MYSQL_MEMORY_LIMIT)
HOST_CAPPED=""
if [ "$HOST_FALLBACK" = "1" ] && [ "$HOST_AVAIL_MB" -gt 0 ]; then
    local_budget="$((MEM_MB - RESERVE_MB - LOG_BUFFER_MB))"
    host_budget="$((HOST_AVAIL_MB * 85 / 100 - RESERVE_MB - LOG_BUFFER_MB))"
    if [ "$host_budget" -gt 0 ] && [ "$host_budget" -lt "$local_budget" ]; then
        AVAIL_MB="$host_budget"
        HOST_CAPPED="（宿主可用内存 ${HOST_AVAIL_MB}MB 低于按总内存计算的预算, 已按其 85% 下调）"
    fi
fi

REBALANCED=""
if [ "$((BUFFER_POOL_MB + REDO_CAPACITY_MB))" -gt "$AVAIL_MB" ]; then
    # 缓冲池与 redo 合计超出可用内存时按 3:1 重新分配，避免小内存容器 OOM
    BUFFER_POOL_MB="$(clamp "$((AVAIL_MB * 3 / 4))" 128 131072)"
    REDO_CAPACITY_MB="$(clamp "$((AVAIL_MB / 4))" 64 8192)"
    REBALANCED="（已按内存预算下调：缓冲池+redo 合计不得超过 内存-保留-日志缓冲）"
fi

# 宿主机回退提示: 未设置容器内存限制时, 参数按宿主机总内存计算, 需提醒用户可能的资源争抢
HOST_HINT=""
if [ "$HOST_FALLBACK" = "1" ] && [ "$HOST_AVAIL_MB" -gt 0 ]; then
    HOST_HINT="注意: 未设置容器内存限制, 按宿主机总内存 ${MEM_MB}MB 计算(当前宿主可用 ${HOST_AVAIL_MB}MB)。
      建议显式限制容器内存(docker run --memory=8g / compose mem_limit)或设置 MYSQL_MEMORY_LIMIT。
"
fi

# innodb_buffer_pool_instances = 每 1GiB 缓冲池 1 个实例（限制 1~16）
BP_GIB="$((BUFFER_POOL_MB / 1024))"
[ "$BP_GIB" -lt 1 ] && BP_GIB=1
BUFFER_POOL_INSTANCES="$(clamp "$BP_GIB" 1 16)"

# 缓冲池预热保留比例：25%（重启后只恢复最热的 1/4 页面，缩短启动时间）
BP_DUMP_PCT=25

# ---------- 会话内存（每连接，按需分配） ----------
# 顺序扫描缓冲 = 内存 ÷ 4096（限制 1MB~4MB）
READ_BUFFER_MB="$(clamp "$((MEM_MB / 4096))" 1 4)"
# 随机读缓冲与顺序扫描缓冲同量级
READ_RND_MB="$READ_BUFFER_MB"
# 排序缓冲 = 内存 ÷ 2048（限制 1MB~8MB）
SORT_BUFFER_MB="$(clamp "$((MEM_MB / 2048))" 1 8)"
# 关联缓冲与排序缓冲同量级
JOIN_BUFFER_MB="$SORT_BUFFER_MB"
# 内存临时表上限 = 内存 ÷ 32（限制 16MB~512MB）
TMP_TABLE_MB="$(clamp "$((MEM_MB / 32))" 16 512)"
# 单包上限 = 内存 ÷ 32（限制 32MB~512MB）
MAX_PACKET_MB="$(clamp "$((MEM_MB / 32))" 32 512)"
# 单事务 binlog 缓存 = 内存 ÷ 4096（限制 1MB~32MB；该缓存按写入连接分配，不宜过大）
BINLOG_CACHE_MB="$(clamp "$((MEM_MB / 4096))" 1 32)"
# 单事务 binlog 缓存上限 = 内存 ÷ 4（限制 256MB~4GB）
MAX_BINLOG_CACHE_MB="$(clamp "$((MEM_MB / 4))" 256 4096)"

# 会话内存估算：每个连接同时执行排序/关联等操作时的上限（不含临时表/单包等按需分配项）
PER_SESSION_MB="$((READ_BUFFER_MB + READ_RND_MB + SORT_BUFFER_MB + JOIN_BUFFER_MB + BINLOG_CACHE_MB))"
SESSION_WORST_MB="$((MAX_CONNECTIONS * PER_SESSION_MB))"
# 典型并发按 10% 连接数估算（绝大多数连接处于空闲状态）
TYPICAL_CONN="$((MAX_CONNECTIONS / 10))"
[ "$TYPICAL_CONN" -lt 1 ] && TYPICAL_CONN=1
SESSION_TYPICAL_MB="$((TYPICAL_CONN * PER_SESSION_MB))"

# ---------- 表缓存 / 线程缓存（按 CPU 推导） ----------
# table_open_cache = CPU × 2048（限制 2000~65535）
TABLE_OPEN_CACHE="$(clamp "$((CPU_COUNT * 2048))" 2000 65535)"
# table_definition_cache = table_open_cache ÷ 2（限制 1000~65535）
TABLE_DEF_CACHE="$(clamp "$((TABLE_OPEN_CACHE / 2))" 1000 65535)"
# table_open_cache_instances = CPU 核数（限制 1~16）
TABLE_OPEN_INSTANCES="$(clamp "$CPU_COUNT" 1 16)"
# thread_cache_size = CPU × 32（限制 64~2048）
THREAD_CACHE="$(clamp "$((CPU_COUNT * 32))" 64 2048)"
# back_log = CPU × 1024（限制 1024~65535）
BACK_LOG="$(clamp "$((CPU_COUNT * 1024))" 1024 65535)"
# open_files_limit = max_connections + table_open_cache×2 + 2048（限制 65535~1048576）
OPEN_FILES="$(clamp "$((MAX_CONNECTIONS + TABLE_OPEN_CACHE * 2 + 2048))" 65535 1048576)"
# innodb_open_files 与 table_open_cache 对齐（限制 2000~65535）
INNODB_OPEN_FILES="$(clamp "$TABLE_OPEN_CACHE" 2000 65535)"

# ---------- IO（按 CPU 与磁盘基准推导） ----------
# innodb_io_capacity = MYSQL_IOPS（默认 4000，对应 SSD；HDD 建议 200，NVMe 可到 10000+）
IO_CAPACITY="$IOPS"
# innodb_io_capacity_max = 基准 × 2（突发刷脏上限）
IO_CAPACITY_MAX="$((IOPS * 2))"
# innodb_read_io_threads / write_io_threads = CPU 核数（限制 4~16）
IO_THREADS="$(clamp "$CPU_COUNT" 4 16)"
# innodb_purge_threads = CPU ÷ 2（限制 2~8）
PURGE_THREADS="$(clamp "$((CPU_COUNT / 2))" 2 8)"
# innodb_lru_scan_depth = 基准 ÷ 2（限制 500~4000）
LRU_SCAN_DEPTH="$(clamp "$((IO_CAPACITY / 2))" 500 4000)"

# ---------- 复制（按 CPU 推导） ----------
# replica_parallel_workers = CPU 核数（限制 4~32）
REPLICA_WORKERS="$(clamp "$CPU_COUNT" 4 32)"

# ==============================================================================
# 5. 生成带中文注释的配置 / 摘要
# ==============================================================================
FORMAT="${1:-conf}"

RESOURCE_LINE="内存 ${MEM_MB}MB[${MEM_SOURCE}] / CPU ${CPU_COUNT} 核[${CPU_SOURCE}] / 磁盘基准 IOPS ${IOPS}"


emit_conf() {
cat <<CONF
###############################################################################
#  Percona Server for MySQL 自动调优配置（由 mysql-config-tuner.sh 生成）
#  资源：${RESOURCE_LINE}
#  说明：本文件每次容器启动都会重新生成，请勿手工修改
#        （需固定参数请改 my.cnf，或设置 MYSQL_MEMORY_LIMIT / MYSQL_CPU_LIMIT）
#  公式说明见 https://github.com/iflyelf/mysql-docker#cpu--内存自动调优
###############################################################################

[mysqld]

#------------------------------------------------------------------------------
# 连接
#------------------------------------------------------------------------------
# 最大连接数：${CONN_SOURCE}
#   内存侧上限 = 内存(MB) ÷ 16 = ${MEM_MB}÷16 = ${CONN_BY_MEM}
#   CPU 侧上限  = CPU × 400 + 100 = ${CPU_COUNT}×400+100 = ${CONN_BY_CPU}
#   自动取值 = clamp(min(两者), 100, 10000) = ${MAX_CONNECTIONS}
max_connections = ${MAX_CONNECTIONS}

# 监听队列 = CPU × 1024，限制 1024~65535 → ${BACK_LOG}
#   实际生效值还会受内核 net.core.somaxconn 限制
back_log = ${BACK_LOG}

#------------------------------------------------------------------------------
# InnoDB 内存
#------------------------------------------------------------------------------
# 缓冲池 = 内存 × 70% = ${MEM_MB}MB × 70% → ${BUFFER_POOL_MB}MB（限制 128MB~128GB）${REBALANCED}${HOST_CAPPED}
#   InnoDB 最热数据与索引缓存，是决定性能的最关键参数
innodb_buffer_pool_size = ${BUFFER_POOL_MB}M

# 缓冲池实例 = 缓冲池 GiB 数 = ${BUFFER_POOL_MB}MB ÷ 1024 → ${BUFFER_POOL_INSTANCES}（限制 1~16）
#   实例越多，并发访问缓冲池时的互斥越少
innodb_buffer_pool_instances = ${BUFFER_POOL_INSTANCES}

# 缓冲池预热保留比例 = ${BP_DUMP_PCT}%（重启后只恢复最热的 1/4 页面，缩短启动时间）
innodb_buffer_pool_dump_pct = ${BP_DUMP_PCT}

# Redo 容量 = 缓冲池 × 25% = ${BUFFER_POOL_MB}MB × 25% → ${REDO_CAPACITY_MB}MB（限制 64MB~8GB）${REBALANCED}${HOST_CAPPED}
#   8.4 用 innodb_redo_log_capacity 统一管理（替代已移除的 innodb_log_file_size
#   与 innodb_log_files_in_group），建议 ≥ 1 小时写入量
innodb_redo_log_capacity = ${REDO_CAPACITY_MB}M

# Redo 日志缓冲 = 缓冲池 ÷ 16 → ${LOG_BUFFER_MB}MB（限制 16MB~256MB）
innodb_log_buffer_size = ${LOG_BUFFER_MB}M

#------------------------------------------------------------------------------
# 会话内存（每连接按需分配）
#------------------------------------------------------------------------------
# 顺序扫描缓冲 = 内存 ÷ 4096 → ${READ_BUFFER_MB}MB（限制 1MB~4MB）
read_buffer_size = ${READ_BUFFER_MB}M

# 随机读缓冲 = 与顺序扫描缓冲同量级 → ${READ_RND_MB}MB
read_rnd_buffer_size = ${READ_RND_MB}M

# 排序缓冲 = 内存 ÷ 2048 → ${SORT_BUFFER_MB}MB（限制 1MB~8MB）
#   按需分配，并发高时按实际负载调整
sort_buffer_size = ${SORT_BUFFER_MB}M

# 关联缓冲 = 与排序缓冲同量级 → ${JOIN_BUFFER_MB}MB（无索引关联时使用）
join_buffer_size = ${JOIN_BUFFER_MB}M

# 内存临时表上限 = 内存 ÷ 32 → ${TMP_TABLE_MB}MB（限制 16MB~512MB）
#   tmp_table_size 与 max_heap_table_size 需一致，超过后落盘为磁盘临时表
tmp_table_size = ${TMP_TABLE_MB}M
max_heap_table_size = ${TMP_TABLE_MB}M

# 单包上限 = 内存 ÷ 32 → ${MAX_PACKET_MB}MB（限制 32MB~512MB）
#   大字段/大 SQL/大事务需要更大包时可按业务放大
max_allowed_packet = ${MAX_PACKET_MB}M

# 单事务 binlog 缓存 = 内存 ÷ 4096 → ${BINLOG_CACHE_MB}MB（限制 1MB~32MB，按写入连接分配）
binlog_cache_size = ${BINLOG_CACHE_MB}M

# 单事务 binlog 缓存上限 = 内存 ÷ 4 → ${MAX_BINLOG_CACHE_MB}MB（限制 256MB~4GB）
max_binlog_cache_size = ${MAX_BINLOG_CACHE_MB}M

#------------------------------------------------------------------------------
# 表缓存 / 线程缓存
#------------------------------------------------------------------------------
# 打开表缓存 = CPU × 2048 = ${CPU_COUNT}×2048 → ${TABLE_OPEN_CACHE}（限制 2000~65535）
table_open_cache = ${TABLE_OPEN_CACHE}

# 表结构缓存 = table_open_cache ÷ 2 → ${TABLE_DEF_CACHE}（限制 1000~65535）
table_definition_cache = ${TABLE_DEF_CACHE}

# 打开表缓存分片 = CPU 核数 → ${TABLE_OPEN_INSTANCES}（限制 1~16，降低 LOCK_open 竞争）
table_open_cache_instances = ${TABLE_OPEN_INSTANCES}

# 线程缓存 = CPU × 32 → ${THREAD_CACHE}（限制 64~2048，复用空闲线程）
thread_cache_size = ${THREAD_CACHE}

# 打开文件上限 = 连接数 + 打开表缓存×2 + 2048 → ${OPEN_FILES}（限制 65535~1048576）
#   需同时满足容器 ulimits nofile（compose 中默认 65535）
open_files_limit = ${OPEN_FILES}

# InnoDB 文件句柄上限 = table_open_cache → ${INNODB_OPEN_FILES}（限制 2000~65535）
innodb_open_files = ${INNODB_OPEN_FILES}

#------------------------------------------------------------------------------
# IO
#------------------------------------------------------------------------------
# IO 能力基准 = 磁盘基准 IOPS = ${IO_CAPACITY}（MYSQL_IOPS，默认 4000 对应 SSD）
#   HDD 建议 200，普通云盘 1000~2000，本地 NVMe 可到 10000+
innodb_io_capacity = ${IO_CAPACITY}

# 刷脏突发上限 = 基准 × 2 → ${IO_CAPACITY_MAX}
innodb_io_capacity_max = ${IO_CAPACITY_MAX}

# LRU 刷脏扫描深度 = 基准 ÷ 2 → ${LRU_SCAN_DEPTH}（限制 500~4000）
innodb_lru_scan_depth = ${LRU_SCAN_DEPTH}

# InnoDB 读写 IO 线程 = CPU 核数 → ${IO_THREADS}（限制 4~16）
innodb_read_io_threads = ${IO_THREADS}
innodb_write_io_threads = ${IO_THREADS}

# purge 线程 = CPU ÷ 2 → ${PURGE_THREADS}（限制 2~8，回收 undo 与历史版本）
innodb_purge_threads = ${PURGE_THREADS}

#------------------------------------------------------------------------------
# 复制（MGR / 主从通用）
#------------------------------------------------------------------------------
# 并行回放线程 = CPU 核数 → ${REPLICA_WORKERS}（限制 4~32）
replica_parallel_workers = ${REPLICA_WORKERS}
CONF
}

emit_summary() {
    local typical_pct="$((SESSION_TYPICAL_MB * 100 / MEM_MB))"
    local worst_pct="$((SESSION_WORST_MB * 100 / MEM_MB))"
    local budget_pct="$(((BUFFER_POOL_MB + REDO_CAPACITY_MB + LOG_BUFFER_MB) * 100 / MEM_MB))"
cat <<SUMMARY
===== MySQL 自动调优资源与关键参数 =====
内存                : ${MEM_MB}MB (${MEM_SOURCE})${HOST_CAPPED}
CPU                 : ${CPU_COUNT} 核 (${CPU_SOURCE})
磁盘基准 IOPS       : ${IOPS} (环境变量 MYSQL_IOPS 可覆盖)
max_connections     : ${MAX_CONNECTIONS} (${CONN_SOURCE})
innodb_buffer_pool  : ${BUFFER_POOL_MB}MB / ${BUFFER_POOL_INSTANCES} 实例 (内存 70%)
innodb_redo 容量    : ${REDO_CAPACITY_MB}MB (缓冲池 25%)
redo log buffer     : ${LOG_BUFFER_MB}MB | binlog cache: ${BINLOG_CACHE_MB}MB (max ${MAX_BINLOG_CACHE_MB}MB)
会话缓冲(读/随机/排序/关联): ${READ_BUFFER_MB}/${READ_RND_MB}/${SORT_BUFFER_MB}/${JOIN_BUFFER_MB}MB
临时表/单包        : ${TMP_TABLE_MB}MB / ${MAX_PACKET_MB}MB
表缓存(open/def/inst): ${TABLE_OPEN_CACHE}/${TABLE_DEF_CACHE}/${TABLE_OPEN_INSTANCES}
线程缓存 / back_log : ${THREAD_CACHE} / ${BACK_LOG}
open_files_limit    : ${OPEN_FILES} (innodb_open_files ${INNODB_OPEN_FILES})
IO 能力(min/max)    : ${IO_CAPACITY}/${IO_CAPACITY_MAX}, 读写线程 ${IO_THREADS}, purge ${PURGE_THREADS}
并行回放线程        : ${REPLICA_WORKERS}
常驻内存预算        : 约 $((BUFFER_POOL_MB + REDO_CAPACITY_MB + LOG_BUFFER_MB))MB (${budget_pct}% 内存)
会话内存估算        : 典型并发 ${TYPICAL_CONN} 连接 ≈ ${SESSION_TYPICAL_MB}MB (${typical_pct}%);
                      极端全满 ${MAX_CONNECTIONS} 连接 ≈ ${SESSION_WORST_MB}MB (${worst_pct}%，实际按需分配不会全部占用)
提示: 连接池场景可用 MYSQL_MAX_CONNECTIONS 调小; 云盘请按实际 IOPS 设置 MYSQL_IOPS
${HOST_HINT}=======================================
SUMMARY
}

case "$FORMAT" in
    conf)     emit_conf ;;
    summary)  emit_summary ;;
    *)        echo "未知格式: $FORMAT（可选: conf | summary）" >&2; exit 2 ;;
esac
