module(..., package.seeall)

local bt = require("apps.lwaftr.binding_table")
local constants = require("apps.lwaftr.constants")
local lwdebug = require("apps.lwaftr.lwdebug")
local lwutil = require("apps.lwaftr.lwutil")
local ilink = require("apps.lwaftr.ilink")

local checksum = require("lib.checksum")
local datagram = require("lib.protocol.datagram")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local counter = require("core.counter")
local packet = require("core.packet")
local lib = require("core.lib")
local link = require("core.link")
local engine = require("core.app")
local bit = require("bit")
local ffi = require("ffi")
local alarms = require("lib.yang.alarms")

local CounterAlarm = alarms.CounterAlarm
local band, bnot = bit.band, bit.bnot
local rshift, lshift = bit.rshift, bit.lshift
local receive, transmit = link.receive, link.transmit
local rd16, wr16, rd32, wr32 = lwutil.rd16, lwutil.wr16, lwutil.rd32, lwutil.wr32
local ipv6_equals = lwutil.ipv6_equals
local htons, ntohs, ntohl = lib.htons, lib.ntohs, lib.ntohl

local S = require("syscall")

-- Note whether an IPv4 packet is actually coming from the internet, or from
-- a b4 and hairpinned to be re-encapsulated in another IPv6 packet.
local PKT_FROM_INET = 1
local PKT_HAIRPINNED = 2

local debug = lib.getenv("LWAFTR_DEBUG")

local ethernet_header_t = ffi.typeof([[
   struct {
      uint8_t  dhost[6];
      uint8_t  shost[6];
      uint16_t type;
   }
]])
local ipv4_header_t = ffi.typeof [[
   struct {
      uint8_t version_and_ihl;       // version:4, ihl:4
      uint8_t dscp_and_ecn;          // dscp:6, ecn:2
      uint16_t total_length;
      uint16_t id;
      uint16_t flags_and_fragment_offset;  // flags:3, fragment_offset:13
      uint8_t  ttl;
      uint8_t  protocol;
      uint16_t checksum;
      uint32_t  src_ip;
      uint32_t  dst_ip;
   } __attribute__((packed))
]]
local ipv6_header_t = ffi.typeof([[
   struct {
      uint32_t v_tc_fl;             // version:4, traffic class:8, flow label:20
      uint16_t payload_length;
      uint8_t  next_header;
      uint8_t  hop_limit;
      uint8_t  src_ip[16];
      uint8_t  dst_ip[16];
   } __attribute__((packed))
]])
local ipv6_pseudo_header_t = ffi.typeof[[
struct {
   char src_ip[16];
   char dst_ip[16];
   uint32_t payload_length;
   uint32_t next_header;
} __attribute__((packed))
]]
local icmp_header_t = ffi.typeof [[
struct {
   uint8_t type;
   uint8_t code;
   int16_t checksum;
} __attribute__((packed))
]]

local ethernet_header_ptr_t = ffi.typeof("$*", ethernet_header_t)
local ethernet_header_size = ffi.sizeof(ethernet_header_t)

local ipv4_header_ptr_t = ffi.typeof("$*", ipv4_header_t)
local ipv4_header_size = ffi.sizeof(ipv4_header_t)

local ipv6_header_ptr_t = ffi.typeof("$*", ipv6_header_t)
local ipv6_header_size = ffi.sizeof(ipv6_header_t)

local icmp_header_t = ffi.typeof("$*", icmp_header_t)
local icmp_header_size = ffi.sizeof(icmp_header_t)

local ipv6_pseudo_header_size = ffi.sizeof(ipv6_pseudo_header_t)

-- Local bindings for constants that are used in the hot path of the
-- data plane.  Not having them here is a 1-2% performance penalty.
local n_ethertype_ipv4 = constants.n_ethertype_ipv4
local n_ethertype_ipv6 = constants.n_ethertype_ipv6

local o_ipv4_checksum = constants.o_ipv4_checksum
local o_ipv4_dscp_and_ecn = constants.o_ipv4_dscp_and_ecn
local o_ipv4_dst_addr = constants.o_ipv4_dst_addr
local o_ipv4_flags = constants.o_ipv4_flags
local o_ipv4_proto = constants.o_ipv4_proto
local o_ipv4_src_addr = constants.o_ipv4_src_addr
local o_ipv4_total_length = constants.o_ipv4_total_length
local o_ipv4_ttl = constants.o_ipv4_ttl

local function get_ipv4_header_length(ptr)
   local ver_and_ihl = ptr[0]
   return lshift(band(ver_and_ihl, 0xf), 2)
end
local function get_ipv4_total_length(ptr)
   return ntohs(rd16(ptr + o_ipv4_total_length))
end
local function get_ipv4_src_address_ptr(ptr)
   return ptr + o_ipv4_src_addr
end
local function get_ipv4_dst_address_ptr(ptr)
   return ptr + o_ipv4_dst_addr
end
local function get_ipv4_src_address(ptr)
   return ntohl(rd32(get_ipv4_src_address_ptr(ptr)))
end
local function get_ipv4_dst_address(ptr)
   return ntohl(rd32(get_ipv4_dst_address_ptr(ptr)))
end
local function get_ipv4_proto(ptr)
   return ptr[o_ipv4_proto]
end
local function get_ipv4_flags(ptr)
   return ptr[o_ipv4_flags]
end
local function get_ipv4_dscp_and_ecn(ptr)
   return ptr[o_ipv4_dscp_and_ecn]
end
local function get_ipv4_payload(ptr)
   return ptr + get_ipv4_header_length(ptr)
end
local function get_ipv4_payload_src_port(ptr)
   -- Assumes that the packet is TCP or UDP.
   return ntohs(rd16(get_ipv4_payload(ptr)))
end
local function get_ipv4_payload_dst_port(ptr)
   -- Assumes that the packet is TCP or UDP.
   return ntohs(rd16(get_ipv4_payload(ptr) + 2))
end

local ipv6_fixed_header_size = constants.ipv6_fixed_header_size
local o_ipv6_dst_addr = constants.o_ipv6_dst_addr
local o_ipv6_next_header = constants.o_ipv6_next_header
local o_ipv6_src_addr = constants.o_ipv6_src_addr

local function get_ipv6_src_address(ptr)
   return ptr + o_ipv6_src_addr
end
local function get_ipv6_dst_address(ptr)
   return ptr + o_ipv6_dst_addr
end
local function get_ipv6_next_header(ptr)
   return ptr[o_ipv6_next_header]
end
local function get_ipv6_payload(ptr)
   -- FIXME: Deal with multiple IPv6 headers?
   return ptr + ipv6_fixed_header_size
end

local proto_icmp = constants.proto_icmp
local proto_icmpv6 = constants.proto_icmpv6
local proto_ipv4 = constants.proto_ipv4

local function get_icmp_type(ptr)
   return ptr[0]
end
local function get_icmp_code(ptr)
   return ptr[1]
end
local function get_icmpv4_echo_identifier(ptr)
   return ntohs(rd16(ptr + constants.o_icmpv4_echo_identifier))
end
local function get_icmp_mtu(ptr)
   local next_hop_mtu_offset = 6
   return ntohs(rd16(ptr + next_hop_mtu_offset))
end
local function get_icmp_payload(ptr)
   return ptr + constants.icmp_base_size
end

local function bit_mask(bits) return bit.lshift(1, bits) - 1 end
local ipv4_fragment_offset_bits = 13
local ipv4_fragment_offset_mask = bit_mask(ipv4_fragment_offset_bits)
local ipv4_flag_more_fragments = 0x1
-- If a packet has the "more fragments" flag set, or the fragment
-- offset is non-zero, it is a fragment.
local ipv4_is_fragment_mask = bit.bor(
   ipv4_fragment_offset_mask,
   bit.lshift(ipv4_flag_more_fragments, ipv4_fragment_offset_bits))
local cast = ffi.cast
local function is_ipv4_fragment(pkt)
   local h = cast(ipv4_header_ptr_t, pkt.data)
   return band(ntohs(h.flags_and_fragment_offset), ipv4_is_fragment_mask) ~= 0
end

local ipv6_fragment_proto = 44
local function is_ipv6_fragment(pkt)
   local h = cast(ipv6_header_ptr_t, pkt.data)
   return h.next_header == ipv6_fragment_proto
end

local function add_ethernet_headers(pkt, ether_type)
   pkt = packet.shiftright(pkt, ethernet_header_size)
   ffi.fill(pkt.data, ethernet_header_size)
   cast(ethernet_header_ptr_t, pkt.data).type = ether_type
   return pkt
end

local function write_ipv6_header(ptr, src, dst, tc, next_header, payload_length)
   local h = ffi.cast(ipv6_header_ptr_t, ptr)
   h.v_tc_fl = 0
   lib.bitfield(32, h, 'v_tc_fl', 0, 4, 6)   -- IPv6 Version
   lib.bitfield(32, h, 'v_tc_fl', 4, 8, tc)  -- Traffic class
   lib.bitfield(32, h, 'v_tc_fl', 12, 20, 0) -- Flow label
   h.payload_length = htons(payload_length)
   h.next_header = next_header
   h.hop_limit = constants.default_ttl
   h.src_ip = src
   h.dst_ip = dst
end

local function calculate_icmp_payload_size(dst_pkt, initial_pkt, max_size, config)
   local original_bytes_to_skip = 0
   if config.extra_payload_offset then
      original_bytes_to_skip = original_bytes_to_skip + config.extra_payload_offset
   end
   local payload_size = initial_pkt.length - original_bytes_to_skip
   local non_payload_bytes = dst_pkt.length + constants.icmp_base_size
   local full_pkt_size = payload_size + non_payload_bytes
   if full_pkt_size > max_size then
      full_pkt_size = max_size
      payload_size = full_pkt_size - non_payload_bytes
   end
   return payload_size, original_bytes_to_skip, non_payload_bytes
end

-- Write ICMP data to the end of a packet
-- Config must contain code and type
-- Config may contain a 'next_hop_mtu' setting.

local function write_icmp(dst_pkt, initial_pkt, max_size, base_checksum, config)
   local payload_size, original_bytes_to_skip, non_payload_bytes =
      calculate_icmp_payload_size(dst_pkt, initial_pkt, max_size, config)
   local off = dst_pkt.length
   dst_pkt.data[off] = config.type
   dst_pkt.data[off + 1] = config.code
   wr16(dst_pkt.data + off + 2, 0) -- checksum
   wr32(dst_pkt.data + off + 4, 0) -- Reserved
   if config.next_hop_mtu then
      wr16(dst_pkt.data + off + 6, htons(config.next_hop_mtu))
   end
   local dest = dst_pkt.data + non_payload_bytes
   ffi.C.memmove(dest, initial_pkt.data + original_bytes_to_skip, payload_size)

   local icmp_bytes = constants.icmp_base_size + payload_size
   local icmp_start = dst_pkt.data + dst_pkt.length
   local csum = checksum.ipsum(icmp_start, icmp_bytes, base_checksum)
   wr16(dst_pkt.data + off + 2, htons(csum))

   dst_pkt.length = dst_pkt.length + icmp_bytes
end

local function to_datagram(pkt)
   return datagram:new(pkt)
end

-- initial_pkt is the one to embed (a subset of) in the ICMP payload
function new_icmpv4_packet(from_ip, to_ip, initial_pkt, config)
   local new_pkt = packet.allocate()
   local dgram = to_datagram(new_pkt)
   local ipv4_header = ipv4:new({ttl = constants.default_ttl,
                                 protocol = constants.proto_icmp,
                                 src = from_ip, dst = to_ip})
   dgram:push(ipv4_header)
   new_pkt = dgram:packet()
   ipv4_header:free()

   -- Generate RFC 1812 ICMPv4 packets, which carry as much payload as they can,
   -- rather than RFC 792 packets, which only carry the original IPv4 header + 8 octets
   write_icmp(new_pkt, initial_pkt, constants.max_icmpv4_packet_size, 0, config)

   -- Fix up the IPv4 total length and checksum
   local new_ipv4_len = new_pkt.length
   local ip_tl_p = new_pkt.data + constants.o_ipv4_total_length
   wr16(ip_tl_p, ntohs(new_ipv4_len))
   local ip_checksum_p = new_pkt.data + constants.o_ipv4_checksum
   wr16(ip_checksum_p,  0) -- zero out the checksum before recomputing
   local csum = checksum.ipsum(new_pkt.data, new_ipv4_len, 0)
   wr16(ip_checksum_p, htons(csum))

   return new_pkt
end

