#!/usr/bin/env bash

# Notes:
# - uses iptables and -F with some tests, probably not very friendly to your firewall

cd $(dirname $0)

# set up gpdb source env
### START ###
which psql
if [ $? -ne 0 ]
then
	source /usr/local/greenplum-db-devel/greenplum_path.sh
	source ../../gpdb_src/gpAux/gpdemo/gpdemo-env.sh
fi
export PGDATA=$MASTER_DATA_DIRECTORY
# PG_PORT is gpdb master server port and PGPORT will be set us pgboucer server port
PG_PORT=${PGPORT}

if [ -d ${PGDATA} ]; then
	cp ${PGDATA}/postgresql.conf ${PGDATA}/postgresql.conf.orig
	cp ${PGDATA}/pg_hba.conf ${PGDATA}/pg_hba.conf.orig

fi

# replace port in test.ini
cp test.ini test.ini.orig
sed -i "s/PGPORT/${PG_PORT}/" test.ini
### END ###

export PGHOST=127.0.0.1
export PGPORT=6667
export EF_ALLOW_MALLOC_0=1
export LC_ALL=C
export POSIXLY_CORRECT=1

BOUNCER_LOG=test.log
BOUNCER_INI=test.ini
BOUNCER_PID=test.pid
BOUNCER_PORT=`sed -n '/^listen_port/s/listen_port.*=[^0-9]*//p' $BOUNCER_INI`
BOUNCER_EXE="$BOUNCER_EXE_PREFIX ../pgbouncer"

BOUNCER_ADMIN_HOST=/tmp

LOGDIR=log
NC_PORT=6668

# gpdb doesn't support alter system, so use the following function to reconfig it
reconf_pgsql() {
	cp ${PGDATA}/postgresql.conf.orig ${PGDATA}/postgresql.conf
	for ln in "$@"; do
		echo "$ln" >> ${PGDATA}/postgresql.conf
	done
	gpstop  -u
}

# not used
pgctl() {
	pg_ctl -w -o "-p $PG_PORT" -D $PGDATA $@ >>$PG_LOG 2>&1
}

ulimit -c unlimited

which initdb > /dev/null || {
	echo "initdb not found, need postgres tools in PATH"
	exit 1
}

# The tests require that psql can connect to the PgBouncer admin
# console.  On platforms that have getpeereid(), this works by
# connecting as user pgbouncer over the Unix socket.  On other
# platforms, we have to rely on "trust" authentication, but then we
# have to skip any tests that use authentication methods other than
# "trust".
case `uname` in
	MINGW*)
		have_getpeereid=false
		use_unix_sockets=false
		;;
	*)
		have_getpeereid=true
		use_unix_sockets=true
		;;
esac

# System configuration checks
SED_ERE_OP='-E'
case `uname` in
Linux)
	SED_ERE_OP='-r'
	;;
esac

case `uname` in
MINGW*)
	createdb() { createdb.exe "$@"; }
	initdb() { initdb.exe "$@"; }
	psql() { psql.exe "$@"; }
	;;
esac

pg_majorversion=$(initdb --version | sed -n $SED_ERE_OP 's/.* ([0-9]+).*/\1/p')
if test $pg_majorversion -ge 10; then
	pg_supports_scram=true
else
	pg_supports_scram=false
fi

if ! $use_unix_sockets; then
	BOUNCER_ADMIN_HOST=/tmp

	cp test.ini test.ini.bak
	sed -i 's/^unix_socket_dir =/#&/' test.ini
	echo 'admin_users = pgbouncer' >> test.ini
fi

MAX_PASSWORD=$(sed -n $SED_ERE_OP 's/#define MAX_PASSWORD[[:space:]]+([0-9]+)/\1/p' ../include/bouncer.h)
long_password=$(printf '%*s' $(($MAX_PASSWORD - 1)) | tr ' ' 'a')

# System configuration checks
if ! grep -q "^\"${USER:=$(id -un)}\"" userlist.txt; then
	cp userlist.txt userlist.txt.bak
	echo "\"${USER}\" \"01234\"" >> userlist.txt
	echo "\"longpass\" \"${long_password}\"" >> userlist.txt
	echo "\"ldapuser1\" \"123456\"" >> userlist.txt
fi

if test -n "$USE_SUDO"; then
	case `uname` in
	OpenBSD)
		sudo pfctl -a pgbouncer -F all -q 2>&1 | grep -q "pfctl:" && {
			cat <<-EOF
			Please enable PF and add the following rule to /etc/pf.conf
			
			  anchor "pgbouncer/*"
			
			EOF
			exit 1
		}
		;;
	esac
fi

stopit() {
	local pid
	if test -f "$1"; then
		pid=`head -n1 "$1"`
		kill $pid
		while kill -0 $pid 2>/dev/null; do sleep 0.1; done
		rm -f "$1"
	fi
}

stopit test.pid

mkdir -p $LOGDIR
rm -f $BOUNCER_LOG
# suppose gpdb has been started

if $use_unix_sockets; then
	sed $SED_ERE_OP -i "/unix_socket_director/s:.*(unix_socket_director.*=).*:\\1 '/tmp':" ${PGDATA}/postgresql.conf
fi
cat >>${PGDATA}/postgresql.conf <<-EOF
log_connections = on
EOF
if $pg_supports_scram; then
	cat >${PGDATA}/pg_hba.conf <<-EOF
	local  p6   all                scram-sha-256
	host   p6   all  127.0.0.1/32  scram-sha-256
	host   p6   all  ::1/128       scram-sha-256
	EOF
else
	cat >${PGDATA}/pg_hba.conf </dev/null
fi
cat >>${PGDATA}/pg_hba.conf <<-EOF
local  p4   all                password
host   p4   all  127.0.0.1/32  password
host   p4   all  ::1/128       password
local  p5   all                md5
host   p5   all  127.0.0.1/32  md5
host   p5   all  ::1/128       md5
local  all  all                trust
host   all  all  127.0.0.1/32  trust
host   all  all  ::1/128       trust
EOF
gpstop -u
if ! $use_unix_sockets; then
	sed -i 's/^local/#local/' pgdata/pg_hba.conf
fi

echo "Creating databases"
psql -X -p $PG_PORT -l | grep p0 > /dev/null || {
	psql -X -o /dev/null -p $PG_PORT -c "create user bouncer" template1 || exit 1
	for dbname in p0 p1 p3 p4 p5 p6 p7; do
		createdb -p $PG_PORT $dbname || exit 1
	done
}

