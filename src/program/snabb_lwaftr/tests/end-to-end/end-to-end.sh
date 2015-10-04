#!/bin/bash

snabb_lwaftr=../../../../snabb-lwaftr
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

function scmp {
    if ! cmp $1 $2 ; then
        ls -l $1
        ls -l $2
        quit_with_msg "$3"
    fi
}

function snabb_run_and_cmp {
   rm -f ${test_out}/endoutv4.pcap ${test_out}/endoutv6.pcap
   if [ -z $5 ]; then
      echo "not enough arguments to snabb_run_and_cmp"
      exit 1
   fi
   ${snabb_lwaftr} check ${test_base}/binding.table \
      $1 $2 $3 ${test_out}/endoutv4.pcap ${test_out}/endoutv6.pcap || quit_with_msg \
        "Failure: ${snabb_lwaftr} check \
         ${test_base}/binding.table $1 $2 $3 \
         ${test_out}/endoutv4.pcap ${test_out}/endoutv6.pcap"
   scmp $4 ${test_out}/endoutv4.pcap \
    "Failure: ${snabb_lwaftr} check ${test_base}/binding.table $1 $2 $3 $4 $5"
   scmp $5 ${test_out}/endoutv6.pcap \
    "Failure: ${snabb_lwaftr} check ${test_base}/binding.table $1 $2 $3 $4 $5"
   echo "Test passed"
}

echo "Testing: from-internet IPv4 packet found in the binding table."
snabb_run_and_cmp ${test_base}/icmp_on_fail.conf \
   ${test_base}/tcp-frominet-bound.pcap ${empty} \
   ${empty} ${test_base}/tcp-afteraftr-ipv6.pcap

echo "Testing: from-internet IPv4 packet found in the binding table with vlan tag."
snabb_run_and_cmp ${test_base}/vlan.conf \
   ${test_base}/tcp-frominet-bound-vlan.pcap ${empty} \
   ${empty} ${test_base}/tcp-afteraftr-ipv6-vlan.pcap

echo "Testing: traffic class mapping"
snabb_run_and_cmp ${test_base}/icmp_on_fail.conf \
   ${test_base}/tcp-frominet-trafficclass.pcap ${empty} \
   ${empty} ${test_base}/tcp-afteraftr-ipv6-trafficclass.pcap

echo "Testing: from-internet IPv4 packet found in the binding table, original TTL=1."
snabb_run_and_cmp ${test_base}/icmp_on_fail.conf \
   ${test_base}/tcp-frominet-bound-ttl1.pcap ${empty}\
   ${test_base}/icmpv4-time-expired.pcap ${empty}

echo "Testing: from-B4 IPv4 fragmentation (2)"
snabb_run_and_cmp ${test_base}/small_ipv4_mtu_icmp.conf \
   ${empty} ${test_base}/tcp-ipv6-fromb4-toinet-1046.pcap \
   ${test_base}/tcp-ipv4-toinet-2fragments.pcap ${empty}

echo "Testing: from-B4 IPv4 fragmentation (3)"
snabb_run_and_cmp ${test_base}/small_ipv4_mtu_icmp.conf \
   ${empty} ${test_base}/tcp-ipv6-fromb4-toinet-1500.pcap \
   ${test_base}/tcp-ipv4-toinet-3fragments.pcap ${empty}

echo "Testing: from-internet IPv4 packet found in the binding table, needs IPv6 fragmentation (2)."
snabb_run_and_cmp ${test_base}/small_ipv6_mtu_no_icmp.conf \
   ${test_base}/tcp-frominet-bound1494.pcap ${empty} \
   ${empty} ${test_base}/tcp-afteraftr-ipv6-2frags.pcap

echo "Testing: from-internet IPv4 packet found in the binding table, needs IPv6 fragmentation (3)."
snabb_run_and_cmp ${test_base}/small_ipv6_mtu_no_icmp.conf \
   ${test_base}/tcp-frominet-bound-2734.pcap ${empty} \
   ${empty} ${test_base}/tcp-afteraftr-ipv6-3frags.pcap

