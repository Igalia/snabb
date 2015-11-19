module(..., package.seeall)

local ffi = require("ffi")
local C = ffi.C
local S = require("syscall")
local bit = require("bit")
local band, bxor, bor, bnot = bit.band, bit.bxor, bit.bor, bit.bnot
local tobit, lshift, rshift = bit.tobit, bit.lshift, bit.rshift

PodHashMap = {}
CachingPodHashMap = {}

local INITIAL_SIZE = 8
local MAX_OCCUPANCY_RATE = 0.9
local MIN_OCCUPANCY_RATE = 0.0

--- 32 bytes
local function make_entry_type(key_type, value_type)
   return ffi.typeof([[struct {
         int32_t hash;
         $ key;
         $ value;
      } __attribute__((packed))]],
      key_type,
      value_type)
end

local function make_entries_type(entry_type)
   return ffi.typeof('$[?]', entry_type)
end

local function entry_distance(hash, index, mask)
   -- ORIGIN indicates the slot in the hash table at which HASH
   -- would like to be placed: the slot for which the distance would
   -- be zero.
   local origin = band(hash, mask)

   -- However we found this hash at INDEX.  The distance is the offset
   -- from ORIGIN, taking wraparound into account.
   return band(index - origin, mask)
end

function PodHashMap.new(entry_or_key_type, maybe_value_type)
   local phm = {}   
   if maybe_value_type then
      phm.entry_type = make_entry_type(entry_or_key_type, maybe_value_type)
   else
      phm.entry_type = entry_or_key_type
   end
   phm.type = make_entries_type(phm.entry_type)
   phm.size = 0
   phm.occupancy = 0
   phm.max_occupancy_rate = MAX_OCCUPANCY_RATE
   phm.min_occupancy_rate = MIN_OCCUPANCY_RATE
   phm = setmetatable(phm, { __index = PodHashMap })
   phm:resize(INITIAL_SIZE)
   return phm
end

local function is_power_of_two(n)
   return n ~= 0 and bit.band(n, n-1) == 0
end

function PodHashMap:save(filename)
   local file = io.open(filename, "w")
   file:write(ffi.string(self.entries, ffi.sizeof(self.type, self.size)))
   file:close()
end

function PodHashMap:load(filename)
   local fd, err = S.open(filename, "rdwr")
   if not fd then
      error("error opening saved hash table ("..path.."):"..tostring(err))
   end
   local size = S.fstat(fd).size
   local entry_count = math.floor(size / ffi.sizeof(self.type, 1))
   if size ~= ffi.sizeof(self.type, entry_count) then
      fd:close()
      error("corrupted saved hash table ("..path.."): bad size"..size)
   end
   local mem, err = S.mmap(nil, size, 'read, write', 'private', fd, 0)
   fd:close()
   if not mem then error("mmap failed: " .. tostring(err)) end

   -- OK!
   self.size = entry_count
   self.occupancy = 0
   self.max_displacement = 0
   self.entries = ffi.cast(ffi.typeof('$*', self.entry_type), mem)
   self.occupancy_hi = math.floor(self.size * self.max_occupancy_rate)
   self.occupancy_lo = math.floor(self.size * self.min_occupancy_rate)

   ffi.gc(self.entries, function (ptr) S.munmap(ptr, size) end)

   local mask = self.size-1
   for i=0,self.size-1 do
      if self.entries[i].hash ~= 0 then
         self.occupancy = self.occupancy + 1
         local displacement = entry_distance(self.entries[i].hash, i, mask)
         self.max_displacement = math.max(self.max_displacement, displacement)
      end
   end
end

function PodHashMap:resize(size)
   assert(size >= (self.occupancy / self.max_occupancy_rate))
   assert(is_power_of_two(size))
   local old_entries = self.entries
   local old_size = self.size

   self.size = size
   self.occupancy = 0
   self.max_displacement = 0
   self.entries = self.type(self.size)
   self.occupancy_hi = math.floor(self.size * self.max_occupancy_rate)
   self.occupancy_lo = math.floor(self.size * self.min_occupancy_rate)
   for i=0,self.size-1 do self.entries[i].hash = 0 end

   for i=0,old_size-1 do
      if old_entries[i].hash ~= 0 then
         self:add(old_entries[i].hash, old_entries[i].key, old_entries[i].value)
      end
   end
end

function PodHashMap:prepare_lookup_bufs(stride)
   return self.type(stride), self.type(stride * (self.max_displacement + 1))
end

function PodHashMap:fill_lookup_bufs(keys, results, stride)
   local entries = self.entries
   local mask = self.size - 1
   local max_displacement = self.max_displacement
   local unit_size = ffi.sizeof(self.entry_type)
   for i=0,stride-1 do
      local hash = keys[i].hash
      local start_index = band(hash, mask)
      local end_index = band(start_index + max_displacement + 1, mask)
      if (start_index < end_index) then
         ffi.copy(results + i * (max_displacement + 1),
                  entries + start_index,
                  unit_size * (end_index - start_index))
      else
         -- This span of entries wraps around.
         local tail_count = self.size - start_index
         ffi.copy(results + i * (max_displacement + 1),
                  entries + start_index,
                  unit_size * tail_count)
         ffi.copy(results + i * (max_displacement + 1) + tail_count,
                  entries,
                  unit_size * ((max_displacement + 1) - tail_count))
      end
   end
