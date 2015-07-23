module(..., package.seeall)

local utils = require("apps.basicnat.utils")
local ffi = require("ffi")

local bytes, byte, word16 = utils.bytes, utils.byte, utils.word16
local word32 = utils.word32

--- ### `basicnat` app: Implement http://www.ietf.org/rfc/rfc1631.txt Basic NAT.
--- This translates one IP address to another IP address.
--
BasicNAT = {
   -- Lazy initializator for BasicNAT proxy table
   get_proxy_t = (function()
      local proxy_t
      local function create_proxy_t()
         ffi.cdef([[
         typedef struct ProxyTable {
            uint32_t proxy, ip;
         } ProxyTable;
         ]])
         return ffi.new("ProxyTable")
      end
      return function()
         if proxy_t == nil then
            proxy_t = create_proxy_t()
         end
         return proxy_t
      end
   end)()
}

local ARP_HDR_SIZE   = 28
local ETHER_HDR_SIZE = 14
local IPV4_HDR_SIZE  = 20
local TRANSPORT_BASE = 34  -- Tranport layer (TCP/UDP/etc) header start.

local PROTO_ARP     = 0x806
local PROTO_IPV4    = 0x800
local PROTO_TCP     = 6
local PROTO_UDP     = 17

local function debug(...)
   io.write("### DEBUG: ")
   print(...)
end

local function checksum_carry_and_not(csum)
   while csum > 0xffff do -- Process the carry nibbles.
      local carry = bit.rshift(csum, 16)
      csum = bit.band(csum, 0xffff) + carry
   end
   return bit.band(bit.bnot(csum), 0xffff)
end

-- https://en.wikipedia.org/wiki/IPv4_header_checksum.
local function calculate_checksum(p, offset)
   local offset = offset or ETHER_HDR_SIZE
   local checksum = 0
   for i = offset, offset + 18, 2 do
      if i ~= offset + 10 then -- The checksum bytes are assumed to be 0.
         checksum = checksum + p.data[i] * 0x100 + p.data[i+1]
      end
   end
   return checksum_carry_and_not(checksum)
end

local function checksum(p, val)
   local offset = ETHER_HDR_SIZE + 10
   return word16(p, offset, val)
end

local function ethertype(p)
   return word16(p, ETHER_HDR_SIZE - 2)
end

local function ip_proto(p)
   if ethertype(p) == PROTO_IPV4 then
      return byte(p, ETHER_HDR_SIZE + 9)
   end
end

local function tcplen(p)
   return word16(p, ETHER_HDR_SIZE + 2) - 20
end

local function transport_checksum(pkt)
   local csum = 0
   -- First 64 bytes of the TCP pseudo-header: the ip addresses.
   for i = ETHER_HDR_SIZE + 12, ETHER_HDR_SIZE + 18, 2 do
      csum = csum + word16(pkt, i)
   end
   -- Add the protocol field of the IPv4 header to the csum.
   csum = csum + ip_proto(pkt)
   local tcplen = tcplen(p)
   csum = csum + tcplen -- End of pseudo-header.

   for i = TRANSPORT_BASE, TRANSPORT_BASE + tcplen - 2, 2 do
      if i ~= TRANSPORT_BASE + 16 then -- The csum bytes are zero.
         csum = csum + word16(pkt, i)
      end
   end
   if tcplen % 2 == 1 then
      csum = csum + byte(pkt, TRANSPORT_BASE + tcplen - 1)
   end
   return checksum_carry_and_not(csum)
end

local function refresh_checksum(p)
   checksum(p, calculate_checksum(p))
   local proto = ip_proto(p)
   if proto == PROTO_TCP then
      word16(p, TRANSPORT_BASE + 16, transport_checksum(p))
      return true
   end
   if proto == PROTO_UDP then
      -- IPv4 UDP checksums are optional.
      word16(p, TRANSPORT_BASE + 6, 0)
      return true
   end
   -- Didn't attempt to change a transport-layer checksum.
   return false
end

local function src_ip(p, val)
   if ethertype(p) == PROTO_ARP then
      local offset = ETHER_HDR_SIZE + ARP_HDR_SIZE - 14
      return word32(p, offset, val)
   end
   if ethertype(p) == PROTO_IPV4 then
      local offset = ETHER_HDR_SIZE + IPV4_HDR_SIZE - 8
      local result = word32(p, offset, val)
      if val then
         refresh_checksum(p)
      end
      return result
   end