psql -X -p $PG_PORT -d p0 -c "select * from pg_user" | grep pswcheck > /dev/null || {
	echo "Creating users"
	psql -X -o /dev/null -p $PG_PORT -c "create user pswcheck with superuser createdb password 'pgbouncer-check';" p0 || exit 1
	psql -X -o /dev/null -p $PG_PORT -c "create user someuser with password 'anypasswd';" p0 || exit 1
	psql -X -o /dev/null -p $PG_PORT -c "create user maxedout;" p0 || exit 1
	psql -X -o /dev/null -p $PG_PORT -c "create user longpass with password '$long_password';" p0 || exit 1
	psql -X -o /dev/null -p $PG_PORT -c "create user ldapuser1" p0 || exit 1
	if $pg_supports_scram; then
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = 'md5'; create user muser1 password 'foo';" p0 || exit 1
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = 'md5'; create user muser2 password 'wrong';" p0 || exit 1
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = 'md5'; create user puser1 password 'foo';" p0 || exit 1
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = 'md5'; create user puser2 password 'wrong';" p0 || exit 1
		# match SCRAM secret in userlist.txt
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = 'scram-sha-256'; create user scramuser1 password '"'SCRAM-SHA-256$4096:D76gvGUVj9Z4DNiGoabOBg==$RukL0Xo3Ql/2F9FsD7mcQ3GATG2fD3PA71qY1JagGDs=:BhKUwyyivFm7Tq2jDJVXSVRbRDgTWyBilZKgg6DDuYU='"';" p0 || exit 1
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = 'scram-sha-256'; create user scramuser3 password 'baz';" p0 || exit 1
	else
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = on; create user muser1 password 'foo';" p0 || exit 1
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = on; create user muser2 password 'wrong';" p0 || exit 1
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = on; create user puser1 password 'foo';" p0 || exit 1
		psql -X -o /dev/null -p $PG_PORT -c "set password_encryption = on; create user puser2 password 'wrong';" p0 || exit 1
	fi
}

#
#  fw hacks
#

fw_enable() {
	case `uname` in
	Darwin)
		fw_token=$(sudo pfctl -E 2>&1 | grep '^Token' | cut -d ' ' -f 3);;
	esac
}

fw_disable() {
	case `uname` in
	Darwin)
		sudo pfctl -X "$fw_token";;
	esac
}

fw_drop_port() {
	fw_enable
	case `uname` in
	Linux)
		sudo iptables -A OUTPUT -p tcp --dport $1 -j DROP;;
	Darwin)
		echo "block drop out proto tcp from any to 127.0.0.1 port $1" \
		    | sudo pfctl -f -;;
	OpenBSD)
		echo "block drop out proto tcp from any to 127.0.0.1 port $1" \
		    | sudo pfctl -a pgbouncer -f -;;
	*)
		echo "Unknown OS"; exit 1;;
	esac
}
fw_reject_port() {
	fw_enable
	case `uname` in
	Linux)
		sudo iptables -A OUTPUT -p tcp --dport $1 -j REJECT --reject-with tcp-reset;;
	Darwin)
		echo "block return-rst out proto tcp from any to 127.0.0.1 port $1" \
		    | sudo pfctl -f -;;
	OpenBSD)
		echo "block return-rst out proto tcp from any to 127.0.0.1 port $1" \
		    | sudo pfctl -a pgbouncer -f -;;
	*)
		echo "Unknown OS"; exit 1;;
	esac
}

fw_reset() {
	fw_disable
	case `uname` in
	Linux)
		sudo iptables -F OUTPUT;;
	Darwin)
		sudo pfctl -F all;;
	OpenBSD)
		sudo pfctl -a pgbouncer -F all;;
	*)
		echo "Unknown OS"; exit 1;;
	esac
}

#
# util functions
#

complete() {
	test -f $BOUNCER_PID && kill `cat $BOUNCER_PID` >/dev/null 2>&1
	rm -f $BOUNCER_PID
	test -e test.ini.bak && mv test.ini.bak test.ini
	test -e userlist.txt.bak && mv userlist.txt.bak userlist.txt
	cp ${PGDATA}/postgresql.conf.orig ${PGDATA}/postgresql.conf
	cp ${PGDATA}/pg_hba.conf.orig ${PGDATA}/pg_hba.conf
	rm test.ini
	mv test.ini.orig test.ini
}

die() {
	echo $@
	complete
	exit 1
}

admin() {
	psql -X -h $BOUNCER_ADMIN_HOST -U pgbouncer -d pgbouncer -c "$@;" || die "Cannot contact bouncer!"
}

runtest() {
	local status

	case `uname` in
	MINGW*)
		(nohup $BOUNCER_EXE $BOUNCER_INI </dev/null >/dev/null 2>&1 &)
		;;
	*)
		$BOUNCER_EXE -d $BOUNCER_INI
		;;
	esac
	until psql -X -h $BOUNCER_ADMIN_HOST -U pgbouncer -d pgbouncer -c "show version" 2>/dev/null 1>&2; do sleep 0.1; done

	printf "`date` running $1 ... "
	eval $1 >$LOGDIR/$1.out 2>&1
	status=$?

	# Detect fatal errors from PgBouncer (which are internal
	# errors), but not those from PostgreSQL (which could be
	# normal, such as authentication failures)
	if grep 'FATAL @' $BOUNCER_LOG >> $LOGDIR/$1.out; then
		status=1
	fi

	if [ $status -eq 0 ]; then
		echo "ok"
	elif [ $status -eq 77 ]; then
		echo "skipped"
		status=0
	else
		echo "FAILED"
		cat $LOGDIR/$1.out | sed 's/^/# /'
	fi
	date >> $LOGDIR/$1.out

	# allow background processing to complete
	wait

	case `uname` in
	MINGW*)
		psql -X -h $BOUNCER_ADMIN_HOST -U pgbouncer -d pgbouncer -c "shutdown;" 2>/dev/null
		sleep 1
		;;
	*)
		stopit test.pid
		;;
	esac
	mv $BOUNCER_LOG $LOGDIR/$1.log

	return $status
}

# show version and --version
test_show_version() {
	v1=$($BOUNCER_EXE --version | head -n 1) || return 1
	v2=$(psql -X -tAq -h $BOUNCER_ADMIN_HOST -U pgbouncer -d pgbouncer -c "show version;") || return 1

	echo "v1=$v1"
	echo "v2=$v2"

	test x"$v1" = x"$v2"
}

