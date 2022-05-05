#! /bin/bash

cd $(dirname $0)

rm -rf TestCA1 TestCA2

which psql
if [ $? -ne 0 ]
then
	source /usr/local/greenplum-db-devel/greenplum_path.sh
	source ../../../gpdb_src/gpAux/gpdemo/gpdemo-env.sh
fi
# PG_PORT is gpdb master server port and PGPORT will be set us pgboucer server port
PG_PORT=${PGPORT}

(
./newca.sh TestCA1 C=QQ O=Org1 CN="TestCA1"
./newsite.sh TestCA1 localhost C=QQ O=Org1 L=computer OU=db
./newsite.sh TestCA1 bouncer C=QQ O=Org1 L=computer OU=Dev
./newsite.sh TestCA1 random C=QQ O=Org1 L=computer OU=Dev
./newca.sh TestCA2 C=QQ O=Org2 CN="TestCA2"
./newsite.sh TestCA2 localhost C=QQ O=Org1 L=computer OU=db
) > /dev/null
#export LD_LIBRARY_PATH=/usr/local/pgsql/lib:$LD_LIBRARY_PATH
#export PATH=/usr/local/pgsql/bin:$PATH
export PGDATA=$MASTER_DATA_DIRECTORY
export PGHOST=localhost
export PGPORT=6667
export EF_ALLOW_MALLOC_0=1
export LC_ALL=C
export POSIXLY_CORRECT=1

mkdir -p tmp

BOUNCER_LOG=test.log
BOUNCER_INI=test.ini
BOUNCER_PID=test.pid
BOUNCER_PORT=`sed -n '/^listen_port/s/listen_port.*=[^0-9]*//p' $BOUNCER_INI`
BOUNCER_EXE="$BOUNCER_EXE_PREFIX ../../pgbouncer"

LOGDIR=log
PG_LOG=$LOGDIR/pg.log

pgctl() {
	pg_ctl -w -o "-p $PG_PORT" -D $PGDATA $@ >>$PG_LOG 2>&1
}

ulimit -c unlimited

# System configuration checks
SED_ERE_OP='-E'
case `uname` in
Linux)
	SED_ERE_OP='-r'
	;;
esac

pg_majorversion=$(initdb --version | sed -n $SED_ERE_OP 's/.* ([0-9]+).*/\1/p')
if test $pg_majorversion -ge 10; then
	pg_supports_scram=true
else
	pg_supports_scram=false
fi
# Because gpdb6 has supported scram-sha-256, but the psql version is not changed,
# so we enable scram test for it.
pg_supports_scram=true

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
rm -f $BOUNCER_LOG $PG_LOG

if [  -d $PGDATA ]; then
	cp ${PGDATA}/postgresql.conf ${PGDATA}/postgresql.conf.orig
	cp ${PGDATA}/pg_hba.conf ${PGDATA}/pg_hba.conf.orig
	cp ${PGDATA}/pg_ident.conf ${PGDATA}/pg_ident.conf.orig

	cp -p TestCA1/sites/01-localhost.crt ${PGDATA}/server.crt
	cp -p TestCA1/sites/01-localhost.key ${PGDATA}/server.key
	cp -p TestCA1/ca.crt ${PGDATA}/root.crt
	# replace port in test.ini
	cp test.ini test.ini.orig
	sed -i "s/PGPORT/${PG_PORT}/" test.ini

	echo '"bouncer" "zzz"' > tmp/userlist.txt

	chmod 600 ${PGDATA}/server.key
	chmod 600 tmp/userlist.txt

fi

echo "createdb"
psql -X -p $PG_PORT -l | grep p0 > /dev/null || {
	psql -X -o /dev/null -p $PG_PORT -c "create user bouncer" template1
	createdb -p $PG_PORT p0
	createdb -p $PG_PORT p1
}

reconf_bouncer() {
	cp test.ini tmp/test.ini
	for ln in "$@"; do
		echo "$ln" >> tmp/test.ini
	done
	test -f test.pid && kill `cat test.pid`
	sleep 1
	$BOUNCER_EXE -v -v -v -d tmp/test.ini
}

reconf_pgsql() {
	cp ${PGDATA}/postgresql.conf.orig ${PGDATA}/postgresql.conf
	for ln in "$@"; do
		echo "$ln" >> ${PGDATA}/postgresql.conf
	done
	pg_ctl restart -w -t 3 -D $MASTER_DATA_DIRECTORY
}


#
#  fw hacks
#

#
# util functions
#

