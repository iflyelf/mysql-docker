#!/bin/bash
set -eo pipefail
shopt -s nullglob

# logging functions
mysql_log() {
	local type="$1"; shift
	# accept argument string or stdin
	local text="$*"; if [ "$#" -eq 0 ]; then text="$(cat)"; fi
	local dt; dt="$(date --rfc-3339=seconds)"
	printf '%s [%s] [Entrypoint]: %s\n' "$dt" "$type" "$text"
}
mysql_note() {
	mysql_log Note "$@"
}
mysql_warn() {
	mysql_log Warn "$@" >&2
}
mysql_error() {
	mysql_log ERROR "$@" >&2
	exit 1
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		mysql_error "Both $var and $fileVar are set (but are exclusive)"
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# check to see if this file is being run or sourced from another script
_is_sourced() {
	# https://unix.stackexchange.com/a/215279
	[ "${#FUNCNAME[@]}" -ge 2 ] \
		&& [ "${FUNCNAME[0]}" = '_is_sourced' ] \
		&& [ "${FUNCNAME[1]}" = 'source' ]
}

# usage: docker_process_init_files [file [file [...]]]
#    ie: docker_process_init_files /always-initdb.d/*
# process initializer files, based on file extensions
docker_process_init_files() {
	# mysql here for backwards compatibility "${mysql[@]}"
	mysql=( docker_process_sql )

	echo
	local f
	for f; do
		case "$f" in
			*.sh)
				# https://github.com/docker-library/postgres/issues/450#issuecomment-393167936
				# https://github.com/docker-library/postgres/pull/452
				if [ -x "$f" ]; then
					mysql_note "$0: running $f"
					"$f"
				else
					mysql_note "$0: sourcing $f"
					. "$f"
				fi
				;;
			*.sql)    mysql_note "$0: running $f"; docker_process_sql < "$f"; echo ;;
			*.sql.gz) mysql_note "$0: running $f"; gunzip -c "$f" | docker_process_sql; echo ;;
			*.sql.xz) mysql_note "$0: running $f"; xzcat "$f" | docker_process_sql; echo ;;
			*)        mysql_warn "$0: ignoring $f" ;;
		esac
		echo
	done
}

# arguments necessary to run "mysqld --verbose --help" successfully (used for testing configuration validity and for extracting default/configured values)
_verboseHelpArgs=(
	--verbose --help
	--log-bin-index="$(mktemp -u)" # https://github.com/docker-library/mysql/issues/136
)

