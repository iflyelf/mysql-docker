#!/usr/bin/env bash
#=================================================
# https://github.com/iflyelf/mysql-docker
# Percona XtraBackup 8.4 备份/恢复管理脚本
#
# 用法:
#   xtrabackup-manage.sh full           全量备份
#   xtrabackup-manage.sh incremental    增量备份(基于最近一次全量/增量)
#   xtrabackup-manage.sh list           列出备份
#   xtrabackup-manage.sh prepare [目录] 准备备份(应用 redo, 支持增量链)
#   xtrabackup-manage.sh restore <目录> 恢复(需先停止 mysqld)
#   xtrabackup-manage.sh prune          按保留策略清理旧备份
#   xtrabackup-manage.sh cron           常驻定时备份(全量: 每周日; 增量: 每天)
#
# 环境变量:
#   XB_BACKUP_DIR          备份根目录(默认 /backup)
#   XB_HOST / XB_PORT      连接地址(默认 localhost:3306; 容器外备份用 mysql:3306)
#   XB_USER                备份账号(默认 root, 需要 BACKUP_ADMIN/RELOAD/LOCK TABLES 权限)
#   XB_PASSWORD            备份账号密码(默认取 MYSQL_ROOT_PASSWORD)
#   XB_SOCKET              socket 路径(默认 /var/run/mysqld/mysqld.sock)
#   XB_DATADIR             数据目录(默认 /var/lib/mysql)
#   XB_PARALLEL            并行线程数(默认 2)
#   XB_COMPRESS            none|zstd|lz4(默认 none, 压缩影响恢复速度)
#   XB_KEEP_FULL           保留最近几份全量(含其增量, 默认 2)
#   XB_RETENTION_DAYS      增量备份保留天数(默认 7)
#   XB_BACKUP_TIME         cron 模式每日执行时间(HH:MM, 默认 03:00, 容器内 UTC)
#   XB_EXTRA_ARGS          追加给 xtrabackup 的额外参数
#
# 说明:
#   - 备份目录结构: ${XB_BACKUP_DIR}/full/<时间戳>、${XB_BACKUP_DIR}/inc/<时间戳>
#   - 恢复前脚本会把原数据目录重命名为 datadir.bak-<时间戳>, 便于回滚
#   - MGR 集群建议在 SECONDARY 节点执行备份(避免影响主库写入)
#=================================================
set -euo pipefail

XB_BIN="${XB_BIN:-xtrabackup}"
XB_BACKUP_DIR="${XB_BACKUP_DIR:-/backup}"
XB_HOST="${XB_HOST:-localhost}"
XB_PORT="${XB_PORT:-3306}"
XB_USER="${XB_USER:-root}"
XB_PASSWORD="${XB_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
XB_SOCKET="${XB_SOCKET:-/var/run/mysqld/mysqld.sock}"
XB_DATADIR="${XB_DATADIR:-/var/lib/mysql}"
XB_PARALLEL="${XB_PARALLEL:-2}"
XB_COMPRESS="${XB_COMPRESS:-none}"
XB_KEEP_FULL="${XB_KEEP_FULL:-2}"
XB_RETENTION_DAYS="${XB_RETENTION_DAYS:-7}"
XB_BACKUP_TIME="${XB_BACKUP_TIME:-03:00}"
XB_EXTRA_ARGS="${XB_EXTRA_ARGS:-}"

FULL_DIR="${XB_BACKUP_DIR}/full"
INC_DIR="${XB_BACKUP_DIR}/inc"

# ------------------------------------------------------------------------------
# 日志
# ------------------------------------------------------------------------------
log()  { printf '%s [xtrabackup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [xtrabackup][WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { printf '%s [xtrabackup][ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

require_xtrabackup() {
    command -v "$XB_BIN" >/dev/null 2>&1 || die "未找到 $XB_BIN, 请在备份容器(percona/percona-xtrabackup:8.4)或已安装 xtrabackup 的环境执行"
}

# 连接参数: 容器内优先 socket, 跨容器用 TCP
conn_args() {
    if [ -n "${XB_HOST}" ] && [ "${XB_HOST}" != "localhost" ] && [ "${XB_HOST}" != "127.0.0.1" ]; then
        printf '%s\n' "--host=${XB_HOST}" "--port=${XB_PORT}"
    else
        printf '%s\n' "--socket=${XB_SOCKET}"
    fi
}

base_args() {
    local a=()
    mapfile -t a < <(conn_args)
    a+=("--user=${XB_USER}")
    [ -n "$XB_PASSWORD" ] && a+=("--password=${XB_PASSWORD}")
    a+=("--datadir=${XB_DATADIR}" "--parallel=${XB_PARALLEL}" "--no-timestamp")
    case "$XB_COMPRESS" in
        zstd) a+=(--compress-zstd=1 "--compress-threads=${XB_PARALLEL}") ;;
        lz4)  a+=(--compress=lz4 "--compress-threads=${XB_PARALLEL}") ;;
        none|'') ;;
        *) warn "未知 XB_COMPRESS=${XB_COMPRESS}, 按不压缩处理" ;;
    esac
    [ -n "$XB_EXTRA_ARGS" ] && a+=($XB_EXTRA_ARGS)
    printf '%s\n' "${a[@]}"
}

