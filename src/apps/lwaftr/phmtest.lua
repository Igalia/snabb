local ffi = require('ffi')
local bit = require('bit')
local hash_i32 = require("apps.lwaftr.podhashmap").hash_i32
local murmur_hash_i32 = require("apps.lwaftr.podhashmap").murmur_hash_i32
local phm = require("apps.lwaftr.podhashmap").PodHashMap

-- e.g. ./snabb snsh apps/lwaftr/phmtest.lua
local function run(params)
   require("apps.lwaftr.binary_search").selftest()
   require("apps.lwaftr.podhashmap").selfcheck()

   print('insertion rate test (40% occupancy)')
   local rhh = phm.new(ffi.typeof('uint32_t'), ffi.typeof('int32_t'))
   rhh:resize(1e7 / 0.4 + 1)
   start = ffi.C.get_time_ns()
   count = 1e7
   for i = 1, count do
      local h = hash_i32(i)
      local v = bit.bnot(i)
      rhh:add(h, i, v)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million insertions per second')

   print('selfcheck')
   rhh:selfcheck(hash_i32)

   print('population check')
   for i = 1, count do
      local offset = rhh:lookup(hash_i32(i), i)
      assert(rhh:val_at(offset) == bit.bnot(i))
   end

   print('lookup speed test (hits, uniform distribution)')
   start = ffi.C.get_time_ns()
   for i = 1, count do
      result = rhh:lookup(hash_i32(i), i)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print('lookup2 speed test (hits, uniform distribution)')
   start = ffi.C.get_time_ns()
   local result2
   for i = 1, count, 2 do
      result2, result = rhh:lookup2(hash_i32(i), i, hash_i32(i+1), i+1)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print('lookup2p speed test (hits, uniform distribution)')
   start = ffi.C.get_time_ns()
   local result2
   for i = 1, count, 2 do
      result2, result = rhh:lookup2p(hash_i32(i), i, hash_i32(i+1), i+1)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print('lookup4p speed test (hits, uniform distribution)')
   start = ffi.C.get_time_ns()
   local result3, result4
   for i = 1, count, 4 do
      result4, result3, result2, result =
         rhh:lookup4p(hash_i32(i), i, hash_i32(i+1), i+1,
                      hash_i32(i+2), i+2, hash_i32(i+3), i+3)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (result: '..result..')')

   print('lookup with 2xprefetch speed test (hits, uniform distribution)')
   start = ffi.C.get_time_ns()
   for i = 1, count, 2 do
      local hash2 = hash_i32(i)
      rhh:prefetch(hash2)
      local hash1 = hash_i32(i+1)
      rhh:prefetch(hash1)

      result2 = rhh:lookup(hash2, i)
      result = rhh:lookup(hash1, i+1)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (results: '..result2..','..result..')')

   print('lookup with 4xprefetch speed test (hits, uniform distribution)')
   start = ffi.C.get_time_ns()
   for i = 1, count, 4 do
      local hash4 = hash_i32(i)
      local prefetch4 = rhh:prefetch(hash4)
      local hash3 = hash_i32(i+1)
      local prefetch3 = rhh:prefetch(hash3)
      local hash2 = hash_i32(i+2)
      local prefetch2 = rhh:prefetch(hash2)
      local hash1 = hash_i32(i+3)
      local prefetch1 = rhh:prefetch(hash1)

      result4 = rhh:lookup_with_prefetch(hash4, i, prefetch4)
      result3 = rhh:lookup_with_prefetch(hash3, i+1, prefetch3)
      result2 = rhh:lookup_with_prefetch(hash2, i+2, prefetch2)
      result = rhh:lookup_with_prefetch(hash1, i+3, prefetch1)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (results: '..result4..','..result3..','..result2..','..result..')')

   print('lookup speed test (hits, only 32K active entries)')
   start = ffi.C.get_time_ns()
   for i = 1, count do
      i = bit.band(i, 0x7fff)
      result = rhh:lookup(hash_i32(i), i)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   if false then rhh:dump() end
   print("success")
end

run(main.parameters)
