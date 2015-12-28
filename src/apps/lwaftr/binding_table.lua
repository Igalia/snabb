module(..., package.seeall)

local ffi = require("ffi")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local lwutil = require("apps.lwaftr.lwutil")

ffi.cdef[[
// 4 bytes for the hash, which precedes the key.
// 8 bytes for the key.
struct binding_table_key {
   uint8_t ipv4[4];     // Public IPv4 address of this tunnel.
   uint16_t psid;       // Port set ID.
   uint8_t a, k;        // A and K parameters used to divide the port
                        // range for this IP.
} __attribute__((packed));
// 20 bytes for the value.
struct binding_table_value {
   uint32_t br;         // Which border router (lwAFTR)?
   uint8_t b4_ipv6[16]; // Address of B4.
} __attribute__((packed));
// Sum: 32 bytes, which has nice cache alignment properties.
]]

-- TODO: rewrite this after netconf integration
local function read_binding_table(bt_file)
  local input = io.open(bt_file)
  local entries = input:read('*a')
  local full_bt = 'return ' .. entries
  return assert(loadstring(full_bt))()
end

local machine_friendly_binding_table

-- b4_v6 is for the B4, br_v6 is for the border router (lwAFTR)
function pton_binding_table(bt)
   local pbt = {}
   for _, v in ipairs(bt) do
      local b4_v6 = ipv6:pton(v[1])
      local pv4 = lwutil.rd32(ipv4:pton(v[2]))
      local pentry
      if v[5] then
         local br_v6 = ipv6:pton(v[5])
         pentry = {b4_v6, pv4, v[3], v[4], br_v6}
      else
         pentry = {b4_v6, pv4, v[3], v[4]}
      end
      table.insert(pbt, pentry)
   end
   return pbt
end

function load_binding_table(bt_file)
   if not bt_file then
      error("bt_file must be specified or the BT pre-initialized")
   end
   local binding_table = read_binding_table(bt_file)
   machine_friendly_binding_table = pton_binding_table(binding_table)
   return machine_friendly_binding_table
end

function get_binding_table(bt_file)
   if not machine_friendly_binding_table then
      load_binding_table(bt_file)
   end
   return machine_friendly_binding_table
end
