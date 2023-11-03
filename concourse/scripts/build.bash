#!/bin/bash -l

set -ex
export HOME_DIR=$PWD

function install_dependencies() {
    case "$TARGET_OS" in
        "")
            echo TARGET_OS is undefined
            ;;
        centos*|photon*)
            yum update
            yum install -y pandoc
            ;;
        rhel8|oel8|rocky8)
            dnf update -y
            dnf install -y epel-release
            dnf install -y pandoc
            ;;
        sles*)
            zypper update
            zypper install -y pandoc
            ;;
        ubuntu*|debian*)
            apt update
            apt install -y pandoc
            library_path=$(ldconfig -p | grep libreadline.so.8)
            readline_path=$(echo "$library_path" | awk '{print $4}')
            ln -s $readline_path /usr/lib/libreadline.so.7
            ;;
        *)
            echo Unknown system: $TARGET_OS
            ;;
    esac
}

function build_pgbouncer() {
    pushd pgbouncer_src
    git submodule init
    git submodule update
    ./autogen.sh
    ./configure --prefix=${HOME_DIR}/bin_pgbouncer/ --enable-evdns --with-pam --with-openssl --with-ldap
    make install
    popd
}

function build_hba_test() {
    pushd pgbouncer_src/test
    make all
    popd
}

function init_platform() {
    case "$TARGET_OS" in
        "")
            export platform="unknown"
            ;;
        centos*)
            export platform=rhel${TARGET_OS: -1}
            ;;
        rhel8|oel8|rocky8) # Use one package for three platform
            export platform=el8
            ;;
        *)
            export platform=$TARGET_OS
            ;;
    esac
}

function build_tar_for_release() {
    init_platform
    if [ "x$platform" == "xunknown" ]; then
        return
    fi
    pushd pgbouncer_src
    cp concourse/scripts/install_gpdb_component ${HOME_DIR}/bin_pgbouncer/
    useradd gpadmin
    chown -R gpadmin:gpadmin ${HOME_DIR}/bin_pgbouncer/
    pgbouncer_tag=$(git describe --tags --abbrev=0)
    pgbouncer_version=${pgbouncer_tag#"pgbouncer_"}
    pgbouncer_version_dot=${pgbouncer_version//_/\.}

    tar -zcvf pgbouncer-gpdb7-${pgbouncer_version_dot}-${platform}_x86_64.tar.gz -C ${HOME_DIR}/bin_pgbouncer/ .
    popd
}

function _main() {
    install_dependencies
    build_pgbouncer
    build_tar_for_release
    build_hba_test
    cp -rf pgbouncer_src/* pgbouncer_compiled
}

_main "$@"
