local ffi = require('ffi')
local bit = require('bit')
local hash_i32 = require("apps.lwaftr.podhashmap").hash_i32
local phm = require("apps.lwaftr.podhashmap").PodHashMap

-- e.g. ./snabb snsh apps/lwaftr/test_phm_lookupn.lua stride filename
local function run(params)
   if #params ~= 2 then error('usage: test_phm_lookupn.lua STRIDE FILENAME') end
   local stride, filename = unpack(params)
   stride = assert(tonumber(stride), 'stride should be a number')
   assert(stride == math.floor(stride) and stride > 0,
          'stride should be a positive integer')

   local rhh = phm.new(ffi.typeof('uint32_t'), ffi.typeof('int32_t'))

   print('loading saved file '..filename)
   rhh:load(filename)

   local keys, results = rhh:prepare_lookup_bufs(stride)

   print('max displacement: '..rhh.max_displacement)

   print('lookup1 speed test (hits, uniform distribution)')
   local start = ffi.C.get_time_ns()
   local count = rhh.occupancy
   for i = 1, count, stride do
      local n = math.min(stride, count + 1 - i)
      for j = 0, n-1 do
         rhh:prepare_lookup(keys, results, j, hash_i32(i+j), i+j)
      end
      for j = 0, n-1 do
         local result = rhh:lookup_from_bufs(keys, results, j)
      --   assert(result, i+j)
      --   assert(results[result].key == i+j)
      --   assert(results[result].value == bit.bnot(i+j))
      end
   end
   local stop = ffi.C.get_time_ns()
   local iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second')

   print("done")
end

run(main.parameters)