function new_icmpv6_packet(from_ip, to_ip, initial_pkt, config)
   local new_pkt = packet.allocate()
   local dgram = to_datagram(new_pkt)
   local ipv6_header = ipv6:new({hop_limit = constants.default_ttl,
                                 next_header = constants.proto_icmpv6,
                                 src = from_ip, dst = to_ip})
   dgram:push(ipv6_header)
   new_pkt = dgram:packet()

   local max_size = constants.max_icmpv6_packet_size
   local ph_len = calculate_icmp_payload_size(new_pkt, initial_pkt, max_size, config) + constants.icmp_base_size
   local ph = ipv6_header:pseudo_header(ph_len, constants.proto_icmpv6)
   local ph_csum = checksum.ipsum(ffi.cast("uint8_t*", ph), ffi.sizeof(ph), 0)
   ph_csum = band(bnot(ph_csum), 0xffff)
   write_icmp(new_pkt, initial_pkt, max_size, ph_csum, config)

   local new_ipv6_len = new_pkt.length - (constants.ipv6_fixed_header_size)
   local ip_pl_p = new_pkt.data + constants.o_ipv6_payload_len
   wr16(ip_pl_p, ntohs(new_ipv6_len))

   ipv6_header:free()
   return new_pkt
end

-- This function converts between IPv4-as-host-uint32 and IPv4 as
-- uint8_t[4].  It's a stopgap measure; really the rest of the code
-- should be converted to use IPv4-as-host-uint32.
local function convert_ipv4(addr)
   local str = require('lib.yang.util').ipv4_ntop(addr)
   return require('lib.protocol.ipv4'):pton(str)
end

local function drop(pkt)
   packet.free(pkt)
end

local function select_instance(conf)
   local function table_merge(t1, t2)
      local ret = {}
      for k,v in pairs(t1) do ret[k] = v end
      for k,v in pairs(t2) do ret[k] = v end
      return ret
   end
   local device, id, queue = lwutil.parse_instance(conf)
   conf.softwire_config.external_interface = table_merge(
      conf.softwire_config.external_interface, queue.external_interface)
   conf.softwire_config.internal_interface = table_merge(
      conf.softwire_config.internal_interface, queue.internal_interface)
   return conf
end

LwAftr = { yang_schema = 'snabb-softwire-v2' }
-- Fields:
--   - direction: "in", "out", "hairpin", "drop";
--   If "direction" is "drop":
--     - reason: reasons for dropping;
--   - protocol+version: "icmpv4", "icmpv6", "ipv4", "ipv6";
--   - size: "bytes", "packets".
LwAftr.shm = {
   ["drop-all-ipv4-iface-bytes"]                       = {counter},
   ["drop-all-ipv4-iface-packets"]                     = {counter},
   ["drop-all-ipv6-iface-bytes"]                       = {counter},
   ["drop-all-ipv6-iface-packets"]                     = {counter},
   ["drop-bad-checksum-icmpv4-bytes"]                  = {counter},
   ["drop-bad-checksum-icmpv4-packets"]                = {counter},
   ["drop-in-by-policy-icmpv4-bytes"]                  = {counter},
   ["drop-in-by-policy-icmpv4-packets"]                = {counter},
   ["drop-in-by-policy-icmpv6-bytes"]                  = {counter},
   ["drop-in-by-policy-icmpv6-packets"]                = {counter},
   ["drop-in-by-rfc7596-icmpv4-bytes"]                 = {counter},
   ["drop-in-by-rfc7596-icmpv4-packets"]               = {counter},
   ["drop-ipv4-frag-disabled"]                         = {counter},
   ["drop-ipv6-frag-disabled"]                         = {counter},
   ["drop-misplaced-not-ipv4-bytes"]                   = {counter},
   ["drop-misplaced-not-ipv4-packets"]                 = {counter},
   ["drop-misplaced-not-ipv6-bytes"]                   = {counter},
   ["drop-misplaced-not-ipv6-packets"]                 = {counter},
   ["drop-no-dest-softwire-ipv4-bytes"]                = {counter},
   ["drop-no-dest-softwire-ipv4-packets"]              = {counter},
   ["drop-no-source-softwire-ipv6-bytes"]              = {counter},
   ["drop-no-source-softwire-ipv6-packets"]            = {counter},
   ["drop-out-by-policy-icmpv4-packets"]               = {counter},
   ["drop-out-by-policy-icmpv6-packets"]               = {counter},
   ["drop-over-mtu-but-dont-fragment-ipv4-bytes"]      = {counter},
   ["drop-over-mtu-but-dont-fragment-ipv4-packets"]    = {counter},
   ["drop-over-rate-limit-icmpv4-bytes"]               = {counter},
   ["drop-over-rate-limit-icmpv4-packets"]             = {counter},
   ["drop-over-rate-limit-icmpv6-bytes"]               = {counter},
   ["drop-over-rate-limit-icmpv6-packets"]             = {counter},
   ["drop-over-time-but-not-hop-limit-icmpv6-bytes"]   = {counter},
   ["drop-over-time-but-not-hop-limit-icmpv6-packets"] = {counter},
   ["drop-too-big-type-but-not-code-icmpv6-bytes"]     = {counter},
   ["drop-too-big-type-but-not-code-icmpv6-packets"]   = {counter},
   ["drop-ttl-zero-ipv4-bytes"]                        = {counter},
   ["drop-ttl-zero-ipv4-packets"]                      = {counter},
   ["drop-unknown-protocol-icmpv6-bytes"]              = {counter},
   ["drop-unknown-protocol-icmpv6-packets"]            = {counter},
   ["drop-unknown-protocol-ipv6-bytes"]                = {counter},
   ["drop-unknown-protocol-ipv6-packets"]              = {counter},
   ["hairpin-ipv4-bytes"]                              = {counter},
   ["hairpin-ipv4-packets"]                            = {counter},
   ["ingress-packet-drops"]                            = {counter},
   ["in-ipv4-bytes"]                                   = {counter},
   ["in-ipv4-packets"]                                 = {counter},
   ["in-ipv6-bytes"]                                   = {counter},
   ["in-ipv6-packets"]                                 = {counter},
   ["out-icmpv4-bytes"]                                = {counter},
   ["out-icmpv4-packets"]                              = {counter},
   ["out-icmpv6-bytes"]                                = {counter},
   ["out-icmpv6-packets"]                              = {counter},
   ["out-ipv4-bytes"]                                  = {counter},
   ["out-ipv4-packets"]                                = {counter},
   ["out-ipv6-bytes"]                                  = {counter},
   ["out-ipv6-packets"]                                = {counter}
}

