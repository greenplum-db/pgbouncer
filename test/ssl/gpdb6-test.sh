#! /bin/sh

rm -rf TestCA1

which psql
if [ $? -ne 0 ]
then
	source /usr/local/greenplum-db-devel/greenplum_path.sh
	source ../../../gpdb_src/gpAux/gpdemo/gpdemo-env.sh
fi

(
./newca.sh TestCA1 C=QQ O=Org1 CN="TestCA1"
./newsite.sh TestCA1 localhost C=QQ O=Org1 L=computer OU=db
./newsite.sh TestCA1 bouncer C=QQ O=Org1 L=computer OU=Dev
./newsite.sh TestCA1 random C=QQ O=Org1 L=computer OU=Dev
) > /dev/null
#export LD_LIBRARY_PATH=/usr/local/pgsql/lib:$LD_LIBRARY_PATH
#export PATH=/usr/local/pgsql/bin:$PATH
export PGDATA=$MASTER_DATA_DIRECTORY
export PGHOST=localhost
export PGPORT=6667
export EF_ALLOW_MALLOC_0=1

mkdir -p tmp

BOUNCER_LOG=tmp/test.log
BOUNCER_INI=test.ini
BOUNCER_PID=tmp/test.pid
BOUNCER_PORT=`sed -n '/^listen_port/s/listen_port.*=[^0-9]*//p' $BOUNCER_INI`
BOUNCER_EXE="../../pgbouncer"

LOGDIR=tmp
NC_PORT=6668
PG_PORT=15432
PG_LOG=$LOGDIR/pg.log

################################
#  return code
################################
result=0

rm -f core
ulimit -c unlimited
for f in  tmp/test.pid; do
	test -f $f && { kill `cat $f` || true; }
done

mkdir -p $LOGDIR
rm -fr $BOUNCER_LOG $PG_LOG

if [ ! -d $${PGDATA} ]; then
	#sed -r -i "/unix_socket_director/s:.*(unix_socket_director.*=).*:\\1 '/tmp':" ${PGDATA}/postgresql.conf
	#echo "port = $PG_PORT" >> ${PGDATA}/postgresql.conf
	#echo "log_connections = on" >> ${PGDATA}/postgresql.conf
	#echo "log_disconnections = on" >> ${PGDATA}/postgresql.conf
	cp ${PGDATA}/postgresql.conf ${PGDATA}/postgresql.conf.orig
	cp ${PGDATA}/pg_hba.conf ${PGDATA}/pg_hba.conf.orig
	cp ${PGDATA}/pg_ident.conf ${PGDATA}/pg_ident.conf.orig
	cp -p TestCA1/sites/01-localhost.crt ${PGDATA}/server.crt
	cp -p TestCA1/sites/01-localhost.key ${PGDATA}/server.key
	cp -p TestCA1/ca.crt ${PGDATA}/root.crt

	echo '"bouncer" "zzz"' > tmp/userlist.txt

	chmod 600 ${PGDATA}/server.key
	chmod 600 tmp/userlist.txt
fi

echo "createdb"
psql -p $PG_PORT -l | grep p0 > /dev/null || {
	psql -p $PG_PORT -c "create user bouncer" template1
	createdb -p $PG_PORT p0
	createdb -p $PG_PORT p1
}

$BOUNCER_EXE -d $BOUNCER_INI
sleep 1

reconf_bouncer() {
	cp test.ini tmp/test.ini
	for ln in "$@"; do
		echo "$ln" >> tmp/test.ini
	done
	test -f tmp/test.pid && kill `cat tmp/test.pid`
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
	rm -f $BOUNCER_PID
}

die() {
	echo $@
	complete
	exit 1
}

admin() {
	psql -h /tmp -U pgbouncer pgbouncer -c "$@;" || die "Cannot contact bouncer!"
}

runtest() {
	echo -n "`date` running $1 ... "
	eval $1 >$LOGDIR/$1.log 2>&1
	if [ $? -eq 0 ]; then
		echo "ok"
	else
		result=1
		echo "FAILED"
	fi
	date >> $LOGDIR/$1.log

	# allow background processing to complete
	wait
	# start with fresh config
	kill -HUP `cat $BOUNCER_PID`
}

psql_pg() {
	psql -U bouncer -h 127.0.0.1 -p $PG_PORT "$@"
}

psql_bouncer() {
	PGUSER=bouncer psql "$@"

}

# server_lifetime
test_server_ssl() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = require" 
	echo "local all gpadmin ident" > ${PGDATA}/pg_hba.conf
	echo "hostssl all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "hostssl all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file = 'root.crt'" "ssl_cert_file = 'server.crt'" "ssl_key_file = 'server.key'"
	psql_bouncer -q -d p0 -c "select 'ssl-connect'" | tee tmp/test.tmp0
	grep -q "ssl-connect"  tmp/test.tmp0
	rc=$?
	return $rc
}

test_server_ssl_verify() {
	reconf_bouncer "auth_type = trust" \
		"server_tls_sslmode = verify-full" \
		"server_tls_ca_file = TestCA1/ca.crt"

	echo "local all gpadmin ident" > ${PGDATA}/pg_hba.conf
	echo "hostssl all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "hostssl all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file = 'root.crt'" "ssl_cert_file = 'server.crt'" "ssl_key_file = 'server.key'"
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

	echo "local all gpadmin ident" > ${PGDATA}/pg_hba.conf
	echo "host all gpadmin 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "host all gpadmin ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	echo "hostssl all all 127.0.0.1/32 cert" >> ${PGDATA}/pg_hba.conf
	echo "hostssl all all ::1/128 cert" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on" "ssl_ca_file = 'root.crt'" "ssl_cert_file = 'server.crt'" "ssl_key_file = 'server.key'"
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

	echo "local all gpadmin ident" > ${PGDATA}/pg_hba.conf
	echo "host all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "hostssl all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d "dbname=p0 sslmode=require" -c "select 'client-ssl-connect'" | tee tmp/test.tmp
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

test_client_ssl_ca() {
	reconf_bouncer "auth_type = trust" "server_tls_sslmode = prefer" \
		"client_tls_sslmode = require" \
		"client_tls_key_file = TestCA1/sites/01-localhost.key" \
		"client_tls_cert_file = TestCA1/sites/01-localhost.crt" \
		"client_tls_ca_file = TestCA1/sites/01-localhost.crt"

	echo "local all gpadmin ident" > ${PGDATA}/pg_hba.conf
	echo "host all all  127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d "dbname=p0 sslmode=verify-full sslrootcert=TestCA1/ca.crt" -c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
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

	echo "local all gpadmin ident" > ${PGDATA}/pg_hba.conf
	echo "host all all 127.0.0.1/32 trust" >> ${PGDATA}/pg_hba.conf 
	echo "host all all ::1/128 trust" >> ${PGDATA}/pg_hba.conf
	reconf_pgsql "ssl=on"
	psql_bouncer -q -d "dbname=p0 sslmode=require sslkey=TestCA1/sites/02-bouncer.key sslcert=TestCA1/sites/02-bouncer.crt" \
		-c "select 'client-ssl-connect'" | tee tmp/test.tmp 2>&1
	grep -q "client-ssl-connect"  tmp/test.tmp
	rc=$?
	return $rc
}

testlist="
test_server_ssl
test_server_ssl_verify
test_server_ssl_pg_auth
test_client_ssl
test_client_ssl_ca
test_client_ssl_auth
"
if [ $# -gt 0 ]; then
	testlist="$*"
fi

for test in $testlist
do
	runtest $test
done

complete
exit $result
# vim: sts=0 sw=8 noet nosmarttab:
