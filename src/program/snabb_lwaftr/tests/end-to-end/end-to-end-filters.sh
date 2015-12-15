#!/bin/bash

SNABB_LWAFTR=../../../../snabb-lwaftr
TEST_CONF=../data
TEST_DATA=../data
TEST_OUT=/tmp
EMPTY=../data/empty.pcap

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

function quit_with_msg {
   echo $1; exit 1
}

function scmp {
    if ! cmp $1 $2 ; then
        ls -l $1
        ls -l $2
        quit_with_msg "$3"
    fi
}

function snabb_run_and_cmp {
   rm -f ${TEST_OUT}/endoutv4.pcap ${TEST_OUT}/endoutv6.pcap
   if [ -z $5 ]; then
      echo "not enough arguments to snabb_run_and_cmp"
      exit 1
   fi
   ${SNABB_LWAFTR} check ${TEST_CONF}/binding.table \
      $1 $2 $3 ${TEST_OUT}/endoutv4.pcap ${TEST_OUT}/endoutv6.pcap || quit_with_msg \
        "Failure: ${SNABB_LWAFTR} check \
         ${TEST_CONF}/binding.table $1 $2 $3 \
         ${TEST_OUT}/endoutv4.pcap ${TEST_OUT}/endoutv6.pcap"
   scmp $4 ${TEST_OUT}/endoutv4.pcap \
    "Failure: ${SNABB_LWAFTR} check ${TEST_CONF}/binding.table $1 $2 $3 $4 $5"
   scmp $5 ${TEST_OUT}/endoutv6.pcap \
    "Failure: ${SNABB_LWAFTR} check ${TEST_CONF}/binding.table $1 $2 $3 $4 $5"
   echo "Test passed"
}

# Ingress filters

echo "Testing: ingress-filter: from-internet (IPv4) packet found in binding table (ACCEPT)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_accept.conf \
   ${TEST_DATA}/tcp-frominet-trafficclass.pcap ${EMPTY} \
   ${EMPTY} ${TEST_DATA}/tcp-afteraftr-ipv6-trafficclass.pcap

echo "Testing: ingress-filter: from-internet (IPv4) packet found in binding table (DROP)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_drop.conf \
   ${TEST_DATA}/tcp-frominet-trafficclass.pcap ${EMPTY} \
   ${EMPTY} ${EMPTY}

echo "Testing: ingress-filter: from-b4 (IPv6) packet found in binding table (ACCEPT)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_accept.conf \
   ${EMPTY} ${TEST_DATA}/tcp-fromb4-ipv6.pcap \
   ${TEST_DATA}/decap-ipv4.pcap ${EMPTY}

echo "Testing: ingress-filter: from-b4 (IPv6) packet found in binding table (DROP)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_drop.conf \
   ${EMPTY} ${TEST_DATA}/tcp-fromb4-ipv6.pcap \
   ${EMPTY} ${EMPTY}

# Egress filters

echo "Testing: egress-filter: to-internet (IPv4) (ACCEPT)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_accept.conf \
   ${EMPTY} ${TEST_DATA}/tcp-fromb4-ipv6.pcap \
   ${TEST_DATA}/decap-ipv4.pcap ${EMPTY}

echo "Testing: egress-filter: to-internet (IPv4) (DROP)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_drop.conf \
   ${EMPTY} ${TEST_DATA}/tcp-fromb4-ipv6.pcap \
   ${EMPTY} ${EMPTY}

echo "Testing: egress-filter: to-b4 (IPv4) (ACCEPT)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_accept.conf \
   ${TEST_DATA}/tcp-frominet-trafficclass.pcap ${EMPTY} \
   ${EMPTY} ${TEST_DATA}/tcp-afteraftr-ipv6-trafficclass.pcap

echo "Testing: egress-filter: to-b4 (IPv4) (DROP)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_drop.conf \
   ${TEST_DATA}/tcp-frominet-trafficclass.pcap ${EMPTY} \
   ${EMPTY} ${EMPTY}

# Ingress filters VLAN

TEST_DATA=../data/vlan

echo "Testing: ingress-filter: from-internet (IPv4) packet found in binding table (ACCEPT)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_accept_vlan.conf \
   ${TEST_DATA}/tcp-frominet-trafficclass.pcap ${EMPTY} \
   ${EMPTY} ${TEST_DATA}/tcp-afteraftr-ipv6-trafficclass.pcap

echo "Testing: ingress-filter: from-internet (IPv4) packet found in binding table (DROP)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_drop_vlan.conf \
   ${TEST_DATA}/tcp-frominet-trafficclass.pcap ${EMPTY} \
   ${EMPTY} ${EMPTY}

echo "Testing: ingress-filter: from-b4 (IPv6) packet found in binding table (ACCEPT)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_accept_vlan.conf \
   ${EMPTY} ${TEST_DATA}/tcp-fromb4-ipv6.pcap \
   ${TEST_DATA}/decap-ipv4.pcap ${EMPTY}

echo "Testing: ingress-filter: from-b4 (IPv6) packet found in binding table (DROP)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_drop_vlan.conf \
   ${EMPTY} ${TEST_DATA}/tcp-fromb4-ipv6.pcap \
   ${EMPTY} ${EMPTY}

# Egress filters VLAN

echo "Testing: egress-filter: to-internet (IPv4) (ACCEPT)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_accept_vlan.conf \
   ${EMPTY} ${TEST_DATA}/tcp-fromb4-ipv6.pcap \
   ${TEST_DATA}/decap-ipv4.pcap ${EMPTY}

echo "Testing: egress-filter: to-internet (IPv4) (DROP)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_drop_vlan.conf \
   ${EMPTY} ${TEST_DATA}/tcp-fromb4-ipv6.pcap \
   ${EMPTY} ${EMPTY}

echo "Testing: egress-filter: to-b4 (IPv4) (ACCEPT)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_accept_vlan.conf \
   ${TEST_DATA}/tcp-frominet-trafficclass.pcap ${EMPTY} \
   ${EMPTY} ${TEST_DATA}/tcp-afteraftr-ipv6-trafficclass.pcap

echo "Testing: egress-filter: to-b4 (IPv4) (DROP)"
snabb_run_and_cmp ${TEST_CONF}/no_icmp_with_filters_drop_vlan.conf \
   ${TEST_DATA}/tcp-frominet-trafficclass.pcap ${EMPTY} \
   ${EMPTY} ${EMPTY}

echo "All end-to-end lwAFTR tests passed."