function LwAftr:new(conf)
   if conf.debug then debug = true end
   local o = setmetatable({}, {__index=LwAftr})
   conf = select_instance(conf).softwire_config
   o.conf = conf

   o.binding_table = bt.load(conf.binding_table)
   o.lookup_streamer = o.binding_table.softwires:make_lookup_streamer(32)

   local function make_rate_limit(interface, protocol)
      local limit = { count = 0, start = 0, protocol = protocol }
      if interface.generate_icmp_errors then
         limit.limit = interface.error_rate_limiting.packets
         limit.period = interface.error_rate_limiting.period
      else
         limit.period, limit.limit = 60, 0
      end
      return limit
   end

   o.icmpv4_limits = make_rate_limit(conf.external_interface, 'icmpv4')
   o.icmpv6_limits = make_rate_limit(conf.internal_interface, 'icmpv6')

   alarms.add_to_inventory {
     [{alarm_type_id='bad-ipv4-softwires-matches'}] = {
       resource=tostring(S.getpid()),
       has_clear=true,
       description="lwAFTR's bad matching softwires due to not found destination "..
         "address for IPv4 packets",
     }
   }
   alarms.add_to_inventory {
     [{alarm_type_id='bad-ipv6-softwires-matches'}] = {
       resource=tostring(S.getpid()),
       has_clear=true,
       description="lwAFTR's bad matching softwires due to not found source"..
         "address for IPv6 packets",
     }
   }
   local bad_ipv4_softwire_matches = alarms.declare_alarm {
      [{resource=tostring(S.getpid()), alarm_type_id='bad-ipv4-softwires-matches'}] = {
         perceived_severity = 'major',
         alarm_text = "lwAFTR's bad softwires matches due to non matching destination"..
            "address for incoming packets (IPv4) has reached over 100,000 softwires "..
            "binding-table.  Please review your lwAFTR's configuration binding-table."
      },
   }
   local bad_ipv6_softwire_matches = alarms.declare_alarm {
      [{resource=tostring(S.getpid()), alarm_type_id='bad-ipv6-softwires-matches'}] = {
         perceived_severity = 'major',
         alarm_text = "lwAFTR's bad softwires matches due to non matching source "..
            "address for outgoing packets (IPv6) has reached over 100,000 softwires "..
            "binding-table.  Please review your lwAFTR's configuration binding-table."
      },
   }
   o.bad_ipv4_softwire_matches_alarm = CounterAlarm.new(bad_ipv4_softwire_matches,
      5, 1e5, o, 'drop-no-dest-softwire-ipv4-packets')
   o.bad_ipv6_softwire_matches_alarm = CounterAlarm.new(bad_ipv6_softwire_matches,
      5, 1e5, o, 'drop-no-source-softwire-ipv6-packets')

   o.scratch_softwire = o.binding_table.softwires.entry_type()
   o.softwire_entry_ptr_t = ffi.typeof('$*', o.binding_table.softwires.entry_type)
   o.softwire_entry_size = ffi.sizeof(o.binding_table.softwires.entry_type)

   o.q = {}
   for _,k in ipairs({'ipv4_in', 'ipv6_in', 'icmpv6_in', 'hairpin',
                      'decap', 'decap_not_found',
                      'encap', 'encap_not_found', 'encap_ttl', 'encap_mtu',
                      'icmpv6_out', 'icmpv4_out', 'ipv4_pre_out',
                      'ipv4_out', 'ipv6_out'}) do
      o.q[k] = ilink.new()
   end

   if debug then lwdebug.pp(conf) end
   return o
end

-- The following two methods are called by lib.ptree.worker in reaction
-- to binding table changes, via
-- lib/ptree/support/snabb-softwire-v2.lua.
function LwAftr:add_softwire_entry(entry_blob)
   self.binding_table:add_softwire_entry(entry_blob)
end
function LwAftr:remove_softwire_entry(entry_key_blob)
   self.binding_table:remove_softwire_entry(entry_key_blob)
end

local function decrement_ttl(pkt)
   local ipv4_header = pkt.data
   local chksum = bnot(ntohs(rd16(ipv4_header + o_ipv4_checksum)))
   local old_ttl = ipv4_header[o_ipv4_ttl]
   if old_ttl == 0 then return 0 end
   local new_ttl = band(old_ttl - 1, 0xff)
   ipv4_header[o_ipv4_ttl] = new_ttl
   -- Now fix up the checksum.  o_ipv4_ttl is the first byte in the
   -- 16-bit big-endian word, so the difference to the overall sum is
   -- multiplied by 0xff.
   chksum = chksum + lshift(new_ttl - old_ttl, 8)
   -- Now do the one's complement 16-bit addition of the 16-bit words of
   -- the checksum, which necessarily is a 32-bit value.  Two carry
   -- iterations will suffice.
   chksum = band(chksum, 0xffff) + rshift(chksum, 16)
   chksum = band(chksum, 0xffff) + rshift(chksum, 16)
   wr16(ipv4_header + o_ipv4_checksum, htons(bnot(chksum)))
   return new_ttl
end

function LwAftr:ipv4_in_binding_table (ip)
   return self.binding_table:is_managed_ipv4_address(ip)
end

function LwAftr:drop_ipv4(pkt, pkt_src_link)
   if pkt_src_link == PKT_FROM_INET then
      counter.add(self.shm["drop-all-ipv4-iface-bytes"], pkt.length)
      counter.add(self.shm["drop-all-ipv4-iface-packets"])
   elseif pkt_src_link == PKT_HAIRPINNED then
      -- B4s emit packets with no IPv6 extension headers.
      local orig_packet_len = pkt.length + ipv6_fixed_header_size
      counter.add(self.shm["drop-all-ipv6-iface-bytes"], orig_packet_len)
      counter.add(self.shm["drop-all-ipv6-iface-packets"])
   else
      assert(false, "Programming error, bad pkt_src_link: " .. pkt_src_link)
   end
   return drop(pkt)
end

function LwAftr:encapsulating_packet_with_df_flag_would_exceed_mtu(pkt)
   local payload_length = pkt.length
   local mtu = self.conf.internal_interface.mtu
   if payload_length + ipv6_fixed_header_size <= mtu then
      -- Packet will not exceed MTU.
      return false
   end
   -- The result would exceed the IPv6 MTU; signal an error via ICMPv4 if
   -- the IPv4 fragment has the DF flag.
   return band(get_ipv4_flags(pkt.data), 0x40) == 0x40
end

