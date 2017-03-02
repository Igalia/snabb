"""
Environment support code for tests.
"""

import os
from pathlib import Path

from lib import sh


# Commands run under "sudo" run as root. The root's user PATH should not
# include "." (the current directory) for security reasons. If this is the
# case, when we run tests from the "src" directory (where the "snabb"
# executable is), the "snabb" executable will not be found by relative paths.
# Therefore we make all paths absolute.
TESTS_DIR = Path(os.environ['TESTS_DIR']).resolve()
DATA_DIR = TESTS_DIR / 'data'
COUNTERS_DIR = DATA_DIR / 'counters'
BENCHDATA_DIR = TESTS_DIR / 'benchdata'
SNABB_CMD = TESTS_DIR.parents[2] / 'snabb'
BENCHMARK_FILENAME = 'benchtest.csv'
# Snabb creates the benchmark file in the current directory
BENCHMARK_PATH = Path.cwd() / BENCHMARK_FILENAME


def nic_names():
    return os.environ.get('SNABB_PCI0'), os.environ.get('SNABB_PCI1')


def tap_name():
    """
    Return the first TAP interface name if one found: (tap_iface, None).
    Return (None, 'No TAP interface available') if none found.
    """
    output = sh.ip('tuntap', 'list')
    tap_iface = output.split(':')[0]
    if not tap_iface:
        return None, 'No TAP interface available'
    return tap_iface, None