echo "Testing: IPv6 reassembly (followed by decapsulation)."
snabb_run_and_cmp ${test_base}/small_ipv6_mtu_no_icmp.conf \
   ${empty} ${test_base}/tcp-ipv6-2frags-bound.pcap \
   ${test_base}/tcp-ipv4-2ipv6frags-reassembled.pcap ${empty}

echo "Testing: from-internet IPv4 packet found in the binding table, needs IPv6 fragmentation, DF set, ICMP-3,4."
snabb_run_and_cmp ${test_base}/small_ipv6_mtu_no_icmp.conf \
   ${test_base}/tcp-frominet-bound1494-DF.pcap  ${empty} \
   ${test_base}/icmpv4-fromlwaftr-replyto-tcp-frominet-bound1494-DF.pcap ${empty}

echo "Testing: from-internet IPv4 packet NOT found in the binding table, no ICMP."
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${test_base}/tcp-frominet-unbound.pcap ${empty} \
   ${empty} ${empty}

echo "Testing: from-internet IPv4 packet NOT found in the binding table (ICMP-on-fail)."
snabb_run_and_cmp ${test_base}/icmp_on_fail.conf \
   ${test_base}/tcp-frominet-unbound.pcap ${empty} \
   ${test_base}/icmpv4-dst-host-unreachable.pcap ${empty}

echo "Testing: from-to-b4 IPv6 packet NOT found in the binding table, no ICMP."
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${test_base}/tcp-afteraftr-ipv6.pcap ${empty} \
   ${empty} ${empty}

echo "Testing: from-b4 to-internet IPv6 packet found in the binding table."
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-ipv6.pcap \
   ${test_base}/decap-ipv4.pcap ${empty}

echo "Testing: from-b4 to-internet IPv6 packet found in the binding table with vlan tag."
snabb_run_and_cmp ${test_base}/vlan.conf \
   ${empty} ${test_base}/tcp-fromb4-ipv6-vlan.pcap \
   ${test_base}/decap-ipv4-vlan.pcap ${empty}

echo "Testing: from-b4 to-internet IPv6 packet NOT found in the binding table, no ICMP"
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-ipv6-unbound.pcap \
   ${empty} ${empty}

echo "Testing: from-b4 to-internet IPv6 packet NOT found in the binding table (ICMP-on-fail)"
snabb_run_and_cmp ${test_base}/icmp_on_fail.conf \
   ${empty} ${test_base}/tcp-fromb4-ipv6-unbound.pcap \
   ${empty} ${test_base}/icmpv6-nogress.pcap

echo "Testing: from-to-b4 IPv6 packet, no hairpinning"
# The idea is that with hairpinning off, the packet goes out the inet interface
# and something else routes it back for re-encapsulation. It's not clear why
# this would be desired behaviour, but it's my reading of the RFC.
snabb_run_and_cmp ${test_base}/no_hairpin.conf \
   ${empty} ${test_base}/tcp-fromb4-tob4-ipv6.pcap \
   ${test_base}/decap-ipv4-nohair.pcap ${empty}

echo "Testing: from-to-b4 IPv6 packet, with hairpinning"
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-tob4-ipv6.pcap \
   ${empty} ${test_base}/recap-ipv6.pcap

echo "Testing: from-to-b4 IPv6 packet, with hairpinning, with vlan tag"
snabb_run_and_cmp ${test_base}/vlan.conf \
   ${empty} ${test_base}/tcp-fromb4-tob4-ipv6-vlan.pcap \
   ${empty} ${test_base}/recap-ipv6-vlan.pcap

echo "Testing: from-b4 IPv6 packet, with hairpinning, to B4 with custom lwAFTR address"
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-tob4-customBRIP-ipv6.pcap \
   ${empty} ${test_base}/recap-tocustom-BRIP-ipv6.pcap