function LwAftr:cannot_fragment_df_packet_error(pkt)
   -- According to RFC 791, the original packet must be discarded.
   -- Return a packet with ICMP(3, 4) and the appropriate MTU
   -- as per https://tools.ietf.org/html/rfc2473#section-7.2
   if debug then lwdebug.print_pkt(pkt) end
   -- The ICMP packet should be set back to the packet's source.
   local dst_ip = get_ipv4_src_address_ptr(pkt.data)
   local mtu = self.conf.internal_interface.mtu
   local icmp_config = {
      type = constants.icmpv4_dst_unreachable,
      code = constants.icmpv4_datagram_too_big_df,
      extra_payload_offset = 0,
      next_hop_mtu = mtu - constants.ipv6_fixed_header_size,
   }
   return new_icmpv4_packet(
      convert_ipv4(self.conf.external_interface.ip),
      dst_ip, pkt, icmp_config)
end

function LwAftr:compute_port_for_icmpv4(p, pkt_src_link)
   local ipv4_header = p.data
   local ipv4_header_size = get_ipv4_header_length(ipv4_header)
   local icmp_header = get_ipv4_payload(ipv4_header)
   local icmp_type = get_icmp_type(icmp_header)

   if not self.conf.external_interface.allow_incoming_icmp then
      counter.add(self.shm["drop-in-by-policy-icmpv4-bytes"], p.length)
      counter.add(self.shm["drop-in-by-policy-icmpv4-packets"])
      return nil
   end

   -- RFC 7596 is silent on whether to validate echo request/reply checksums.
   -- ICMP checksums SHOULD be validated according to RFC 5508.
   -- Choose to verify the echo reply/request ones too.
   -- Note: the lwaftr SHOULD NOT validate the transport checksum of the embedded packet.
   -- Were it to nonetheless do so, RFC 4884 extension headers MUST NOT
   -- be taken into account when validating the checksum
   local icmp_bytes = get_ipv4_total_length(ipv4_header) - ipv4_header_size
   if checksum.ipsum(icmp_header, icmp_bytes, 0) ~= 0 then
      -- Silently drop the packet, as per RFC 5508
      counter.add(self.shm["drop-bad-checksum-icmpv4-bytes"], p.length)
      counter.add(self.shm["drop-bad-checksum-icmpv4-packets"])
      return nil
   end

   if icmp_type == constants.icmpv4_echo_request then
      -- For an incoming ping from the IPv4 internet, assume port == 0
      -- for the purposes of looking up a softwire in the binding table.
      -- This will allow ping to a B4 on an IPv4 without port sharing.
      -- It also has the nice property of causing a drop if the IPv4 has
      -- any reserved ports.
      --
      -- RFC 7596 section 8.1 seems to suggest that we should use the
      -- echo identifier for this purpose, but that only makes sense for
      -- echo requests originating from a B4, to identify the softwire
      -- of the source.  It can't identify a destination softwire.  This
      -- makes sense because you can't really "ping" a port-restricted
      -- IPv4 address.
      return 0
   elseif icmp_type == constants.icmpv4_echo_reply then
      -- A reply to a ping that originally issued from a subscriber on
      -- the B4 side; the B4 set the port in the echo identifier, as per
      -- RFC 7596, section 8.1, so use that to look up the destination
      -- softwire.
      return get_icmpv4_echo_identifier(icmp_header)
   else
      -- As per REQ-3, use the IP address embedded in the ICMP payload,
      -- assuming that the payload is shaped like TCP or UDP with the
      -- ports first.
      local embedded_ipv4_header = get_icmp_payload(icmp_header)
      return get_ipv4_payload_src_port(embedded_ipv4_header)
   end
end

function LwAftr:tunnel_unreachable(pkt, code, next_hop_mtu)
   local ipv6_header = pkt.data
   local icmp_header = get_ipv6_payload(ipv6_header)
   local embedded_ipv6_header = get_icmp_payload(icmp_header)
   local embedded_ipv4_header = get_ipv6_payload(embedded_ipv6_header)

   local icmp_config = {type = constants.icmpv4_dst_unreachable,
                        code = code,
                        extra_payload_offset = embedded_ipv4_header - ipv6_header,
                        next_hop_mtu = next_hop_mtu
                        }
   local dst_ip = get_ipv4_src_address_ptr(embedded_ipv4_header)
   local icmp_reply = new_icmpv4_packet(
      convert_ipv4(self.conf.external_interface.ip),
      dst_ip, pkt, icmp_config)
   return icmp_reply
end

function LwAftr:receive_ipv6(src, dst)
   -- Strip ethernet headers from incoming IPv6 packets.
   for _=1,link.nreadable(src) do
      local p = receive(src)
      if cast(ethernet_header_ptr_t, p.data).type == n_ethertype_ipv6 then
         p = packet.shiftleft(p, ethernet_header_size)
         counter.add(self.shm["in-ipv6-bytes"], p.length)
         counter.add(self.shm["in-ipv6-packets"])
         dst:push(p)
      else
         -- Drop anything that's not IPv6.
         counter.add(self.shm["drop-misplaced-not-ipv6-bytes"], p.length - 14)
         counter.add(self.shm["drop-misplaced-not-ipv6-packets"])
         counter.add(self.shm["drop-all-ipv6-iface-bytes"], p.length - 14)
         counter.add(self.shm["drop-all-ipv6-iface-packets"])
         drop(p)
      end
   end
end

function LwAftr:receive_ipv4(src, dst)
   -- Strip ethernet headers from incoming IPv4 packets.
   for _=1,link.nreadable(src) do
      local p = receive(src)
      if cast(ethernet_header_ptr_t, p.data).type == n_ethertype_ipv4 then
         p = packet.shiftleft(p, ethernet_header_size)
         counter.add(self.shm["in-ipv4-bytes"], p.length)
         counter.add(self.shm["in-ipv4-packets"])
         dst:push(p)
      else
         -- Drop anything that's not IPv4.
         counter.add(self.shm["drop-misplaced-not-ipv4-bytes"], p.length - 14)
         counter.add(self.shm["drop-misplaced-not-ipv4-packets"])
         counter.add(self.shm["drop-all-ipv4-iface-bytes"], p.length - 14)
         counter.add(self.shm["drop-all-ipv4-iface-packets"])
         drop(p)
      end
   end
end

