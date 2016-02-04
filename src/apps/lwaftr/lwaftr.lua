module(..., package.seeall)

local bt = require("apps.lwaftr.binding_table")
local constants = require("apps.lwaftr.constants")
local dump = require('apps.lwaftr.dump')
local icmp = require("apps.lwaftr.icmp")
local lwconf = require("apps.lwaftr.conf")
local lwdebug = require("apps.lwaftr.lwdebug")
local lwheader = require("apps.lwaftr.lwheader")
local lwutil = require("apps.lwaftr.lwutil")

local S = require("syscall")
local timer = require("core.timer")
local checksum = require("lib.checksum")
local ethernet = require("lib.protocol.ethernet")
local ipv6 = require("lib.protocol.ipv6")
local ipv4 = require("lib.protocol.ipv4")
local packet = require("core.packet")
local lib = require("core.lib")
local bit = require("bit")
local ffi = require("ffi")

local band, bor, bnot = bit.band, bit.bor, bit.bnot
local rshift, lshift = bit.rshift, bit.lshift
local cast = ffi.cast
local receive, transmit = link.receive, link.transmit
local rd16, wr16, rd32 = lwutil.rd16, lwutil.wr16, lwutil.rd32
local get_ihl_from_offset = lwutil.get_ihl_from_offset
local htons, htonl = lwutil.htons, lwutil.htonl
local ntohs, ntohl = htons, htonl
local keys = lwutil.keys
local write_eth_header, write_ipv6_header = lwheader.write_eth_header, lwheader.write_ipv6_header

local debug = false

-- Local bindings for constants that are used in the hot path of the
-- data plane.  Not having them here is a 1-2% performance penalty.
local ethernet_header_size = constants.ethernet_header_size
local o_ethernet_ethertype = constants.o_ethernet_ethertype
local n_ethertype_ipv4 = constants.n_ethertype_ipv4
local n_ethertype_ipv6 = constants.n_ethertype_ipv6

local function is_ipv6(pkt)
   return rd16(pkt.data + o_ethernet_ethertype) == n_ethertype_ipv6
end
local function is_ipv4(pkt)
   return rd16(pkt.data + o_ethernet_ethertype) == n_ethertype_ipv4
end
local function get_ethernet_payload(pkt)
   return pkt.data + ethernet_header_size
end
local function get_ethernet_payload_length(pkt)
   return pkt.length - ethernet_header_size
end

local o_ipv4_checksum = constants.o_ipv4_checksum
local o_ipv4_dscp_and_ecn = constants.o_ipv4_dscp_and_ecn
local o_ipv4_dst_addr = constants.o_ipv4_dst_addr
local o_ipv4_flags = constants.o_ipv4_flags
local o_ipv4_identification = constants.o_ipv4_identification
local o_ipv4_proto = constants.o_ipv4_proto
local o_ipv4_src_addr = constants.o_ipv4_src_addr
local o_ipv4_total_length = constants.o_ipv4_total_length
local o_ipv4_ttl = constants.o_ipv4_ttl
local o_ipv4_ver_and_ihl = constants.o_ipv4_ver_and_ihl

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

local function drop(pkt)
   packet.free(pkt)
end

local transmit_icmpv6_with_rate_limit

local function init_transmit_icmpv6_with_rate_limit(lwstate)
   assert(lwstate.icmpv6_rate_limiter_n_seconds > 0,
      "Incorrect icmpv6_rate_limiter_n_seconds value, must be > 0")
   assert(lwstate.icmpv6_rate_limiter_n_packets >= 0,
      "Incorrect icmpv6_rate_limiter_n_packets value, must be >= 0")
   local icmpv6_rate_limiter_n_seconds = lwstate.icmpv6_rate_limiter_n_seconds
   local icmpv6_rate_limiter_n_packets = lwstate.icmpv6_rate_limiter_n_packets
   local counter = 0
   local last_time
   return function (o, pkt)
      local cur_now = tonumber(engine.now())
      last_time = last_time or cur_now
      -- Reset if elapsed time reached.
      if cur_now - last_time >= icmpv6_rate_limiter_n_seconds then
         last_time = cur_now
         counter = 0
      end
      -- Send packet if limit not reached.
      if counter < icmpv6_rate_limiter_n_packets then
         counter = counter + 1
         return transmit(o, pkt)
      else
         return drop(pkt)
      end
   end
