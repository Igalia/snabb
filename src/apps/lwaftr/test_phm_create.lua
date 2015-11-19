local ffi = require('ffi')
local bit = require('bit')
local hash_i32 = require("apps.lwaftr.podhashmap").hash_i32
local phm = require("apps.lwaftr.podhashmap").PodHashMap

-- e.g. ./snabb snsh apps/lwaftr/test_phm_create.lua count filename
local function run(params)
   if #params ~= 2 then error('usage: test_phm_create.lua COUNT FILENAME') end
   local count, filename = unpack(params)
   count = assert(tonumber(count), "count not a number: "..count)

   print('creating uint32->int32 podhashmap with '..count..' entries')
   local rhh = phm.new(ffi.typeof('uint32_t'), ffi.typeof('int32_t'))
   local start = ffi.C.get_time_ns()
   for i = 1, count do
      local h = hash_i32(i)
      local v = bit.bnot(i)
      rhh:add(h, i, v)
   end
   local stop = ffi.C.get_time_ns()
   local iter_rate = count/(tonumber(stop-start)/1e9)/1e6
   print(iter_rate..' million insertions per second')

   print('saving '..filename)
   rhh:save(filename)

   print('reloading saved file')
   rhh:load(filename)

   print('verifying saved file')
   for i = 0, rhh.size-1 do
      local entry = rhh.entries[i]
      if entry.hash ~= 0 then
         assert(entry.hash == hash_i32(entry.key))
         assert(entry.value == bit.bnot(entry.key))
      end
   end

   for i = 1, count do
      local offset = rhh:lookup(hash_i32(i), i)
      assert(rhh:val_at(offset) == bit.bnot(i))
   end

   -- rhh:dump()

   print("done")
end

run(main.parameters)