-- FIXME: Verify that the packet length is big enough?
function LwAftr:prepare_decapsulation(src, icmpv6, dst)
   for _=1,#src do
      local p = src:pop()
      local ipv6_header = p.data
      local proto = get_ipv6_next_header(ipv6_header)

      if proto ~= proto_ipv4 then
         if proto == proto_icmpv6 then
            icmpv6:push(p)
         else
            -- Drop packet with unknown protocol.
            if proto == ipv6_fragment_proto then
               counter.add(self.shm["drop-ipv4-frag-disabled"])
            else
               counter.add(self.shm["drop-unknown-protocol-ipv6-bytes"], p.length)
               counter.add(self.shm["drop-unknown-protocol-ipv6-packets"])
            end
            counter.add(self.shm["drop-all-ipv6-iface-bytes"], p.length)
            counter.add(self.shm["drop-all-ipv6-iface-packets"])
            drop(p)
         end
      else
         p = packet.shiftright(p, self.softwire_entry_size)
         local entry = ffi.cast(self.softwire_entry_ptr_t, p.data)
         local tunneled_ipv4_header = p.data + self.softwire_entry_size +
            ipv6_header_size
         entry.key.ipv4 = get_ipv4_src_address(tunneled_ipv4_header)
         if get_ipv4_proto(tunneled_ipv4_header) == proto_icmp then
            local icmp_header = get_ipv4_payload(tunneled_ipv4_header)
            local icmp_type = get_icmp_type(icmp_header)
            if icmp_type == constants.icmpv4_echo_request then
               -- A ping going out from the B4 to the internet; the B4 will
               -- encode a port in its range into the echo identifier, as per
               -- RFC 7596 section 8.
               entry.key.psid = get_icmpv4_echo_identifier(icmp_header)
            elseif icmp_type == constants.icmpv4_echo_reply then
               -- A reply to a ping, coming from the B4.  Only B4s whose
               -- softwire is associated with port 0 are pingable.  See
               -- icmpv4_incoming for more discussion.
               entry.key.psid = 0
            else
               -- Otherwise it's an error in response to a non-ICMP packet,
               -- routed to the B4 via the ports in IPv4 payload.  Extract
               -- these ports from the embedded packet fragment in the ICMP
               -- payload.
               local embedded_ipv4_header = get_icmp_payload(icmp_header)
               entry.key.psid = get_ipv4_payload_src_port(embedded_ipv4_header)
            end
         else
            -- It's not ICMP.  Assume we can find ports in the IPv4 payload,
            -- as in TCP and UDP.  We could check strictly for TCP/UDP, but
            -- that would filter out similarly-shaped protocols like SCTP, so
            -- we optimistically assume that the incoming traffic has the
            -- right shape.
            entry.key.psid = get_ipv4_payload_src_port(tunneled_ipv4_header)
         end
         dst:push(p)
      end
   end
end

function LwAftr:process_icmpv6(src, dst)
   for _=1,#src do
      local p = src:pop()
      local ipv6_header = p.data
      local icmp_header = get_ipv6_payload(ipv6_header)
      local icmp_type = get_icmp_type(icmp_header)
      local icmp_code = get_icmp_code(icmp_header)
      if not self.conf.internal_interface.allow_incoming_icmp then
         counter.add(self.shm["drop-in-by-policy-icmpv6-bytes"], p.length)
         counter.add(self.shm["drop-in-by-policy-icmpv6-packets"])
         counter.add(self.shm["drop-all-ipv6-iface-bytes"], p.length)
         counter.add(self.shm["drop-all-ipv6-iface-packets"])
      elseif icmp_type == constants.icmpv6_packet_too_big then
         if icmp_code ~= constants.icmpv6_code_packet_too_big then
            -- Invalid code.
            counter.add(self.shm["drop-too-big-type-but-not-code-icmpv6-bytes"],
                        p.length)
            counter.add(self.shm["drop-too-big-type-but-not-code-icmpv6-packets"])
            counter.add(self.shm["drop-all-ipv6-iface-bytes"], p.length)
            counter.add(self.shm["drop-all-ipv6-iface-packets"])
         else
            local mtu = get_icmp_mtu(icmp_header) - constants.ipv6_fixed_header_size
            local reply = self:tunnel_unreachable(
               p, constants.icmpv4_datagram_too_big_df, mtu)
            dst:push(reply)
         end
         -- Take advantage of having already checked for 'packet too
         -- big' (2), and unreachable node/hop limit exceeded/paramater
         -- problem being 1, 3, 4 respectively.
      elseif icmp_type <= constants.icmpv6_parameter_problem then
         -- If the time limit was exceeded, require it was a hop limit code
         if (icmp_type == constants.icmpv6_time_limit_exceeded
             and icmp_code ~= constants.icmpv6_hop_limit_exceeded) then
            counter.add(self.shm[
               "drop-over-time-but-not-hop-limit-icmpv6-bytes"], p.length)
            counter.add(
               self.shm["drop-over-time-but-not-hop-limit-icmpv6-packets"])
            counter.add(self.shm["drop-all-ipv6-iface-bytes"], p.length)
            counter.add(self.shm["drop-all-ipv6-iface-packets"])
         else
            -- Accept all unreachable or parameter problem codes.
            local reply = self:tunnel_unreachable(
               p, constants.icmpv4_host_unreachable)
            dst:push(reply)
         end
      else
         -- No other types of ICMPv6, including echo request/reply, are
         -- handled.
         counter.add(self.shm["drop-unknown-protocol-icmpv6-bytes"], p.length)
         counter.add(self.shm["drop-unknown-protocol-icmpv6-packets"])
         counter.add(self.shm["drop-all-ipv6-iface-bytes"], p.length)
         counter.add(self.shm["drop-all-ipv6-iface-packets"])
      end
      drop(p)
   end
end

-- FIXME: Verify that the total_length declared in the packet is correct.
function LwAftr:prepare_encapsulation(src, dst, pkt_src_link)
   for _=1,#src do
      local p = src:pop()
      local port
      local ipv4_header = p.data

      if is_ipv4_fragment(p) then
         -- If fragmentation support is enabled, the lwAFTR never
         -- receives fragments.  If it does, fragment support is
         -- disabled and it should drop them.
         counter.add(self.shm["drop-ipv4-frag-disabled"])
         port = nil
      elseif get_ipv4_proto(ipv4_header) == proto_icmp then
         -- ICMP has its own port-for-PSID logic.
         port = self:compute_port_for_icmpv4(p)
      else
         -- Assume we can find ports in the IPv4 payload, as in TCP and
         -- UDP.  We could check strictly for TCP/UDP, but that would
         -- filter out similarly-shaped protocols like SCTP, so we
         -- optimistically assume that the incoming traffic has the
         -- right shape.
         port = get_ipv4_payload_dst_port(ipv4_header)
      end

      if port then
         p = packet.shiftright(p, self.softwire_entry_size)
         local entry = ffi.cast(self.softwire_entry_ptr_t, p.data)
         local ipv4 = p.data + self.softwire_entry_size
         entry.key.ipv4 = get_ipv4_dst_address(ipv4)
         entry.key.psid = port
         dst:push(p)
      else
         self:drop_ipv4(p, pkt_src_link)
      end
   end