end

local function on_signal(sig, f)
   local fd = S.signalfd(sig, "nonblock") -- handle signal via fd
   local buf = S.types.t.siginfos(8)
   S.sigprocmask("block", sig)            -- block traditional handler
   timer.activate(timer.new(sig, function ()
      local events, err = S.util.signalfd_read(fd, buf)
      if events and #events > 0 then
         print(("[snabb-lwaftr: %s caught]"):format(sig:upper()))
         f()
      end
  end, 1e4, 'repeating'))
end

LwAftr = {}

function LwAftr:new(conf)
   if type(conf) == 'string' then
      conf = lwconf.load_lwaftr_config(conf)
   end
   if conf.debug then debug = true end
   local o = setmetatable({}, {__index=LwAftr})
   o.conf = conf

   -- FIXME: Access these from the conf instead of splatting them onto
   -- the lwaftr app, if there is no performance impact.
   o.aftr_ipv4_ip = conf.aftr_ipv4_ip
   o.aftr_ipv6_ip = conf.aftr_ipv6_ip
   o.aftr_mac_b4_side = conf.aftr_mac_b4_side or ethernet:pton("00:00:00:00:00:00")
   o.aftr_mac_inet_side = conf.aftr_mac_inet_side
   o.b4_mac = conf.b4_mac
   o.hairpinning = conf.hairpinning
   o.icmpv6_rate_limiter_n_packets = conf.icmpv6_rate_limiter_n_packets
   o.icmpv6_rate_limiter_n_seconds = conf.icmpv6_rate_limiter_n_seconds
   o.inet_mac = conf.inet_mac
   o.ipv4_mtu = conf.ipv4_mtu
   o.ipv6_mtu = conf.ipv6_mtu
   o.policy_icmpv4_incoming = conf.policy_icmpv4_incoming
   o.policy_icmpv4_outgoing = conf.policy_icmpv4_outgoing
   o.policy_icmpv6_incoming = conf.policy_icmpv6_incoming
   o.policy_icmpv6_outgoing = conf.policy_icmpv6_outgoing

   o.binding_table = bt.load(o.conf.binding_table)

   transmit_icmpv6_with_rate_limit = init_transmit_icmpv6_with_rate_limit(o)
   on_signal("hup", function()
      print('Reloading binding table.')
      o.binding_table = bt.load(o.conf.binding_table)
   end)
   on_signal("usr1", function()
      dump.dump_configuration(o)
      dump.dump_binding_table(o)
   end)
   if debug then lwdebug.pp(conf) end
   return o
end

local function decrement_ttl(pkt)
   local ipv4_header = get_ethernet_payload(pkt)
   local checksum = bnot(ntohs(rd16(ipv4_header + o_ipv4_checksum)))
   local old_ttl = ipv4_header[o_ipv4_ttl]
   local new_ttl = band(old_ttl - 1, 0xff)
   ipv4_header[o_ipv4_ttl] = new_ttl
   -- Now fix up the checksum.  o_ipv4_ttl is the first byte in the
   -- 16-bit big-endian word, so the difference to the overall sum is
   -- multiplied by 0xff.
   checksum = checksum + lshift(new_ttl - old_ttl, 8)
   -- Now do the one's complement 16-bit addition of the 16-bit words of
   -- the checksum, which necessarily is a 32-bit value.  Two carry
   -- iterations will suffice.
   checksum = band(checksum, 0xffff) + rshift(checksum, 16)
   checksum = band(checksum, 0xffff) + rshift(checksum, 16)
   wr16(ipv4_header + o_ipv4_checksum, htons(bnot(checksum)))
   return new_ttl
end

-- https://www.ietf.org/id/draft-farrer-softwire-br-multiendpoints-01.txt
-- Return the IPv6 address of the B4 and the AFTR.
local function binding_lookup_ipv4(lwstate, ipv4_ip, port)
   if debug then
      print(lwdebug.format_ipv4(ipv4_ip), 'port: ', port, string.format("%x", port))
      lwdebug.pp(lwstate.binding_table)
   end
   local val = lwstate.binding_table:lookup(ipv4_ip, port)
   if val then
      return val.b4_ipv6, lwstate.binding_table:get_br_address(val.br)
   end
   if debug then
      print("Nothing found for ipv4:port", lwdebug.format_ipv4(ipv4_ip),
      string.format("%i (0x%x)", port, port))
   end
