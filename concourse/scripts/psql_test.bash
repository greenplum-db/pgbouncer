#!/bin/bash -l

set -ex

export HOME_DIR=$PWD
CWDIR=$HOME_DIR/gpdb_src/concourse/scripts/
source "${CWDIR}/common.bash"

function init_os() {
    case "$TARGET_OS" in
        centos*|rhel*)
            export TEST_OS=centos
            ;;
        photon*)
            export TEST_OS=photon
            ;;
        ubuntu*)
            export TEST_OS=ubuntu
            ;;
        *) export TEST_OS=$TARGET_OS
            ;;
    esac
}

function install_dependencies() {
    case "$TARGET_OS" in
        "")
            echo TARGET_OS is undefined
            ;;
        centos*|photon*)
            ;;
        rhel8|oel8|rocky8)
            ;;
        sles*)
            ;;
        ubuntu*|debian*)
            library_path=$(ldconfig -p | grep libreadline.so.8)
            readline_path=$(echo "$library_path" | awk '{print $4}')
            if [ ! -e /usr/lib/libreadline.so.7 ]; then
                ln -s $readline_path /usr/lib/libreadline.so.7
            fi
            ;;
        *)
            echo Unknown system: $TARGET_OS
            ;;
    esac
}

function setup_gpdb_cluster() {
    init_os
    export CONFIGURE_FLAGS=" --with-openssl --with-ldap"
    if [ ! -f "bin_gpdb/bin_gpdb.tar.gz" ];then
        mv bin_gpdb/*.tar.gz bin_gpdb/bin_gpdb.tar.gz
    fi

    time install_and_configure_gpdb

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
    if [[ $TARGET_OS == "ubuntu"* ]];then
        os="debian"
    fi
    if [ $TARGET_OS = "rocky8" ];then
        dnf update -y
        wget -q https://repo.symas.com/configs/SOFL/rhel8/sofl.repo -O /etc/yum.repos.d/sofl.repo
        dnf install symas-openldap-clients symas-openldap-servers -y
    elif [ x$os == "xcentos" ];then
        yum install -y openldap-servers openldap-clients
    elif [ x$os == "xdebian" ];then
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        echo -e '\n\n' | apt install -y slapd ldap-utils libldap2-dev
        unset DEBIAN_FRONTEND
    else
        echo "Platform not support"
    fi
}

function _main(){
    install_dependencies
    install_openldap
    setup_gpdb_cluster
    chown -R gpadmin:gpadmin pgbouncer_src
    echo "gpadmin ALL=(ALL)       NOPASSWD: ALL" >> /etc/sudoers
    cd pgbouncer_src/test
    su gpadmin -c "make check"
}

_main "$@"