end

function LwAftr:perform_lookup(q)
   local idx, avail = 0, #q
   local bt = self.binding_table
   local streamer = self.lookup_streamer
   while idx < avail do
      -- Look up PSIDs for the incoming packets and copy keys to the
      -- streamer.
      for i = 0, math.min(32, avail - idx) - 1 do
         local p = q:peek(idx + i)
         local entry = ffi.cast(self.softwire_entry_ptr_t, p.data)
         local ipv4, port = entry.key.ipv4, entry.key.psid
         streamer.entries[i].key.ipv4 = ipv4
         streamer.entries[i].key.psid = bt:lookup_psid(ipv4, port)
      end
      -- Run the streaming lookup and copy out the results.
      streamer:stream()
      for i = 0, math.min(32, avail - idx) - 1 do
         local p = q:peek(idx + i)
         ffi.copy(p.data, streamer.entries[i], self.softwire_entry_size)
      end
      idx = idx + 32
   end
end

function LwAftr:perform_decapsulation(src, err_not_found, dst)
   for _=1,#src do
      local p = src:pop()
      local entry = ffi.cast(self.softwire_entry_ptr_t, p.data)
      local ipv6 = ffi.cast(ipv6_header_ptr_t, p.data + self.softwire_entry_size)

      if (entry.hash ~= 0xffffffff
             and ipv6_equals(ipv6.src_ip, entry.value.b4_ipv6)
             and ipv6_equals(ipv6.dst_ip, entry.value.br_address)) then
         -- Source softwire is valid; decapsulate and forward.
         dst:push(
            packet.shiftleft(p, self.softwire_entry_size + ipv6_header_size))
      else
         -- Softwire not found.
         err_not_found:push(packet.shiftleft(p, self.softwire_entry_size))
      end
   end
end

-- ICMPv6 type 1 code 5, as per RFC 7596.
-- The source (ipv6, ipv4, port) tuple is not in the table.
function LwAftr:process_decapsulation_failures(src, dst)
   for i=1,#src do
      local p = src:pop()
      counter.add(self.shm["drop-no-source-softwire-ipv6-bytes"], p.length)
      counter.add(self.shm["drop-no-source-softwire-ipv6-packets"])
      counter.add(self.shm["drop-all-ipv6-iface-bytes"], p.length)
      counter.add(self.shm["drop-all-ipv6-iface-packets"])
      if not self.conf.internal_interface.generate_icmp_errors then
         -- ICMP error messages off by policy; silently drop.
         -- Not counting bytes because we do not even generate the packets.
         counter.add(self.shm["drop-out-by-policy-icmpv6-packets"])
      else
         local ipv6_header = p.data
         local orig_src_addr_icmp_dst = get_ipv6_src_address(ipv6_header)
         -- Send packet back from the IPv6 address it was sent to.
         local icmpv6_src_addr = get_ipv6_dst_address(ipv6_header)
         local icmp_config = {type = constants.icmpv6_dst_unreachable,
                              code = constants.icmpv6_failed_ingress_egress_policy,
                             }
         local b4fail_icmp = new_icmpv6_packet(
            icmpv6_src_addr, orig_src_addr_icmp_dst, p, icmp_config)
         dst:push(b4fail_icmp)
      end
      drop(p)
   end
end

-- Hairpinned packets need to be handled quite carefully. We've decided they:
-- * should increment hairpin-ipv4-bytes and hairpin-ipv4-packets
-- * should increment [in|out]-ipv6-[bytes|packets]
-- * should NOT increment  [in|out]-ipv4-[bytes|packets]
-- The latter is because decapsulating and re-encapsulating them via IPv4
-- packets is an internal implementation detail that DOES NOT go out over
-- physical wires.
-- Not incrementing out-ipv4-bytes and out-ipv4-packets is straightforward.
-- Not incrementing in-ipv4-[bytes|packets] is harder. The easy way would be
-- to add extra flags and conditionals, but it's expected that a high enough
-- percentage of traffic might be hairpinned that this could be problematic,
-- (and a nightmare as soon as we add any kind of parallelism)
-- so instead we speculatively decrement the counters here.
-- It is assumed that any packet we transmit to self.input.v4 will not
-- be dropped before the in-ipv4-[bytes|packets] counters are incremented;
-- I *think* this approach bypasses using the physical NIC but am not
-- absolutely certain.
function LwAftr:apply_hairpinning(src, hairpin, dst, use_hairpin_counter)
   local hairpinning = self.conf.internal_interface.hairpinning
   for i=1,#src do
      local p = src:pop()
      local ipv4_header = p.data
      local dst_ip = get_ipv4_dst_address(ipv4_header)
      if hairpinning and self:ipv4_in_binding_table(dst_ip) then
         if use_hairpin_counter then
            counter.add(self.shm["hairpin-ipv4-bytes"], p.length)
            counter.add(self.shm["hairpin-ipv4-packets"])
         end
         hairpin:push(p)
      else
         dst:push(p)
      end
   end
end

function LwAftr:perform_encapsulation(src, err_not_found, err_ttl, err_mtu, dst)
   for _=1,#src do
      local p = src:pop()

      if ffi.cast(self.softwire_entry_ptr_t, p.data).hash == 0xffffffff then
         err_not_found:push(packet.shiftleft(p, self.softwire_entry_size))
      else
         -- Source softwire is valid; decapsulate and forward.
         ffi.copy(self.scratch_softwire, p.data, self.softwire_entry_size)
         p = packet.shiftleft(p, self.softwire_entry_size)

         local ttl = decrement_ttl(p)
         if ttl == 0 then
            err_ttl:push(p)
         elseif self:encapsulating_packet_with_df_flag_would_exceed_mtu(p) then
            err_mtu:push(p)
         else
            local payload_length = p.length
            local l3_header = p.data
            local traffic_class = get_ipv4_dscp_and_ecn(l3_header)
            p = packet.shiftright(p, ipv6_header_size)
            write_ipv6_header(p.data, self.scratch_softwire.value.br_address,
                              self.scratch_softwire.value.b4_ipv6, traffic_class,
                              proto_ipv4, payload_length)
            dst:push(p)
         end
      end
   end
