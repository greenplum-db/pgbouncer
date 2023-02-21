#!/bin/bash -l

set -ex
export HOME_DIR=$PWD
CWDIR=$HOME_DIR/gpdb_src/concourse/scripts/
source "${CWDIR}/common.bash"

function build_pgbouncer() {
    cd pgbouncer_src
    git submodule init
    git submodule update
    ./autogen.sh
    ./configure
    make
    cd ..
    cp -R pgbouncer_src/*  pgbouncer_bin/
}


function _main() {
    build_pgbouncer
}

_main "$@"