end

local function ipv4_in_binding_table(lwstate, ip)
   return lwstate.binding_table:is_managed_ipv4_address(ip)
end

local uint64_ptr_t = ffi.typeof('uint64_t*')
local function ipv6_equals(a, b)
   local a, b = ffi.cast(uint64_ptr_t, a), ffi.cast(uint64_ptr_t, b)
   return a[0] == b[0] and a[1] == b[1]
end

local function in_binding_table(lwstate, ipv6_src_ip, ipv6_dst_ip, ipv4_src_ip, ipv4_src_port)
   local b4, br = binding_lookup_ipv4(lwstate, ipv4_src_ip, ipv4_src_port)
   return b4 and ipv6_equals(b4, ipv6_src_ip) and ipv6_equals(br, ipv6_dst_ip)
end

-- ICMPv4 type 3 code 1, as per RFC 7596.
-- The target IPv4 address + port is not in the table.
local function icmp_after_discard(lwstate, pkt, to_ip)
   local icmp_config = {type = constants.icmpv4_dst_unreachable,
                        code = constants.icmpv4_host_unreachable,
                        }
   local icmp_dis = icmp.new_icmpv4_packet(lwstate.aftr_mac_inet_side, lwstate.inet_mac,
                                           lwstate.aftr_ipv4_ip, to_ip, pkt,
                                           ethernet_header_size, icmp_config)
   return transmit(lwstate.o4, icmp_dis)
end

-- ICMPv6 type 1 code 5, as per RFC 7596.
-- The source (ipv6, ipv4, port) tuple is not in the table.
local function icmp_b4_lookup_failed(lwstate, pkt, to_ip)
   local icmp_config = {type = constants.icmpv6_dst_unreachable,
                        code = constants.icmpv6_failed_ingress_egress_policy,
                       }
   local b4fail_icmp = icmp.new_icmpv6_packet(lwstate.aftr_mac_b4_side, lwstate.b4_mac,
                                              lwstate.aftr_ipv6_ip, to_ip, pkt,
                                              ethernet_header_size, icmp_config)
   transmit_icmpv6_with_rate_limit(lwstate.o6, b4fail_icmp)
end

local function encapsulating_packet_with_df_flag_would_exceed_mtu(lwstate, pkt)
   local payload_length = get_ethernet_payload_length(pkt)
   if payload_length + ipv6_fixed_header_size <= lwstate.ipv6_mtu then
      -- Packet will not exceed MTU.
      return false
   end
   -- The result would exceed the IPv6 MTU; signal an error via ICMPv4 if
   -- the IPv4 fragment has the DF flag.
   return band(get_ipv4_flags(get_ethernet_payload(pkt)), 0x40) == 0x40
end

local function cannot_fragment_df_packet_error(lwstate, pkt)
   -- According to RFC 791, the original packet must be discarded.
   -- Return a packet with ICMP(3, 4) and the appropriate MTU
   -- as per https://tools.ietf.org/html/rfc2473#section-7.2
   if debug then lwdebug.print_pkt(pkt) end
   -- The ICMP packet should be set back to the packet's source.
   local dst_ip = get_ipv4_src_address_ptr(get_ethernet_payload(pkt))
   local icmp_config = {
      type = constants.icmpv4_dst_unreachable,
      code = constants.icmpv4_datagram_too_big_df,
      extra_payload_offset = 0,
      next_hop_mtu = lwstate.ipv6_mtu - constants.ipv6_fixed_header_size,
   }
   return icmp.new_icmpv4_packet(lwstate.aftr_mac_inet_side, lwstate.inet_mac,
                                 lwstate.aftr_ipv4_ip, dst_ip, pkt,
                                 ethernet_header_size, icmp_config)
end

