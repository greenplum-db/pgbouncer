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

# python3 -m pytest ./test_admin.py::test_help
python3 -m pytest
