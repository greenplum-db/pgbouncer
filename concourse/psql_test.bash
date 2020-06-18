#!/bin/bash -l

set -ex

export HOME_DIR=$PWD
CWDIR=$HOME_DIR/gpdb_src/concourse/scripts/
source "${CWDIR}/common.bash"

function setup_gpdb_cluster() {
    export TEST_OS=centos
    export PGPORT=15432
    export CONFIGURE_FLAGS=" --with-openssl"
    if [ ! -f "bin_gpdb/bin_gpdb.tar.gz" ];then
        mv bin_gpdb/*.tar.gz bin_gpdb/bin_gpdb.tar.gz
    fi

    if [ "$(type -t install_and_configure_gpdb)" = "function" ] ; then
        time install_and_configure_gpdb
    else
        # gpdb5 doesn't have function install_add_configure_gpdb
        time configure
        time install_gpdb
    fi
    time ${HOME_DIR}/gpdb_src/concourse/scripts/setup_gpadmin_user.bash "$TEST_OS"
    export WITH_MIRRORS=false
    time make_cluster
    . /usr/local/greenplum-db-devel/greenplum_path.sh
    . gpdb_src/gpAux/gpdemo/gpdemo-env.sh
}

function _main(){
	yum erase libevent-devel -y
	yum install libevent2-devel -y
    yum install -y sudo
    setup_gpdb_cluster
    chown -R gpadmin:gpadmin pgbouncer_src
    echo "gpadmin ALL=(ALL)       NOPASSWD: ALL" >> /etc/sudoers
    cd pgbouncer_src/test
    su  gpadmin -c "./test.sh"
    su  gpadmin -c "make all"
    cd ssl
    su gpadmin -c "./test.sh"
}

_main "$@"