# test all the show commands
#
# This test right now just runs all the commands without checking the
# output, which would be difficult.  This at least ensures the
# commands don't completely die.  The output can be manually eyeballed
# in the test log file.
test_show() {
	for what in clients config databases fds help lists pools servers sockets active_sockets stats stats_totals stats_averages users totals mem dns_hosts dns_zones; do
		    echo "=> show $what;"
		    psql -X -h $BOUNCER_ADMIN_HOST -U pgbouncer -d pgbouncer -c "show $what;" || return 1
	done

	psql -X -h $BOUNCER_ADMIN_HOST -U pgbouncer -d pgbouncer -c "show bogus;" && return 1

	return 0
}

# server_lifetime
test_server_lifetime() {
	admin "set server_lifetime=2"
	psql -X -c "select now()" p0
	sleep 3

	rc=`psql -X -p $PG_PORT -tAqc "select count(1) from pg_stat_activity where usename='bouncer' and datname='p0'" p0`
	psql -X -c "select now()" p0
	return $rc
}

# server_idle_timeout
test_server_idle_timeout() {
	admin "set server_idle_timeout=2"
	psql -X -c "select now()" p0
	sleep 3
	rc=`psql -X -p $PG_PORT -tAq -c "select count(1) from pg_stat_activity where usename='bouncer' and datname='p0'" p0`
	psql -X -c "select now()" p0
	return $rc
}

# query_timeout
test_query_timeout() {
	admin "set query_timeout=3"
	psql -X -c "select pg_sleep(5)" p0 && return 1
	return 0
}

# idle_transaction_timeout
test_idle_transaction_timeout() {
	admin "set pool_mode=transaction"
	admin "set idle_transaction_timeout=2"

	psql -X --set ON_ERROR_STOP=1 p0 <<-PSQL_EOF
	begin;
	\! sleep 3
	select now();
	PSQL_EOF
	test $? -eq 0 && return 1

	# test for GH issue #125
	psql -X --set ON_ERROR_STOP=1 p0 <<-PSQL_EOF
	begin;
	select pg_sleep(2);
	\! sleep 1
	select now();
	PSQL_EOF
	test $? -ne 0 && return 1

	return 0
}

# client_idle_timeout
test_client_idle_timeout() {
	admin "set client_idle_timeout=2"
	psql -X --set ON_ERROR_STOP=1 p0 <<-PSQL_EOF
	select now();
	\! sleep 3
	select now();
	PSQL_EOF
	test $? -eq 0 && return 1
	return 0
}

# server_login_retry 
# set server_login_retry to 10 instead of 1 beacuse
# gpdb master will start firstly and segments are not
# start yet. So the pgbouncer connect to master will
# fail with the following message:
#"FATAL System was started in master-only utility mode - only utility mode connections are allowed"
# So it needs to try more times to login

test_server_login_retry() {
	admin "set query_timeout=60"
	admin "set server_login_retry=30"
	gpstop -aM fast
	(sleep 4; gpstart -a) &
	sleep 2
	psql -X -c "select now()" p0
	rc=$?
	wait
	return $rc
}

# tcp_user_timeout
test_tcp_user_timeout() {
	test -z "$USE_SUDO" && return 77
	test `uname` = Linux || return 77
	# Doesn't seem to work with older kernels (Ubuntu trusty is
	# affected), not sure what the actual cut-off is.
	case `uname -r` in 1.*|2.*|3.*|4.*) return 77;; esac

	admin "set tcp_user_timeout=1000"
	admin "set query_timeout=5"

	# make a connection is active
	psql -X -c "select now()" p0

	# block connectivity
	fw_drop_port $PG_PORT

	# try to use the connection again
	psql -X -c "select now()" p0

	fw_reset

	# without tcp_user_timeout, you get a different error message
	# about "query timeout" instead
	grep -F 'closing because: server conn crashed?' $BOUNCER_LOG
}

# server_connect_timeout
test_server_connect_timeout_establish() {
	reconf_pgsql "pre_auth_delay=60"
	sleep 1

	admin "set query_timeout=3"
	admin "set server_connect_timeout=2"
	psql -X -c "select now()" p0
	# client will always see query_timeout, need to grep for connect timeout
	grep "closing because: connect timeout" $BOUNCER_LOG
	rc=$?

	rm -f ${PGDATA}/postgresql.auto.conf
	reconf_pgsql
	sleep 1

	return $rc
}

# server_connect_timeout - block with iptables
test_server_connect_timeout_reject() {
	test -z "$USE_SUDO" && return 77
	admin "set query_timeout=5"
	admin "set server_connect_timeout=3"
	fw_drop_port $PG_PORT
	psql -X -c "select now()" p0
	fw_reset
	# client will always see query_timeout, need to grep for connect timeout
	grep "closing because: connect failed" $BOUNCER_LOG
}

# server_check_delay
test_server_check_delay() {
	test -z "$USE_SUDO" && return 77

	admin "set server_check_delay=2"
	admin "set server_login_retry=3"
	admin "set query_timeout=10"

	psql -X -c "select now()" p0
	fw_reject_port $PG_PORT
	sleep 3
	psql -X -tAq -c "select 1" p0 >$LOGDIR/test.tmp &
	sleep 1
	fw_reset
	echo `date` rules flushed
	wait
	echo `date` done waiting

	test "`cat $LOGDIR/test.tmp`" = "1"
}

# max_client_conn
test_max_client_conn() {
	admin "set max_client_conn=5"
	admin "show config"

	for i in {1..4}; do
		psql -X -c "select now() as sleeping from pg_sleep(3);" p1 &
	done

	# last conn allowed
	psql -X -c "select now() as last_conn" p1 || return 1

	# exhaust it
	psql -X -c "select now() as sleeping from pg_sleep(3);" p1 &
	sleep 1

	# shouldn't be allowed
	psql -X -c "select now() as exhausted" p1 && return 1

	# should be ok
	echo 'waiting for clients to complete ...'
	wait
	psql -X -c "select now() as ok" p1 || return 1

	return 0
}

# - max pool size
test_pool_size() {
	# make existing connections go away
	psql -X -p $PG_PORT -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where usename='bouncer'"
	until test $(psql -X -p $PG_PORT -d postgres -tAq -c "select count(1) from pg_stat_activity where usename='bouncer'") -eq 0; do sleep 0.1; done

	docount() {
		for i in {1..10}; do
			psql -X -c "select pg_sleep(0.5)" $1 >/dev/null &
		done
		wait
		cnt=`psql -X -p $PG_PORT -tAq -c "select count(1) from pg_stat_activity where usename='bouncer' and datname='$1'" postgres`
		echo $cnt
	}

	test `docount p0` -eq 2 || return 1
	test `docount p1` -eq 5 || return 1

	# test reload (GH issue #248)
	admin "set default_pool_size = 7"
	test `docount p1` -eq 7 || return 1

	return 0
}

