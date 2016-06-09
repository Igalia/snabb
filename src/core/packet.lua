module(...,package.seeall)

local debug = _G.developer_debug

local ffi = require("ffi")
local C = ffi.C

local freelist = require("core.freelist")
local lib      = require("core.lib")
local memory   = require("core.memory")
local counter  = require("core.counter")
local freelist_add, freelist_remove, freelist_nfree = freelist.add, freelist.remove, freelist.nfree

require("core.packet_h")

local packet_t = ffi.typeof("struct packet")
local packet_ptr_t = ffi.typeof("struct packet *")
local packet_size = ffi.sizeof(packet_t)
local header_size = 8
-- By default, enough headroom for an inserted IPv6 header and a
-- virtio header.
local default_headroom = 64
local max_payload = tonumber(C.PACKET_PAYLOAD_SIZE)

-- Freelist containing empty packets ready for use.
local max_packets = 1e5
local packet_allocation_step = 1000
local packets_allocated = 0
local packets_fl = freelist.new("struct packet *", max_packets)

-- Return an empty packet.
function allocate ()
   if freelist_nfree(packets_fl) == 0 then
      preallocate_step()
   end
   return freelist_remove(packets_fl)
end

-- Create a new empty packet.
function new_packet ()
   local p = ffi.cast(packet_ptr_t, memory.dma_alloc(packet_size))
   p.headroom = default_headroom
   p.data = p.data_ + p.headroom
   p.length = 0
   return p
end

-- Create an exact copy of a packet.
function clone (p)
   local p2 = allocate()
   ffi.copy(p2.data, p.data, p.length)
   p2.length = p.length
   return p2
end

-- Append data to the end of a packet.
function append (p, ptr, len)
   assert(p.length + len <= max_payload, "packet payload overflow")
   ffi.copy(p.data + p.length, ptr, len)
   p.length = p.length + len
   return p
end

-- Prepend data to the start of a packet.
function prepend (p, ptr, len)
   shiftright(p, len)
   ffi.copy(p.data, ptr, len)                -- Fill the gap
   return p
end

-- Move packet data to the left. This shortens the packet by dropping
-- the header bytes at the front.
function shiftleft (p, bytes)
   assert(bytes >= 0 and bytes <= p.length)
   p.data = p.data + bytes
   p.headroom = p.headroom + bytes
   p.length = p.length - bytes
end

-- Move packet data to the right. This leaves length bytes of data
-- at the beginning of the packet.
function shiftright (p, bytes)
   if bytes <= p.headroom then
      -- Take from the headroom.
      assert(bytes >= 0)
      p.headroom = p.headroom - bytes
   else
      -- No headroom for the shift; re-set the headroom to the default.
      assert(bytes <= max_payload - p.length)
      p.headroom = default_headroom
      -- Could be we fit in the packet, but not with headroom.
      if p.length + bytes >= max_payload - p.headroom then p.headroom = 0 end
      C.memmove(p.data_ + p.headroom + bytes, p.data, p.length)
   end
   p.data = p.data_ + p.headroom
   p.length = p.length + bytes
end

-- Conveniently create a packet by copying some existing data.
function from_pointer (ptr, len) return append(allocate(), ptr, len) end
function from_string (d)         return from_pointer(d, #d) end

-- Free a packet that is no longer in use.
local function free_internal (p)
   p.length = 0
   p.headroom = default_headroom
   p.data = p.data_ + p.headroom
   freelist_add(packets_fl, p)
end

function free (p)
   counter.add(engine.frees)
   counter.add(engine.freebytes, p.length)
   -- Calculate bits of physical capacity required for packet on 10GbE
   -- Account for minimum data size and overhead of CRC and inter-packet gap
   counter.add(engine.freebits, (math.max(p.length, 46) + 4 + 5) * 8)
   free_internal(p)
end

-- Return pointer to packet data.
function data (p) return p.data end

-- Return physical address of packet data
function physical (p)
   return memory.memory.virtual_to_physical(p.data)
end

-- Return packet data length.
function length (p) return p.length end

function preallocate_step()
   if _G.developer_debug then
      assert(packets_allocated + packet_allocation_step <= max_packets)
   end

   for i=1, packet_allocation_step do
      free_internal(new_packet(), true)
   end
   packets_allocated = packets_allocated + packet_allocation_step
   packet_allocation_step = 2 * packet_allocation_step
end

function dump(p, w)
   w = w or io.write
   for i = 0, p.length-1 do
      if i % 16 == 0 then w('\n', bit.tohex(i, -4), ': ') end
      w(bit.tohex(p.data[i], -2), ' ')
   end
   w('\n')
end

ffi.metatype(packet_t, {__index = {
   clone = clone,
   append = append,
   prepend = prepend,
   shiftleft = shiftleft,
   free = free,
   physical = physical,
   dump = dump,
}})