-- Given a packet containing IPv4 and Ethernet, encapsulate the IPv4 portion.
local function ipv6_encapsulate(lwstate, pkt, next_hdr_type, ipv6_src, ipv6_dst,
                                 ether_src, ether_dst)
   -- TODO: decrement the IPv4 ttl as this is part of forwarding
   -- TODO: do not encapsulate if ttl was already 0; send icmp
   if debug then print("ipv6", ipv6_src, ipv6_dst) end

   if encapsulating_packet_with_df_flag_would_exceed_mtu(lwstate, pkt) then
      local icmp_pkt = cannot_fragment_df_packet_error(lwstate, pkt)
      drop(pkt)
      return transmit(lwstate.o4, icmp_pkt)
   end

   local payload_length = get_ethernet_payload_length(pkt)
   local l3_header = get_ethernet_payload(pkt)
   local dscp_and_ecn = get_ipv4_dscp_and_ecn(l3_header)
   packet.shiftright(pkt, ipv6_fixed_header_size)
   write_eth_header(pkt.data, ether_src, ether_dst, n_ethertype_ipv6)
   write_ipv6_header(l3_header, ipv6_src, ipv6_dst,
                     dscp_and_ecn, next_hdr_type, payload_length)

   if debug then
      print("encapsulated packet:")
      lwdebug.print_pkt(pkt)
   end
   return transmit(lwstate.o6, pkt)
end

local function icmpv4_incoming(lwstate, pkt)
   local ipv4_header = get_ethernet_payload(pkt)
   local ipv4_header_size = get_ipv4_header_length(ipv4_header)
   local icmp_header = get_ipv4_payload(ipv4_header)
   local icmp_type = get_icmp_type(icmp_header)

   -- RFC 7596 is silent on whether to validate echo request/reply checksums.
   -- ICMP checksums SHOULD be validated according to RFC 5508.
   -- Choose to verify the echo reply/request ones too.
   -- Note: the lwaftr SHOULD NOT validate the transport checksum of the embedded packet.
   -- Were it to nonetheless do so, RFC 4884 extension headers MUST NOT
   -- be taken into account when validating the checksum
   local icmp_bytes = get_ipv4_total_length(ipv4_header) - ipv4_header_size
   if checksum.ipsum(icmp_header, icmp_bytes, 0) ~= 0 then
      -- Silently drop the packet, as per RFC 5508
      return drop(pkt)
   end

   local source_port, ipv4_dst

   -- checksum was ok
   if icmp_type == constants.icmpv4_echo_reply or icmp_type == constants.icmpv4_echo_request then
      source_port = get_icmpv4_echo_identifier(icmp_header)
      -- Use the outermost IP header for the destination; it's not
      -- repeated in the payload.
      ipv4_dst = get_ipv4_dst_address(ipv4_header)
   else
      -- As per REQ-3, use the ip address embedded in the ICMP payload
      -- TODO: explicitly check for tcp/udp?
      local embedded_ipv4_header = get_icmp_payload(icmp_header)
      source_port = get_ipv4_payload_src_port(embedded_ipv4_header)
      ipv4_dst = get_ipv4_src_address(embedded_ipv4_header)
   end
   local ipv6_dst, ipv6_src = binding_lookup_ipv4(lwstate, ipv4_dst, source_port)
   if not ipv6_dst then
      -- No match found in the binding table; the packet MUST be
      -- discarded.
      return drop(pkt)
   end
   -- Otherwise, the packet MUST be forwarded
   local next_hdr = proto_ipv4
   return ipv6_encapsulate(lwstate, pkt, next_hdr, ipv6_src, ipv6_dst,
                           lwstate.aftr_mac_b4_side, lwstate.b4_mac)
end