test_min_pool_size() {
	# make existing connections go away
	psql -X -p $PG_PORT -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where usename='bouncer'"
	until test $(psql -X -p $PG_PORT -d postgres -tAq -c "select count(1) from pg_stat_activity where usename='bouncer'") -eq 0; do sleep 0.1; done

	# default_pool_size=5
	admin "set min_pool_size = 3"

	cnt=`psql -X -p $PG_PORT -tAq -c "select count(1) from pg_stat_activity where usename='bouncer' and datname='p1'" postgres`
	echo $cnt
	test "$cnt" -eq 0 || return 1

	# It's a bit tricky to get the timing of this test to work
	# robustly: Full maintenance runs three times a second, so we
	# need to wait at least 1/3 seconds for it to notice for sure
	# that the pool is in use.  When it does, it will launch one
	# connection per round, so we need to wait at least 3 * 1/3
	# second before all the min pool connections are launched.
	# Also, we need to keep the query running while this is
	# happening so that the pool doesn't become momentarily
	# unused.
	psql -X -c "select pg_sleep(2)" p1 &
	sleep 2

	cnt=`psql -X -p $PG_PORT -tAq -c "select count(1) from pg_stat_activity where usename='bouncer' and datname='p1'" postgres`
	echo $cnt
	test "$cnt" -eq 3 || return 1
}

test_reserve_pool_size() {
	# make existing connections go away
	psql -X -p $PG_PORT -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where usename='bouncer'"
	until test $(psql -X -p $PG_PORT -d postgres -tAq -c "select count(1) from pg_stat_activity where usename='bouncer'") -eq 0; do sleep 0.1; done

	# default_pool_size=5
	admin "set reserve_pool_size = 3"

	for i in {1..8}; do
		psql -X -c "select pg_sleep(8)" p1 >/dev/null &
	done
	sleep 1
	cnt=`psql -X -p $PG_PORT -tAq -c "select count(1) from pg_stat_activity where usename='bouncer' and datname='p1'" postgres`
	echo $cnt
	test "$cnt" -eq 5 || return 1

	sleep 7  # reserve_pool_timeout + wiggle room

	cnt=`psql -X -p $PG_PORT -tAq -c "select count(1) from pg_stat_activity where usename='bouncer' and datname='p1'" postgres`
	echo $cnt
	test "$cnt" -eq 8 || return 1

	grep "taking connection from reserve_pool" $BOUNCER_LOG || return 1
}

test_max_db_connections() {
	local users

	# some users, doesn't matter which ones
	users=(muser1 muser2 puser1 puser2)

	docount() {
		for i in {1..10}; do
			psql -X -U ${users[$(($i % 4))]} -c "select pg_sleep(0.5)" p2 >/dev/null &
		done
		wait
		cnt=`psql -X -p $PG_PORT -tAq -c "select count(1) from pg_stat_activity where usename in ('muser1', 'muser2', 'puser1', 'puser2') and datname='p0'" postgres`
		echo $cnt
	}

	test `docount` -eq 4 || return 1

	return 0
}

test_max_user_connections() {
	local databases

	databases=(p7a p7b p7c)

	docount() {
		for i in {1..10}; do
			psql -X -U maxedout -c "select pg_sleep(0.5)" ${databases[$(($i % 3))]} >/dev/null &
		done
		wait
		cnt=`psql -X -p $PG_PORT -tAq -c "select count(1) from pg_stat_activity where datname = 'p7'" postgres`
		echo $cnt
	}

	test `docount` -eq 3 || return 1

	return 0
}

# test online restart while clients running
test_online_restart() {
# max_client_conn=10
# default_pool_size=5
	$have_getpeereid || return 77

	for i in {1..5}; do
		echo "`date` attempt $i"

		for j in {1..5}; do
			psql -X -c "select now() as sleeping from pg_sleep(2)" p1 &
		done

		pid1=`cat $BOUNCER_PID`
		echo "old bouncer is $pid1"
		$BOUNCER_EXE -d -R  $BOUNCER_INI
		sleep 2
		pid2=`cat $BOUNCER_PID`
		echo "new bouncer is $pid2"
		[ $pid1 = $pid2 ] && return 1
	done
	return 0
}

# test pause/resume
test_pause_resume() {
	rm -f $LOGDIR/test.tmp
	for i in {1..50}; do
		psql -X -tAq -c 'select 1 from pg_sleep(0.1)' p0 >>$LOGDIR/test.tmp
	done &

	for i in {1..5}; do
		admin "pause"
		sleep 1
		admin "resume"
		sleep 1
	done

	wait
	test `wc -l <$LOGDIR/test.tmp` -eq 50
}

# test suspend/resume
test_suspend_resume() {
	rm -f $LOGDIR/test.tmp
	for i in {1..50}; do
		psql -X -tAq -c 'select 1 from pg_sleep(0.1)' p0 >>$LOGDIR/test.tmp
	done &

	for i in {1..5}; do
		psql -X -h $BOUNCER_ADMIN_HOST -p $BOUNCER_PORT -d pgbouncer -U pgbouncer <<-PSQL_EOF
		suspend;
		\! sleep 1
		resume;
		\! sleep 1
		PSQL_EOF
	done

	wait
	test `wc -l <$LOGDIR/test.tmp` -eq 50
}

# test enable/disable
test_enable_disable() {
	rm -f $LOGDIR/test.tmp
	psql -X -tAq -c "select 'enabled 1'" >>$LOGDIR/test.tmp p0 2>&1

	admin "disable p0"
	psql -X -tAq -c "select 'disabled 1'" >>$LOGDIR/test.tmp p0 2>&1
	admin "enable p0"
	psql -X -tAq -c "select 'enabled 2'" >>$LOGDIR/test.tmp p0 2>&1

	grep -q "enabled 1" $LOGDIR/test.tmp || return 1
	grep -q "enabled 2" $LOGDIR/test.tmp || return 1
	grep -q "disabled 1" $LOGDIR/test.tmp && return 1
	grep -q "does not allow" $LOGDIR/test.tmp || return 1
	return 0
}

