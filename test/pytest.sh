#!/usr/bin/env bash

# Notes:
# - uses iptables and -F with some tests, probably not very friendly to your firewall

# cd $(dirname $0)

# set up gpdb source env
### START ###
source /usr/local/greenplum-db-devel/greenplum_path.sh
source ../../gpdb_src/gpAux/gpdemo/gpdemo-env.sh

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
export BOUNCER_PORT=`sed -n '/^listen_port/s/listen_port.*=[^0-9]*//p' $BOUNCER_INI`
BOUNCER_EXE="$BOUNCER_EXE_PREFIX ../pgbouncer"

BOUNCER_ADMIN_HOST=/tmp

LOGDIR=log
NC_PORT=6668
## PG_PORT=6666
## PG_LOG=$LOGDIR/pg.log

ulimit -c unlimited

# The tests require that psql can connect to the PgBouncer admin
# console.  On platforms that have getpeereid(), this works by
# connecting as user pgbouncer over the Unix socket.  On other
# platforms, we have to rely on "trust" authentication, but then we
# have to skip any tests that use authentication methods other than
# "trust".
case `uname` in
	MINGW*)
		use_unix_sockets=false
		;;
	*)
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

if ! $use_unix_sockets; then
	## BOUNCER_ADMIN_HOST=/tmp
	BOUNCER_ADMIN_HOST=127.0.0.1

	cp test.ini test.ini.bak
	## echo "unix_socket_dir = ''" >> test.ini
	sed -i 's/^unix_socket_dir =/#&/' test.ini
	echo 'admin_users = pgbouncer' >> test.ini
fi

# System configuration checks
if ! grep -q "^\"${USER:=$(id -un)}\"" userlist.txt; then
	cp userlist.txt userlist.txt.bak
	echo "\"${USER}\" \"01234\"" >> userlist.txt
	echo "\"longpass\" \"${long_password}\"" >> userlist.txt
	echo "\"ldapuser1\" \"123456\"" >> userlist.txt
fi

if $use_unix_sockets; then
	sed $SED_ERE_OP -i "/unix_socket_director/s:.*(unix_socket_director.*=).*:\\1 '/tmp':" ${PGDATA}/postgresql.conf
fi


cat >>${PGDATA}/postgresql.conf <<-EOF
logging_collector = off
log_destination = stderr
log_connections = on
EOF
if $use_unix_sockets; then
    local='local'
else
    local='#local'
fi
if $pg_supports_scram; then
	cat >${PGDATA}/pg_hba.conf <<-EOF
	$local  p6   all                scram-sha-256
	host   p6   all  127.0.0.1/32  scram-sha-256
	host   p6   all  ::1/128       scram-sha-256
	EOF
else
	cat >${PGDATA}/pg_hba.conf </dev/null
fi
cat >>${PGDATA}/pg_hba.conf <<-EOF
$local  p4   all                password
host   p4   all  127.0.0.1/32  password
host   p4   all  ::1/128       password
$local  p5   all                md5
host   p5   all  127.0.0.1/32  md5
host   p5   all  ::1/128       md5
$local  all  all                trust
host   all  all  127.0.0.1/32  trust
host   all  all  ::1/128       trust
EOF
gpstop -u
if ! $use_unix_sockets; then
	sed -i 's/^local/#local/' pgdata/pg_hba.conf
fi


# python3 -m pytest ./test_admin.py::test_help
# python3 -m pytest ./test_auth.py
python3 -m pytest