mysql_check_config() {
	local toRun=( "$@" "${_verboseHelpArgs[@]}" ) errors
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		mysql_error $'mysqld failed while attempting to check config\n\tcommand was: '"${toRun[*]}"$'\n\t'"$errors"
	fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
mysql_get_config() {
	local conf="$1"; shift
	"$@" "${_verboseHelpArgs[@]}" 2>/dev/null \
		| awk -v conf="$conf" '$1 == conf && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
	# match "datadir      /some/path with/spaces in/it here" but not "--xyz=abc\n     datadir (xyz)"
}

# Ensure that the package default socket can also be used
# since rpm packages are compiled with a different socket location
# and "mysqlsh --mysql" doesn't read the [client] config
# related to https://github.com/docker-library/mysql/issues/829
mysql_socket_fix() {
	local defaultSocket
	defaultSocket="$(mysql_get_config 'socket' mysqld --no-defaults)"
	if [ "$defaultSocket" != "$SOCKET" ]; then
		ln -sfTv "$SOCKET" "$defaultSocket" || :
	fi
}

# Do a temporary startup of the MySQL server, for init purposes
docker_temp_server_start() {
	if [ "${MYSQL_MAJOR}" = '5.7' ]; then
		"$@" --skip-networking --default-time-zone=SYSTEM --socket="${SOCKET}" &
		mysql_note "Waiting for server startup"
		local i
		for i in {30..0}; do
			# only use the root password if the database has already been initialized
			# so that it won't try to fill in a password file when it hasn't been set yet
			extraArgs=()
			if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
				extraArgs+=( '--dont-use-mysql-root-password' )
			fi
			if docker_process_sql "${extraArgs[@]}" --database=mysql <<<'SELECT 1' &> /dev/null; then
				break
			fi
			sleep 1
		done
		if [ "$i" = 0 ]; then
			mysql_error "Unable to start server."
		fi
	else
		# For 5.7+ the server is ready for use as soon as startup command unblocks
		# 初始化/临时启动阶段必须关闭 MGR 自动入组, 否则空实例会尝试加入已有集群
		if ! "$@" --daemonize --skip-networking --default-time-zone=SYSTEM --socket="${SOCKET}" \
			--loose-group_replication_start_on_boot=OFF; then
			mysql_error "Unable to start server."
		fi
	fi
}

# Stop the server. When using a local socket file mysqladmin will block until
# the shutdown is complete.
docker_temp_server_stop() {
	if ! mysqladmin --defaults-extra-file=<( _mysql_passfile ) shutdown -uroot --socket="${SOCKET}"; then
		mysql_error "Unable to shut down server."
	fi
}

# Verify that the minimally required password settings are set for new databases.
docker_verify_minimum_env() {
	if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" -a -z "$MYSQL_REPL_PASSWORD" ]; then
		mysql_error <<-'EOF'
			Database is uninitialized and password option is not specified
			    You need to specify one of the following:
			    - MYSQL_ROOT_PASSWORD
			    - MYSQL_ALLOW_EMPTY_PASSWORD
			    - MYSQL_RANDOM_ROOT_PASSWORD
		            - MYSQL_REPL_PASSWORD
		EOF
	fi

	# This will prevent the CREATE USER from failing (and thus exiting with a half-initialized database)
	if [ "$MYSQL_USER" = 'root' ]; then
		mysql_error <<-'EOF'
			MYSQL_USER="root", MYSQL_USER and MYSQL_PASSWORD are for configuring a regular user and cannot be used for the root user
			    Remove MYSQL_USER="root" and use one of the following to control the root user password:
			    - MYSQL_ROOT_PASSWORD
			    - MYSQL_ALLOW_EMPTY_PASSWORD
			    - MYSQL_RANDOM_ROOT_PASSWORD
		EOF
	fi

	# warn when missing one of MYSQL_USER or MYSQL_PASSWORD
	if [ -n "$MYSQL_USER" ] && [ -z "$MYSQL_PASSWORD" ]; then
		mysql_warn 'MYSQL_USER specified, but missing MYSQL_PASSWORD; MYSQL_USER will not be created'
	elif [ -z "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
		mysql_warn 'MYSQL_PASSWORD specified, but missing MYSQL_USER; MYSQL_PASSWORD will be ignored'
	fi
}

# creates folders for the database
# also ensures permission for user mysql of run as root
docker_create_db_directories() {
	local user; user="$(id -u)"

	# TODO other directories that are used by default? like /var/lib/mysql-files
	# see https://github.com/docker-library/mysql/issues/562
	mkdir -p "$DATADIR"
	
	if [ "$user" = "0" ]; then
		# this will cause less disk access than `chown -R`
		find "$DATADIR" \! -user mysql -exec chown mysql '{}' +
	fi
}

# initializes the database directory
docker_init_database_dir() {
	mysql_note "Initializing database files"
	"$@" --initialize-insecure --user=mysql --default-time-zone=SYSTEM
	mysql_note "Database files initialized"
}

# Loads various settings that are used elsewhere in the script
# This should be called after mysql_check_config, but before any other functions
docker_setup_env() {
	# Get config
	declare -g DATADIR SOCKET
	DATADIR="$(mysql_get_config 'datadir' "$@")"
	SOCKET="$(mysql_get_config 'socket' "$@")"

	# Initialize values that might be stored in a file
	file_env 'MYSQL_ROOT_HOST' '%'
	file_env 'MYSQL_DATABASE'
	file_env 'MYSQL_USER'
	file_env 'MYSQL_PASSWORD'
	file_env 'MYSQL_ROOT_PASSWORD'
	file_env 'MYSQL_REPL_USER' 'repl'
	file_env 'MYSQL_REPL_PASSWORD'

	declare -g DATABASE_ALREADY_EXISTS
	if [ -d "$DATADIR/mysql" ]; then
		DATABASE_ALREADY_EXISTS='true'
	fi
}

# MGR 相关环境变量说明:
#   MYSQL_MGR_GROUP_SEEDS  组内各成员的通信地址列表(host:33061,...)，设置后才启用 MGR
#   MYSQL_MGR_LOCAL_ADDRESS 本节点通信地址(默认 <hostname>:33061)
#   MYSQL_SERVER_ID        本节点 server_id(集群内唯一, 默认 1)
#   MYSQL_MGR_GROUP_NAME   组名(UUID, 集群内一致)
#   MYSQL_MGR_BOOTSTRAP    1 = 首次初始化时引导新组(仅首个节点首次启动使用)
#   MYSQL_MGR_SINGLE_PRIMARY  ON/OFF，默认 ON(单主)
# 根据环境变量生成 MGR 动态配置(必须早于配置检查执行)
# 说明: 只有 root 身份才生成(容器默认以 root 进入入口脚本, 初始化完成后才 gosu 降权),
#       避免降权后重复执行把 bootstrap 参数覆盖掉。
docker_mgr_generate_config() {
	[ -n "${MYSQL_MGR_GROUP_SEEDS:-}" ] || return 0
	[ "$(id -u)" = "0" ] || return 0

	local confDir='/etc/mysql/conf.d'
	local confFile="${confDir}/zz-mgr-auto.cnf"
	if [ ! -w "$confDir" ]; then
		mysql_warn "配置目录不可写, 跳过 MGR 动态配置生成: $confDir"
		return 0
	fi

	local serverId="${MYSQL_SERVER_ID:-1}"
	local localAddr="${MYSQL_MGR_LOCAL_ADDRESS:-$(hostname):33061}"
	local groupName="${MYSQL_MGR_GROUP_NAME:-d9b5b0c4-8f1e-11f0-9a52-0242ac110002}"
	local singlePrimary="${MYSQL_MGR_SINGLE_PRIMARY:-ON}"
	local dataDir="${MYSQL_DATA:-/var/lib/mysql}"
	local bootstrap='OFF'

	# 仅新数据目录的首次启动允许引导:
	#   引导标记写在数据目录中, 引导成功后重启不会再引导, 避免脑裂
	if [ "${MYSQL_MGR_BOOTSTRAP:-0}" = "1" ] && [ ! -f "${dataDir}/.mgr_bootstrapped" ]; then
		bootstrap='ON'
		# 先落标记: 保证"引导只发生一次"; 若引导过程异常, 删除该文件后重启可重试
		touch "${dataDir}/.mgr_bootstrapped"
		mysql_note "MGR: 首次启动, 本次将引导新组(bootstrap=ON)"
	fi

	cat > "$confFile" <<-EOF
		# 由 docker-entrypoint.sh 根据环境变量自动生成, 请勿手工修改
		[mysqld]
		server_id = ${serverId}
		loose_group_replication_start_on_boot = ON
		loose_group_replication_bootstrap_group = ${bootstrap}
		loose_group_replication_group_name = '${groupName}'
		loose_group_replication_local_address = '${localAddr}'
		loose_group_replication_group_seeds = '${MYSQL_MGR_GROUP_SEEDS}'
		loose_group_replication_single_primary_mode = ${singlePrimary}
	EOF
	chmod 644 "$confFile"
	mysql_note "MGR 配置已生成: server_id=${serverId} local_address=${localAddr} bootstrap=${bootstrap} seeds=${MYSQL_MGR_GROUP_SEEDS}"
}

# 初始化结束后清空本机 GTID: 导入时区表/初始化脚本会写入本机 server_uuid 的 GTID,
# 这些事务不在组内, 加入 MGR 时会被拒绝("This member has more executed transactions than
# those present in the group"), 因此在首次初始化完成后统一清空(此时尚未复制任何数据)。
docker_mgr_reset_gtid() {
	[ -n "${MYSQL_MGR_GROUP_SEEDS:-}" ] || return 0
	mysql_note "MGR: 清空初始化阶段产生的 GTID (RESET BINARY LOGS AND GTIDS)"
	docker_process_sql --database=mysql <<<"RESET BINARY LOGS AND GTIDS;" \
		|| mysql_warn "MGR: 清空 GTID 失败, 该节点加入集群时可能被拒绝"
}

# 等待组内任意一个同伴的 33061 端口可达后再启动, 解决"节点同时启动但引导节点尚未就绪"的问题
# (MGR 在启动时若无法联系到任何同伴, 会停在 OFFLINE, 需要重启才能重新加入)
docker_mgr_wait_for_seeds() {
	[ -n "${MYSQL_MGR_GROUP_SEEDS:-}" ] || return 0
	[ "${MYSQL_MGR_BOOTSTRAP:-0}" = "1" ] && return 0

	local timeout="${MYSQL_MGR_WAIT_TIMEOUT:-180}"
	local localAddr="${MYSQL_MGR_LOCAL_ADDRESS:-$(hostname):33061}"
	local waited=0 addr host port seed
	local seeds=()

	IFS=',' read -r -a seeds <<< "${MYSQL_MGR_GROUP_SEEDS}"
	mysql_note "MGR: 等待组内同伴就绪(最多 ${timeout}s): ${MYSQL_MGR_GROUP_SEEDS}"
	while [ "$waited" -lt "$timeout" ]; do
		for seed in "${seeds[@]}"; do
			addr="${seed//[[:space:]]/}"
			[ -n "$addr" ] || continue
			[ "$addr" = "$localAddr" ] && continue
			host="${addr%:*}"
			port="${addr##*:}"
			if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
				mysql_note "MGR: 同伴 ${addr} 已可达, 继续启动"
				return 0
			fi
		done
		sleep 5
		waited=$((waited + 5))
		if [ $((waited % 30)) -eq 0 ]; then
			mysql_note "MGR: 仍在等待同伴 (${waited}/${timeout}s)"
		fi
	done
	mysql_warn "MGR: 等待同伴超时(${timeout}s), 继续启动; 节点可能暂时 OFFLINE, 待同伴恢复后重启本节点即可重新加入"
	return 0
}

# 配置 MGR 分布式恢复(组复制)通道账号，需要在临时服务器中执行一次并持久化
docker_mgr_setup_recovery() {
	[ -n "${MYSQL_MGR_GROUP_SEEDS:-}" ] || return 0
	if [ -z "${MYSQL_REPL_PASSWORD:-}" ]; then
		mysql_warn "未设置 MYSQL_REPL_PASSWORD, MGR 分布式恢复可能失败"
		return 0
	fi
	mysql_note "MGR: 配置分布式恢复通道 (${MYSQL_REPL_USER:-repl})"
	docker_process_sql --database=mysql <<-EOSQL
		SET @@SESSION.SQL_LOG_BIN=0;
		CHANGE REPLICATION SOURCE TO
			SOURCE_USER = '${MYSQL_REPL_USER:-repl}',
			SOURCE_PASSWORD = '${MYSQL_REPL_PASSWORD}'
			FOR CHANNEL 'group_replication_recovery';
	EOSQL
}

# Execute sql script, passed via stdin
# usage: docker_process_sql [--dont-use-mysql-root-password] [mysql-cli-args]
#    ie: docker_process_sql --database=mydb <<<'INSERT ...'
#    ie: docker_process_sql --dont-use-mysql-root-password --database=mydb <my-file.sql
docker_process_sql() {
	passfileArgs=()
	if [ '--dont-use-mysql-root-password' = "$1" ]; then
		passfileArgs+=( "$1" )
		shift
	fi
	# args sent in can override this db, since they will be later in the command
	if [ -n "$MYSQL_DATABASE" ]; then
		set -- --database="$MYSQL_DATABASE" "$@"
	fi

	mysql --defaults-extra-file=<( _mysql_passfile "${passfileArgs[@]}") --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" --comments "$@"
}

# Initializes database with timezone info and root password, plus optional extra db/user
docker_setup_db() {
	# Load timezone info into database
	if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
		# sed is for https://bugs.mysql.com/bug.php?id=20545
		mysql_tzinfo_to_sql /usr/share/zoneinfo \
			| sed 's/Local time zone must be set--see zic manual page/FCTY/' \
			| docker_process_sql --dont-use-mysql-root-password --database=mysql
			# tell docker_process_sql to not use MYSQL_ROOT_PASSWORD since it is not set yet
	fi
	# Generate random root password
	if [ -n "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
		MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24)"; export MYSQL_ROOT_PASSWORD
		mysql_note "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
	fi
	# Sets root password and creates root users for non-localhost hosts
	local rootCreate=
	# default root to listen for connections from anywhere
	if [ -n "$MYSQL_ROOT_HOST" ] && [ "$MYSQL_ROOT_HOST" != 'localhost' ]; then
		# no, we don't care if read finds a terminating character in this heredoc
		# https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
		read -r -d '' rootCreate <<-EOSQL || true
			CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
		EOSQL
	fi
	
	local replCreate=
	if [ -n "$MYSQL_REPL_PASSWORD" ]; then
		# MySQL 8.4 起 mysql_native_password 默认禁用, 统一使用默认的 caching_sha2_password;
		# MGR 分布式恢复通过 group_replication_recovery_get_public_key=ON + 该账号完成认证。
		read -r -d '' replCreate <<-EOSQL || true
			CREATE USER '${MYSQL_REPL_USER:-repl}'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}' ;
			GRANT REPLICATION SLAVE, REPLICATION CLIENT, BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, CONNECTION_ADMIN ON *.* TO '${MYSQL_REPL_USER:-repl}'@'%' ;
			GRANT SELECT ON performance_schema.log_status TO '${MYSQL_REPL_USER:-repl}'@'%' ;
			GRANT SELECT ON performance_schema.keyring_component_status TO '${MYSQL_REPL_USER:-repl}'@'%' ;
		EOSQL
	fi

	local passwordSet=
	# no, we don't care if read finds a terminating character in this heredoc (see above)
	read -r -d '' passwordSet <<-EOSQL || true
		ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
	EOSQL

	# tell docker_process_sql to not use MYSQL_ROOT_PASSWORD since it is just now being set
	docker_process_sql --dont-use-mysql-root-password --database=mysql <<-EOSQL
		-- What's done in this file shouldn't be replicated
		--  or products like mysql-fabric won't work
		SET @@SESSION.SQL_LOG_BIN=0;

		${passwordSet}
		GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
		FLUSH PRIVILEGES ;
		${rootCreate}
		${replCreate}
		DROP DATABASE IF EXISTS test ;
	EOSQL

	# Creates a custom database and user if specified
	if [ -n "$MYSQL_DATABASE" ]; then
		mysql_note "Creating database ${MYSQL_DATABASE}"
		docker_process_sql --database=mysql <<<"CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;"
	fi

	if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
		mysql_note "Creating user ${MYSQL_USER}"
		docker_process_sql --database=mysql <<<"CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;"

		if [ -n "$MYSQL_DATABASE" ]; then
			mysql_note "Giving user ${MYSQL_USER} access to schema ${MYSQL_DATABASE}"
			docker_process_sql --database=mysql <<<"GRANT ALL ON \`${MYSQL_DATABASE//_/\\_}\`.* TO '$MYSQL_USER'@'%' ;"
		fi
	fi
}

_mysql_passfile() {
	# echo the password to the "file" the client uses
	# the client command will use process substitution to create a file on the fly
	# ie: --defaults-extra-file=<( _mysql_passfile )
	if [ '--dont-use-mysql-root-password' != "$1" ] && [ -n "$MYSQL_ROOT_PASSWORD" ]; then
		cat <<-EOF
			[client]
			password="${MYSQL_ROOT_PASSWORD}"
		EOF
	fi
}

# Mark root user as expired so the password must be changed before anything
# else can be done (only supported for 5.6+)
mysql_expire_root_user() {
	if [ -n "$MYSQL_ONETIME_PASSWORD" ]; then
		docker_process_sql --database=mysql <<-EOSQL
			ALTER USER 'root'@'%' PASSWORD EXPIRE;
		EOSQL
	fi
}

# check arguments for an option that would cause mysqld to stop
# return true if there is one
_mysql_want_help() {
	local arg
	for arg; do
		case "$arg" in
			-'?'|--help|--print-defaults|-V|--version)
				return 0
				;;
		esac
	done
	return 1
}

_main() {
	# if command starts with an option, prepend mysqld
	if [ "${1:0:1}" = '-' ]; then
		set -- mysqld "$@"
	fi

	# skip setup if they aren't running mysqld or want an option that stops mysqld
	if [ "$1" = 'mysqld' ] && ! _mysql_want_help "$@"; then
		mysql_note "Entrypoint script for MySQL Server ${MYSQL_VERSION} started."

		# 生成 MGR 动态配置(必须在配置检查之前)
		docker_mgr_generate_config
		mysql_check_config "$@"
		# Load various environment variables
		docker_setup_env "$@"
		docker_create_db_directories

		# If container is started as root user, restart as dedicated mysql user
		if [ "$(id -u)" = "0" ]; then
			mysql_note "Switching to dedicated user 'mysql'"
			exec gosu mysql "$BASH_SOURCE" "$@"
		fi

		# there's no database, so it needs to be initialized
		if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
			docker_verify_minimum_env

			# check dir permissions to reduce likelihood of half-initialized database
			ls /docker-entrypoint-initdb.d/ > /dev/null

			docker_init_database_dir "$@"

			mysql_note "Starting temporary server"
			docker_temp_server_start "$@"
			mysql_note "Temporary server started."

			mysql_socket_fix
			docker_setup_db
			# 配置 MGR 分布式恢复通道(仅启用 MGR 时)
			docker_mgr_setup_recovery
			docker_process_init_files /docker-entrypoint-initdb.d/*

			mysql_expire_root_user

			# MGR: 清空初始化产生的 GTID, 否则新成员无法加入已有集群
			docker_mgr_reset_gtid

			mysql_note "Stopping temporary server"
			docker_temp_server_stop
			mysql_note "Temporary server stopped"

			echo
			mysql_note "MySQL init process done. Ready for start up."
			echo
		else
			mysql_socket_fix
		fi

		# 等待组内同伴就绪(引导节点立即启动; 其他节点避免因同伴未就绪而停在 OFFLINE)
		docker_mgr_wait_for_seeds
	fi
	exec "$@"
}

# If we are sourced from elsewhere, don't perform any further actions
if ! _is_sourced; then
	_main "$@"
fi