# test pool database restart
test_database_restart() {
	admin "set server_login_retry=1"

	psql -X -c "select now() as p0_before_restart" p0
	gpstop -ar
	echo `date` restart 1
	psql -X -c "select now() as p0_after_restart" p0 || return 1


	# do with some more clients
	for i in {1..5}; do
		psql -X -c "select pg_sleep($i)" p0 &
		psql -X -c "select pg_sleep($i)" p1 &
	done

	gpstop -ar
	echo `date` restart 2

	wait
	psql -X -c "select now() as p0_after_restart" p0 || return 1

	# connect to clear server_login_retry state
	psql -X -c "select now() as p1_after_restart" p1

	return 0
}

# test connect string change
test_database_change() {
	admin "set server_lifetime=2"

	db1=`psql -X -tAq -c "select current_database()" p1`

	cp test.ini test.ini.bak
	sed '/^p1 =/s/dbname=p1/dbname=p0/g' test.ini >test2.ini
	mv test2.ini test.ini

	admin "reload"

	sleep 3
	db2=`psql -X -tAq -c "select current_database()" p1`

	echo "db1=$db1 db2=$db2"
	cp test.ini.bak test.ini
	rm test.ini.bak

	admin "show databases"
	admin "show pools"

	test "$db1" = "p1" -a "$db2" = "p0"
}

# test reconnect
test_reconnect() {
	bp1=`psql -X -tAq -c "select pg_backend_pid()" p1`
	admin "reconnect p1"
	sleep 1
	bp2=`psql -X -tAq -c "select pg_backend_pid()" p1`
	echo "bp1=$bp1 bp2=$bp2"
	test "$bp1" != "$bp2"
}

# test server_fast_close
test_fast_close() {
	(
		echo "select pg_backend_pid();"
		sleep 2
		echo "select pg_backend_pid();"
		echo "\q"
	) | psql -X -tAq -f- -d p3 >$LOGDIR/testout.tmp 2>$LOGDIR/testerr.tmp &
	sleep 1
	admin "set server_fast_close = 1"
	admin "reconnect p3"
	wait

	admin "show databases"
	admin "show pools"
	admin "show servers"

	# If this worked correctly, the session will be closed between
	# the two queries, so the second query will fail and leave an
	# error.
	test `wc -l <$LOGDIR/testout.tmp` -eq 1 && test `wc -l <$LOGDIR/testerr.tmp` -ge 1
}

# test wait_close
test_wait_close() {
	case `uname` in MINGW*) return 77;; esac # TODO

	(
		echo "select pg_backend_pid();"
		sleep 3
		echo "select pg_backend_pid();"
		echo "\q"
	) | psql -X -tAq -f- -d p3 &
	psql_pid=$!
	sleep 1
	admin "reconnect p3"
	admin "wait_close p3"
	sleep 1  # give psql a moment to exit

	# psql should no longer be running now.  (Without the
	# wait_close it would still be running.)
	kill -0 $psql_pid
	psql_running=$?

	wait

	admin "show databases"
	admin "show pools"
	admin "show servers"

	test $psql_running -ne 0
}

# test auth_user
test_auth_user() {
	$have_getpeereid || return 77

	admin "set auth_type='md5'"
	curuser=`psql -X -d "dbname=authdb user=someuser password=anypasswd" -tAq -c "select current_user;"`
	echo "curuser=$curuser"
	test "$curuser" = "someuser" || return 1

	curuser2=`psql -X -d "dbname=authdb user=nouser password=anypasswd" -tAq -c "select current_user;"`
	echo "curuser2=$curuser2"
	test "$curuser2" = "" || return 1

	curuser2=`psql -X -d "dbname=authdb user=someuser password=badpasswd" -tAq -c "select current_user;"`
	echo "curuser2=$curuser2"
	test "$curuser2" = "" || return 1

	admin "show databases"
	admin "show pools"

	return 0
}

# test plain-text password authentication from PgBouncer to PostgreSQL server
#
# The PostgreSQL server no longer supports storing plain-text
# passwords, so the server-side user actually uses md5 passwords in
# this test case, but the communication is still in plain text.
test_password_server() {
	admin "set auth_type='trust'"

	# good password from ini
	psql -X -c "select 1" p4 || return 1
	# bad password from ini
	psql -X -c "select 2" p4x && return 1

	# good password from auth_file
	psql -X -c "select 1" p4y || return 1
	# bad password from auth_file
	psql -X -c "select 1" p4z && return 1

	# long password from auth_file
	psql -X -c "select 1" p4l || return 1

	return 0
}

# test plain-text password authentication from client to PgBouncer
test_password_client() {
	$have_getpeereid || return 77

	admin "set auth_type='plain'"

	# test with users that have a plain-text password stored

	# good password
	PGPASSWORD=foo psql -X -U puser1 -c "select 1" p1 || return 1
	# bad password
	PGPASSWORD=wrong psql -X -U puser2 -c "select 2" p1 && return 1
	# long password
	PGPASSWORD=$long_password psql -X -U longpass -c "select 3" p1 || return 1
	# too long password
	PGPASSWORD=X$long_password psql -X -U longpass -c "select 4" p1 && return 1

	# test with users that have an md5 password stored

	# good password
	PGPASSWORD=foo psql -X -U muser1 -c "select 1" p1 || return 1
	# bad password
	PGPASSWORD=wrong psql -X -U muser2 -c "select 2" p1 && return 1

	# test with users that have a SCRAM password stored

	# good password
	PGPASSWORD=foo psql -X -U scramuser1 -c "select 1" p1 || return 1
	# bad password
	PGPASSWORD=wrong psql -X -U scramuser2 -c "select 2" p1 && return 1

	admin "set auth_type='trust'"

	return 0
}

# test md5 authentication from PgBouncer to PostgreSQL server
test_md5_server() {
	admin "set auth_type='trust'"

	# good password from ini
	psql -X -c "select 1" p5 || return 1
	# bad password from ini
	psql -X -c "select 2" p5x && return 1

	# good password from auth_file
	psql -X -c "select 1" p5y || return 1
	# bad password from auth_file
	psql -X -c "select 1" p5z && return 1

	return 0
}

