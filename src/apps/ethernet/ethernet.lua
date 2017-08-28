-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- Ethernet header insert and removal.  Removing ethernet headers also
-- checks that packets are of a specified type.

module(..., package.seeall)

local bit      = require("bit")
local ffi      = require("ffi")
local counter  = require("core.counter")
local packet   = require("core.packet")
local link     = require("core.link")
local lib      = require("core.lib")
local ethernet = require("lib.protocol.ethernet")

local receive, transmit = link.receive, link.transmit
local cast = ffi.cast
local htons, ntohs = lib.htons, lib.ntohs

local ether_header_t = ffi.typeof [[
/* All values in network byte order.  */
struct {
   uint8_t  dhost[6];
   uint8_t  shost[6];
   uint16_t type;
} __attribute__((packed))
]]
local ether_header_len = ffi.sizeof(ether_header_t)
local ether_header_ptr_t = ffi.typeof('$*', ether_header_t)

local well_known_ether_types = { ipv4 = 0x0800, ipv6 = 0x86dd, arp = 0x0806 }

local function random_locally_administered_unicast_mac_address()
   local mac = lib.random_bytes(6)
   -- Bit 0 is 0, indicating unicast.  Bit 1 is 1, indicating locally
   -- administered.
   mac[0] = bit.lshift(mac[0], 2) + 2
   return mac
end

local function network_order_ether_type(ether_type)
   if type(ether_type) == 'string' then
      ether_type = assert(well_known_ether_types[ether_type:lower()],
                          "Unknown ethernet type: "..ether_type)
   end
   return ntohs(ether_type)
end

Insert = {}
local insert_config_params = {
   ether_type = { mandatory=true },
   src_addr = { },
   dst_addr = { default='00:00:00:00:00:00' }
}

function Insert:new(conf)
   local o = lib.parse(conf, insert_config_params)
   o.ether_type = network_order_ether_type(o.ether_type)
   if type(o.src_addr) == 'nil' then
      o.src_addr = random_locally_administered_unicast_mac_address()
   elseif type(o.src_addr) == 'string' then
      o.src_addr = ethernet:pton(o.src_addr)
   end
   if type(o.dst_addr) == 'string' then
      o.dst_addr = ethernet:pton(o.dst_addr)
   end
   return setmetatable(o, {__index=Insert})
end

function Insert:push ()
   local input, output = self.input.input, self.output.output
   local src, dst, ether_type = self.src_addr, self.dst_addr, self.ether_type
   for _=1,link.nreadable(input) do
      local pkt = receive(input)
      pkt = packet.shiftright(pkt, ether_header_len)
      local h = cast(ether_header_ptr_t, pkt.data)
      h.shost, h.dhost, h.type = src, dst, ether_type
      transmit(output, pkt)
   end
end

Remove = {}
Remove.shm = {
   drop = {counter}
}
local remove_config_params = {
   ether_type = { mandatory=true }
}

function Remove:new(conf)
   local o = lib.parse(conf, remove_config_params)
   o.ether_type = network_order_ether_type(o.ether_type)
   return setmetatable(o, {__index=Remove})
end

function Remove:push ()
   local input, output = self.input.input, self.output.output
   for _=1,link.nreadable(input) do
      local pkt = receive(input)
      local h = cast(ether_header_ptr_t, pkt.data)
      if h.type == self.ether_type then
         transmit(output, packet.shiftleft(pkt, ether_header_len))
      else
         counter.add(self.shm.drop)
         packet.free(pkt)
      end
   end
end

function selftest()
   print('selftest: ethernet')
   local shm = require("core.shm")

   local function test_insert_remove(pkt, insert_type, remove_type)
      local insert = Insert:new({ether_type=insert_type})
      local remove = Remove:new({ether_type=remove_type})
      remove.shm = shm.create_frame("apps/remove", remove.shm)
      local input, middle = link.new('input'), link.new('middle')
      local output = link.new('output')
      insert.input, insert.output = { input = input }, { output = middle }
      remove.input, remove.output = { input = middle }, { output = output }
      link.transmit(input, packet.clone(pkt))
      insert:push()
      remove:push()
      if link.nreadable(output) == 0 then pkt = nil
      elseif link.nreadable(output) == 1 then pkt = link.receive(output)
      else error('unexpected # of output packets: '..link.nreadable(output)) end
      link.free(input, 'input')
      link.free(middle, 'middle')
      link.free(output, 'output')
      shm.delete_frame(remove.shm)
      return pkt
   end

   for _, size in ipairs({0, 64, 9000}) do
      for _, insert_type in ipairs({'ipv4', 'ipv6'}) do
         for _, remove_type in ipairs({'ipv4', 'ipv6'}) do
            local input = packet.from_pointer(lib.random_bytes(size), size)
            local output = test_insert_remove(input, insert_type, remove_type)
            if insert_type == remove_type then
               assert(output ~= nil)
               assert(input.length == output.length)
               assert(ffi.C.memcmp(input.data, output.data, input.length) == 0)
               packet.free(input)
               packet.free(output)
            else
               assert(output == nil)
               packet.free(input)
            end
         end
      end
   end
   print('selftest: ok')
end
