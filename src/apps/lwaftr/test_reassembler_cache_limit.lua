-- Allow both importing this script as a module and running as a script
if type((...)) == "string" then module(..., package.seeall) end

local ipv4_apps = require("apps.lwaftr.ipv4_apps")
local ipv6_apps = require("apps.lwaftr.ipv6_apps")
local constants = require("apps.lwaftr.constants")
local lwutil = require("apps.lwaftr.lwutil")

local ethernet = require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local packet = require("core.packet")
local link = require("core.link")

local bit = require("bit")
local ffi = require("ffi")

local flag_more_fragments_mask = 0x2000
local frag_offset_field_mask   = 0x1FFF


local function make_fragment_base(ethertype, upper_size, payload_size)
   local pkt = packet.allocate()
   pkt.length = ethernet:sizeof() + upper_size + payload_size
   ffi.fill(pkt.data, ethernet:sizeof() + upper_size)

   -- Ethernet header. The leading bits of the MAC addresses are those for
   -- "Intel Corp" devices, the rest are arbitrary.
   local eth = ethernet:new_from_mem(pkt.data, ethernet:sizeof())
   eth:src(ethernet:pton("5c:51:4f:8f:aa:ee"))
   eth:dst(ethernet:pton("5c:51:4f:8f:aa:ef"))
   eth:type(ethertype)

   return pkt
end

local function make_fragment_ipv4(src, dst, frag_id, frag_offset, more_frags, payload_size)
   assert(frag_offset % 8 == 0)

   local pkt = make_fragment_base(constants.ethertype_ipv4, ipv4:sizeof(), payload_size)
   local ip = ipv4:new_from_mem(pkt.data + ethernet:sizeof(), ipv4:sizeof())

   ip:version(4)
   ip:ihl(ipv4:sizeof() / 4)
   ip:total_length(ipv4:sizeof() + payload_size)
   ip:ttl(15)
   ip:protocol(0xFF)
   ip:src(ipv4:pton(src))
   ip:dst(ipv4:pton(dst))
   ip:frag_off(frag_offset / 8)
   if more_frags then
      ip:flags(0x1)
   end
   ip:checksum()
   return pkt
end

local function make_fragment_ipv6(src, dst, frag_id, frag_offset, more_frags, payload_size)
   assert(frag_offset % 8 == 0)
   frag_offset = bit.lshift(frag_offset / 8, 3)
   if more_frags then
      frag_offset = bit.bor(frag_offset, 0x1)
   end

   local pkt = make_fragment_base(constants.ethertype_ipv6,
                                  constants.ipv6_fixed_header_size + constants.ipv6_frag_header_size,
                                  payload_size)
   local ip = ipv6:new_from_mem(pkt.data + ethernet:sizeof(), constants.ipv6_fixed_header_size)

   ip:version(6)
   ip:payload_length(payload_size + constants.ipv6_frag_header_size)
   ip:next_header(constants.ipv6_frag)
   ip:hop_limit(15)
   ip:src(ipv6:pton(src))
   ip:dst(ipv6:pton(dst))

   pkt.data[ethernet:sizeof() + constants.ipv6_fixed_header_size + 0] = constants.proto_tcp
   lwutil.wr16(pkt.data + ethernet:sizeof() + constants.ipv6_fixed_header_size + 2, lwutil.htons(frag_offset))
   lwutil.wr32(pkt.data + ethernet:sizeof() + constants.ipv6_fixed_header_size + 4, lwutil.htonl(frag_id))

   return pkt
end

local function make_reassembler(ip_apps)
   local i = link.new("testinput")
   local o = link.new("testoutput")
   local r = ip_apps.Reassembler:new { fragment_cache_max = 2 }
   r.input, r.output = { input = i }, { output = o }
   function r:push_packet(pkt)
      link.transmit(self.input.input, pkt)
      self:push()
   end
   function r:pull_packet()
      return link.receive(self.output.output)
   end
   function r:finish()
      link.free(self.input.input, "testinput")
      link.free(self.output.output, "testoutput")
   end
   return r
end