-- The incoming packet is a complete one with ethernet headers.
-- FIXME: Verify that the total_length declared in the packet is correct.
local function from_inet(lwstate, pkt)
   -- Check incoming ICMP -first-, because it has different binding table lookup logic
   -- than other protocols.
   local ipv4_header = get_ethernet_payload(pkt)
   if get_ipv4_proto(ipv4_header) == proto_icmp then
      if lwstate.policy_icmpv4_incoming == lwconf.policies['DROP'] then
         return drop(pkt)
      else
         return icmpv4_incoming(lwstate, pkt)
      end
   end

   -- It's not incoming ICMP.  Assume we can find ports in the IPv4
   -- payload, as in TCP and UDP.  We could check strictly for TCP/UDP,
   -- but that would filter out similarly-shaped protocols like SCTP, so
   -- we optimistically assume that the incoming traffic has the right
   -- shape.
   local dst_ip = get_ipv4_dst_address(ipv4_header)
   local dst_port = get_ipv4_payload_dst_port(ipv4_header)
   local ipv6_dst, ipv6_src = binding_lookup_ipv4(lwstate, dst_ip, dst_port)
   if not ipv6_dst then
      -- Lookup failed.
      if debug then print("lookup failed") end
      if lwstate.policy_icmpv4_outgoing == lwconf.policies['DROP'] then
         return drop(pkt)
      else
         local to_ip = get_ipv4_src_address_ptr(ipv4_header)
         -- ICMPv4 type 3 code 1 (dst/host unreachable)
         return icmp_after_discard(lwstate, pkt, to_ip)
      end
   end

   local ether_src = lwstate.aftr_mac_b4_side
   local ether_dst = lwstate.b4_mac -- FIXME: this should probaby use NDP

   -- Do not encapsulate packets that now have a ttl of zero or wrapped around
   local ttl = decrement_ttl(pkt)
   if ttl == 0 or ttl == 255 then
      if lwstate.policy_icmpv4_outgoing == lwconf.policies['DROP'] then
         return
      end
      local dst_ip = get_ipv4_src_address_ptr(ipv4_header)
      local icmp_config = {type = constants.icmpv4_time_exceeded,
                           code = constants.icmpv4_ttl_exceeded_in_transit,
                           }
      local ttl0_icmp =  icmp.new_icmpv4_packet(lwstate.aftr_mac_inet_side, lwstate.inet_mac,
                                                lwstate.aftr_ipv4_ip, dst_ip, pkt,
                                                ethernet_header_size, icmp_config)
      return transmit(lwstate.o4, ttl0_icmp)
   end

   local next_hdr = proto_ipv4
   return ipv6_encapsulate(lwstate, pkt, next_hdr, ipv6_src, ipv6_dst,
                           ether_src, ether_dst)
end

local function tunnel_unreachable(lwstate, pkt, code, next_hop_mtu)
   local ipv6_header = get_ethernet_payload(pkt)
   local icmp_header = get_ipv6_payload(ipv6_header)
   local embedded_ipv6_header = get_icmp_payload(icmp_header)
   local embedded_ipv4_header = get_ipv6_payload(embedded_ipv6_header)

   local icmp_config = {type = constants.icmpv4_dst_unreachable,
                        code = code,
                        extra_payload_offset = embedded_ipv4_header - ipv6_header,
                        next_hop_mtu = next_hop_mtu
                        }
   local dst_ip = get_ipv4_src_address_ptr(embedded_ipv4_header)
   local icmp_reply = icmp.new_icmpv4_packet(lwstate.aftr_mac_inet_side, lwstate.inet_mac,
                                             lwstate.aftr_ipv4_ip, dst_ip, pkt,
                                             ethernet_header_size, icmp_config)
   return icmp_reply
end

local function transmit_translated_icmpv4_reply(lwstate, pkt)
   -- If the ICMPv4 packet is in response to a packet from the external
   -- network, send it there. If hairpinning is/was enabled, it could be
   -- from a b4; if it was from a b4, encapsulate the generated IPv4
   -- message and send it.  This is the most plausible reading of RFC
   -- 2473, although not unambigous.
   local ipv4_header = get_ethernet_payload(pkt)
   local icmp_header = get_ipv4_payload(ipv4_header)
   local embedded_ipv4_header = get_icmp_payload(icmp_header)
   local embedded_ipv4_src_ip = get_ipv4_src_address(embedded_ipv4_header)
   if lwstate.hairpinning and ipv4_in_binding_table(lwstate, embedded_ipv4_src_ip) then
      if debug then print("Hairpinning ICMPv4 mapped from ICMPv6") end
      return icmpv4_incoming(lwstate, pkt) -- to B4
   else
      return transmit(lwstate.o4, pkt)
   end
end

