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

-- b4_v6 is for the B4, br_v6 is for the border router (lwAFTR)
local function pton_binding_table(bt)
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

local function expand_row(range, row)
   local v6, v4, br_v6 = row[1], row[2], row[4]
   v6, v4 = ipv6:pton(v6), lwutil.rd32(ipv4:pton(v4))
   if br_v6 then br_v6 = ipv6:pton(br_v6) end
   return {v6, v4, range.start, range.last, br_v6}
end

local function port_ranges(psid, offset, length)
   assert(tonumber(psid) >= 0 and tonumber(psid) < 2^length, ("Incorrect psid value: %d"):format(psid))
   local result, total = {}, 0
   local a, m = offset, 16 - (offset + length)
   local A = 2^a
   local M = 2^m

   if A == 1 then
      local start = psid * 2^m
      local last = start + 2^m - 1
      table.insert(result, {start = start, last = last})
      total = total + 2^m
      assert(total == 2^m, "Incorrect total number of ports assigned")
   else
      for i=1,A-1 do
         local start = i * 2^(16 - a) + psid * 2^m
         local last = start + 2^m - 1
         table.insert(result, {start = start, last = last})
         total = total + 2^m
      end
      assert(total == 2^(16 - length) - 2^m, "Incorrect total number of ports assigned")
   end
   return result
end

local function psid_bt_to_pton(psid_bt)
   local result = {}
   for _, row in ipairs(psid_bt) do
      local psid_params = row[3]
      for _, range in ipairs(port_ranges(unpack(psid_params))) do
         table.insert(result, expand_row(range, row))
      end
   end
   return result
end

local function is_psid(filename)
   return filename:match("psid")
end

local function to_machine_friendly(bt_file)
   local binding_table = read_binding_table(bt_file)
   if is_psid(bt_file) then
      machine_friendly_binding_table = psid_bt_to_pton(binding_table)
   else
      machine_friendly_binding_table = pton_binding_table(binding_table)
   end
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
