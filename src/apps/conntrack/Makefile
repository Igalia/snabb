SHELL:=/bin/bash

SNABB_DIR=../..

check_tcp:
	sudo $(SNABB_DIR)/snabb snsh $(SNABB_DIR)/apps/conntrack/main.lua tests/techcrunch.pcap

check_udp:
	sudo $(SNABB_DIR)/snabb snsh $(SNABB_DIR)/apps/conntrack/main.lua tests/udp.pcap
