"""
Test the "snabb lwaftr monitor" subcommand. Needs a NIC name and a TAP interface.

1. Execute "snabb lwaftr run" in on-a-stick mode and with the mirror option set.
2. Run "snabb lwaftr monitor" to set the counter and check its output.
"""

import unittest

from lib.test_env import (
    BENCHDATA_DIR, DATA_DIR, SNABB_CMD, BaseTestCase, nic_names, tap_name)


SNABB_PCI0 = nic_names()[0]
TAP_IFACE, tap_err_msg = tap_name()


@unittest.skipUnless(SNABB_PCI0, 'NIC not configured')
@unittest.skipUnless(TAP_IFACE, tap_err_msg)
class TestMonitor(BaseTestCase):

    daemon_args = (
        str(SNABB_CMD), 'lwaftr', 'run',
        '--name', 'monitor_test_daemon',
        '--bench-file', '/dev/null',
        '--conf', str(DATA_DIR / 'icmp_on_fail.conf'),
        '--on-a-stick', SNABB_PCI0,
        '--mirror', TAP_IFACE,
    )

    monitor_args = (
        str(SNABB_CMD), 'lwaftr', 'monitor',
        '--name', 'monitor_test',
        'all',
    )

    def test_monitor(self):
        output = self.run_cmd(self.monitor_args)
        self.assertIn('Mirror address set', output,
            "OUTPUT\n{}".format(output))
        self.assertIn('255.255.255.255', output,
            "OUTPUT\n{}".format(output))


if __name__ == '__main__':
    unittest.main()