end

function PodHashMap:lookup_from_bufs(keys, results, i)
   local mask = self.size - 1
   local max_displacement = self.max_displacement
   local hash = keys[i].hash
   local result = i * (max_displacement + 1)

   -- Fast path.
   if hash == results[result].hash and keys[i].key == results[result].key then
      -- Found!
      return result
   end

   -- The index at which we started looking in the original table.
   local index = band(hash, mask)

   for distance=1, max_displacement do
      result = result + 1
      index = band(index + 1, mask)
      if hash == results[result].hash and keys[i].key == results[result].key then
         -- Found.
         return result
      end
      if results[result].hash == 0 then return nil end
      if entry_distance(results[result].hash, index, mask) < distance then
         -- The entry's distance is less; our key is not in the table.
         return nil
      end
   end

   -- Not found.
   return nil
end

function PodHashMap:add(hash, key, value)
   if self.occupancy + 1 > self.size * self.max_occupancy_rate then
      self:resize(self.size * 2)
   end

   local entries = self.entries
   local size = self.size

   -- size must be a power of two!
   local mask = size - 1
   local index = band(hash, mask);
   local distance = 0

   while true do
      local other_hash = entries[index].hash
      if other_hash == 0 then break end

      --- Update currently unsupported.
      assert(key ~= entries[index].key)

      --- Displace the entry if our distance is greater, otherwise keep
      --- looking.
      if entry_distance(other_hash, index, mask) < distance then
         --- Rob from rich!  Note that it is absolutely imperative
         --- that there be space in the table for a new entry.
         local empty = index;
         repeat
            empty = band(empty + 1, mask)
         until entries[empty].hash == 0

         repeat
            local last = band(empty - 1, mask)
            entries[empty] = entries[last]
            empty = last;
         until empty == index;

         -- Now entries[index] free to be set
         break
      end

      distance = distance + 1
      index = band(index + 1, mask)
   end
           
   self.occupancy = self.occupancy + 1
   if distance > self.max_displacement then self.max_displacement = distance end
   entries[index].hash = hash
   entries[index].key = key
   entries[index].value = value
   return index
end

local function lookup_helper(entries, size, hash, other_hash, key)
   -- size must be a power of two!
   local mask = size - 1
   local index = band(hash, mask);

   -- Fast path.
   if hash == other_hash and key == entries[index].key then
      -- Found!
      return index
   end

   for distance=1, size-1 do
      index = band(index + 1, mask);
      if hash == entries[index].hash and key == entries[index].key then
         -- Found!
         return index
      end
      if entries[index].hash == 0 then return nil end
      if entry_distance(entries[index].hash, index, mask) < distance then
         -- The entry's distance is less; our key is not in the table.
         return nil
      end
   end

   -- Looped through the whole table!  Shouldn't happen, but hey.
   return nil
end

function PodHashMap:lookup(hash, key)
   local entries = self.entries
   local size = self.size

   assert(hash ~= 0)

   -- size must be a power of two!
   local mask = size - 1
   local index = band(hash, mask);

   -- Fast path.
   if hash == entries[index].hash and key == entries[index].key then
      -- Found!
      return index
   end

   for distance=1, size-1 do
      index = band(index + 1, mask);
      if hash == entries[index].hash and key == entries[index].key then
         -- Found!
         return index
      end
      if entries[index].hash == 0 then return nil end
      if entry_distance(entries[index].hash, index, mask) < distance then
         -- The entry's distance is less; our key is not in the table.
         return nil
      end
   end

   -- Looped through the whole table!  Shouldn't happen, but hey.
   return nil
end

function PodHashMap:lookup2(hash1, key1, hash2, key2)
   return self:lookup(hash1, key1), self:lookup(hash2, key2)
end

function PodHashMap:lookup2p(hash1, key1, hash2, key2)
   local entries = self.entries
   local size = self.size

   assert(hash1 ~= 0)
   assert(hash2 ~= 0)

   -- size must be a power of two!
   local mask = size - 1
   local index1, index2 = band(hash1, mask), band(hash2, mask)
   local other_hash1, other_hash2 = entries[index1].hash, entries[index2].hash

   local result1 = lookup_helper(entries, size, hash1, other_hash1, key1)
   local result2 = lookup_helper(entries, size, hash2, other_hash2, key2)

   return result1, result2
end

function PodHashMap:lookup4p(hash1, key1, hash2, key2, hash3, key3, hash4, key4)
   assert(hash1 ~= 0)
   assert(hash2 ~= 0)
   assert(hash3 ~= 0)
   assert(hash4 ~= 0)

   -- size must be a power of two!
   local entries, size = self.entries, self.size
   local mask = self.size - 1
   local index1, index2 = band(hash1, mask), band(hash2, mask)
   local other_hash1, other_hash2 = entries[index1].hash, entries[index2].hash
   local index3, index4 = band(hash1, mask), band(hash2, mask)
   local other_hash3, other_hash4 = entries[index3].hash, entries[index4].hash

   local result1 = lookup_helper(entries, size, hash1, other_hash1, key1)
   local result2 = lookup_helper(entries, size, hash2, other_hash2, key2)
   local result3 = lookup_helper(entries, size, hash3, other_hash3, key3)
   local result4 = lookup_helper(entries, size, hash4, other_hash4, key4)

   return result1, result2, result3, result4
