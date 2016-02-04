module(..., package.seeall)

-- NDP address resolution.
-- Given a remote IPv6 address, try to find out its MAC address.
-- Exit if this fails.
-- If resolution succeeds:
-- All packets coming through the 'south' interface (ie, via the network card)
-- are silently forwarded.
-- All packets coming through the 'north' interface (the lwaftr) will have
-- their Ethernet headers rewritten.

-- Expected configuration:
-- lwaftr <-> ipv6 fragmentation app <-> lw_eth_resolve <-> vlan tag handler
-- That is, neither fragmentation nor vlan tagging are within the scope of this app.

local constants = require("apps.lwaftr.constants")
local lwutil = require("apps.lwaftr.lwutil")

local datagram = require("lib.protocol.datagram")
local ethernet = require("lib.protocol.ethernet")
local ipv6 = require("lib.protocol.ipv6")

local checksum = require("lib.checksum")
local ffi = require("ffi")

local C = ffi.C
local rd16, wr16, wr32 = lwutil.rd16, lwutil.wr16, lwutil.wr32

local option_source_link_layer_address = 1
local option_target_link_layer_address = 2
local eth_ipv6_size = 14 + 40

-- Special addresses
ipv6_all_nodes_local_segment_addr = ipv6:pton("ff02::1")
ipv6_unspecified_addr = ipv6:pton("0::0") -- aka ::/128
-- Really just the first 13 bytes of the following...
ipv6_solicited_multicast = ipv6:pton("ff02:0000:0000:0000:0000:0001:ff00:00")

local _scratch_pseudoheader = ffi.new('uint8_t[40]')
local lwdebug = require("apps.lwaftr.lwdebug")

-- Given a pointer to 40 bytes representing an IPv6 header,
-- calculate the checksum the pseudo-header would have if
-- the pseudo-header werer actually constructed.
local function checksum_pseudoheader_from_header(ipv6_fixed_header)
   ffi.fill(_scratch_pseudoheader, 40)
   ffi.copy(_scratch_pseudoheader, ipv6_fixed_header + 8, 32)
   ffi.copy(_scratch_pseudoheader + 34, ipv6_fixed_header + 4, 2)
   ffi.copy(_scratch_pseudoheader + 39, ipv6_fixed_header + 6, 1)
   return checksum.ipsum(_scratch_pseudoheader, 40, 0)
end

local function eth_next_is_ipv6(pkt)
   return rd16(pkt.data + 12) == constants.n_ethertype_ipv6
end

local function ipv6_next_is_icmp6(pkt)
   local offset = 20 -- 14 Ethernet + 6 IPv6 header bytes, 0-indexed
   return pkt.data[offset] == constants.proto_icmpv6
end

local function icmpv6_type_is_na(pkt)
   return pkt.data[eth_ipv6_size] == constants.icmpv6_na
end

local function icmpv6_type_is_ns(pkt)
   return pkt.data[eth_ipv6_size] == constants.icmpv6_ns
end

-- The relevant byte is:
-- [ R S O 0 0 0 0 0 0 ], where S = solicited
local function is_solicited_na(pkt)
   local offset = eth_ipv6_size + 4
   return bit.band(0x40, pkt.data[offset]) == 0x40
end

function is_ndp(pkt)
   if pkt.length > 57 and
      eth_next_is_ipv6(pkt) and
      ipv6_next_is_icmp6(pkt)
   then
      local icmp_type = pkt.data[eth_ipv6_size]
      return (icmp_type >= 133 and icmp_type <= 137)
   end
   return false
end

-- TODO: tune this for speed
-- Note that this must be run after any vlan tags have been stripped out
-- and after any reassembly has been done, and no extra IPv6 headers
-- must be present
--- TODO: could this reasonably use pflang?
function is_solicited_neighbor_announcement(pkt)
   return is_ndp(pkt) and
          icmpv6_type_is_na(pkt) and
          is_solicited_na(pkt)
end

function is_neighbor_solicitation(pkt)
   return is_ndp(pkt) and icmpv6_type_is_ns(pkt)
end

function get_dst_ethernet(p, target_ipv6_addr)
   local na_addr_offset = eth_ipv6_size + 8
   if C.memcmp(target_ipv6_addr, pkt.data + na_addr_offset, 16) == 0 then
      if pkt.data[na_eth_offset] == option_target_link_layer_address then
         return pkt.data + eth_ipv6_size + 24 + 2
      end
   end
   return false
end

