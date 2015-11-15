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
      -- simulate only 16K active flows: i = bit.band(i, 0xffff)
      result = rhh:lookup(hash_i32(i), i)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print('lookup speed test (hits, only 16K active entries)')
   start = ffi.C.get_time_ns()
   for i = 1, count do
      i = bit.band(i, 0x7fff)
      result = rhh:lookup(hash_i32(i), i)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print('lookup speed test (hits, only 16K active entries, 64K entry cache)')
   local cache = cphm.new(rhh, 0x10000)
   start = ffi.C.get_time_ns()
   for i = 1, count do
      i = bit.band(i, 0x7fff)
      result = cache:lookup(hash_i32(i), i)
   end
   stop = ffi.C.get_time_ns()
   iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million lookups per second (final result: '..result..')')

   print('lookup speed test (warm cache hits, only 16K active entries, 64K entry cache)')
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
