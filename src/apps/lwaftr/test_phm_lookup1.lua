local ffi = require('ffi')
local bit = require('bit')
local hash_i32 = require("apps.lwaftr.podhashmap").hash_i32
local phm = require("apps.lwaftr.podhashmap").PodHashMap

-- e.g. ./snabb snsh apps/lwaftr/test_phm_lookup1.lua filename
local function run(params)
   if #params ~= 1 then error('usage: test_phm_lookup1.lua FILENAME') end
   local filename = unpack(params)

   local rhh = phm.new(ffi.typeof('uint32_t'), ffi.typeof('int32_t'))

   print('loading saved file '..filename)
   rhh:load(filename)

   print('lookup1 speed test (hits, uniform distribution)')
   local start = ffi.C.get_time_ns()
   local count = rhh.occupancy
   local result
   for i = 1, count do
      result = rhh:lookup(hash_i32(i), i)
   end
   local stop = ffi.C.get_time_ns()
   local iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print("done")
end

run(main.parameters)