end

local function dst_ip(p, val)
   if ethertype(p) == PROTO_ARP then
      local offset = ETHER_HDR_SIZE + ARP_HDR_SIZE - 4
      return word32(p, offset, val)
   end
   if ethertype(p) == PROTO_IPV4 then
      local offset = ETHER_HDR_SIZE + IPV4_HDR_SIZE - 4
      local result = word32(p, offset, val)
      if val then
         refresh_checksum(p)
      end
      return result
   end
end

local function to_uint32(a, b, c, d)
   return a * 2^24 + b * 2^16 + c * 2^8 + d
end

local function ip_to_uint32(ip)
   local t = {}
   for each in ip:gmatch("(%d+)") do
      each = tonumber(each)
      assert(each >= 0 and each <= 255)
      table.insert(t, each)
   end
   return to_uint32(unpack(t))
end

--

function BasicNAT:new(c)
   local o = {
      proxy_t = c.proxy_t,
      proxy = ip_to_uint32(c.proxy),
      public  = ip_to_uint32(c.public),
      private = ip_to_uint32(c.private),
   }
   return setmetatable(o, { __index = BasicNAT })
end

function BasicNAT:push(p)
   local i = assert(self.input.input, "input port not found")
   local o = assert(self.output.output, "output port not found")

   while not link.empty(i) and not link.full(o) do
      self:process_packet(i, o)
   end
end

function BasicNAT:process_packet(i, o)
   local p = link.receive(i)
   self:rewrite(p)
   link.transmit(o, p)
end

function BasicNAT:rewrite(p)
   if not (ethertype(p) == PROTO_ARP or ethertype(p) == PROTO_IPV4) then
      return
   end
   if dst_ip(p) == self.public then
      src_ip(p, self:mask(src_ip(p)))
      dst_ip(p, self.private)
   end
   -- Reply
   if src_ip(p) == self.private then
      src_ip(p, self.public)
      dst_ip(p, self:unmask(dst_ip(p)))
   end
end

function BasicNAT:mask(ip)
   self.proxy_t.ip = ip
   self.proxy_t.proxy = self.proxy
   return self.proxy
end

function BasicNAT:unmask(proxy)
   if self.proxy_t.proxy == proxy then
      return self.proxy_t.ip
   end
   return proxy
end

---

local function format_ip(ip)
   local t = {}
   if ip == nil then return "" end
   if type(ip) == "number" then
      for _, b in bytes(ip, 4) do
         table.insert(t, b)
      end
   else
      for i=0,3 do
         table.insert(t, ip[i])
      end
   end
   return table.concat(t, ".")
end

local function testIPv4GetSet()
   print("Test ipv4 operations")
   local p = {
      data = ffi.new("uint8_t[?]", 4)
   }
   for i=0,3 do
      if i % 2 == 1 then
         p.data[i] = 0xff
      else
         p.data[i] = 0
      end
   end

   -- Prints 0.255.0.255
   assert("0.255.0.255" == format_ip(p.data), "Wrong format_ip")
   print(("0.255.0.255 == %s"):format(format_ip(p.data)))

   local ip = 0xFF996633
   word32(p, 0, ip)
   ip = word32(p, 0)
   -- Prints 255.153.102.51
   assert("255.153.102.51" == format_ip(ip))
   print(("255.153.102.51 == %s"):format(format_ip(ip)))

   -- Prints 65535
   local ip = 65535
   assert(ip == ip_to_uint32("0.0.255.255"), "Wrong ip_to_uint32")
   print(("%d == %d"):format(ip, ip_to_uint32("0.0.255.255")))

   print("---")
end

local function testChecksum()
   print("Test checksum")
   local header = { 0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00,
      0x40, 0x11, 0xb8, 0x61, 0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7 }
   local p = {
      data = ffi.new("uint8_t[?]", 20)
   }
   for i, byte in ipairs(header) do
      p.data[i-1] = byte
   end
   assert(calculate_checksum(p, 0) == 0xb861)
   print(("Checksum: 0x%x"):format(calculate_checksum(p, 0)))
   print("---")
end

function selftest()
   testIPv4GetSet()
   testChecksum()
   print("OK")
end
