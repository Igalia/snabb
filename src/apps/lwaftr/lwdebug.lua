module(..., package.seeall)

local bit = require("bit")
local band, rshift = bit.band, bit.rshift

local function gen_hex_bytes(data, len)
   local fbytes = {}
   for i=0,len - 1 do
      table.insert(fbytes, string.format("0x%x", data[i]))
   end
   return fbytes
end

function format_ipv4(uint32)
   return string.format("%i.%i.%i.%i",
      rshift(uint32, 24),
      rshift(band(uint32, 0xff0000), 16),
      rshift(band(uint32, 0xff00), 8),
      band(uint32, 0xff))
end

function selftest ()
   assert(format_ipv4(0xfffefdfc) == "255.254.253.252", "Bad conversion in format_ipv4")
end


-- TODO: Maybe it would be better to unconditioally import the "log" module,
--       add the formatters to it, and return the log module itself, so client
--       code both import the "log" module and install our custom formatters
--       by doing:
--
--          local log = require("apps.lwaftr.lwdebug")
--
--       In that case, probably it'd be better to call the "lwdebug" module
--       something else, like "apps.lwaftr.lwlog". Dunno.
--
local has_log, log = pcall(require, "apps.lwaftr.log")
if has_log then
   function log.format.packet (pkt)
      local bytes = gen_hex_bytes(pkt.data, pkt.length)
      return string.format("length: %i, data:\n%s", pkt.length, bytes)
   end
   function log.format.macaddr (addr)
      local chunks = {}
      for i = 0, 5 do
         table.insert(chunks, string.format("%02x", addr[i]))
      end
      return table.concat(chunks, ":")
   end
   function log.format.ipv6 (addr)
      local chunks = {}
      for i = 0, 7 do
         table.insert(chunks, string.format("%x%x", addr[2 * i], addr[2 * i + 1]))
      end
      return table.concat(chunks, ":")
   end
   log.format.ipv4 = format_ipv4
end