# test md5 authentication from client to PgBouncer
test_md5_client() {
	$have_getpeereid || return 77

	admin "set auth_type='md5'"

	# test with users that have a plain-text password stored

	# good password
	PGPASSWORD=foo psql -X -U puser1 -c "select 1" p1 || return 1
	# bad password
	PGPASSWORD=wrong psql -X -U puser2 -c "select 2" p1 && return 1

	# test with users that have an md5 password stored

	# good password
	PGPASSWORD=foo psql -X -U muser1 -c "select 1" p1 || return 1
	# bad password
	PGPASSWORD=wrong psql -X -U muser2 -c "select 2" p1 && return 1

	admin "set auth_type='trust'"

	return 0
}

# test SCRAM authentication from PgBouncer to PostgreSQL server
test_scram_server() {
	$pg_supports_scram || return 77

	admin "set auth_type='trust'"

	# good password from ini
	psql -X -c "select 1" p6 || return 1
	# bad password from ini
	psql -X -c "select 2" p6x && return 1

	# good password from auth_file (fails: not supported with SCRAM)
	psql -X -c "select 1" p6y && return 1
	# bad password from auth_file
	psql -X -c "select 1" p6z && return 1

	return 0
}

# test SCRAM authentication from client to PgBouncer
test_scram_client() {
	$have_getpeereid || return 77
	$pg_supports_scram || return 77

	admin "set auth_type='scram-sha-256'"

	# test with users that have a plain-text password stored

	# good password
	PGPASSWORD=foo psql -X -U puser1 -c "select 1" p1 || return 1
	# bad password
	PGPASSWORD=wrong psql -X -U puser2 -c "select 2" p1 && return 1

	# test with users that have an md5 password stored (all fail)

	# good password
	PGPASSWORD=foo psql -X -U muser1 -c "select 1" p1 && return 1
	# bad password
	PGPASSWORD=wrong psql -X -U muser2 -c "select 2" p1 && return 1

	# test with users that have a SCRAM password stored

	# good password
	PGPASSWORD=foo psql -X -U scramuser1 -c "select 1" p1 || return 1
	# bad password
	PGPASSWORD=wrong psql -X -U scramuser2 -c "select 2" p1 && return 1

	# SCRAM should also work when auth_type is "md5"
	admin "set auth_type='md5'"

	# good password
	PGPASSWORD=foo psql -X -U scramuser1 -c "select 1" p1 || return 1
	# bad password
	PGPASSWORD=wrong psql -X -U scramuser2 -c "select 2" p1 && return 1

	admin "set auth_type='trust'"

	return 0
}

# test SCRAM authentication from client to PgBouncer and on to server
test_scram_both() {
	$have_getpeereid || return 77
	$pg_supports_scram || return 77

	admin "set auth_type='scram-sha-256'"

	# plain-text password in userlist.txt
	PGPASSWORD=baz psql -X -U scramuser3 -c "select 1" p61 || return 1

	# SCRAM password in userlist.txt
	PGPASSWORD=foo psql -X -U scramuser1 -c "select 1" p62 || return 1

	return 0
}

# test that SCRAM authentication pass-through is preserved by online
# restart
#
# Note: coproc requires bash >=4
test_scram_takeover() {
	$have_getpeereid || return 77
	$pg_supports_scram || return 77

	admin "set auth_type='scram-sha-256'"
	admin "set pool_mode=transaction"
	admin "set server_lifetime=3"

	{ coproc { PGPASSWORD=foo psql -X -U scramuser1 -f - -d p62; } >&3; } 3>&1

	echo "select 1;" >&"${COPROC[1]}"
	sleep 4  # wait for server_lifetime

	$BOUNCER_EXE -d -R $BOUNCER_INI
	sleep 1

	echo "select 2;" >&"${COPROC[1]}"
	echo "\q" >&"${COPROC[1]}"

	wait $COPROC_PID

	test $? -eq 0
}

# Several tests that check the behavior when connecting with a
# nonexistent user under various authentication types.  Database p1
# has a forced user, p2 does not; these exercise slightly different
# code paths.

test_no_user_trust() {
	admin "set auth_type='trust'"

	psql -X -U nosuchuser1 -c "select 1" p2 && return 1
	grep -F "closing because: \"trust\" authentication failed" $BOUNCER_LOG || return 1

	return 0
}

test_no_user_trust_forced_user() {
	admin "set auth_type='trust'"

	psql -X -U nosuchuser1 -c "select 1" p1 && return 1
	grep -F "closing because: \"trust\" authentication failed" $BOUNCER_LOG || return 1

	return 0
}

test_no_user_password() {
	$have_getpeereid || return 77

	admin "set auth_type='plain'"

	PGPASSWORD=whatever psql -X -U nosuchuser1 -c "select 1" p2 && return 1
	grep -F "no such user: nosuchuser1" $BOUNCER_LOG || return 1
	grep -F "closing because: password authentication failed" $BOUNCER_LOG || return 1

	return 0
}

test_no_user_password_forced_user() {
	$have_getpeereid || return 77

	admin "set auth_type='plain'"

	PGPASSWORD=whatever psql -X -U nosuchuser1 -c "select 1" p1 && return 1
	grep -F "no such user: nosuchuser1" $BOUNCER_LOG || return 1
	grep -F "closing because: password authentication failed" $BOUNCER_LOG || return 1

	return 0
}

test_no_user_md5() {
	$have_getpeereid || return 77

	admin "set auth_type='md5'"

	PGPASSWORD=whatever psql -X -U nosuchuser1 -c "select 1" p2 && return 1
	grep -F "no such user: nosuchuser1" $BOUNCER_LOG || return 1
	grep -F "closing because: password authentication failed" $BOUNCER_LOG || return 1

	return 0
}

test_no_user_md5_forced_user() {
	$have_getpeereid || return 77

	admin "set auth_type='md5'"

	PGPASSWORD=whatever psql -X -U nosuchuser1 -c "select 1" p1 && return 1
	grep -F "no such user: nosuchuser1" $BOUNCER_LOG || return 1
	grep -F "closing because: password authentication failed" $BOUNCER_LOG || return 1

	return 0
}

test_no_user_scram() {
	$have_getpeereid || return 77
	$pg_supports_scram || return 77

	admin "set auth_type='scram-sha-256'"

	PGPASSWORD=whatever psql -X -U nosuchuser1 -c "select 1" p2 && return 1
	grep -F "no such user: nosuchuser1" $BOUNCER_LOG || return 1
	grep -F "closing because: SASL authentication failed" $BOUNCER_LOG || return 1

	return 0
}

