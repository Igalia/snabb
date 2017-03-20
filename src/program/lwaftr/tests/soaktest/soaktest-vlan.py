#!/usr/bin/env python3
import os
import subprocess
import sys

os.putenv("TEST_BASE", "../data/vlan")
args = sys.argv[1:]
args.insert(0, "./core-soaktest.py")
args.insert(0, "python3")
subprocess.call(args=args)