end         
            
function LwAftr:process_encapsulation_failures(err_not_found, err_ttl, err_mtu,
                                               dst, pkt_src_link)
   for _=1,#err_not_found do
      local p = err_not_found:pop()
      counter.add(self.shm["drop-no-dest-softwire-ipv4-bytes"], p.length)
      counter.add(self.shm["drop-no-dest-softwire-ipv4-packets"])

      if get_ipv4_proto(p.data) == proto_icmp then
         -- RFC 7596 section 8.1 requires us to silently drop incoming
         -- ICMPv4 messages that don't match the binding table.
         counter.add(self.shm["drop-in-by-rfc7596-icmpv4-bytes"], p.length)
         counter.add(self.shm["drop-in-by-rfc7596-icmpv4-packets"])
      else
         local ipv4_header = p.data
         local to_ip = get_ipv4_src_address_ptr(ipv4_header)
         local icmp_config = {
            type = constants.icmpv4_dst_unreachable,
            code = constants.icmpv4_host_unreachable,
         }
         dst:push(new_icmpv4_packet(
                     convert_ipv4(self.conf.external_interface.ip),
                     to_ip, p, icmp_config))
      end
      self:drop_ipv4(p, pkt_src_link)
   end
   for _=1,#err_ttl do
      local p = err_ttl:pop()
      counter.add(self.shm["drop-ttl-zero-ipv4-bytes"], p.length)
      counter.add(self.shm["drop-ttl-zero-ipv4-packets"])

      local ipv4_header = p.data
      local dst_ip = get_ipv4_src_address_ptr(ipv4_header)
      local icmp_config = {
         type = constants.icmpv4_time_exceeded,
         code = constants.icmpv4_ttl_exceeded_in_transit,
      }
      dst:push(new_icmpv4_packet(
                  convert_ipv4(self.conf.external_interface.ip),
                  dst_ip, p, icmp_config))
      self:drop_ipv4(p, pkt_src_link)
   end
   for _=1,#err_mtu do
      local p = err_mtu:pop()
      counter.add(self.shm["drop-over-mtu-but-dont-fragment-ipv4-bytes"], p.length)
      counter.add(self.shm["drop-over-mtu-but-dont-fragment-ipv4-packets"])
      dst:push(self:cannot_fragment_df_packet_error(p))
      self:drop_ipv4(p, pkt_src_link)
   end
end

function LwAftr:forward_with_rate_limiting(src, dst, limit)
   local now = engine.now()
   if now - limit.start >= limit.period then
      limit.start, limit.count = now, 0
   end
   local protocol = limit.protocol
   for _=1,#src do
      local p = src:pop()
      if limit.count < limit.limit then
         limit.count = limit.count + 1
         counter.add(self.shm["out-"..protocol.."-bytes"], p.length)
         counter.add(self.shm["out-"..protocol.."-packets"])
         dst:push(p)
      else
         if limit.limit == 0 then
            counter.add(self.shm["drop-out-by-policy-"..protocol.."-packets"])
         else
            counter.add(self.shm["drop-over-rate-limit-"..protocol.."-bytes"],
                        p.length)
            counter.add(self.shm["drop-over-rate-limit-"..protocol.."-packets"])
         end
         drop(p)
      end
   end
end

function LwAftr:transmit_ipv6(src, dst)
   for _=1,#src do
      local p = src:pop()
      counter.add(self.shm["out-ipv6-bytes"], p.length)
      counter.add(self.shm["out-ipv6-packets"])
      transmit(dst, add_ethernet_headers(p, n_ethertype_ipv6))
   end
end

function LwAftr:transmit_ipv4(src, dst)
   for _=1,#src do
      local p = src:pop()
      counter.add(self.shm["out-ipv4-bytes"], p.length)
      counter.add(self.shm["out-ipv4-packets"])
      transmit(dst, add_ethernet_headers(p, n_ethertype_ipv4))
   end
end

function LwAftr:push ()
   self.bad_ipv4_softwire_matches_alarm:check()
   self.bad_ipv6_softwire_matches_alarm:check()

   local q = self.q

   self:receive_ipv6(self.input.v6, q.ipv6_in)
   self:prepare_decapsulation(q.ipv6_in, q.icmpv6_in, q.decap)
   self:process_icmpv6(q.icmpv6_in, q.icmpv4_out)
   self:perform_lookup(q.decap)
   self:perform_decapsulation(q.decap, q.decap_not_found, q.ipv4_pre_out)
   self:process_decapsulation_failures(q.decap_not_found, q.icmpv6_out)

   self:apply_hairpinning(q.ipv4_pre_out, q.hairpin, q.ipv4_out, true)

   self:receive_ipv4(self.input.v4, q.ipv4_in)
   self:prepare_encapsulation(q.ipv4_in, q.encap, PKT_FROM_INET)
   self:perform_lookup(q.encap)
   self:perform_encapsulation(q.encap, q.encap_not_found, q.encap_ttl,
                              q.encap_mtu, q.ipv6_out)
   self:process_encapsulation_failures(q.encap_not_found, q.encap_ttl,
                                       q.encap_mtu, q.icmpv4_out, PKT_FROM_INET)

   self:prepare_encapsulation(q.hairpin, q.encap, PKT_HAIRPINNED)
   self:perform_lookup(q.encap)
   self:perform_encapsulation(q.encap, q.encap_not_found, q.encap_ttl,
                              q.encap_mtu, q.ipv6_out)
   -- FIXME: Could hairpinning errors cause a hairpinned error loop?
   self:process_encapsulation_failures(q.encap_not_found, q.encap_ttl,
                                       q.encap_mtu, q.icmpv4_out, PKT_HAIRPINNED)

   self:forward_with_rate_limiting(q.icmpv6_out, q.ipv6_out, self.icmpv6_limits)
   self:forward_with_rate_limiting(q.icmpv4_out, q.ipv4_pre_out,
                                   self.icmpv4_limits)

   -- See above fixme: here the graph loops back to q.hairpin which may
   -- not be drained.
   self:apply_hairpinning(q.ipv4_pre_out, q.hairpin, q.ipv4_out, false)

   self:transmit_ipv6(q.ipv6_out, self.output.v6)
   self:transmit_ipv4(q.ipv4_out, self.output.v4)
end
