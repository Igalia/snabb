#!/usr/bin/env bash

TEST_DIR="./program/lwaftr/tests"
source ${TEST_DIR}/common.sh || exit $?

TEST_NAME="lwaftr run"

check_nics_available "$TEST_NAME"

echo "Testing ${TEST_NAME}"

LWAFTR_CONF=${TEST_DIR}/icmp_on_fail.conf

./snabb lwaftr run --duration 1 --bench-file bench.csv \
    --conf ${LWAFTR_CONF}
    --v4 $SNABB_PCI0 --v6 $SNABB_PCI1 &> /dev/null
assert_equal $? 0 "${TEST_NAME} failed with error code $?"
assert_file_exists ./bench.csv --remove

./snabb lwaftr run --duration 1 --bench-file bench.csv --reconfigurable \
    --conf ${LWAFTR_CONF} \
    --v4 $SNABB_PCI0 --v6 $SNABB_PCI1 &> /dev/null
assert_equal $? 0 "${TEST_NAME} --reconfigurable failed with error code $?"
assert_file_exists ./bench.csv --remove

exit 0
