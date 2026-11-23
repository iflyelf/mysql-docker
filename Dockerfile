#############################################################################
#  iflyelf/mysql (Percona Server for MySQL 8.4 LTS) 多阶段构建
#  - builder(构建阶段) = iflyelf/ubuntu:latest
#      只做"下载官方 deb + 解包 + 裁剪", 不重装庞大工具链, 构建更快更稳。
#  - runtime(运行阶段) = iflyelf/ubuntu:lite
#      仅拷贝 mysqld / 客户端 / 插件 / 字符集 + 安装运行所需的共享库, 镜像更小。
#
#  说明: Percona 官方 deb 的发行版代号必须与运行基础镜像一致,
#        iflyelf/ubuntu:lite 当前为 Ubuntu 26.04 (resolute), 故 PERCONA_DISTRO=resolute。
#        若基础镜像切换到 noble(24.04)/jammy(22.04), 需同步修改 PERCONA_DISTRO。
#############################################################################

# ========================= 全局版本变量(两个阶段共享) =========================
# MySQL 系列: 8.4 为 Percona LTS
ARG MYSQL_SERIES=8.4
# 完整版本号(不含 deb 的 -1.<distro> 后缀), 由 scripts/update-version.sh 自动跟进
ARG MYSQL_VERSION=8.4.11-12
# Percona 官方仓库发行版代号(见文件头说明)
ARG PERCONA_DISTRO=resolute
# gosu 版本(用于从 root 降权到 mysql 用户) https://github.com/tianon/gosu
ARG GOSU_VERSION=1.20
# 可选下载代理(国内构建可设为 https://down.xiaonuo.live, 用法: ?url=<原始地址>)
ARG DOWNLOAD_PROXY=

ARG DOWNLOAD_SRC=/tmp/src


####################################################################
#                     构建阶段 (builder)                            #
####################################################################
FROM iflyelf/ubuntu:latest AS builder

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf"

# buildx 自动注入的目标架构
ARG TARGETARCH

# 继承全局版本变量
ARG MYSQL_SERIES
ARG MYSQL_VERSION
ARG PERCONA_DISTRO
ARG GOSU_VERSION
ARG DOWNLOAD_PROXY
ARG DOWNLOAD_SRC

ENV DEBIAN_FRONTEND=noninteractive \
    MYSQL_VERSION=$MYSQL_VERSION \
    DOWNLOAD_SRC=$DOWNLOAD_SRC

# ***** 下载 Percona 官方 deb + gosu *****
# 直接按 URL 下载(带断点续传/重试), 可用 DOWNLOAD_PROXY 走代理加速
RUN set -eux; \
    mkdir -p "${DOWNLOAD_SRC}/deb" "${DOWNLOAD_SRC}/rootfs"; \
    fetch() { \
        if [ -n "${DOWNLOAD_PROXY}" ]; then \
            wget -q -c --tries=10 --timeout=60 -O "$2" "${DOWNLOAD_PROXY}?url=$1" \
                || wget -q -c --tries=10 --timeout=60 -O "$2" "$1"; \
        else \
            wget -q -c --tries=10 --timeout=60 -O "$2" "$1"; \
        fi; \
    }; \
    # 注意: /bin/sh(dash) 不支持 ${var//x/y}; 仓库代号规则为去掉小数点(8.4 => 84)
    repoSeries="$(echo "${MYSQL_SERIES}" | tr -d '.')"; \
    repoBase="https://repo.percona.com/ps-${repoSeries}-lts/apt/pool/main/p/percona-server"; \
    for pkg in common client server; do \
        debName="percona-server-${pkg}_${MYSQL_VERSION}-1.${PERCONA_DISTRO}_${TARGETARCH}.deb"; \
        echo "==> 下载 ${debName}"; \
        fetch "${repoBase}/${debName}" "${DOWNLOAD_SRC}/deb/${debName}"; \
    done; \
    echo "==> 下载 gosu-${GOSU_VERSION}-${TARGETARCH}"; \
    fetch "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${TARGETARCH}" "${DOWNLOAD_SRC}/gosu"; \
    chmod +x "${DOWNLOAD_SRC}/gosu"; \
    "${DOWNLOAD_SRC}/gosu" --version || true