local function write_ndp(pkt, local_eth, target_addr, i_type, flags)
   local i_code = 0
   pkt.data[0] = i_type
   pkt.data[1] = i_code
   wr16(pkt.data + 2, 0) -- initial 0 checksum
   wr32(pkt.data + 4, 0) -- 29-32 reserved bits, depending on type
   pkt.data[4] = flags
   ffi.copy(pkt.data + 8, target_addr, 16)

   -- The link layer address SHOULD or MUST be set, so set it
   pkt.data[24] = 2 -- target link layer address
   pkt.data[25] = 1 -- this option is one 8-octet chunk long
   ffi.copy(pkt.data + 26, local_eth, 6)
   pkt.length = 32
end

-- This only does solicited neighbor announcements
local function write_sna(pkt, local_eth, is_router, soliciting_pkt, base_checksum)
   local target_addr = soliciting_pkt.data + eth_ipv6_size + 8
   local i_type = 136 -- RFC 4861 neighbor advertisement
   local flags = 0x40 -- solicited
   -- don't support the override flag for now; TODO?
   if is_router then flags = flags + 0x80 end
   write_ndp(pkt, local_eth, target_addr, i_type, flags)
end

-- This does not allow setting any options in the packet.
-- Target address must be in the format that results from pton.
local function write_ns(pkt, local_eth, target_addr)
   local i_type = 135 -- RFC 4861 neighbor solicitation
   write_ndp(pkt, local_eth, target_addr, i_type, 0)
end


function form_ns(local_eth, local_ipv6, dst_ipv6)
   local ns_pkt = packet.allocate()
   local ethernet_broadcast = ethernet:pton("ff:ff:ff:ff:ff:ff")
   local hop_limit = 255 -- as per RFC 4861

   write_ns(ns_pkt, local_eth, dst_ipv6)
   local dgram = datagram:new(ns_pkt)
   local i = ipv6:new({ hop_limit = hop_limit, 
                        next_header = constants.proto_icmpv6,
                        src = local_ipv6, dst = dst_ipv6 })
   i:payload_length(ns_pkt.length)
   
   local ph = i:pseudo_header(ns_pkt.length, constants.proto_icmpv6)
   ph_len = 40
   local base_checksum = checksum.ipsum(ffi.cast("uint8_t*", ph), ph_len, 0)
   local csum = checksum.ipsum(ns_pkt.data, ns_pkt.length, bit.bnot(base_checksum))
   wr16(ns_pkt.data + 2, C.htons(csum))
   
   dgram:push(i)
   dgram:push(ethernet:new({ src = local_eth, dst = ethernet_broadcast,
                             type = constants.ethertype_ipv6 }))
   dgram:free()
   return ns_pkt
end

--[[ IPv6 Destination Address
                     For solicited advertisements, the Source Address of
                     an invoking Neighbor Solicitation or, if the
                     solicitation s Source Address is the unspecified
                     address, the all-nodes multicast address.
--]]
-- TODO: verify that the all nodes *local segment* rather than *node local*
-- IPv6 multicast address is the right one.
local function form_sna(local_eth, local_ipv6, is_router, soliciting_pkt)
   if not soliciting_pkt then return nil end
   local na_pkt = packet.allocate()
   -- The destination of the reply is the source of the original packet
   local dst_eth = soliciting_pkt.data + 6
   local hop_limit = 255 -- as per RFC 4861

   write_sna(na_pkt, local_eth, is_router, soliciting_pkt)
   local dgram = datagram:new(na_pkt)
   local src_addr_offset = 14 + 8
   local invoking_src_addr = soliciting_pkt.data + src_addr_offset
   local dst_ipv6
   if C.memcmp(invoking_src_addr, ipv6_unspecified_addr, 16) ~= 0 then
      dst_ipv6 = invoking_src_addr
   else
      dst_ipv6 = ipv6_all_nodes_local_segment_addr
   end
   local i = ipv6:new({ hop_limit = hop_limit,
                        next_header = constants.proto_icmpv6,
                        src = local_ipv6, dst = dst_ipv6 })
   i:payload_length(na_pkt.length)
   
   local ph = i:pseudo_header(na_pkt.length, constants.proto_icmpv6)
   ph_len = 40
   local base_checksum = checksum.ipsum(ffi.cast("uint8_t*", ph), ph_len, 0)
   local csum = checksum.ipsum(na_pkt.data, na_pkt.length, bit.bnot(base_checksum))
   wr16(na_pkt.data + 2, C.htons(csum))
   
   dgram:push(i)
   dgram:push(ethernet:new({ src = local_eth, dst = dst_eth,
                             type = constants.ethertype_ipv6 }))
   dgram:free()
   return na_pkt
end

-- This does not deal with vlans
function set_dst_ethernet(pkt, dst_eth)
   ffi.copy(pkt.data, dst_eth, 6)
