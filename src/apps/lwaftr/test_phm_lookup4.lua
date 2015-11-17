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
   -- NOTE!  Results don't flow out of this loop, so LuaJIT is free to
   -- kill the whole loop.  Currently that's not the case but you need
   -- to verify the traces to ensure that all is well.  Caveat emptor!
   for i = 1, count, 4 do
      local i2, i3, i4 = i+1, i+2, i+3
      local prefetch1 = rhh:prefetch(hash_i32(i))
      local prefetch2 = rhh:prefetch(hash_i32(i2))
      local prefetch3 = rhh:prefetch(hash_i32(i3))
      local prefetch4 = rhh:prefetch(hash_i32(i4))

      rhh:lookup_with_prefetch(hash_i32(i), i, prefetch1)
      rhh:lookup_with_prefetch(hash_i32(i2), i2, prefetch2)
      rhh:lookup_with_prefetch(hash_i32(i3), i3, prefetch3)
      rhh:lookup_with_prefetch(hash_i32(i4), i4, prefetch4)
   end
   local stop = ffi.C.get_time_ns()
   local iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second')

   print("done")
end

run(main.parameters)
