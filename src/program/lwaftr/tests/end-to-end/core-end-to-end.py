import os
import subprocess
import sys
from test_list import tests

if os.getuid() != 0:
    sys.exit("This script must be run as root")

REGEN = False

TEST_BASE = os.getenv("TEST_BASE")
COUNTERS = "../data/counters"
EMPTY = "../data/empty.pcap"
TEST_OUT = "/tmp"
SNABB_BIN = "../../../../snabb"

# TODO: refactor this to not be global; it's aping the original bash
if sys.argv[1:] and sys.argv[1] == '-r':
    REGEN = True


def scmp(file1, file2, err):
    if subprocess.call(args=["cmp", file1, file2]):
        subprocess.run(args=["ls", "-l", file1])
        subprocess.run(args=["ls", "-l", file2])
        sys.exit(err)


def snabb_run_and_cmp_two_interfaces(conf, v4_in, v6_in, v4_out, v6_out, counters_path):
    endoutv4 = TEST_OUT + "/endoutv4.pcap"
    endoutv6 = TEST_OUT + "/endoutv6.pcap"
    failmsg = "Failure: %s lwaftr check %s" % (SNABB_BIN, " ".join(sys.argv))
    subprocess.call(args=["rm", "-f", endoutv4, endoutv6])
    if subprocess.call(args=[SNABB_BIN, "lwaftr", "check", conf, v4_in, v6_in, endoutv4,
                             endoutv6, counters_path]):
        sys.exit(failmsg)
    scmp(v4_out, endoutv4, failmsg)
    scmp(v6_out, endoutv6, failmsg)
    print("Test passed")


def snabb_run_and_regen_counters(conf, v4_in, v6_in, v4_out, v6_out, counters_path):
    endoutv4 = TEST_OUT + "/endoutv4.pcap"
    endoutv6 = TEST_OUT + "/endoutv6.pcap"
    failmsg = "Failed to regen counters:\n\t: %s lwaftr check %s" % (
        SNABB_BIN, " ".join(sys.argv))
    subprocess.call(args=["rm", "-f", endoutv4, endoutv6])
    if subprocess.call(args=[SNABB_BIN, "lwaftr", "check", '-r', conf, v4_in, v6_in,
                             endoutv4, endoutv6, counters_path]):
        sys.exit(failmsg)
    print("Regenerated counters")


def is_packet_in_wrong_interface_test(cp):
    return (cp == COUNTERS + "/non-ipv6-traffic-to-ipv6-interface.lua") \
        or (cp == COUNTERS + "/non-ipv4-traffic-to-ipv4-interface.lua")


def snabb_run_and_cmp_on_a_stick(conf, v4_in, v6_in, v4_out, v6_out, counters_path):
    endoutv4 = TEST_OUT + "/endoutv4.pcap"
    endoutv6 = TEST_OUT + "/endoutv6.pcap"
    failmsg = "Failure: %s lwaftr check --on-a-stick %s" % (
        SNABB_BIN, " ".join(sys.argv))
    # Skip these tests as they will fail in on-a-stick mode.
    if is_packet_in_wrong_interface_test(counters_path):
        print("Test skipped")
        return
    subprocess.call(args=["rm", "-f", endoutv4, endoutv6])
    if subprocess.call(args=[SNABB_BIN, "lwaftr", "check", "--on-a-stick", conf, v4_in,
                             v6_in, endoutv4, endoutv6, counters_path]):
        sys.exit(failmsg)
    scmp(v4_out, endoutv4, failmsg)
    scmp(v6_out, endoutv6, failmsg)
    print("Test passed")


def snabb_run_and_cmp(conf, v4_in, v6_in, v4_out, v6_out, counters_path):
    if not counters_path:
        sys.exit("not enough arguments to snabb_run_and_cmp")

    if REGEN:
        snabb_run_and_regen_counters(
            conf, v4_in, v6_in, v4_out, v6_out, counters_path)
    else:
        snabb_run_and_cmp_two_interfaces(
            conf, v4_in, v6_in, v4_out, v6_out, counters_path)
        snabb_run_and_cmp_on_a_stick(
            conf, v4_in, v6_in, v4_out, v6_out, counters_path)

# Substitute "", a convenience when specifying tests, with empty.pcap
# Also, make all paths relative to a base test directory
# Counter paths, the last argument, are instead relative to the counters dir


def preprocess_test_args(test_base, args):
    prepped = []
    for arg in args[:-1]:
        if arg:
            prepped.append(test_base + '/' + arg)
        else:
            prepped.append(EMPTY)
    prepped.append(COUNTERS + '/' + args[-1])
    return prepped

for test in tests:
    print(test[0])  # the test name
    t = preprocess_test_args(TEST_BASE, test[1:])
    snabb_run_and_cmp(t[0], t[1], t[2], t[3], t[4], t[5])

print("All end-to-end lwAFTR tests passed.")
