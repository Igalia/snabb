#!/usr/bin/env bash

TEST_DIR="./program/lwaftr/tests"
source ${TEST_DIR}/common.sh || exit $?

TEST_NAME="lwaftr run"

check_nics_available "$TEST_NAME"

echo "Testing ${TEST_NAME}"

function test_lwaftr_run {
    local log=`cat $1`
    local lineno=`cat $1 | wc -l`
    rm -f $1
    if [[ $lineno -lt 2 ]]; then
        echo -e $log
        exit_on_error "Error: log of lwaftr run is too short"
    fi
}

LWAFTR_CONF=${TEST_DIR}/data/icmp_on_fail.conf

./snabb lwaftr run --duration 1 --bench-file /dev/null \
    --conf ${LWAFTR_CONF} \
    --v4 $SNABB_PCI0 --v6 $SNABB_PCI1 &> lwaftr_run.log
assert_equal $? 0 "${TEST_NAME} failed with error code $?"
test_lwaftr_run lwaftr_run.log

./snabb lwaftr run --duration 1 --bench-file /dev/null --reconfigurable \
    --conf ${LWAFTR_CONF} \
    --v4 $SNABB_PCI0 --v6 $SNABB_PCI1 &> lwaftr_run.log
assert_equal $? 0 "${TEST_NAME} --reconfigurable failed with error code $?"
test_lwaftr_run lwaftr_run.log

exit 0
