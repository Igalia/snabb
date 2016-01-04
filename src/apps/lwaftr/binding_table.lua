module(..., package.seeall)

local ffi = require("ffi")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local lwutil = require("apps.lwaftr.lwutil")

-- TODO: rewrite this after netconf integration
local function read_binding_table(bt_file)
  local input = io.open(bt_file)
  local entries = input:read('*a')
  local full_bt = 'return ' .. entries
  return assert(loadstring(full_bt))()
end

local machine_friendly_binding_table

local function pton_binding_table(bt)
   local pbt = {}
   for _, v in ipairs(bt) do
      local b4_v6, pv4, psid, br_v6 = unpack(v)
      pv4 = lwutil.rd32(ipv4:pton(pv4))
      b4_v6 = ipv6:pton(b4_v6)
      local pentry
      if br_v6 then
         pentry = {b4_v6, pv4, psid, ipv6:pton(br_v6)}
      else
         pentry = {b4_v6, pv4, psid}
      end
      table.insert(pbt, pentry)
   end
   return pbt
end

local function to_machine_friendly(bt_file)
   local binding_table = read_binding_table(bt_file)
   machine_friendly_binding_table = pton_binding_table(binding_table)
   return machine_friendly_binding_table
end

function load_binding_table(bt_file)
   assert(bt_file, "bt_file must be specified or the BT pre-initialized")
   return to_machine_friendly(bt_file)
end

function get_binding_table(bt_file)
   if not machine_friendly_binding_table then
      load_binding_table(bt_file)
   end
   return machine_friendly_binding_table
end