function test_ipv4_assemble()
   print("IPv4 Reassembler ok no cache eviction")

   local r = assert(make_reassembler(ipv4_apps))
   assert(r.fragment_count == 0)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.10.0.1", "10.10.0.2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.10.0.1", "10.10.0.2", 1, 16, false, 16))
   assert(r.fragment_count == 0)

   assert(link.nreadable(r.output.output) == 1)
   local p = assert(r:pull_packet())
   assert(p.length == ethernet:sizeof() + ipv4:sizeof() + 32)

   r:finish()
end

function test_ipv4_evict()
   print("IPv4 Reassembler cache eviction")

   local r = assert(make_reassembler(ipv4_apps))
   assert(r.fragment_count == 0)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.10.0.1", "10.10.0.2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.20.0.1", "10.20.0.2", 2, 0, true, 16))
   assert(r.fragment_count == 2)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.30.0.1", "10.30.0.2", 3, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:finish()
end

function test_ipv4_evict_same_flow()
   print("IPv4 Reassembler: same flow packets cache eviction")

   local r = assert(make_reassembler(ipv4_apps))
   assert(r.fragment_count == 0)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.0.0.1", "10.0.0.2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.0.0.1", "10.0.0.2", 1, 16, true, 16))
   assert(r.fragment_count == 2)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.0.0.1", "10.0.0.2", 1, 32, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:finish()
end

function test_ipv4_evict_then_assemble()
   print("IPv4 Reassembler: same flow packets cache eviction, then reassembly")

   local r = assert(make_reassembler(ipv4_apps))
   assert(r.fragment_count == 0)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.0.0.1", "10.0.0.2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.0.0.1", "10.0.0.2", 1, 16, true, 16))
   assert(r.fragment_count == 2)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.0.0.1", "10.0.0.2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv4("10.0.0.1", "10.0.0.2", 1, 16, false, 16))
   assert(r.fragment_count == 0)

   assert(link.nreadable(r.output.output) == 1)
   local p = assert(r:pull_packet())
   assert(p.length == ethernet:sizeof() + ipv4:sizeof() + 32)

   r:finish()
end

function test_ipv6_assemble()
   print("IPv6 Reassembler ok no cache eviction")

   local r = assert(make_reassembler(ipv6_apps))
   assert(r.fragment_count == 0)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 16, false, 16))
   assert(r.fragment_count == 0)

   assert(link.nreadable(r.output.output) == 1)
   local p = assert(r:pull_packet())
   assert(p.length == ethernet:sizeof() + constants.ipv6_fixed_header_size + 32)

   r:finish()
end

function test_ipv6_evict()
   print("IPv6 Reassembler cache eviction")

   local r = assert(make_reassembler(ipv6_apps))
   assert(r.fragment_count == 0)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2002::1", "2002::2", 2, 0, true, 16))
   assert(r.fragment_count == 2)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2003::1", "2003::2", 3, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:finish()
end

function test_ipv6_evict_same_flow()
   print("IPv6 Reassembler: same flow packets cache eviction")

   local r = assert(make_reassembler(ipv6_apps))
   assert(r.fragment_count == 0)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 16, true, 16))
   assert(r.fragment_count == 2)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 32, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:finish()
end

function test_ipv6_evict_then_assemble()
   print("IPv6 Reassembler: same flow packets cache eviction, then reassembly")

   local r = assert(make_reassembler(ipv6_apps))
   assert(r.fragment_count == 0)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 16, true, 16))
   assert(r.fragment_count == 2)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 0, true, 16))
   assert(r.fragment_count == 1)
   assert(link.empty(r.output.output))

   r:push_packet(make_fragment_ipv6("2001::1", "2001::2", 1, 16, false, 16))
   assert(r.fragment_count == 0)

   assert(link.nreadable(r.output.output) == 1)
   local p = assert(r:pull_packet())
   assert(p.length == ethernet:sizeof() + constants.ipv6_fixed_header_size + 32)

   r:finish()
end

function selftest()
   test_ipv4_assemble()
   test_ipv4_evict()
   test_ipv4_evict_same_flow()
   test_ipv4_evict_then_assemble()

   test_ipv6_assemble()
   test_ipv6_evict()
   test_ipv6_evict_same_flow()
   test_ipv6_evict_then_assemble()
end

-- Run tests when being invoked as a script from the command line.
if type((...)) == "nil" then selftest() end
