#!/bin/bash -l

set -ex

export HOME_DIR=$PWD
CWDIR=$HOME_DIR/gpdb_src/concourse/scripts/
source "${CWDIR}/common.bash"

function setup_gpdb_cluster() {
    export TEST_OS=centos
    #export PGPORT=15432
    export CONFIGURE_FLAGS=" --with-openssl --with-ldap"
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
function install_openldap() {
    local os=""
    if [ -f /etc/redhat-release ];then
          os="centos"
    fi
    if [ x$os == "xcentos" ];then
        yum install -y openldap-servers openldap-clients
    else
        echo "Platform not support"
    fi
}

function _main(){
    #yum install -y sudo
    install_openldap
    setup_gpdb_cluster
    chown -R gpadmin:gpadmin pgbouncer_src
    echo "gpadmin ALL=(ALL)       NOPASSWD: ALL" >> /etc/sudoers
    cd pgbouncer_src/test
    su gpadmin -c "make check"
}

_main "$@"
