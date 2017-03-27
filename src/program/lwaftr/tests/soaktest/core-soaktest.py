import os
import subprocess
import sys
from test_list import tests

if os.getuid() != 0:
    sys.exit("This script must be run as root")

TEST_BASE = os.getenv("TEST_BASE")
TEST_OUT = "/tmp"
EMPTY = "../data/empty.pcap"
SNABB_BIN = "../../../../snabb"

DURATION = 1
if sys.argv[1:] and sys.argv[1]:
    DURATION = float(sys.argv[1])


def soaktest(conf, in_v4, in_v6):
    failmsg = " %s lwaftr soaktest -D %s %s %s %s" % \
        (SNABB_BIN, DURATION, conf, in_v4, in_v6)
    ret = subprocess.call(args=[SNABB_BIN, "lwaftr", "soaktest", "-D",
                                str(DURATION), conf, in_v4, in_v6])
    if ret:
        sys.exit(str(ret) + failmsg)

    ret = subprocess.call(args=[SNABB_BIN, "lwaftr", "soaktest", "-D",
                                str(DURATION), "--on-a-stick", conf, in_v4, in_v6])
    if ret:
        sys.exit(str(ret) + failmsg)

# Substitute "", a convenience when specifying tests, with empty.pcap
# Also, make all paths relative to a base test directory


def preprocess_test_args(test_base, args):
    prepped = []
    for arg in args[0:3]:
        if arg:
            prepped.append(test_base + '/' + arg)
        else:
            prepped.append(EMPTY)
    return prepped

for test in tests:
    print(test[0])  # the test name
    t = preprocess_test_args(TEST_BASE, test[1:])
    soaktest(t[0], t[1], t[2])

print("All lwAFTR soak tests passed.")
