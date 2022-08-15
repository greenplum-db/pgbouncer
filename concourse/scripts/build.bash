#!/bin/bash -l

set -ex
export HOME_DIR=$PWD
# common.bash set up the compile enviroment
#CWDIR=$HOME_DIR/gpdb_src/concourse/scripts/
#source "${CWDIR}/common.bash"

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


function _main() {
    build_pgbouncer
    build_hba_test
    cp -rf pgbouncer_src/* pgbouncer_compiled
}

_main "$@"