check_priv() {
    # 简单连通性检查(避免备份到一半才报权限错误); 备份镜像可能不带 mysql 客户端
    if ! command -v mysqladmin >/dev/null 2>&1; then
        warn "未安装 mysql 客户端(mysqladmin), 跳过连通性检查"
        return 0
    fi
    local ping
    if [ "$XB_HOST" = "localhost" ] || [ "$XB_HOST" = "127.0.0.1" ]; then
        ping="$(mysqladmin --socket="$XB_SOCKET" --user="$XB_USER" --password="$XB_PASSWORD" ping 2>&1 || true)"
    else
        ping="$(mysqladmin --host="$XB_HOST" --port="$XB_PORT" --user="$XB_USER" --password="$XB_PASSWORD" ping 2>&1 || true)"
    fi
    case "$ping" in
        *"is alive"*) return 0 ;;
        *) die "无法连接 MySQL(${XB_HOST}:${XB_PORT}): ${ping}" ;;
    esac
}

# 若节点是 MGR PRIMARY, 给出建议(不阻断)
mgr_hint() {
    if ! command -v mysql >/dev/null 2>&1; then
        return 0
    fi
    local role
    role="$(mysql -N -B --socket="$XB_SOCKET" --user="$XB_USER" --password="$XB_PASSWORD" -e \
        "SELECT MEMBER_ROLE FROM performance_schema.replication_group_members WHERE MEMBER_ID=@@server_uuid" 2>/dev/null || true)"
    if [ "$role" = "PRIMARY" ]; then
        warn "当前节点是 MGR PRIMARY, 建议改在 SECONDARY 节点执行备份以减少对写入的影响"
    elif [ -n "$role" ]; then
        log "当前节点 MGR 角色: ${role}(在 SECONDARY 备份对业务影响更小)"
    fi
}

latest_full() {
    [ -d "$FULL_DIR" ] || return 0
    find "$FULL_DIR" -mindepth 1 -maxdepth 1 -type d | sort | tail -1
}

latest_backup() {
    local full inc
    full="$(latest_full)"
    inc="$(find "$INC_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1 || true)"
    if [ -z "$full" ] && [ -z "$inc" ]; then return 0; fi
    if [ -z "$inc" ] || { [ -n "$full" ] && [[ "$full" > "$inc" ]]; }; then
        echo "$full"
    else
        echo "$inc"
    fi
}

# ------------------------------------------------------------------------------
# 全量备份
# ------------------------------------------------------------------------------
cmd_full() {
    require_xtrabackup
    check_priv
    mgr_hint
    local ts target
    ts="$(date '+%Y%m%d-%H%M%S')"
    target="${FULL_DIR}/${ts}"
    mkdir -p "$target"
    log "开始全量备份 → ${target}"
    local args=()
    mapfile -t args < <(base_args)
    "$XB_BIN" --backup "${args[@]}" --target-dir="$target" 2>&1 | sed 's/^/  /'
    log "全量备份完成: $(du -sh "$target" | awk '{print $1}')"
    cmd_prune
}

# ------------------------------------------------------------------------------
# 增量备份
# ------------------------------------------------------------------------------
cmd_incremental() {
    require_xtrabackup
    check_priv
    mgr_hint
    local basedir ts target
    basedir="$(latest_backup)"
    [ -n "$basedir" ] || die "没有可用的基础备份, 请先执行 full"
    ts="$(date '+%Y%m%d-%H%M%S')"
    target="${INC_DIR}/${ts}"
    mkdir -p "$target"
    log "开始增量备份(基于 $(basename "$basedir")) → ${target}"
    local args=()
    mapfile -t args < <(base_args)
    "$XB_BIN" --backup "${args[@]}" --target-dir="$target" \
        --incremental-basedir="$basedir" 2>&1 | sed 's/^/  /'
    log "增量备份完成: $(du -sh "$target" | awk '{print $1}')"
    cmd_prune
}

