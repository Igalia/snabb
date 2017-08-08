module(..., package.seeall)

local util  = require("apps.wall.util")
local const = require("apps.wall.constants")
local lib   = require("core.lib")
local bit   = require("bit")
local ffi   = require("ffi")

local rd16 = util.rd16
local ipv4_addr_cmp, ipv6_addr_cmp = util.ipv4_addr_cmp, util.ipv6_addr_cmp
local band = bit.band
local ETH_TYPE_IPv4         = const.ETH_TYPE_IPv4
local ETH_TYPE_IPv6         = const.ETH_TYPE_IPv6
local ETH_TYPE_VLAN         = const.ETH_TYPE_VLAN
local ETH_TYPE_OFFSET       = const.ETH_TYPE_OFFSET
local ETH_HEADER_SIZE       = const.ETH_HEADER_SIZE
local IPv4_PROTO_OFFSET     = const.IPv4_PROTO_OFFSET
local IPv4_SRC_ADDR_OFFSET  = const.IPv4_SRC_ADDR_OFFSET
local IPv4_DST_ADDR_OFFSET  = const.IPv4_DST_ADDR_OFFSET
local IPv4_PROTO_TCP        = const.IPv4_PROTO_TCP
local IPv4_PROTO_UDP        = const.IPv4_PROTO_UDP
local IPv6_NEXTHDR_OFFSET   = const.IPv6_NEXTHDR_OFFSET
local IPv6_SRC_ADDR_OFFSET  = const.IPv6_SRC_ADDR_OFFSET
local IPv6_DST_ADDR_OFFSET  = const.IPv6_DST_ADDR_OFFSET
local IPv6_NEXTHDR_HOPBYHOP = const.IPv6_NEXTHDR_HOPBYHOP
local IPv6_NEXTHDR_TCP      = const.IPv6_NEXTHDR_TCP
local IPv6_NEXTHDR_UDP      = const.IPv6_NEXTHDR_UDP
local IPv6_NEXTHDR_ROUTING  = const.IPv6_NEXTHDR_ROUTING
local IPv6_NEXTHDR_FRAGMENT = const.IPv6_NEXTHDR_FRAGMENT
local IPv6_NEXTHDR_AH       = const.IPv6_NEXTHDR_AH
local IPv6_NEXTHDR_NONE     = const.IPv6_NEXTHDR_NONE
local IPv6_NEXTHDR_DSTOPTS  = const.IPv6_NEXTHDR_DSTOPTS
local TCP_SRC_PORT_OFFSET   = const.TCP_SRC_PORT_OFFSET
local TCP_DST_PORT_OFFSET   = const.TCP_DST_PORT_OFFSET
local UDP_SRC_PORT_OFFSET   = const.UDP_SRC_PORT_OFFSET
local UDP_DST_PORT_OFFSET   = const.UDP_DST_PORT_OFFSET

swall_flow_key_ipv4_t = ffi.typeof([[
   struct {
      uint16_t vlan_id;
      uint8_t  __pad;
      uint8_t  ip_proto;
      uint8_t  lo_addr[4];
      uint8_t  hi_addr[4];
      uint16_t lo_port;
      uint16_t hi_port;
      uint16_t eth_type;
   } __attribute__((packed))
]])

swall_flow_key_ipv6_t = ffi.typeof([[
   struct {
      uint16_t vlan_id;
      uint8_t  __pad;
      uint8_t  ip_proto;
      uint8_t  lo_addr[16];
      uint8_t  hi_addr[16];
      uint16_t lo_port;
      uint16_t hi_port;
      uint16_t eth_type;
   } __attribute__((packed))
]])

local function flow_key_ipv4 ()
   return ffi.new(swall_flow_key_ipv4_t)
end

local the_flow_key_ipv4 = flow_key_ipv4()

local function flow_key_ipv6 ()
   return ffi.new(swall_flow_key_ipv6_t)
end

local the_flow_key_ipv6 = flow_key_ipv6()

-- Helper functions

--
-- Obtain the Internet Header Length (IHL) of an IPv4 packet, and return
-- its value converted to bytes.
--
local function ihl(p, offset)
   local ver_and_ihl = p.data[offset]
   return band(ver_and_ihl, 0x0F) * 4
end

--
-- Traverse an IPv6 header which has the following layout:
--
--     0         8        16
--     | NextHdr | HdrLen | ...
--
--  where "NextHdr" is the type code of the next header, and "HdrLen" is the
--  length of the header in 8-octet units, sans the first 8 octets.
--
local function ipv6_nexthdr_type_len_skip (p)
   return p[0], p + 8 + (p[1] * 8)
end