end

function PodHashMap:prefetch(hash)
   return self.entries[band(hash, self.size-1)].hash
end

function PodHashMap:lookup_with_prefetch(hash, key, prefetch)
   assert(hash ~= 0)
   return lookup_helper(self.entries, self.size, hash, prefetch, key)
end

-- FIXME: Does NOT shrink max_displacement
function PodHashMap:remove_at(i)
   assert(not self:is_empty(i))

   local entries = self.entries
   local size = self.size

   self.occupancy = self.occupancy - 1
   entries[i].hash = 0

   if self.occupancy < self.size * self.min_occupancy_rate then
      self:resize(self.size / 2)
   else
      local mask = size - 1
      while true do
         local next = band(i + 1, mask)
         local next_hash = entries[next].hash
         if next_hash == 0 or band(next_hash, mask) == next then break end
         -- Give to the poor.
         entries[i] = entries[next]
         entries[next].hash = 0
         i = next
      end
   end
end

function PodHashMap:is_empty(i)
   assert(i >= 0 and i < self.size)
   return self.entries[i].hash == 0
end

function PodHashMap:hash_at(i)
   assert(not self:is_empty(i))
   return self.entries[i].hash
end

function PodHashMap:key_at(i)
   assert(not self:is_empty(i))
   return self.entries[i].key
end

function PodHashMap:val_at(i)
   assert(not self:is_empty(i))
   return self.entries[i].value
end

function PodHashMap:dump()
   local mask = self.size - 1
   for index=0,self.size-1 do
      io.write(index..':')
      local entry = self.entries[index]
      if (entry.hash == 0) then
         io.write('\n')
      else
         local distance = entry_distance(entry.hash, index, mask)
         io.write(' hash: '..entry.hash..' (distance: '..distance..')\n')
         io.write('    key: '..tostring(entry.key)..'\n')
         io.write('  value: '..tostring(entry.value)..'\n')
      end
   end
end

--==============
function CachingPodHashMap.new(store, cache_size)
   assert(is_power_of_two(cache_size))
   local cphm = {}
   cphm.store = store
   cphm.cache = PodHashMap.new(store.entry_type)
   cphm.cache:resize(cache_size)
   cphm.evict_index = 0
   return setmetatable(cphm, { __index = CachingPodHashMap })
end

function CachingPodHashMap:add(hash, key, value)
   local index = self.cache:lookup(hash, key)
   if index then self.cache:remove_at(index) end
   return self.store:add(hash, key, value)
end

function CachingPodHashMap:lookup(hash, key)
   local index = self.cache:lookup(hash, key)
   if index then return index end
   local store_index = self.store:lookup(hash, key)
   if not store_index then return nil end
   local cache = self.cache
   if cache.occupancy + 1 > cache.occupancy_hi then self:evict_one() end
   return cache:add(hash, key, self.store:val_at(store_index))
end

function CachingPodHashMap:evict_one()
   local cache, index = self.cache, self.evict_index
   assert(cache.occupancy > 0)
   while cache:is_empty(index) do index = band(index+1, cache.size-1) end
   cache:remove_at(index)
   self.evict_index = band(index+1, cache.size-1)
end

function CachingPodHashMap:remove_at(i)
   local hash, key = self:hash_at(i), self:key_at(i)
   self.cache:remove_at(i)
   self.store:remove_at(self.store:lookup(hash, key))
end

function CachingPodHashMap:is_empty(i)
   return self.cache:is_empty(i)
end

function CachingPodHashMap:hash_at(i)
   return self.cache:hash_at(i)
end

function CachingPodHashMap:key_at(i)
   return self.cache:key_at(i)
end

function CachingPodHashMap:val_at(i)
   return self.cache:val_at(i)
end

function CachingPodHashMap:dump()
   print('cache:')
   self.cache:dump()
   print('store:')
   self.store:dump()
end

-- One of Bob Jenkins' hashes from
-- http://burtleburtle.net/bob/hash/integer.html.  Chosen to result
-- in the least badness as we adapt to int32 bitops.
function hash_i32(i32)
   i32 = tobit(i32)
   i32 = i32 + bnot(lshift(i32, 15))
   i32 = bxor(i32, (rshift(i32, 10)))
   i32 = i32 + lshift(i32, 3)
   i32 = bxor(i32, rshift(i32, 6))
   i32 = i32 + bnot(lshift(i32, 11))
   i32 = bxor(i32, rshift(i32, 16))

   -- Entries whose hash is 0 are empty; ensure that all hashes for
   -- non-empty entries ar e non-zero.
   i32 = bor(0x80000000, i32)

   return i32
end