-- FIXME: Verify that the softwire is in the the binding table.
local function icmpv6_incoming(lwstate, pkt)
   local ipv6_header = get_ethernet_payload(pkt)
   local icmp_header = get_ipv6_payload(ipv6_header)
   local icmp_type = get_icmp_type(icmp_header)
   local icmp_code = get_icmp_code(icmp_header)
   local icmpv4_reply
   if icmp_type == constants.icmpv6_packet_too_big then
      if icmp_code ~= constants.icmpv6_code_packet_too_big then
         -- Invalid code.
         return drop(pkt)
      end
      local mtu = get_icmp_mtu(icmp_header) - constants.ipv6_fixed_header_size
      icmpv4_reply = tunnel_unreachable(lwstate, pkt,
                                        constants.icmpv4_datagram_too_big_df,
                                        mtu)
   -- Take advantage of having already checked for 'packet too big' (2), and
   -- unreachable node/hop limit exceeded/paramater problem being 1, 3, 4 respectively
   elseif icmp_type <= constants.icmpv6_parameter_problem then
      -- If the time limit was exceeded, require it was a hop limit code
      if icmp_type == constants.icmpv6_time_limit_exceeded then
         if icmp_code ~= constants.icmpv6_hop_limit_exceeded then
            return drop(pkt)
         end
      end
      -- Accept all unreachable or parameter problem codes
      icmpv4_reply = tunnel_unreachable(lwstate, pkt,
                                        constants.icmpv4_host_unreachable)
   else
      -- No other types of ICMPv6, including echo request/reply, are
      -- handled.
      return drop(pkt)
   end

   drop(pkt)
   return transmit_translated_icmpv4_reply(lwstate, icmpv4_reply)
end

-- FIXME: Verify that the packet length is big enough?
local function from_b4(lwstate, pkt)
   local ipv6_header = get_ethernet_payload(pkt)
   local proto = get_ipv6_next_header(ipv6_header)

   if proto ~= proto_ipv4 then
      if proto == proto_icmpv6 then
         if lwstate.policy_icmpv6_incoming == lwconf.policies['DROP'] then
            return drop(pkt)
         else
            return icmpv6_incoming(lwstate, pkt)
         end
      else
         -- Drop packet with unknown protocol.
         return drop(pkt)
      end
   end

   local ipv6_src_ip = get_ipv6_src_address(ipv6_header)
   local ipv6_dst_ip = get_ipv6_dst_address(ipv6_header)
   local tunneled_ipv4_header = get_ipv6_payload(ipv6_header)
   local ipv4_src_ip = get_ipv4_src_address(tunneled_ipv4_header)
   local ipv4_dst_ip = get_ipv4_dst_address(tunneled_ipv4_header)
   -- FIXME: Handle non-TCP, non-UDP payloads.
   local ipv4_src_port = get_ipv4_payload_src_port(tunneled_ipv4_header)

   if in_binding_table(lwstate, ipv6_src_ip, ipv6_dst_ip, ipv4_src_ip, ipv4_src_port) then
      -- Is it worth optimizing this to change src_eth, src_ipv6, ttl,
      -- checksum, rather than decapsulating + re-encapsulating? It
      -- would be faster, but more code.
      if lwstate.hairpinning and ipv4_in_binding_table(lwstate, ipv4_dst_ip) then
         -- Remove IPv6 header.
         packet.shiftleft(pkt, ipv6_fixed_header_size)
         write_eth_header(pkt.data, lwstate.b4_mac, lwstate.aftr_mac_b4_side,
                          n_ethertype_ipv4)
         -- TODO:  refactor so this doesn't actually seem to be from the internet?
         return from_inet(lwstate, pkt)
      else
         -- Remove IPv6 header.
         packet.shiftleft(pkt, ipv6_fixed_header_size)
         write_eth_header(pkt.data, lwstate.aftr_mac_inet_side, lwstate.inet_mac,
                          n_ethertype_ipv4)
         return transmit(lwstate.o4, pkt)
      end
   elseif lwstate.policy_icmpv6_outgoing == lwconf.policies['ALLOW'] then
      icmp_b4_lookup_failed(lwstate, pkt, ipv6_src_ip)
      return drop(pkt)
   else
      return drop(pkt)
   end
end

function LwAftr:push ()
   local i4, i6 = self.input.v4, self.input.v6
   local o4, o6 = self.output.v4, self.output.v6
   self.o4, self.o6 = o4, o6

   for _=1,link.nreadable(i4) do
      -- Encapsulate incoming IPv4 packets from the internet interface.
      -- Drop anything that's not IPv4.
      local pkt = receive(i4)
      if is_ipv4(pkt) then
         from_inet(self, pkt)
      else
         drop(pkt)
      end
   end

   for _=1,link.nreadable(i6) do
      -- Decapsulate or hairpin incoming IPv6 packets from the B4
      -- interface.  Drop anything that's not IPv6.
      local pkt = receive(i6)
      if is_ipv6(pkt) then
         from_b4(self, pkt)
      else
         drop(pkt)
      end
   end
end