test_no_user_scram_forced_user() {
	$have_getpeereid || return 77
	$pg_supports_scram || return 77

	admin "set auth_type='scram-sha-256'"

	PGPASSWORD=whatever psql -X -U nosuchuser1 -c "select 1" p1 && return 1
	grep -F "no such user: nosuchuser1" $BOUNCER_LOG || return 1
	grep -F "closing because: SASL authentication failed" $BOUNCER_LOG || return 1

	return 0
}

test_no_user_auth_user() {
	$have_getpeereid || return 77

	admin "set auth_type='md5'"

	PGPASSWORD=whatever psql -X -U nosuchuser1 -c "select 1" authdb && return 1
	# Currently no mock authentication when using
	# auth_query/auth_user.  See TODO in
	# handle_auth_query_response().
	grep -F "closing because: no such user (age" $BOUNCER_LOG || return 1

	return 0
}

test_auto_database() {
	cp test.ini test.ini.bak
	sed 's/^;\*/*/g' test.ini >test2.ini
	mv test2.ini test.ini

	admin "reload"

	psql -X -d p7 -c "select current_database()"
	status1=$?
	grep -F "registered new auto-database" $BOUNCER_LOG
	status2=$?

	cp test.ini.bak test.ini
	rm test.ini.bak

	test $status1 -eq 0 -a $status2 -eq 0
	return 0
}

test_cancel() {
	case `uname` in MINGW*) return 77;; esac

	psql -X -d p3 -c "select pg_sleep(20)" &
	psql_pid=$!
	sleep 1
	kill -INT $psql_pid
	wait $psql_pid
	test $? -ne 0 || return 1

	return 0
}

# Test for waiting connections handling for cancel requests.
#
# The bug fixed by GH PR #542 was: When the connection pool is full,
# cancel requests cannot get through (that is normal), but then when
# unused connections close and pool slots are available, those are not
# used for waiting cancel requests.
test_cancel_wait() {
	case `uname` in MINGW*) return 77;; esac

	# default_pool_size=5
	admin "set server_idle_timeout=2"

	psql -X -d p3 -c "select pg_sleep(20)" &
	psql_pid=$!
	psql -X -d p3 -c "select pg_sleep(2)" &
	psql -X -d p3 -c "select pg_sleep(2)" &
	psql -X -d p3 -c "select pg_sleep(2)" &
	psql -X -d p3 -c "select pg_sleep(2)" &
	sleep 1

	# This cancel must wait for a pool slot to become free.
	kill -INT $psql_pid

	wait $psql_pid

	# Prior to the bug fix, the cancel would never get through and
	# the first psql would simply run the full sleep and exit
	# successfully.
	test $? -ne 0 || return 1

	return 0
}

