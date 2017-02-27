"""
Test the "snabb lwaftr loadtest" subcommand. Needs NIC names.
"""

import unittest

from lib import sh
from lib.test_env import BENCHDATA_DIR, DATA_DIR, SNABB_CMD, nic_names


SNABB_PCI0, SNABB_PCI1 = nic_names()


@unittest.skipUnless(SNABB_PCI0 and SNABB_PCI1, 'NICs not configured')
class TestLoadtest(unittest.TestCase):

    run_cmd_args = (
        SNABB_CMD, 'lwaftr', 'run',
        '--bench-file', '/dev/null',
        '--conf', DATA_DIR / 'icmp_on_fail.conf',
        '--v4', SNABB_PCI0,
        '--v6', SNABB_PCI1,
    )

    loadtest_cmd_args = (
        SNABB_CMD, 'lwaftr', 'loadtest',
        '--bench-file', '/dev/null',
        '--program', 'ramp_up',
        '--step', '0.1e8',
        '--duration', '0.1',
        '--bitrate', '0.2e8',
        BENCHDATA_DIR / 'ipv4-0550.pcap', 'IPv4', 'IPv6', SNABB_PCI0,
        BENCHDATA_DIR / 'ipv6-0550.pcap', 'IPv6', 'IPv4', SNABB_PCI1,
    )

    # Use setUpClass to only setup the "run" daemon once for all tests.
    @classmethod
    def setUpClass(cls):
        cls.run_cmd = sh.sudo(*cls.run_cmd_args, _bg=True)

    def test_loadtest(self):
        output = sh.sudo(*self.loadtest_cmd_args)
        self.assertEqual(output.exit_code, 0)
        self.assert_(len(output.splitlines()) > 10)

    @classmethod
    def tearDownClass(cls):
        cls.run_cmd.terminate()


if __name__ == '__main__':
    unittest.main()