local ipv6_walk_header_funcs = {
   [IPv6_NEXTHDR_HOPBYHOP] = ipv6_nexthdr_type_len_skip,
   [IPv6_NEXTHDR_ROUTING]  = ipv6_nexthdr_type_len_skip,
   [IPv6_NEXTHDR_DSTOPTS]  = ipv6_nexthdr_type_len_skip,
   [IPv6_NEXTHDR_FRAGMENT] = function (p)
      return p[0], p + 8
   end,
   [IPv6_NEXTHDR_AH] = function (p)
      -- Size specified in 4-octet units (plus two octets).
      return p[0], p + 2 + (p[1] * 4)
   end,
}

--
-- Traverses all the IPv6 headers (using the "next header" fields) until an
-- upper-level protocol header (e.g. TCP, UDP) is found. The returned value
-- is the type of the upper level protocol code and pointer to the beginning
-- of the upper level protocol header data.
--
local function ipv6_walk_headers (p, offset)
   local ptr = p.data + offset
   local nexthdr = ptr[IPv6_NEXTHDR_OFFSET]
   while ipv6_walk_header_funcs[nexthdr] do
      local new_nexthdr, new_ptr = ipv6_walk_header_funcs[nexthdr](ptr)
      if new_ptr > p.data + p.length then
         break
      end
      nexthdr, ptr = new_nexthdr, new_ptr
   end
   return nexthdr, ptr
end


Scanner = subClass()
Scanner._name = "SnabbWall base packet Scanner"

function Scanner:extract_packet_info(p)
   local eth_type  = rd16(p.data + ETH_TYPE_OFFSET)
   local ip_offset = ETH_HEADER_SIZE
   local vlan_id   = 0

   while eth_type == ETH_TYPE_VLAN do
      vlan_id   = rd16(p.data + ip_offset)
      eth_type  = rd16(p.data + ip_offset + 2)
      ip_offset = ip_offset + 4
   end

   local key, src_addr, src_port, dst_addr, dst_port, ip_proto
   if eth_type == ETH_TYPE_IPv4 then
      key = the_flow_key_ipv4
      src_addr = p.data + ip_offset + IPv4_SRC_ADDR_OFFSET
      dst_addr = p.data + ip_offset + IPv4_DST_ADDR_OFFSET
      if ipv4_addr_cmp(src_addr, dst_addr) <= 0 then
         ffi.copy(key.lo_addr, src_addr, 4)
         ffi.copy(key.hi_addr, dst_addr, 4)
      else
         ffi.copy(key.lo_addr, dst_addr, 4)
         ffi.copy(key.hi_addr, src_addr, 4)
      end

      ip_proto = p.data[ip_offset + IPv4_PROTO_OFFSET]
      local ip_payload_offset = ip_offset + ihl(p, ip_offset)
      if ip_proto == IPv4_PROTO_TCP then
         src_port = rd16(p.data + ip_payload_offset + TCP_SRC_PORT_OFFSET)
         dst_port = rd16(p.data + ip_payload_offset + TCP_DST_PORT_OFFSET)
      elseif ip_proto == IPv4_PROTO_UDP then
         src_port = rd16(p.data + ip_payload_offset + UDP_SRC_PORT_OFFSET)
         dst_port = rd16(p.data + ip_payload_offset + UDP_DST_PORT_OFFSET)
      end
      key.eth_type = ETH_TYPE_IPv4
   elseif eth_type == ETH_TYPE_IPv6 then
      key = the_flow_key_ipv6
      src_addr = p.data + ip_offset + IPv6_SRC_ADDR_OFFSET
      dst_addr = p.data + ip_offset + IPv6_DST_ADDR_OFFSET
      if ipv6_addr_cmp(src_addr, dst_addr) <= 0 then
         ffi.copy(key.lo_addr, src_addr, 16)
         ffi.copy(key.hi_addr, dst_addr, 16)
      else
         ffi.copy(key.lo_addr, dst_addr, 16)
         ffi.copy(key.hi_addr, src_addr, 16)
      end

      local proto_header_ptr
      ip_proto, proto_header_ptr = ipv6_walk_headers (p, ip_offset)
      if ip_proto == IPv6_NEXTHDR_TCP then
         src_port = rd16(proto_header_ptr + TCP_SRC_PORT_OFFSET)
         dst_port = rd16(proto_header_ptr + TCP_DST_PORT_OFFSET)
      elseif ip_proto == IPv6_NEXTHDR_UDP then
         src_port = rd16(proto_header_ptr + UDP_SRC_PORT_OFFSET)
         dst_port = rd16(proto_header_ptr + UDP_DST_PORT_OFFSET)
      end
      key.eth_type = ETH_TYPE_IPv6
   else
      return nil
   end

   key.vlan_id = vlan_id
   key.ip_proto = ip_proto

   if src_port and dst_port then
      if src_port < dst_port then
         key.lo_port, key.hi_port = src_port, dst_port
      else
         key.lo_port, key.hi_port = dst_port, src_port
      end
   end

   return key, ip_offset, src_addr, src_port, dst_addr, dst_port
end

