#!/usr/bin/env bash
#=================================================
# https://github.com/iflyelf/mysql-docker
# 同步 Percona Server for MySQL / gosu 版本号
#
# 用法:
#   bash scripts/update-version.sh
#
# 在 GitHub Actions 中会额外写入 $GITHUB_ENV:
#   CHANGED=0|1        是否有改动
#   SUMMARY=...        改动摘要(用于 commit message)
#   MYSQL_VERSION=...  当前(更新后)的 MySQL 版本号
#=================================================
set -euo pipefail

DOCKERFILE="${DOCKERFILE:-Dockerfile}"
# 华为云/Runners 默认直连; 国内可设置代理前缀(用法: ?url=<原始地址>)
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"

GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# ---------- 语义化版本比较: 若 $1 > $2 返回 0 ----------
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# ---------- 读取 Dockerfile 中的 ARG 默认值 ----------
arg_value() {
    grep -oP "^\s*ARG\s+$1=\K.*" "$DOCKERFILE" | head -1 || true
}

# ---------- HTTP 抓取(支持代理前缀) ----------
fetch() {
    if [ -n "$DOWNLOAD_PROXY" ]; then
        curl -fsSL "${DOWNLOAD_PROXY}?url=$1" 2>/dev/null || curl -fsSL "$1"
    else
        curl -fsSL "$1"
    fi
}

# ---------- 取 Percona 仓库中最新 8.4 LTS 版本(不含 -1.<distro> 后缀) ----------
# 不使用 GitHub API: percona-server 仓库的 release/tag 命名与 deb 版本不一致,
# 官方 apt 索引才是实际可下载的版本来源。
percona_latest() {
    local series="$1" distro="$2" index
    index="https://repo.percona.com/ps-${series//./-}-lts/apt/dists/${distro}/main/binary-amd64/Packages.gz"
    fetch "$index" 2>/dev/null \
        | gzip -dc 2>/dev/null \
        | awk -v series="$series" '
            /^Package: percona-server-server$/ { want=1; next }
            /^Package: / { want=0 }
            want && /^Version: / {
                v = $2
                # 8.4.11-12-1.resolute => 8.4.11-12
                sub(/-1\.[A-Za-z0-9]+$/, "", v)
                if (v ~ "^" series "\\.") print v
            }' \
        | sort -V | tail -1
}

# ---------- 取 GitHub 最新稳定 release(gosu), 去掉前缀 v ----------
github_latest() {
    local repo="$1" out
    if [ -n "$GH_TOKEN" ]; then
        out=$(curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" \
            "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | jq -r 'if .prerelease == false and .draft == false then .tag_name else empty end' 2>/dev/null || true)
    fi
    if [ -z "${out:-}" ]; then
        out=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null || true)
    fi
    echo "${out#v}"
}

CHANGED=0
SUMMARY=""

# ---------- 通用更新函数: $1=ARG名 $2=最新版本 ----------
try_update() {
    local arg="$1" latest="$2" current
    [ -z "$latest" ] && { echo "  [$arg] 获取最新版本失败, 跳过"; return 0; }
    current=$(arg_value "$arg")
    [ -z "$current" ] && { echo "  [$arg] Dockerfile 中未找到, 跳过"; return 0; }
    if [ "$current" = "$latest" ]; then
        echo "  [$arg] 已是最新 ($current)"
    elif version_gt "$latest" "$current"; then
        echo "  [$arg] 更新: $current => $latest"
        sed -i "s|^\(\s*\)ARG ${arg}=.*|\1ARG ${arg}=${latest}|" "$DOCKERFILE"
        CHANGED=1
        SUMMARY="${SUMMARY}\n- ${arg}: ${current} => ${latest}"
    else
        echo "  [$arg] 远程版本($latest)不高于当前($current), 跳过"
    fi
}

MYSQL_SERIES="$(arg_value MYSQL_SERIES)"; MYSQL_SERIES="${MYSQL_SERIES:-8.4}"
PERCONA_DISTRO="$(arg_value PERCONA_DISTRO)"; PERCONA_DISTRO="${PERCONA_DISTRO:-resolute}"

echo "===== 检查 Percona Server ${MYSQL_SERIES} (${PERCONA_DISTRO}) ====="
try_update MYSQL_VERSION "$(percona_latest "$MYSQL_SERIES" "$PERCONA_DISTRO")"

echo "===== 检查 gosu ====="
try_update GOSU_VERSION "$(github_latest tianon/gosu)"

echo ""
if [ "$CHANGED" = "1" ]; then
    echo "检测到版本更新:"
    echo -e "$SUMMARY"
else
    echo "所有版本均为最新, 无需更新"
fi

# 写入 GitHub Actions 环境(本地执行时跳过)
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "CHANGED=${CHANGED}"
        echo "SUMMARY<<EOF"
        echo -e "$SUMMARY"
        echo "EOF"
        echo "MYSQL_VERSION=$(arg_value MYSQL_VERSION)"
    } >> "$GITHUB_ENV"
fi
