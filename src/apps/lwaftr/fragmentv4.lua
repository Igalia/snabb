module(..., package.seeall)

local constants = require("apps.lwaftr.constants")
local lwutil = require("apps.lwaftr.lwutil")
local packet = require("core.packet")
local ipsum = require("lib.checksum").ipsum
local bit = require("bit")
local ffi = require("ffi")

local rd16, wr16, get_ihl_from_offset = lwutil.rd16, lwutil.wr16, lwutil.get_ihl_from_offset
local cast = ffi.cast
local C = ffi.C
local band, bor = bit.band, bit.bor
local ceil = math.ceil

-- Constants to manipulate the flags next to the frag-offset field directly
-- as a 16-bit integer, without needing to shift the 3 flag bits.
local flag_dont_fragment_mask  = 0x4000
local flag_more_fragments_mask = 0x2000
local frag_offset_field_mask   = 0x1FFF

-- TODO: Consider security/performance tradeoffs of randomization
local fresh_frag_id = (function ()
   local internal_frag_id = 0x4242
   return function ()
      internal_frag_id = band(internal_frag_id + 1, 0xFFFF)
      return internal_frag_id
   end
end)()

FRAGMENT_OK = 1
FRAGMENT_UNNEEDED = 2
FRAGMENT_FORBIDDEN = 3

--
-- IPv4 fragmentation, as per https://tools.ietf.org/html/rfc791
--
-- For an invocation:
--
--    local statuscode, packets = fragment_ipv4(input_packet, l2_size, mtu)
--
-- the possible values for the returned "statuscode" are:
--
--   * FRAGMENT_OK: the returned "packets" is a list of IPv4 packets, all
--     of them smaller or equal than "mtu" bytes, which contain the payload
--     from the "input_packet" properly fragmented. Note that "input_packet"
--     is modified in-place.
--
--   * FRAGMENT_UNNEEDED: the returned "packets" is the same object as
--     "input_packet", unmodified. This is the case when the size of packet
--     is smaller or equal than "mtu" bytes.
--
--   * FRAGMENT_FORBIDDEN: the returned "packets" will be "nil". This is
--     the case when "input_packet" has the "don't fragment" flag set, and
--     its size is bigger than "mtu" bytes. Client code may want to return
--     an ICMP Datagram Too Big (Type 3, Code 4) packet back to the sender.
--
function fragment_ipv4(ipv4_pkt, l2_size, mtu)
   if ipv4_pkt.length <= mtu then
      return FRAGMENT_UNNEEDED, ipv4_pkt
   end

   local ver_and_ihl_offset = l2_size + constants.o_ipv4_ver_and_ihl
   local total_length_offset = l2_size + constants.o_ipv4_total_length
   local frag_id_offset = l2_size + constants.o_ipv4_identification
   local flags_and_frag_offset_offset = l2_size + constants.o_ipv4_flags
   local checksum_offset = l2_size + constants.o_ipv4_checksum
   -- Discard packets with the DF (dont't fragment) flag set
   do
      local flags_and_frag_offset = C.ntohs(rd16(ipv4_pkt.data + flags_and_frag_offset_offset))
      if band(flags_and_frag_offset, flag_dont_fragment_mask) ~= 0 then
         return FRAGMENT_FORBIDDEN, nil
      end
   end

   local ihl = get_ihl_from_offset(ipv4_pkt, ver_and_ihl_offset)
   local header_size = l2_size + ihl
   local payload_size = ipv4_pkt.length - header_size
   -- Payload bytes per packet must be a multiple of 8
   local payload_bytes_per_packet = band(mtu - header_size, 0xFFF8)
   local total_length_per_packet = payload_bytes_per_packet + ihl
   local num_packets = ceil(payload_size / payload_bytes_per_packet)

   local pkts = { ipv4_pkt }

   wr16(ipv4_pkt.data + frag_id_offset, C.htons(fresh_frag_id()))
   wr16(ipv4_pkt.data + total_length_offset, C.htons(total_length_per_packet))
   wr16(ipv4_pkt.data + flags_and_frag_offset_offset, C.htons(flag_more_fragments_mask))
   wr16(ipv4_pkt.data + checksum_offset, 0)

   local raw_frag_offset = payload_bytes_per_packet

   for i = 2, num_packets - 1 do
      local frag_pkt = packet.allocate()
      ffi.copy(frag_pkt.data, ipv4_pkt.data, header_size)
      ffi.copy(frag_pkt.data + header_size,
               ipv4_pkt.data + header_size + raw_frag_offset,
               payload_bytes_per_packet)
      wr16(frag_pkt.data + flags_and_frag_offset_offset,
           C.htons(bor(flag_more_fragments_mask,
                       band(frag_offset_field_mask, raw_frag_offset / 8))))
      wr16(frag_pkt.data + checksum_offset,
           C.htons(ipsum(frag_pkt.data + ver_and_ihl_offset, ihl, 0)))
      frag_pkt.length = header_size + payload_bytes_per_packet
      raw_frag_offset = raw_frag_offset + payload_bytes_per_packet
      pkts[i] = frag_pkt
   end

   -- Last packet
   local last_pkt = packet.allocate()
   local last_payload_len = payload_size % payload_bytes_per_packet
   ffi.copy(last_pkt.data, ipv4_pkt.data, header_size)
   ffi.copy(last_pkt.data + header_size,
            ipv4_pkt.data + header_size + raw_frag_offset,
            last_payload_len)
   wr16(last_pkt.data + flags_and_frag_offset_offset,
        C.htons(band(frag_offset_field_mask, raw_frag_offset / 8)))
   wr16(last_pkt.data + total_length_offset, C.htons(last_payload_len + ihl))
   wr16(last_pkt.data + checksum_offset,
        C.htons(ipsum(last_pkt.data + ver_and_ihl_offset, ihl, 0)))
   last_pkt.length = header_size + last_payload_len
   pkts[num_packets] = last_pkt

   -- Truncate the original packet, and update its checksum
   ipv4_pkt.length = header_size + payload_bytes_per_packet
   wr16(ipv4_pkt.data + checksum_offset,
        C.htons(ipsum(ipv4_pkt.data + ver_and_ihl_offset, ihl, 0)))

   return FRAGMENT_OK, pkts
end
