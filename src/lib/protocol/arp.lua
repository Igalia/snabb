module(..., package.seeall)

-- RFC 826 (ARP) requests and replies.
-- Note: all incoming configurations are assumed to be in network byte order.

local ethernet = require("lib.protocol.ethernet")
local header = require("lib.protocol.header")
local packet = require("core.packet")

local ffi = require("ffi")
local C = ffi.C

--[[ Packet format (IPv4/Ethernet), as described on Wikipedia.

Internet Protocol (IPv4) over Ethernet ARP packet
octet offset 	0 	1
0 	Hardware type (HTYPE)
2 	Protocol type (PTYPE)
4 	Hardware address length (HLEN) 	Protocol address length (PLEN)
6 	Operation (OPER)
8 	Sender hardware address (SHA) (first 2 bytes)
10 	(next 2 bytes)
12 	(last 2 bytes)
14 	Sender protocol address (SPA) (first 2 bytes)
16 	(last 2 bytes)
18 	Target hardware address (THA) (first 2 bytes)
20 	(next 2 bytes)
22 	(last 2 bytes)
24 	Target protocol address (TPA) (first 2 bytes)
26 	(last 2 bytes)
--]]

local arp_header_t = ffi.typeof[[
   struct {
   uint16_t arp_htype;
   uint16_t arp_ptype;
   uint8_t arp_hlen;
   uint8_t arp_plen;
   uint16_t arp_oper;
   uint8_t arp_sha[6];
   uint8_t arp_spa[4];
   uint8_t arp_tha[6];
   uint8_t arp_tpa[4];
   } __attribute__((packed))
]]

local arp = subClass(header)
-- ARP class variables
arp._name = "arp"
arp._header_type = arp_header_t
arp._header_ptr_type = ffi.typeof("$*", arp_header_t)
arp._ulp = { method = nil }

-- Constants
local arp_request = C.htons(1)
local arp_reply = C.htons(2)

local unknown_eth = ethernet:pton("00:00:00:00:00:00")

local ethernet_htype = C.htons(1)
local ipv4_ptype = C.htons(0x0800)
local ethernet_hlen = 6
local ipv4_plen = 4

--local function make_arp_packet(l_eth, l_ip, r_eth, r_ip, opcode)
function arp:new (config)
   local o = arp:superClass().new(self)
   local h = o:header()
   h.arp_htype = ethernet_htype
   h.arp_ptype = ipv4_ptype
   h.arp_hlen = ethernet_hlen
   h.arp_plen = ipv4_plen
   h.arp_oper = config.oper
   ffi.copy(h.arp_sha, config.local_eth, ethernet_hlen)
   h.arp_spa = config.local_ipv4
   ffi.copy(h.arp_tha, config.remote_eth, ethernet_hlen)
   h.arp_tpa = config.remote_ipv4
   return o
end

function arp:new_request(local_eth, local_ipv4, remote_ipv4)
   return arp:new({local_eth = local_eth, local_ipv4 = local_ipv4,
                   remote_eth = unknown_eth, remote_ipv4 = remote_ipv4,
                   oper = arp_request})
end

function arp:new_reply(local_eth, local_ipv4, remote_eth, remote_ipv4)
   return arp:new({local_eth = local_eth, local_ipv4 = local_ipv4,
                   remote_eth = remote_eth, remote_ipv4 = remote_ipv4,
                   oper = arp_reply})
end

function selftest()
   local ipv4 = require("lib.protocol.ipv4")
   local tlocal_eth = ethernet:pton("01:02:03:04:05:06")
   local tlocal_ip = ipv4:pton("1.2.3.4")
   local tremote_ip = ipv4:pton("6.7.8.9")
   local a = arp:new_request(tlocal_eth, tlocal_ip, tremote_ip)
   local h = a:header()
   assert(h.arp_plen == ipv4_plen)
   assert(C.memcmp(h.arp_sha, tlocal_eth, ethernet_hlen) == 0)
end

arp.selftest = selftest
return arp
