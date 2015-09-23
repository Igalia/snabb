module(..., package.seeall)

local constants = require("apps.lwaftr.constants")
local packet = require("core.packet")
local ffi = require("ffi")

local band, bor, lshift = bit.band, bit.bor, bit.lshift
local ntohs, htons = ffi.C.ntohs, ffi.C.htons

local int16_ptr_t = ffi.typeof("uint16_t*")

local total_length_offset = constants.ethernet_header_size + constants.o_ipv4_total_length
local frag_id_offset = constants.ethernet_header_size + constants.o_ipv4_identification
local flags_and_frag_offset_offset = constants.ethernet_header_size + constants.o_ipv4_flags
local ihl_and_ver_offset = constants.ethernet_header_size + constants.o_ipv4_ver_and_ihl

-- Constants to manipulate the flags next to the frag-offset field directly
-- as a 16-bit integer, without needing to shift the 3 flag bits.
local flag_dont_fragment_mask  = 0x4000
local flag_more_fragments_mask = 0x2000
local frag_offset_field_mask   = 0x1FFF


local function get_u16_at_offset(pkt, offset)
	return ntohs(ffi.cast(int16_ptr_t, pkt.data + offset)[0])
end

local function set_u16_at_offset(pkt, offset, value)
	ffi.cast(int16_ptr_t, pkt.data + offset)[0] = htons(value)
end

-- TODO: Consider security/performance tradeoffs of randomization
local internal_frag_id = 0x4242
local function fresh_frag_id()
	internal_frag_id = band(internal_frag_id + 1, 0xFFFF)
	return internal_frag_id
end

-- IPv4 fragmentation, as per https://tools.ietf.org/html/rfc791
function fragment_ipv4(ipv4_pkt, mtu)
	if ipv4_pkt.length <= mtu then
		return ipv4_pkt -- No fragmentation needed
	end

	-- Discard packets with the DF (dont't fragment) flag set
	-- TODO: Check the RFCs, maybe this should return an ICMP error
	if band(get_u16_at_offset(ipv4_pkt, flags_and_frag_offset_offset), flag_dont_fragment_mask) ~= 0 then
		return nil
	end

	-- Given as the amount of 32-bit words, in the lower nibble
	local ihl = band(ipv4_pkt.data[ihl_and_ver_offset], 0xF) * 4
	local header_size = constants.ethernet_header_size + ihl
	local payload_size = ipv4_pkt.length - header_size
	-- Payload bytes per packet must be a multiple of 8
	local payload_bytes_per_packet = band(mtu - header_size, 0xFFF8)
	local total_length_per_packet = payload_bytes_per_packet + ihl
	local num_packets = math.ceil(payload_size / payload_bytes_per_packet)

	local pkts = { ipv4_pkt }

	set_u16_at_offset(ipv4_pkt, frag_id_offset, fresh_frag_id())
	set_u16_at_offset(ipv4_pkt, total_length_offset, total_length_per_packet)
	set_u16_at_offset(ipv4_pkt, flags_and_frag_offset_offset, flag_more_fragments_mask)

	local raw_frag_offset = payload_bytes_per_packet

	for i = 2, num_packets - 1 do
		local frag_pkt = packet.allocate()
		ffi.copy(frag_pkt.data, ipv4_pkt.data, header_size)
		ffi.copy(frag_pkt.data + header_size,
		         ipv4_pkt.data + header_size + raw_frag_offset,
		         payload_bytes_per_packet)
		set_u16_at_offset(frag_pkt, flags_and_frag_offset_offset,
			              bor(flag_more_fragments_mask,
			                  band(frag_offset_field_mask, raw_frag_offset / 8)))
		frag_pkt.length = header_size + payload_bytes_per_packet
		raw_frag_offset = raw_frag_offset + payload_bytes_per_packet
		pkts[i] = frag_pkt
	end

	-- Last packet
	local last_pkt = packet.allocate()
	local last_payload_len = payload_size % payload_bytes_per_packet
	ffi.copy(frag_pkt.data, ipv4_pkt.data, header_size)
	ffi.copy(frag_pkt.data + header_size,
			 ipv4_pkt.data + header_size + raw_frag_offset,
			 last_payload_len)
	set_u16_at_offset(last_pkt, flags_and_frag_offset_offset,
		              band(frag_offset_field_mask, raw_frag_offset / 8))
	set_u16_at_offset(last_pkt, total_length_offset,
	                  last_payload_len + ihl)
	last_pkt.length = header_size + last_payload_len
	pkts[num_packets] = last_pkt

	-- Truncate the original packet
	ipv4_pkt.length = header_size + payload_bytes_per_packet

	return pkts
end
