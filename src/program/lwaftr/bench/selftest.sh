#!/usr/bin/env bash

TEST_DIR="./program/lwaftr/tests"
DATA_DIR="${TEST_DIR}/data"
BENCHDATA_DIR="${TEST_DIR}/benchdata"

source ${TEST_DIR}/common.sh

check_for_root

echo "Testing lwaftr bench"

./snabb lwaftr bench --duration 1 --bench-file /dev/null \
    ${DATA_DIR}/icmp_on_fail.conf \
    ${BENCHDATA_DIR}/ipv{4,6}-0550.pcap &> /dev/null
assert_equal $? 0 "lwaftr bench failed with error code $?"

./snabb lwaftr bench --reconfigurable --duration 1 --bench-file /dev/null \
    ${DATA_DIR}/icmp_on_fail.conf \
    ${BENCHDATA_DIR}/ipv{4,6}-0550.pcap &> /dev/null
assert_equal $? 0 "lwaftr bench --reconfigurable failed with error code $?"
