"""
Test the "snabb lwaftr run" subcommand. Needs NIC names.
"""

import unittest

from lib.test_env import DATA_DIR, SNABB_CMD, BaseTestCase, nic_names


SNABB_PCI0, SNABB_PCI1 = nic_names()


@unittest.skipUnless(SNABB_PCI0 and SNABB_PCI1, 'NICs not configured')
class TestRun(BaseTestCase):

    cmd_args = (
        str(SNABB_CMD), 'lwaftr', 'run',
        '--duration', '0.1',
        '--bench-file', '/dev/null',
        '--conf', str(DATA_DIR / 'icmp_on_fail.conf'),
        '--v4', SNABB_PCI0,
        '--v6', SNABB_PCI1,
    )

    def execute_run_test(self, cmd_args):
        output = self.run_cmd(cmd_args)
        self.assertLess(len(output.splitlines()), 1,
            "OUTPUT\n{}".format(output))

    def test_run_standard(self):
        self.execute_run_test(self.cmd_args)

    def test_run_reconfigurable(self):
        reconf_cmd_args = list(self.cmd_args)
        reconf_cmd_args.insert(3, '--reconfigurable')
        self.execute_run_test(reconf_cmd_args)


if __name__ == '__main__':
    unittest.main()
