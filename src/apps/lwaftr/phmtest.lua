local ffi = require('ffi')
local bit = require('bit')
local hash_i32 = require("apps.lwaftr.podhashmap").hash_i32
local phm = require("apps.lwaftr.podhashmap").PodHashMap
local cphm = require("apps.lwaftr.podhashmap").CachingPodHashMap

-- e.g. ./snabb snsh apps/lwaftr/phmtest.lua
local function run(params)
   print('hash rate test')
   local start = ffi.C.get_time_ns()
   local result
   local count = 5e8
   for i = 1, count do
      result = hash_i32(i)
   end
   local stop = ffi.C.get_time_ns()
   local iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million hashes per second (final result: '..result..')')

   print('insertion rate test')
   local rhh = phm.new(ffi.typeof('uint32_t'), ffi.typeof('int32_t'))
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

   print('verification')
   for i = 0, rhh.size-1 do
      local entry = rhh.entries[i]
      if entry.hash ~= 0 then
         assert(entry.hash == bit.bor(0x80000000, hash_i32(entry.key)))
         assert(entry.value == bit.bnot(entry.key))
      end
   end

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
      local prefetch2 = rhh:prefetch(hash2)
      local hash1 = hash_i32(i+1)
      local prefetch1 = rhh:prefetch(hash1)

      result2 = rhh:lookup_with_prefetch(hash2, i, prefetch2)
      result = rhh:lookup_with_prefetch(hash1, i+1, prefetch1)
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

   print('lookup speed test (hits, only 32K active entries, 64K entry cache)')
   local cache = cphm.new(rhh, 0x10000)
   start = ffi.C.get_time_ns()
   for i = 1, count do
      i = bit.band(i, 0x7fff)
      result = cache:lookup(hash_i32(i), i)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print('lookup speed test (warm cache hits, only 32K active entries, 64K entry cache)')
   start = ffi.C.get_time_ns()
   for i = 1, count do
      i = bit.band(i, 0x7fff)
      result = cache:lookup(hash_i32(i), i)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print('cache usage: '..cache.cache.occupancy..'/'..cache.cache.size)

   print('cache verification')
   for i = 0, cache.cache.size-1 do
      local entry = cache.cache.entries[i]
      if entry.hash ~= 0 then
         assert(entry.hash == bit.bor(0x80000000, hash_i32(entry.key)))
         assert(entry.value == bit.bnot(entry.key))
      end
   end

   if false then rhh:dump() end
   print("success")
end

run(main.parameters)
