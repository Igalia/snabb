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

local function coallesce(ranges)
   local start = ranges[1].start
   local last = ranges[#ranges].last
   return { start = start, last = last }
end

local function port_range(psid, k, m , a)
   local A, M, R = 2^a, 2^m, 2^k
   assert(psid >= 0 and psid < R, "Incorrect PSID value")

   local result = {}
   local index_start, index_end = (2^(16-a) / M) / R, ((2^16 / M) / R) - 1
   for j = index_start, index_end do
      local start = R * M * j + M * psid
      local last = start + M-1
      table.insert(result, {start = start, last = last})
   end
   return coallesce(result)
end

-- Uses the lower 8 bytes of ipv6 address as key
local function ipv6_key(ip)
   return tonumber(ffi.cast("uint64_t*", ip + 8)[0])
end

local function merge(rows)
   -- Compute ranges by IPv4
   local ranges_by_entry = {}
   for _, row in ipairs(rows) do
      local v6, v4 = row[1], row[2]
      if not ranges_by_entry[v6] then
         ranges_by_entry[v6] = {}
         if not ranges_by_entry[v4] then
            ranges_by_entry[v6][v4] = {start = row[3], last = row[4]}
         end
      else
         ranges_by_entry[v6][v4].last = row[4]
      end
   end
   -- Merge rows with same IPv4
   local result, inserted = {}, {}
   for _, row in ipairs(rows) do
      local v6, v4, br_v6 = row[1], row[2], row[5]
      local v6_key = ipv6_key(v6)
      if not inserted[v6_key] then 
         inserted[v6_key] = {}
      end
      if not inserted[v6_key][v4] then
         local range = ranges_by_entry[v6][v4]
         table.insert(result, {v6, v4, range.start, range.last, br_v6})
         inserted[v6_key][v4] = true
      end
   end
   return result
end

local function psid_bt_to_pton(psid_bt)
   local result = {}
   for _, row in ipairs(psid_bt) do
      local psid_params = row[3]
      table.insert(result, expand_row(port_range(unpack(psid_params)), row))
   end
   return merge(result)
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
