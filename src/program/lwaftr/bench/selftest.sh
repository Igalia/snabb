#!/usr/bin/env bash

TEST_DIR="./program/lwaftr/tests"
source ${TEST_DIR}/common.sh || exit $?

TEST_NAME="lwaftr bench"

echo "Testing ${TEST_NAME}"

DATA_DIR="${TEST_DIR}/data"
BENCHDATA_DIR="${TEST_DIR}/benchdata"

./snabb lwaftr bench --duration 1 --bench-file bench.csv \
    ${DATA_DIR}/icmp_on_fail.conf \
    ${BENCHDATA_DIR}/ipv{4,6}-0550.pcap &> /dev/null
assert_equal $? 0 "${TEST_NAME} failed with error code $?"
assert_file_exists ./bench.csv --remove

./snabb lwaftr bench --duration 1 --bench-file bench.csv --reconfigurable \
    ${DATA_DIR}/icmp_on_fail.conf \
    ${BENCHDATA_DIR}/ipv{4,6}-0550.pcap &> /dev/null
assert_equal $? 0 "${TEST_NAME} --reconfigurable failed with error code $?"
assert_file_exists ./bench.csv --remove

exit 0
