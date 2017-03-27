#!/bin/sh
cd "`dirname \"$0\"`"
python3 ./soaktest.py
python3 ./soaktest-vlan.py
