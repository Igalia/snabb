#!/bin/bash

snabb_base=../../../..
test_base=../data
test_out=/tmp
empty=${test_base}/empty.pcap

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

function quit_with_msg {
   echo $1; exit 1
}

function usage {
    quit_with_msg "Usage: benchmark-end-to-end <pcidev_v4> <pcidev_v6>"
}

pcidev_v4=$1
pcidev_v6=$2
if [ -z "$pcidev_v4" ] || [ -z "$pcidev_v6" ]; then
    usage
fi

function run_benchmark {
    local script=${snabb_base}/apps/lwaftr/benchmark.lua
    local binding_table=${test_base}/binding.table
    local conf=$1
    local pcap_file_v4=$2
    local pcap_file_v6=$3

    ${snabb_base}/snabb snsh $script $binding_table $conf $pcap_file_v4 $pcap_file_v6 $pcidev_v4 $pcidev_v6
}

echo "Benchmarking: from-internet IPv4 packet found in the binding table."
run_benchmark ${test_base}/icmp_on_fail.conf \
    ${test_base}/tcp-frominet-bound.pcap ${empty}

# Fail
# echo "Testing: from-internet IPv4 packet found in the binding table, original TTL=1."
# run_benchmark ${test_base}/icmp_on_fail.conf \
#     ${test_base}/tcp-frominet-bound-ttl1.pcap

echo "Benchmarking: from-internet IPv4 packet found in the binding table, needs IPv6 fragmentation."
run_benchmark ${test_base}/small_ipv6_mtu_no_icmp.conf \
   ${test_base}/tcp-frominet-bound1494.pcap ${empty}

echo "Benchmarking: from-internet IPv4 packet found in the binding table, needs IPv6 fragmentation, DF set, ICMP-3,4."
run_benchmark ${test_base}/small_ipv6_mtu_no_icmp.conf \
   ${test_base}/tcp-frominet-bound1494-DF.pcap ${empty}

# TODO: Returns 0 Mbps
# echo "Benchmarking: from-internet IPv4 packet NOT found in the binding table, no ICMP."
# run_benchmark ${test_base}/no_icmp.conf \
#    ${test_base}/tcp-frominet-unbound.pcap

# TODO: Fail
# echo "Benchmarking: from-internet IPv4 packet NOT found in the binding table (ICMP-on-fail)."
# run_benchmark ${test_base}/icmp_on_fail.conf \
#    ${test_base}/tcp-frominet-unbound.pcap

# TODO: Returns 0 Mpbs
# echo "Benchmarking: from-to-b4 IPv6 packet NOT found in the binding table, no ICMP."
# run_benchmark ${test_base}/no_icmp.conf \
# ${test_base}/tcp-afteraftr-ipv6.pcap

echo "Benchmarking: from-b4 to-internet IPv6 packet found in the binding table."
run_benchmark ${test_base}/no_icmp.conf \
    ${empty} ${test_base}/tcp-fromb4-ipv6.pcap

# TODO: Returns 0 Mbps
# echo "Benchmarking: from-b4 to-internet IPv6 packet NOT found in the binding table, no ICMP"
# run_benchmark ${test_base}/no_icmp.conf \
#    ${test_base}/tcp-fromb4-ipv6-unbound.pcap

# TODO: Returns 0 Mbps
echo "Benchmarking: from-b4 to-internet IPv6 packet NOT found in the binding table (ICMP-on-fail)"
run_benchmark ${test_base}/icmp_on_fail.conf \
    ${empty} ${test_base}/tcp-fromb4-ipv6-unbound.pcap

echo "Benchmarking: from-to-b4 IPv6 packet, no hairpinning"
run_benchmark ${test_base}/no_hairpin.conf \
   ${empty} ${test_base}/tcp-fromb4-tob4-ipv6.pcap

echo "Benchmarking: from-to-b4 IPv6 packet, with hairpinning"
run_benchmark ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-tob4-ipv6.pcap

echo "Benchmarking: from-b4 IPv6 packet, with hairpinning, to B4 with custom lwAFTR address"
run_benchmark ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-tob4-customBRIP-ipv6.pcap

echo "Benchmarking: from-b4 IPv6 packet, with hairpinning, from B4 with custom lwAFTR address"
run_benchmark ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-customBRIP-tob4-ipv6.pcap

echo "Benchmarking: from-b4 IPv6 packet, with hairpinning, different non-default lwAFTR addresses"
run_benchmark ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-customBRIP1-tob4-customBRIP2-ipv6.pcap

echo "All benchmarking tests run."