# ------------------------------------------------------------------------------
# 准备(应用 redo): 增量链按时间顺序应用
# ------------------------------------------------------------------------------
cmd_prepare() {
    require_xtrabackup
    local target="${1:-}"
    if [ -z "$target" ]; then
        target="$(latest_full)"
        [ -n "$target" ] || die "没有全量备份可准备"
    fi
    [[ "$target" != /* ]] && target="${XB_BACKUP_DIR}/${target}"
    [ -d "$target" ] || die "备份目录不存在: $target"

    # 找到该全量之后的增量链
    local chain=("$target")
    if [[ "$target" == "$FULL_DIR/"* ]]; then
        local inc
        while IFS= read -r inc; do
            [ -n "$inc" ] && chain+=("$inc")
        done < <(find "$INC_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | awk -v t="$(basename "$target")" -F/ '$NF > t')
    fi

    log "准备全量: $(basename "${chain[0]}")"
    "$XB_BIN" --prepare --apply-log-only --target-dir="${chain[0]}" ${XB_EXTRA_ARGS:-} 2>&1 | sed 's/^/  /'

    local i last
    last=$((${#chain[@]} - 1))
    for ((i = 1; i <= last; i++)); do
        log "应用增量: $(basename "${chain[$i]}")"
        if [ "$i" -eq "$last" ]; then
            "$XB_BIN" --prepare --target-dir="${chain[0]}" --incremental-dir="${chain[$i]}" ${XB_EXTRA_ARGS:-} 2>&1 | sed 's/^/  /'
        else
            "$XB_BIN" --prepare --apply-log-only --target-dir="${chain[0]}" --incremental-dir="${chain[$i]}" ${XB_EXTRA_ARGS:-} 2>&1 | sed 's/^/  /'
        fi
    done

    touch "${chain[0]}/.prepared"
    log "准备完成: ${chain[0]}(共 ${#chain[@]} 个备份参与)"
    log "binlog 位点(GTID): $(cat "${chain[0]}/xtrabackup_binlog_info" 2>/dev/null || echo '见 xtrabackup_binlog_info')"
}

# ------------------------------------------------------------------------------
# 列表
# ------------------------------------------------------------------------------
cmd_list() {
    local d
    log "备份根目录: ${XB_BACKUP_DIR}"
    if [ -d "$FULL_DIR" ]; then
        for d in $(find "$FULL_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort); do
            printf '  [全量] %-22s %6s  %s\n' "$(basename "$d")" "$(du -sh "$d" | awk '{print $1}')" \
                "$([ -f "$d/.prepared" ] && echo '已prepare' || echo '未prepare')"
        done
    fi
    if [ -d "$INC_DIR" ]; then
        for d in $(find "$INC_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort); do
            printf '  [增量] %-22s %6s\n' "$(basename "$d")" "$(du -sh "$d" | awk '{print $1}')"
        done
    fi
}

# ------------------------------------------------------------------------------
# 恢复(需先停止 mysqld)
# ------------------------------------------------------------------------------
cmd_restore() {
    require_xtrabackup
    local src="${1:-}"
    [ -n "$src" ] || die "用法: xtrabackup-manage.sh restore <备份目录>"
    src="${src%/}"
    [ -d "$src" ] || die "备份目录不存在: $src"
    [ -f "$src/xtrabackup_checkpoints" ] || die "不是有效的 xtrabackup 备份目录: $src"

    if [ -f "$src/xtrabackup_checkpoints" ] && ! grep -q 'full-prepared' "$src/xtrabackup_checkpoints"; then
        die "备份尚未 prepare(或不是最终 prepare 的全量), 请先执行: xtrabackup-manage.sh prepare ${src}"
    fi

    if pgrep -x mysqld >/dev/null 2>&1; then
        die "检测到 mysqld 正在运行, 请先停止容器/进程后再恢复(避免数据目录被写坏)"
    fi

    local backup_suffix
    backup_suffix="$(date '+%Y%m%d-%H%M%S')"
    if [ -d "$XB_DATADIR" ] && [ -n "$(ls -A "$XB_DATADIR" 2>/dev/null)" ]; then
        log "原数据目录重命名为: ${XB_DATADIR}.bak-${backup_suffix}"
        mv "$XB_DATADIR" "${XB_DATADIR}.bak-${backup_suffix}"
    fi
    mkdir -p "$XB_DATADIR"

    log "开始恢复 → ${XB_DATADIR}"
    "$XB_BIN" --copy-back --target-dir="$src" --datadir="$XB_DATADIR" 2>&1 | sed 's/^/  /'
    chown -R mysql:mysql "$XB_DATADIR"
    log "恢复完成。请启动 MySQL 并检查错误日志:"
    log "  docker start <容器名>  (或 docker compose up -d)"
    log "  MGR 集群: 建议用 clone 插件重建故障成员, 或将本次备份恢复到新节点后再加入组"
}

# ------------------------------------------------------------------------------
# 清理: 保留最近 XB_KEEP_FULL 份全量及其增量, 增量按天数保留
# ------------------------------------------------------------------------------
cmd_prune() {
    [ -d "$FULL_DIR" ] || return 0
    local all=() keep=() i d full_ts
    mapfile -t all < <(find "$FULL_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    [ "${#all[@]}" -eq 0 ] && return 0

    # 需要保留的全量(最后 N 份)
    local start=$(( ${#all[@]} - XB_KEEP_FULL ))
    [ "$start" -lt 0 ] && start=0
    for ((i = start; i < ${#all[@]}; i++)); do keep+=("${all[$i]}"); done
    local oldest_keep="${keep[0]}"

    # 删除更早的全量
    for ((i = 0; i < start; i++)); do
        log "清理旧全量: $(basename "${all[$i]}")"
        rm -rf "${all[$i]}"
    done

    # 删除比最早保留全量更早的增量, 以及超过保留天数的增量
    if [ -d "$INC_DIR" ]; then
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            if [[ "$(basename "$d")" < "$(basename "$oldest_keep")" ]] || \
               [ -n "$(find "$d" -maxdepth 0 -mtime +"$XB_RETENTION_DAYS" 2>/dev/null)" ]; then
                log "清理旧增量: $(basename "$d")"
                rm -rf "$d"
            fi
        done < <(find "$INC_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    fi
}

# ------------------------------------------------------------------------------
# 定时模式: 每周日全量, 其余每天增量(时间由 XB_BACKUP_TIME 指定, 容器内 UTC)
# ------------------------------------------------------------------------------
cmd_cron() {
    log "启动定时备份: 每日 ${XB_BACKUP_TIME}(UTC), 周日全量, 其余增量; 保留 ${XB_KEEP_FULL} 份全量 / ${XB_RETENTION_DAYS} 天增量"
    # 首次启动若没有任何全量备份, 立即做一次
    if [ -z "$(latest_full)" ]; then
        log "未发现全量备份, 立即执行首次全量"
        cmd_full || warn "首次全量备份失败, 将在下次计划时间重试"
    fi
    while true; do
        local now_date now_time dow marker
        now_date="$(date '+%F')"
        now_time="$(date '+%H:%M')"
        dow="$(date '+%u')"   # 1=周一 ... 7=周日
        marker="${XB_BACKUP_DIR}/.last-run-${now_date}"
        if [ "$now_time" = "$XB_BACKUP_TIME" ] && [ ! -f "$marker" ]; then
            if [ "$dow" = "7" ]; then
                log "计划任务: 周日全量备份"
                cmd_full && echo "full" > "$marker" || warn "全量备份失败"
            else
                log "计划任务: 每日增量备份"
                cmd_incremental && echo "incremental" > "$marker" || warn "增量备份失败"
            fi
        fi
        sleep 60
    done
}

# ------------------------------------------------------------------------------
# 入口
# ------------------------------------------------------------------------------
mkdir -p "$FULL_DIR" "$INC_DIR"

case "${1:-}" in
    full)        cmd_full ;;
    incremental|inc) cmd_incremental ;;
    prepare)     shift; cmd_prepare "${1:-}" ;;
    list|ls)     cmd_list ;;
    restore)     shift; cmd_restore "${1:-}" ;;
    prune)       cmd_prune ;;
    cron)        cmd_cron ;;
    *)
        cat >&2 <<EOF
用法: xtrabackup-manage.sh <命令> [参数]

命令:
  full                全量备份
  incremental         增量备份(基于最近一次全量/增量)
  list                列出备份
  prepare [目录]      准备备份(应用 redo; 增量链按顺序应用)
  restore <目录>      恢复(需先停止 mysqld)
  prune               按保留策略清理旧备份
  cron                常驻定时备份(周日全量, 其余增量)

常用环境变量: XB_BACKUP_DIR / XB_HOST / XB_PORT / XB_USER / XB_PASSWORD /
              XB_PARALLEL / XB_COMPRESS(none|zstd|lz4) / XB_KEEP_FULL /
              XB_RETENTION_DAYS / XB_BACKUP_TIME
EOF
        exit 2 ;;
esac