# Test that cancel requests can exceed the pool size
#
# Cancel request connections can use twice the pool size.  See also GH
# PR #543.
test_cancel_pool_size() {
	case `uname` in MINGW*) return 77;; esac

	# default_pool_size=5
	admin "set server_idle_timeout=2"

	psql -X -d p3 -c "select pg_sleep(20)" &
	psql1_pid=$!
	psql -X -d p3 -c "select pg_sleep(20)" &
	psql2_pid=$!
	psql -X -d p3 -c "select pg_sleep(20)" &
	psql3_pid=$!
	psql -X -d p3 -c "select pg_sleep(20)" &
	psql4_pid=$!
	psql -X -d p3 -c "select pg_sleep(20)" &
	psql5_pid=$!
	sleep 1

	# These cancels requires more connections than the
	# default_pool_size=5.
	kill -INT $psql1_pid $psql2_pid $psql3_pid $psql4_pid $psql5_pid

	wait $psql1_pid

	# Prior to the change fix, the cancels would never get through
	# and the psql processes would simply run the full sleep and
	# exit successfully.
	test $? -ne 0 || return 1

	return 0
}
# Test admin user login in different auth_type
test_admin_user_login() {
	# auth_type = hba
	cat >hba.conf<<EOF
host pgbouncer admin_user 0.0.0.0/0 trust
EOF
	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	psql -X -d pgbouncer -U admin_user -c "show pools"
	if [ $? -ne 0 ] ;then
		re=1
	fi

	# auth_type = md5
	echo 'auth_type = md5' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=a psql -X -d pgbouncer -U admin_user -c "show pools"
	if [ $? -ne 0 ] ;then
		re=1
	fi
	return $re
}
# Test ldap authentication
test_ldap_authentication() {
	if [ ! -e ../ldap_configured ];then
		return 77	
	fi
	osname=$(uname -s)
	if [ $osname != "Linux" ];then 
		return 77
	fi
	slapd=/usr/sbin/slapd
	if [ -d '/etc/ldap/schema' ]
	then
		ldap_schema_dir='/etc/ldap/schema'
	else
		ldap_schema_dir='/etc/openldap/schema'
	fi
	if [ ! -e $slapd ];then
		return 77
	fi

	ldap_pwd=$(pwd)/ldap

	ldap_datadir="${ldap_pwd}/openldap-data"
	slapd_conf="${ldap_pwd}/slapd.conf"
	slapd_pidfile="${ldap_pwd}/slapd.pid"
	slapd_logfile="${ldap_pwd}/slapd.log"
	ldap_conf="${ldap_pwd}/ldap.conf"
	ldap_keyfile="auth_key"
	ldap_server='localhost'
	ldap_port=49152
	ldap_url="ldap://$ldap_server:$ldap_port"
	ldap_basedn='dc=example,dc=net'
	ldap_rootdn='cn=Manager,dc=example,dc=net'
	ldap_rootpw='secret'

cat >$slapd_conf <<-EOF
include $ldap_schema_dir/core.schema
include $ldap_schema_dir/cosine.schema
include $ldap_schema_dir/nis.schema
include $ldap_schema_dir/inetorgperson.schema
pidfile $slapd_pidfile
logfile $slapd_logfile
access to *
        by * read
        by anonymous auth

database ldif
directory $ldap_datadir
suffix "dc=example,dc=net"
rootdn "$ldap_rootdn"
rootpw $ldap_rootpw
EOF

cat >$ldap_conf <<-EOF
TLS_REQCERT never
EOF

	if [ -d $ldap_datadir ];then
		rm -rf $ldap_datadir
	fi
	mkdir -p $ldap_datadir

	echo $slapd "-f" $slapd_conf "-h" $ldap_url
	$slapd -f $slapd_conf -h $ldap_url && sleep 1

	export LDAPURI=$ldap_url
	export LDAPBINDDN=$ldap_rootdn
	export LDAPCONF=$ldap_conf

	echo ldapadd -x -w $ldap_rootpw -f $ldap_pwd/ldap.ldif -H $ldap_url
	ldapadd -x -w $ldap_rootpw -f $ldap_pwd/ldap.ldif
	ldappasswd -x -w $ldap_rootpw -s secret1 'uid=ldapuser1,dc=example,dc=net'
	ldapsearch -x -b "dc=example,dc=net"

	local re=0
	#1 test "simple bind"
cat >hba.conf<<EOF
host all ldapuser1 0.0.0.0/0 ldap ldapserver=$ldap_server ldapport=$ldap_port ldapprefix="uid=" ldapsuffix=",dc=example,dc=net"
EOF

	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=secret1 psql -X -d p0 -U ldapuser1 -c "select 1"
	if [ $? -ne 0 ] ;then
		re=1
	fi
	#2 test "search+bind"
cat >hba.conf<<EOF
host all ldapuser1 0.0.0.0/0 ldap ldapserver=$ldap_server ldapport=$ldap_port ldapbasedn="$ldap_basedn"
EOF
	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=secret1 psql -X -d p0 -U ldapuser1 -c "select 1"
	if [ $? -ne 0 ] ;then
		re=1
	fi
	#3 test "encrypted password"
    ldap_binddn=$ldap_rootdn
    ldap_bindpass=$ldap_rootpw
	openssl rand -base64 256 | tr -d '\n' >$ldap_keyfile
	encrypted_passwd=$(echo -n "$ldap_bindpass" | openssl enc -aes-256-cbc -base64 -md sha256 -pass file:${ldap_keyfile})
	echo -n $encrypted_passwd > "${HOME}/.ldapbindpass"
cat >hba.conf<<EOF
host all ldapuser1 0.0.0.0/0 ldap ldapserver=$ldap_server ldapbindpasswd="\$bindpasswd" ldapport=$ldap_port ldapbasedn="$ldap_basedn" ldapbinddn="$ldap_binddn"
EOF
	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=secret1 psql -X -d p0 -U ldapuser1 -c "select 1"
	if [ $? -ne 0 ] ;then
		re=1
	fi
    # with random cipher
    ciphers=($(openssl enc -ciphers | tail -n +2))
    random_ciphers=($(printf "%s\n" "${ciphers[@]}" | shuf -n 1))
    for cipher in "${random_ciphers[@]}"
    do
        encrypted_passwd=$(echo -n "$ldap_bindpass" | openssl enc $cipher -base64 -md sha256 -pass file:${ldap_keyfile})
        echo -n $encrypted_passwd > "${HOME}/.ldapbindpass"
        echo "auth_cipher = ${cipher:1}" >> test.ini
        admin "reload" && sleep 1
        PGPASSWORD=secret1 psql -X -d p0 -U ldapuser1 -c "select 1"
        if [ $? -ne 0 ] ;then
            re=1
        fi
        sed -i '$d' test.ini
    done
	rm -f $ldap_keyfile "${HOME}/.ldapbindpass"
	#4 test "multiple servers"
cat >hba.conf<<EOF
host all ldapuser1 0.0.0.0/0 ldap ldapserver="$ldap_server $ldap_server" ldapport=$ldap_port ldapbasedn="$ldap_basedn"
EOF
	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=secret1 psql -X -d p0 -U ldapuser1 -c "select 1"
	if [ $? -ne 0 ] ;then
		re=1
	fi
	#5 test "LDAP URLs"
cat >hba.conf<<EOF
host all ldapuser1 0.0.0.0/0 ldap ldapurl="$ldap_url/$ldap_basedn?uid?sub"
EOF
	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=secret1 psql -X -d p0 -U ldapuser1 -c "select 1"
	if [ $? -ne 0 ] ;then
		re=1
	fi
	#6 test "search filters"
cat >hba.conf<<EOF
host all ldapuser1 0.0.0.0/0 ldap ldapserver=$ldap_server ldapport=$ldap_port ldapbasedn="$ldap_basedn" ldapsearchfilter="uid=\$username"
EOF
	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=secret1 psql -X -d p0 -U ldapuser1 -c "select 1"
	if [ $? -ne 0 ] ;then
		re=1
	fi
	#7 switch auth type from ldap to md5
	touch userlist.txt # refresh timestamp to change the password of user ldapuser1
cat >hba.conf<<EOF
host all ldapuser1 0.0.0.0/0 md5
EOF
	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=123456 psql -X -d p0 -U ldapuser1 -c "select 1"
	if [ $? -ne 0 ] ;then
		re=1
	fi
	#8 test "search filters in LDAP URLs"
cat >hba.conf<<EOF
host all ldapuser1 0.0.0.0/0 ldap ldapurl="$ldap_url/$ldap_basedn??sub?(|(uid=\$username)(mail=\$username))"
EOF
	echo 'auth_type = hba' >> test.ini
	admin "reload" && sleep 1
	PGPASSWORD=secret1 psql -X -d p0 -U ldapuser1 -c "select 1"
	if [ $? -ne 0 ] ;then
		re=1
	fi

	kill -2 $(cat $slapd_pidfile)
	return $re
}

testlist="
test_show_version
test_show
test_server_login_retry
test_auth_user
test_client_idle_timeout
test_server_lifetime
test_server_idle_timeout
test_query_timeout
test_idle_transaction_timeout
test_server_connect_timeout_establish
test_server_connect_timeout_reject
test_server_check_delay
test_tcp_user_timeout
test_max_client_conn
test_pool_size
test_min_pool_size
test_reserve_pool_size
test_max_db_connections
test_max_user_connections
test_online_restart
test_pause_resume
test_suspend_resume
test_enable_disable
test_database_restart
test_database_change
test_reconnect
test_fast_close
test_wait_close
test_password_server
test_password_client
test_md5_server
test_md5_client
test_scram_server
test_scram_client
test_scram_both
test_scram_takeover
test_no_user_trust
test_no_user_trust_forced_user
test_no_user_password
test_no_user_password_forced_user
test_no_user_md5
test_no_user_md5_forced_user
test_no_user_scram
test_no_user_scram_forced_user
test_no_user_auth_user
test_auto_database
test_cancel
test_cancel_wait
test_cancel_pool_size
test_admin_user_login
test_ldap_authentication
"

if [ $# -gt 0 ]; then
	testlist=$@
fi

total_status=0
for test in $testlist
do
	runtest $test
	status=$?
	if [ $status -ne 0 ]; then
		total_status=1
	fi
done

complete

exit $total_status

# vim: sts=0 sw=8 noet nosmarttab:
