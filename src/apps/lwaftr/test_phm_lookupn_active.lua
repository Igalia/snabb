local ffi = require('ffi')
local bit = require('bit')
local hash_i32 = require("apps.lwaftr.podhashmap").hash_i32
local phm = require("apps.lwaftr.podhashmap").PodHashMap

-- e.g. ./snabb snsh apps/lwaftr/test_phm_lookupn_active.lua stride ACTIVE filename
local function run(params)
   if #params ~= 3 then error('usage: test_phm_lookupn_active.lua STRIDE ACTIVE FILENAME') end
   local stride, active, filename = unpack(params)
   stride = assert(tonumber(stride), 'stride should be a number')
   assert(stride == math.floor(stride) and stride > 0,
          'stride should be a positive integer')
   active = assert(tonumber(active), 'active should be a number')
   assert(active == math.floor(active) and active > 0,
          'active should be a positive integer')

   local rhh = phm.new(ffi.typeof('uint32_t'), ffi.typeof('int32_t'))

   rhh:load(filename)

   local keys, results = rhh:prepare_lookup_bufs(stride)

   io.write(active..' active keys, batching '..stride..' lookups at a time: ')
   local start = ffi.C.get_time_ns()
   local count = rhh.occupancy
   for i = 1, count, stride do
      local n = math.min(stride, count + 1 - i)
      for j = 0, n-1 do
         keys[j].hash = hash_i32((i+j) % active)
         keys[j].key = bit.band((i+j) % active)
      end
      rhh:fill_lookup_bufs(keys, results, n)
      for j = 0, n-1 do
         local result = rhh:lookup_from_bufs(keys, results, j)
      --   assert(result, i+j)
      --   assert(results[result].key == i+j)
      --   assert(results[result].value == bit.bnot(i+j))
      end
   end
   local stop = ffi.C.get_time_ns()
   local iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   io.write(iter_rate..' million lookups per second.\n')
end

run(main.parameters)
