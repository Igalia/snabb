-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- An internal link used for internal buffering in apps.

module(..., package.seeall)

local bit      = require("bit")
local ffi      = require("ffi")
local packet   = require("core.packet")

local max_packets = bit.lshift(1, 10)
local packet_index_mask = max_packets - 1

local band = bit.band

local ilink_t = ffi.typeof([[
   struct {
      int read, write;
      struct packet *packets[$];
   }
]], max_packets)

function new () return ilink_t() end

function count (ilink)
   return band(ilink.write - ilink.read, packet_index_mask)
end

function empty (ilink)
   return ilink.read == ilink.write
end

function push (ilink, p)
   if ilink:count() == max_packets then
      print('warning: ilink overflow; dropping packet')
      packet.free(ilink:pop())
   end

   ilink.packets[band(ilink.write, packet_index_mask)] = p
   ilink.write = ilink.write + 1
end

function pop (ilink)
   if ilink:empty() then error('ilink underflow') end
   local p = ilink.packets[band(ilink.read, packet_index_mask)]
   ilink.read = ilink.read + 1
   return p
end

function peek (ilink, i)
   return ilink.packets[band(ilink.read + i, packet_index_mask)]
end

local mt = { __index = { count=count, push=push, peek=peek, pop=pop,
                         empty=empty },
             __len = count }
ilink_t = ffi.metatype(ilink_t, mt)

function selftest()
   print('selftest: ilink')

   local l = new()
   assert(#l == 0)
   for i = 1, 10 do
      l:push(packet:allocate())
      assert(#l == i)
   end

   while not empty(l) do
      packet.free(pop(l))
   end

   assert(#l == 0)

   print('selftest: ok')
end