complete() {
	test -f $BOUNCER_PID && kill `cat $BOUNCER_PID` >/dev/null 2>&1
	cp ${PGDATA}/postgresql.conf.orig ${PGDATA}/postgresql.conf
	cp ${PGDATA}/pg_hba.conf.orig ${PGDATA}/pg_hba.conf
	cp ${PGDATA}/pg_ident.conf.orig ${PGDATA}/pg_ident.conf
	pg_ctl restart -w -t 3 -D $MASTER_DATA_DIRECTORY
	rm test.ini
	mv test.ini.orig test.ini
	rm -f $BOUNCER_PID
}

die() {
	echo $@
	complete
	exit 1
}

admin() {
	psql -X -h /tmp -U pgbouncer -d pgbouncer -c "$@;" || die "Cannot contact bouncer!"
}

runtest() {
	local status

	$BOUNCER_EXE -d $BOUNCER_INI
	until psql -X -h /tmp -U pgbouncer -d pgbouncer -c "show version" 2>/dev/null 1>&2; do sleep 0.1; done

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
		result=1
		echo "FAILED"
		cat $LOGDIR/$1.out | sed 's/^/# /'
	fi
	date >> $LOGDIR/$1.out

	# allow background processing to complete
	wait

	stopit test.pid
	mv $BOUNCER_LOG $LOGDIR/$1.log

	return $status
}

psql_pg() {
	psql -X -U bouncer -h 127.0.0.1 -p $PG_PORT "$@"
}

psql_bouncer() {
	PGUSER=bouncer PGPASSWORD=zzz psql -X "$@"
}

# server_lifetime
test_server_ssl() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = require" 
	echo "hostssl all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "hostssl all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d p0 -c "select 'ssl-connect'" | tee tmp/test.tmp0
	grep -q "ssl-connect"  tmp/test.tmp0
	rc=$?
	return $rc
}

test_server_ssl_set_disable() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = require"
	echo "hostssl all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "hostssl all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d p0 -c "select 'ssl-connect'" | tee tmp/test.tmp0
	grep -q "ssl-connect"  tmp/test.tmp0 || return 1
	sed s/ssl/nossl/g ${PGDATA}/pg_hba.conf > tmp/pg_hba2.conf
	mv tmp/pg_hba2.conf ${PGDATA}/pg_hba.conf
	pg_ctl reload
	admin "reconnect"
	admin "set server_tls_sslmode=disable"
	psql_bouncer -q -d p0 -c "select 'ssl-connect'" | tee tmp/test.tmp0
	grep -q "ssl-connect"  tmp/test.tmp0
	rc=$?
	return $rc
}

test_server_ssl_set_enable() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = disable"
	echo "hostnossl all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "hostnossl all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d p0 -c "select 'ssl-connect'" | tee tmp/test.tmp0
	grep -q "ssl-connect"  tmp/test.tmp0 || return 1
	sed s/nossl/ssl/g ${PGDATA}/pg_hba.conf > tmp/pg_hba2.conf
	mv tmp/pg_hba2.conf ${PGDATA}/pg_hba.conf
	pg_ctl reload
	admin "reconnect"
	admin "set server_tls_sslmode=require"
	psql_bouncer -q -d p0 -c "select 'ssl-connect'" | tee tmp/test.tmp0
	grep -q "ssl-connect"  tmp/test.tmp0
	rc=$?
	return $rc
}

test_server_ssl_verify() {
	reconf_bouncer "auth_type = trust" \
		"server_tls_sslmode = verify-full" \
		"server_tls_ca_file = TestCA1/ca.crt"

	echo "hostssl all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "hostssl all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d p0 -c "select 'ssl-full-connect'" | tee tmp/test.tmp1
	grep -q "ssl-full-connect"  tmp/test.tmp1
	rc=$?
	return $rc
}

test_server_ssl_pg_auth() {
	reconf_bouncer "auth_type = trust" \
		"server_tls_sslmode = verify-full" \
		"server_tls_ca_file = TestCA1/ca.crt" \
		"server_tls_key_file = TestCA1/sites/02-bouncer.key" \
		"server_tls_cert_file = TestCA1/sites/02-bouncer.crt"

	echo "hostssl all all 127.0.0.1/32 cert" >> ${PGDATA}/pg_hba.conf
	echo "hostssl all all ::1/128 cert" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d p0 -c "select 'ssl-cert-connect'" | tee tmp/test.tmp2
	grep "ssl-cert-connect"  tmp/test.tmp2
	rc=$?
	return $rc
}