echo "Testing: from-b4 IPv6 packet, with hairpinning, from B4 with custom lwAFTR address"
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-customBRIP-tob4-ipv6.pcap \
   ${empty} ${test_base}/recap-fromcustom-BRIP-ipv6.pcap

echo "Testing: from-b4 IPv6 packet, with hairpinning, different non-default lwAFTR addresses"
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${empty} ${test_base}/tcp-fromb4-customBRIP1-tob4-customBRIP2-ipv6.pcap \
   ${empty} ${test_base}/recap-customBR-IPs-ipv6.pcap

# Test UDP input

# Test ICMP inputs (with and without drop policy)
echo "Testing: incoming ICMPv4 echo request, matches binding table"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${test_base}/incoming-icmpv4-echo-request.pcap ${empty} \
   ${empty} ${test_base}/ipv6-tunneled-incoming-icmpv4-echo-request.pcap

echo "Testing: incoming ICMPv4 echo request, matches binding table"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${test_base}/incoming-icmpv4-echo-request-invalid-icmp-checksum.pcap ${empty} \
   ${empty} ${empty}

echo "Testing: incoming ICMPv4 echo request, matches binding table, dropping ICMP"
snabb_run_and_cmp ${test_base}/no_icmp.conf \
   ${test_base}/incoming-icmpv4-echo-request.pcap ${empty} \
   ${empty} ${empty}

echo "Testing: incoming ICMPv4 echo request, doesn't match binding table"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${test_base}/incoming-icmpv4-echo-request-unbound.pcap ${empty} \
   ${empty} ${empty}

echo "Testing: incoming ICMPv4 echo reply, matches binding table"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${test_base}/incoming-icmpv4-echo-reply.pcap ${empty} \
   ${empty} ${test_base}/ipv6-tunneled-incoming-icmpv4-echo-reply.pcap

echo "Testing: incoming ICMPv4 3,4 'too big' notification, matches binding table"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${test_base}/incoming-icmpv4-34toobig.pcap ${empty} \
   ${empty} ${test_base}/ipv6-tunneled-incoming-icmpv4-34toobig.pcap

echo "Testing: incoming ICMPv6 1,3 destination/address unreachable, OPE from internet"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${empty} ${test_base}/incoming-icmpv6-13dstaddressunreach-inet-OPE.pcap \
   ${test_base}/response-ipv4-icmp31-inet.pcap ${empty}

echo "Testing: incoming ICMPv6 2,0 'too big' notification, OPE from internet"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${empty} ${test_base}/incoming-icmpv6-20pkttoobig-inet-OPE.pcap \
   ${test_base}/response-ipv4-icmp34-inet.pcap ${empty}

echo "Testing: incoming ICMPv6 3,0 hop limit exceeded, OPE from internet"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${empty} ${test_base}/incoming-icmpv6-30hoplevelexceeded-inet-OPE.pcap \
   ${test_base}/response-ipv4-icmp31-inet.pcap ${empty}

echo "Testing: incoming ICMPv6 3,1 frag reasembly time exceeded, OPE from internet"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${empty} ${test_base}/incoming-icmpv6-31fragreassemblytimeexceeded-inet-OPE.pcap \
   ${empty} ${empty}

echo "Testing: incoming ICMPv6 4,3 parameter problem, OPE from internet"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${empty} ${test_base}/incoming-icmpv6-43paramprob-inet-OPE.pcap \
   ${test_base}/response-ipv4-icmp31-inet.pcap ${empty}

echo "Testing: incoming ICMPv6 3,0 hop limit exceeded, OPE hairpinned"
snabb_run_and_cmp ${test_base}/tunnel_icmp.conf \
   ${empty} ${test_base}/incoming-icmpv6-30hoplevelexceeded-hairpinned-OPE.pcap \
   ${empty} ${test_base}/response-ipv6-tunneled-icmpv4_31-tob4.pcap

echo "All end-to-end lwAFTR tests passed."