function Scanner:get_flow(p)
   error("method must be overriden in a subclass")
end

function Scanner:flows()
   error("method must be overriden in a subclass")
end

function Scanner:scan_packet(p, time)
   error("method must be overriden in a subclass")
end

function Scanner:protocol_name(protocol)
   return tostring(protocol)
end

function selftest()
   local ipv6 = require("lib.protocol.ipv6")
   local ipv4 = require("lib.protocol.ipv4")
   local cltable = require('lib.cltable')

   do -- Test comparison of IPv6 addresses
      assert(ipv6_addr_cmp(ipv6:pton("2001:fd::1"),
                           ipv6:pton("2001:fd::2")) <= 0)

      local a = ipv6:pton("2001:fd48::01")
      local b = ipv6:pton("2001:fd48::02")  -- Last byte differs
      local c = ipv6:pton("2002:fd48::01")  -- Second byte differs
      local d = ipv6:pton("2102:fd48::01")  -- First byte differs

      assert(ipv6_addr_cmp(a, a) == 0)
      assert(ipv6_addr_cmp(b, b) == 0)
      assert(ipv6_addr_cmp(c, c) == 0)
      assert(ipv6_addr_cmp(d, d) == 0)

      assert(ipv6_addr_cmp(a, b) < 0)
      assert(ipv6_addr_cmp(a, c) < 0)
      assert(ipv6_addr_cmp(a, d) < 0)

      assert(ipv6_addr_cmp(b, a) > 0)
      assert(ipv6_addr_cmp(b, c) < 0)
      assert(ipv6_addr_cmp(b, d) < 0)

      assert(ipv6_addr_cmp(c, a) > 0)
      assert(ipv6_addr_cmp(c, b) > 0)
      assert(ipv6_addr_cmp(c, d) < 0)
   end

   do -- Test hashing of IPv4 flow keys
      local function make_ipv4_key()
         local key = flow_key_ipv4()
         key.vlan_id = 10
         key.ip_proto = IPv4_PROTO_UDP
         ffi.copy(key.lo_addr, ipv4:pton("10.0.0.1"), 4)
         ffi.copy(key.hi_addr, ipv4:pton("10.0.0.2"), 4)
         key.lo_port = 8080
         key.hi_port = 1010
         return key
      end
      local cltab = cltable.new({key_type=swall_flow_key_ipv4_t})
      local k = make_ipv4_key()
      assert(not cltab[k])
      cltab[k] = 'hi'
      -- Return same value as keys produce same hash.
      assert(cltab[k] == cltab[make_ipv4_key()])
      -- Changing any value makes the hash vary.
      k.lo_port = 2020
      assert(not cltab[k])
      assert(cltab[make_ipv4_key()])
   end

   do -- Test hashing of IPv6 flow keys
      local function make_ipv6_key()
         local key = flow_key_ipv6()
         key.vlan_id = 42
         key.ip_proto = IPv6_NEXTHDR_TCP
         ffi.copy(key.lo_addr, ipv6:pton("2001:fd::1"), 16)
         ffi.copy(key.hi_addr, ipv6:pton("2001:fd::2"), 16)
         key.lo_port = 4040
         key.hi_port = 3030
         return key
      end
      local cltab = cltable.new({key_type=swall_flow_key_ipv6_t})
      local k = make_ipv6_key()
      assert(not cltab[k])
      cltab[k] = 'hi'
      -- Return same value as keys produce same hash.
      assert(cltab[k] == cltab[make_ipv6_key()])
      -- Changing any value makes the hash vary.
      k.lo_port = 2020
      assert(not cltab[k])
      assert(cltab[make_ipv6_key()])
   end

   do -- Test Scanner:extract_packet_info()
      local s = Scanner:new()

      local datagram = require("lib.protocol.datagram")
      local ethernet = require("lib.protocol.ethernet")
      local dg = datagram:new()
      dg:push(ipv6:new({ src = ipv6:pton("2001:fd::1"),
                         dst = ipv6:pton("2001:fd::2"),
                         next_header = IPv6_NEXTHDR_NONE }))
      dg:push(ethernet:new({ src = ethernet:pton("02:00:00:00:00:01"),
                             dst = ethernet:pton("02:00:00:00:00:02"),
                             type = lib.ntohs(ETH_TYPE_IPv6) }))

      local key, ip_offset, src_addr, src_port, dst_addr, dst_port =
            s:extract_packet_info(dg:packet())
      assert(key.vlan_id == 0)
      assert(key.ip_proto == IPv6_NEXTHDR_NONE)
      assert(ipv6_addr_cmp(key.lo_addr, ipv6:pton("2001:fd::1")) == 0)
      assert(ipv6_addr_cmp(key.hi_addr, ipv6:pton("2001:fd::2")) == 0)
      assert(key.lo_port == 0)
      assert(key.hi_port == 0)
   end

   print("selftest ok")
end