test_client_ssl() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = require" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt" \
		"client_tls_ca_file = TestCA1/sites/01-localhost.crt"

	echo "host all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d "dbname=p0 sslmode=require" -c "select 'client-ssl-connect'" | tee tmp/test.tmp
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_verify() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = require" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt" \
		"client_tls_ca_file = TestCA1/sites/01-localhost.crt"

	echo "host all all  127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_set_disable() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = require" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt"
	echo "host all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp || return 1
	admin "set client_tls_sslmode=disable"
	psql_bouncer -q -d "dbname=p0 sslmode=disable" -c "select 'client-ssl-disable'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-disable"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_set_enable() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = disable"
	echo "host all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=disable" -c "select 'client-ssl-disable'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-disable"  tmp/test.tmp || return 1
	admin "set client_tls_key_file='TestCA1/sites/01-localhost.key'"
	admin "set client_tls_cert_file='TestCA1/sites/01-localhost.crt'"
	admin "set client_tls_sslmode=require"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_set_change_ca() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = require" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt"
	echo "host all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp || return 1
	admin "set client_tls_key_file='TestCA2/sites/01-localhost.key'"
	admin "set client_tls_cert_file='TestCA2/sites/01-localhost.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA2/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_reload_disable() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt" \
		"client_tls_sslmode=require"
	echo "host all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp || return 1
	sed 's/client_tls_sslmode=require/client_tls_sslmode=disable/g' tmp/test.ini > tmp/test2.ini
	mv tmp/test2.ini tmp/test.ini
	admin "reload"
	psql_bouncer -q -d "dbname=p0 sslmode=disable" -c "select 'client-ssl-disable'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-disable"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_reload_enable() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt" \
		"client_tls_sslmode=disable"
	echo "host all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=disable" -c "select 'client-ssl-disable'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-disable"  tmp/test.tmp || return 1
	sed 's/client_tls_sslmode=disable/client_tls_sslmode=require/g' tmp/test.ini > tmp/test2.ini
	mv tmp/test2.ini tmp/test.ini
	admin "reload"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_reload_change_ca() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = require" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt"
	echo "host all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp || return 1
	sed 's/TestCA1/TestCA2/g' tmp/test.ini > tmp/test2.ini
	mv tmp/test2.ini tmp/test.ini
	admin "reload"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA2/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_sighup_disable() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt" \
		"client_tls_sslmode=require"
	echo "host all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp || return 1
	sed 's/client_tls_sslmode=require/client_tls_sslmode=disable/g' tmp/test.ini > tmp/test2.ini
	mv tmp/test2.ini tmp/test.ini
	kill -HUP `cat test.pid`
	sleep 1
	psql_bouncer -q -d "dbname=p0 sslmode=disable" -c "select 'client-ssl-disable'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-disable"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_sighup_enable() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt" \
		"client_tls_sslmode=disable"
	echo "host all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=disable" -c "select 'client-ssl-disable'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-disable"  tmp/test.tmp || return 1
	sed 's/client_tls_sslmode=disable/client_tls_sslmode=require/g' tmp/test.ini > tmp/test2.ini
	mv tmp/test2.ini tmp/test.ini
	kill -HUP `cat test.pid`
	sleep 1
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_sighup_change_ca() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = require" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt"
	echo "host all all 127.0.0.1/32 trust" > ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp || return 1
	sed 's/TestCA1/TestCA2/g' tmp/test.ini > tmp/test2.ini
	mv tmp/test2.ini tmp/test.ini
	kill -HUP `cat test.pid`
	sleep 1
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA2/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_auth() {
	reconf_bouncer "auth_type = cert" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = verify-full" \
		"client_tls_ca_file = TestCA1/ca.crt" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt"

	echo "host all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf 
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d "dbname=p0 sslmode=require sslkey=TestCA1/sites/02-bouncer.key sslcert=TestCA1/sites/02-bouncer.crt" \
		-c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_scram() {
	$pg_supports_scram || return 77

	reconf_bouncer "auth_type = scram-sha-256" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = require" \
		"client_tls_ca_file = TestCA1/ca.crt" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt"
	reconf_pgsql "ssl=on" "ssl_ca_file='root.crt'"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

testlist="
test_server_ssl
test_server_ssl_set_disable
test_server_ssl_set_enable
test_server_ssl_verify
test_server_ssl_pg_auth
test_client_ssl
test_client_ssl_verify
#test_client_ssl_set_disable
#test_client_ssl_set_enable
#test_client_ssl_set_change_ca
#test_client_ssl_reload_disable
#test_client_ssl_reload_enable
#test_client_ssl_reload_change_ca
#test_client_ssl_sighup_disable
#test_client_ssl_sighup_enable
#test_client_ssl_sighup_change_ca
test_client_ssl_auth
test_client_ssl_scram
"
if [ $# -gt 0 ]; then
	testlist="$*"
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
