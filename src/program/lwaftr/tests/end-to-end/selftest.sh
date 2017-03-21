#!/bin/sh
cd "`dirname \"$0\"`"
python3 ./end-to-end.py
python3 ./end-to-end-vlan.py