# ***** 解包(不执行 maintainer 脚本, 避免二次初始化/启动服务) *****
RUN set -eux; \
    for f in "${DOWNLOAD_SRC}"/deb/*.deb; do \
        echo "==> 解包 $(basename "$f")"; \
        dpkg-deb -x "$f" "${DOWNLOAD_SRC}/rootfs"; \
    done

# ***** 裁剪: 去掉调试版二进制/测试插件/文档/系统集成文件 *****
RUN set -eux; \
    R="${DOWNLOAD_SRC}/rootfs"; \
    rm -rf \
        "$R/usr/sbin/mysqld-debug" \
        "$R/usr/lib/mysql/plugin/debug" \
        "$R/usr/lib/mysql/plugin/test_udf_wrappers.so" \
        "$R/usr/lib/mysql/plugin"/component_test_*.so \
        "$R/usr/share/doc" \
        "$R/usr/share/man" \
        "$R/usr/share/lintian" \
        "$R/usr/include" \
        "$R/usr/lib/systemd" \
        "$R/usr/lib/tmpfiles.d" \
        "$R/etc"; \
    # 确认核心文件存在, 否则构建失败(避免基础镜像变更导致产物残缺)
    for f in usr/sbin/mysqld usr/bin/mysql usr/bin/mysqladmin usr/bin/mysqldump \
             usr/bin/mysql_tzinfo_to_sql usr/bin/mysqlbinlog \
             usr/lib/mysql/plugin/group_replication.so usr/lib/mysql/plugin/mysql_clone.so; do \
        [ -f "$R/$f" ] || { echo "ERROR: 缺少文件 $f" >&2; exit 1; }; \
    done; \
    du -sh "$R/usr/sbin" "$R/usr/bin" "$R/usr/lib/mysql" "$R/usr/share/mysql"


####################################################################
#                     运行阶段 (runtime)                            #
####################################################################
FROM iflyelf/ubuntu:lite

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf" \
      org.opencontainers.image.description="Percona Server for MySQL 8.4 LTS (MGR ready), runtime on ubuntu:lite"

# 时区/语言(继承 lite 默认, 显式声明便于覆盖)
ARG TZ=Asia/Shanghai
ENV TZ=$TZ
ARG LANG=zh_CN.UTF-8
ENV LANG=$LANG

# 镜像变量
ARG DOCKER_IMAGE=iflyelf/mysql
ENV DOCKER_IMAGE=$DOCKER_IMAGE
ARG DOCKER_IMAGE_OS=ubuntu
ENV DOCKER_IMAGE_OS=$DOCKER_IMAGE_OS
ARG DOCKER_IMAGE_TAG=latest
ENV DOCKER_IMAGE_TAG=$DOCKER_IMAGE_TAG

# MySQL 版本变量(entrypoint 会读取 MYSQL_MAJOR / MYSQL_VERSION)
ARG MYSQL_SERIES
ARG MYSQL_VERSION
ARG GOSU_VERSION
ENV MYSQL_MAJOR=$MYSQL_SERIES \
    MYSQL_VERSION=$MYSQL_VERSION \
    GOSU_VERSION=$GOSU_VERSION

# 自动调优开关(1=按容器 CPU/内存自动计算容量类参数; 0=关闭, 使用 my.cnf 内置默认值)
ARG MYSQL_AUTO_TUNE=1
ENV MYSQL_AUTO_TUNE=$MYSQL_AUTO_TUNE

# 数据目录 / 工作目录
ARG MYSQL_DIR=/var/lib/mysql
ENV MYSQL_DIR=$MYSQL_DIR
ARG MYSQL_DATA=/var/lib/mysql
ENV MYSQL_DATA=$MYSQL_DATA

# ***** 安装 mysqld 运行所需的共享库(非 -dev 运行库) *****
# 依据 Percona 8.4 mysqld/客户端/插件的 DT_NEEDED 精确选取:
#   libaio1t64        -> 异步 IO
#   libatomic1        -> 原子操作
#   libcurl4t64       -> 组件/通用库
#   libfido2-1        -> FIDO2 认证插件
#   libgssapi-krb5-2 / libkrb5-3 -> Kerberos 认证
#   libldap2          -> LDAP 认证
#   libmecab2         -> MeCab 全文解析器
#   libnuma1          -> NUMA
#   libpam0g          -> PAM 认证
#   libsasl2-2        -> SASL(LDAP/Kerberos)
#   libssl3t64        -> TLS
#   libstdc++6        -> C++ 运行时
#   libtinfo6         -> ncurses 终端
#   libtirpc3t64      -> RPC(NIS)
#   xz-utils          -> 入口脚本支持 .sql.xz 初始化文件
# 说明: 逐个安装(允许个别包在基础镜像升级后改名而跳过), 最终以 ldd 校验兜底。
ARG MYSQL_RUNTIME_DEPS="\
    libaio1t64 \
    libatomic1 \
    libcurl4t64 \
    libfido2-1 \
    libgssapi-krb5-2 \
    libkrb5-3 \
    libldap2 \
    libmecab2 \
    libnuma1 \
    libpam0g \
    libsasl2-2 \
    libssl3t64 \
    libstdc++6 \
    libtinfo6 \
    libtirpc3t64 \
    xz-utils"

RUN set -eux; \
    DEBIAN_FRONTEND=noninteractive apt update -qqy; \
    for pkg in $MYSQL_RUNTIME_DEPS; do \
        DEBIAN_FRONTEND=noninteractive apt install -qqy --no-install-recommends \
            "$pkg" --option=Dpkg::Options::=--force-confdef \
            || echo "::warning:: 运行依赖 $pkg 在当前基础镜像不可用, 已跳过(由后续 ldd 校验兜底)"; \
    done; \
    ldconfig; \
    DEBIAN_FRONTEND=noninteractive apt -qqy autoremove --purge || true; \
    DEBIAN_FRONTEND=noninteractive apt -qqy autoclean || true; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/*

# ***** 拷贝构建产物 *****
COPY --from=builder /tmp/src/rootfs/usr/sbin /usr/sbin
COPY --from=builder /tmp/src/rootfs/usr/bin /usr/bin
COPY --from=builder /tmp/src/rootfs/usr/lib/mysql /usr/lib/mysql
COPY --from=builder /tmp/src/rootfs/usr/share/mysql /usr/share/mysql
COPY --from=builder /tmp/src/gosu /usr/local/bin/gosu

# ***** 拷贝配置、入口脚本与自动调优脚本 *****
COPY ["conf/mysql/", "/etc/mysql/"]
COPY ["ps-entry.sh", "/docker-entrypoint.sh"]
COPY ["scripts/mysql-config-tuner.sh", "/usr/local/bin/mysql-config-tuner.sh"]

# ***** 初始化: 用户/目录/权限 + 自检 *****
# mysql 用户 UID/GID 固定为 1001, 与 Percona 官方镜像及 k8s 部署(runAsUser: 1001)保持一致,
# 便于宿主机目录授权与 k8s 静态 PV 复用。
RUN set -eux; \
    chmod +x /usr/local/bin/gosu /docker-entrypoint.sh /usr/local/bin/mysql-config-tuner.sh; \
    # 创建 mysql 用户/用户组(1001)
    if ! getent group mysql >/dev/null; then groupadd -r -g 1001 mysql; fi; \
    if ! getent passwd mysql >/dev/null; then \
        useradd -r -u 1001 -g mysql -d "${MYSQL_DIR}" -s /bin/bash -M mysql; \
    fi; \
    # 数据/运行/初始化目录
    mkdir -p "${MYSQL_DIR}" /var/run/mysqld /docker-entrypoint-initdb.d /var/log/mysql; \
    chown -R mysql:mysql "${MYSQL_DIR}" /var/run/mysqld /var/log/mysql; \
    chmod 755 /var/run/mysqld; \
    # 配置权限(仅 root 可写, 避免容器内进程篡改)
    chown -R root:root /etc/mysql; \
    chmod 644 /etc/mysql/my.cnf; \
    find /etc/mysql/conf.d -type f -name '*.cnf' -exec chmod 644 {} + 2>/dev/null || true; \
    # 动态库缓存 + 运行库校验(任何 "not found" 直接失败)
    ldconfig; \
    missing="$(ldd /usr/sbin/mysqld /usr/bin/mysql /usr/lib/mysql/plugin/group_replication.so /usr/lib/mysql/plugin/mysql_clone.so 2>/dev/null | awk '/not found/{print $1}' | sort -u)"; \
    if [ -n "$missing" ]; then \
        echo "ERROR: 以下共享库缺失: $missing" >&2; exit 1; \
    fi; \
    # 版本与配置自检
    mysqld --version; \
    mysql --version; \
    mysqld --defaults-file=/etc/mysql/my.cnf --validate-config --user=mysql; \
    # 自动调优脚本自检: 两种输出模式都要能跑通, 且生成的配置必须通过 mysqld 校验
    mysql-config-tuner.sh summary > /dev/null; \
    MYSQL_MEMORY_LIMIT=2Gi MYSQL_CPU_LIMIT=2 mysql-config-tuner.sh conf > /etc/mysql/conf.d/zz-auto-tuned.cnf; \
    mysqld --defaults-file=/etc/mysql/my.cnf --validate-config --user=mysql; \
    MYSQL_MEMORY_LIMIT=512Mi MYSQL_CPU_LIMIT=1 mysql-config-tuner.sh conf > /etc/mysql/conf.d/zz-auto-tuned.cnf; \
    mysqld --defaults-file=/etc/mysql/my.cnf --validate-config --user=mysql; \
    rm -f /etc/mysql/conf.d/zz-auto-tuned.cnf; \
    echo "Percona Server ${MYSQL_VERSION} 运行环境与自动调优脚本自检通过"

# ***** 容器信号处理 *****
STOPSIGNAL SIGQUIT

# ***** 监听端口 *****
# 3306: MySQL 协议 | 33060: X Protocol | 33061: MGR 组通信
EXPOSE 3306 33060 33061

# ***** 工作目录 *****
WORKDIR ${MYSQL_DIR}

# ***** 挂载目录 *****
VOLUME ${MYSQL_DATA}

# ***** 健康检查(服务存活, 不校验账号) *****
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD mysqladmin --protocol=socket --socket=/var/run/mysqld/mysqld.sock ping >/dev/null 2>&1 || exit 1

# ***** 入口(tini 处理信号/僵尸进程) *****
ENTRYPOINT ["/usr/bin/tini", "--", "/docker-entrypoint.sh"]

# ***** 执行命令 *****
CMD ["mysqld"]