end

local function verify_icmp_checksum(pkt)
   local icmp_length = C.ntohs(rd16(pkt.data + 18))
   ph_csum = checksum_pseudoheader_from_header(pkt.data + 14)
   local a = checksum.ipsum(pkt.data + eth_ipv6_size, icmp_length, bit.bnot(ph_csum))
   local raw_without_pseudo = checksum.ipsum(pkt.data + eth_ipv6_size, icmp_length, 0)
   return a == 0
end

-- IPv6 multicast addresses start with FF.
local function is_address_multicast(ipv6_addr)
   return ipv6_addr[0] == 0xff
end

local function target_address_is_multicast(pkt)
   return is_address_multicast(pkt.data + eth_ipv6_size + 8)
end

-- Each 1 added to length represents an 8 octet chunk.
local function option_lengths_are_nonzero(pkt)
   local start = eth_ipv6_size + 24
   while start < pkt.length do
      local cur_option_length = pkt.data[start + 1]
      if cur_option_length == 0 then return false end
      start = start + 8 * cur_option_length
   end
   return true
end

-- Solicited multicast addresses have their first 13 bytes
-- set to ff02::1:ff00:0/104, aka
-- ff02:0000:0000:0000:0000:0001:ff
local function ip_dst_is_solicited_node_multicast_address(pkt)
   return C.memcmp(pkt.data + 14 + 24, ipv6_solicited_multicast, 13) == 0
end

local function has_src_link_layer_address_option(pkt)
   local start = eth_ipv6_size + 24
   while start < pkt.length do
      local cur_option_length = pkt.data[start + 1]
      local cur_option_type = pkt.data[start]
      if cur_option_type == option_source_link_layer_address then return true end
      start = start + 8 * cur_option_length
   end
   return false
end

--[[ RFC 4861
   A node MUST silently discard any received Neighbor Solicitation
   messages that do not satisfy all of the following validity checks:

      - The IP Hop Limit field has a value of 255, i.e., the packet
        could not possibly have been forwarded by a router.
      - ICMP length (derived from the IP length) is 24 or more octets.
      - ICMP Checksum is valid.
      - ICMP Code is 0.
      - Target Address is not a multicast address.
      - All included options have a length that is greater than zero.
      - If the IP source address is the unspecified address, the IP
        destination address is a solicited-node multicast address.
      - If the IP source address is the unspecified address, there is no
        source link-layer address option in the message.
--]]
-- Note that any vlan/etc tags have been stripped off already by another app
local function is_valid_ns(pkt)
   -- Verify that there are no extra IPv6 headers via is_ndp
   if not is_ndp(pkt) then return false end

   local ip_offset = 14
   local ip_hop_offset = ip_offset + 7
   if pkt.data[ip_hop_offset] ~= 255 then return false end

   local iplen_offset = ip_offset + 4
   local icmp_length = C.ntohs(rd16(pkt.data + iplen_offset))
   if icmp_length < 24 then return false end
   if not verify_icmp_checksum(pkt) then return false end
   local icmp_code_offset = eth_ipv6_size + 1
   if pkt.data[icmp_code_offset] ~= 0 then return false end

   if target_address_is_multicast(pkt) then return false end
   if not option_lengths_are_nonzero(pkt) then return false end
   if C.memcmp(ipv6_unspecified_addr, pkt.data + ip_offset + 8, 16) == 0 then
      if ip_dst_is_solicited_node_multicast_address(pkt) then return false end
      if has_src_link_layer_address_option(pkt) then return false end
   end
   return true -- all checks passed
end

function form_nsolicitation_reply(local_eth, local_ipv6, ns_pkt)
   if not local_eth or not local_ipv6 then return nil end
   if not is_valid_ns(ns_pkt) then return nil end
   return form_sna(local_eth, local_ipv6, true, ns_pkt)
end

function selftest()
   local lmac = ethernet:pton("01:02:03:04:05:06")
   local lip = ipv6:pton("1:2:3:4:5:6:7:8")
   local rip = ipv6:pton("9:a:b:c:d:e:f:0")
   local nsp = form_ns(lmac, lip, rip)
   assert(is_ndp(nsp))
   assert(is_solicited_neighbor_announcement(nsp) == false)
   set_dst_ethernet(nsp, lmac) -- Not a meaningful thing to do, just a test
   
   local sol_na = form_nsolicitation_reply(lmac, lip, nsp)
   assert(sol_na, "an na packet should have been formed")
   assert(is_ndp(sol_na), "sol_na must be ndp!")
   assert(is_solicited_neighbor_announcement(sol_na), "sol_na must be sna!")
end
