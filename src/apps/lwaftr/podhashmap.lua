module(..., package.seeall)

local ffi = require("ffi")
local C = ffi.C
local S = require("syscall")
local bit = require("bit")
local bxor, bnot = bit.bxor, bit.bnot
local tobit, lshift, rshift = bit.tobit, bit.lshift, bit.rshift
local max, floor = math.max, math.floor

PodHashMap = {}

local HASH_MAX = 0xFFFFFFFF
local INT32_MIN = -0x80000000
local INITIAL_SIZE = 8
local MAX_OCCUPANCY_RATE = 0.9
local MIN_OCCUPANCY_RATE = 0.0

--- 32 bytes
local function make_entry_type(key_type, value_type)
   return ffi.typeof([[struct {
         uint32_t hash;
         $ key;
         $ value;
      } __attribute__((packed))]],
      key_type,
      value_type)
end

local function make_entries_type(entry_type)
   return ffi.typeof('$[?]', entry_type)
end

-- hash := [0,HASH_MAX); scale := size/HASH_MAX
local function hash_to_index(hash, scale)
   return floor(hash*scale + 0.5)
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

function PodHashMap:save(filename)
   local fd, err = S.open(filename, "creat, wronly")
   if not fd then
      error("error saving hash table, while creating "..filename..": "..tostring(err))
   end
   local size = ffi.sizeof(self.type, self.size * 2)
   local ptr = ffi.cast("uint8_t*", self.entries)
   while size > 0 do
      local written, err = S.write(fd, ptr, size)
      if not written then
         fd:close()
         error("error saving hash table, while writing "..filename..": "..tostring(err))
      end
      ptr = ptr + written
      size = size - written
   end
   fd:close()
end

function PodHashMap:load(filename)
   local fd, err = S.open(filename, "rdwr")
   if not fd then
      error("error opening saved hash table ("..filename.."): "..tostring(err))
   end
   local size = S.fstat(fd).size
   local entry_count = floor(size / ffi.sizeof(self.type, 1))
   if size ~= ffi.sizeof(self.type, entry_count) then
      fd:close()
      error("corrupted saved hash table ("..filename.."): bad size: "..size)
   end
   local mem, err = S.mmap(nil, size, 'read, write', 'private', fd, 0)
   fd:close()
   if not mem then error("mmap failed: " .. tostring(err)) end

   -- OK!
   self.size = floor(entry_count / 2)
   self.scale = self.size / HASH_MAX
   self.occupancy = 0
   self.max_displacement = 0
   self.entries = ffi.cast(ffi.typeof('$*', self.entry_type), mem)
   self.occupancy_hi = floor(self.size * self.max_occupancy_rate)
   self.occupancy_lo = floor(self.size * self.min_occupancy_rate)

   ffi.gc(self.entries, function (ptr) S.munmap(ptr, size) end)

   for i=0,self.size*2-1 do
      if self.entries[i].hash ~= HASH_MAX then
         self.occupancy = self.occupancy + 1
         local displacement = i - hash_to_index(self.entries[i].hash, self.scale)
         self.max_displacement = max(self.max_displacement, displacement)
      end
   end
end

function PodHashMap:resize(size)
   assert(size >= (self.occupancy / self.max_occupancy_rate))
   local old_entries = self.entries
   local old_size = self.size

   self.size = size
   self.scale = self.size / HASH_MAX
   self.occupancy = 0
   self.max_displacement = 0
   self.entries = self.type(self.size * 2)
   self.occupancy_hi = floor(self.size * self.max_occupancy_rate)
   self.occupancy_lo = floor(self.size * self.min_occupancy_rate)
   for i=0,self.size*2-1 do self.entries[i].hash = HASH_MAX end

   for i=0,old_size*2-1 do
      if old_entries[i].hash ~= HASH_MAX then
         self:add(old_entries[i].hash, old_entries[i].key, old_entries[i].value)
      end
   end
end

function PodHashMap:prepare_lookup_bufs(stride)
   return self.type(stride), self.type(stride * (self.max_displacement + 1))
end

function PodHashMap:fill_lookup_buf(hash, dst, offset, width)
   local entries = self.entries
   local unit_size = ffi.sizeof(self.entry_type)
   local start_index = hash_to_index(hash, self.scale)
   ffi.copy(dst + offset, entries + start_index, unit_size * width)
end

function PodHashMap:fill_lookup_bufs(keys, results, stride)
   local width = self.max_displacement + 1
   for i=0,stride-1 do
      self:fill_lookup_buf(keys[i].hash, results, i * width, width)
   end
end

function PodHashMap:lookup_from_bufs(keys, results, i)
   local max_displacement = self.max_displacement
   local result = i * (max_displacement + 1)

   -- Fast path for displacement == 0.
   if results[result].hash == keys[i].hash then
      if keys[i].key == results[result].key then
         return result
      end
   end

   for result = result+1, result+max_displacement+1 do
      if results[result].hash > keys[i].hash then return nil end
      if results[result].hash == keys[i].hash then
         if keys[i].key == results[result].key then return result end
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
   local scale = self.scale
   local start_index = hash_to_index(hash, self.scale)
   local index = start_index
   --print('adding ', hash, key, value, index)

   while entries[index].hash < hash do
      --print('displace', index, entries[index].hash)
      index = index + 1
   end

   while entries[index].hash == hash do
      --- Update currently unsupported.
      --print('update?', index)
      assert(key ~= entries[index].key)
      index = index + 1
   end

   self.max_displacement = max(self.max_displacement, index - start_index)

   if entries[index].hash ~= HASH_MAX then
      --- Rob from rich!
      --print('steal', index)
      local empty = index;
      while entries[empty].hash ~= HASH_MAX do empty = empty + 1 end
      --print('end', empty)
      while empty > index do
         entries[empty] = entries[empty - 1]
         local displacement = empty - hash_to_index(entries[empty].hash, scale)
         self.max_displacement = max(self.max_displacement, displacement)
         empty = empty - 1;
      end
   end
           
   self.occupancy = self.occupancy + 1
   entries[index].hash = hash
   entries[index].key = key
   entries[index].value = value
   return index
end

local function lookup_helper(entries, index, hash, other_hash, key)
   if hash == other_hash and key == entries[index].key then
      -- Found!
      return index
   end

   while other_hash < hash do
      index = index + 1
      other_hash = entries[index].hash
   end

   while other_hash == hash do
      if key == entries[index].key then
         -- Found!
         return index
      end
      -- Otherwise possibly a collision.
      index = index + 1
      other_hash = entries[index].hash
   end

   -- Not found.
   return nil
end

function PodHashMap:lookup(hash, key)
   assert(hash ~= HASH_MAX)

   local entries = self.entries
   local index = hash_to_index(hash, self.scale)
   local other_hash = entries[index].hash

   return lookup_helper(entries, index, hash, other_hash, key)
end

function PodHashMap:lookup2(hash1, key1, hash2, key2)
   return self:lookup(hash1, key1), self:lookup(hash2, key2)
end

function PodHashMap:lookup2p(hash1, key1, hash2, key2)
   assert(hash1 ~= HASH_MAX)
   assert(hash2 ~= HASH_MAX)

   local entries, scale = self.entries, self.scale

   local index1 = hash_to_index(hash1, scale)
   local other_hash1 = entries[index1].hash
   local index2 = hash_to_index(hash2, scale)
   local other_hash2 = entries[index2].hash

   local result1 = lookup_helper(entries, index1, hash1, other_hash1, key1)
   local result2 = lookup_helper(entries, index2, hash2, other_hash2, key2)

   return result1, result2
end

function PodHashMap:lookup4p(hash1, key1, hash2, key2, hash3, key3, hash4, key4)
   assert(hash1 ~= HASH_MAX)
   assert(hash2 ~= HASH_MAX)
   assert(hash3 ~= HASH_MAX)
   assert(hash4 ~= HASH_MAX)

   local entries, scale = self.entries, self.scale

   local index1 = hash_to_index(hash1, scale)
   local other_hash1 = entries[index1].hash
   local index2 = hash_to_index(hash2, scale)
   local other_hash2 = entries[index2].hash
   local index3 = hash_to_index(hash3, scale)
   local other_hash3 = entries[index3].hash
   local index4 = hash_to_index(hash4, scale)
   local other_hash4 = entries[index4].hash

   local result1 = lookup_helper(entries, index1, hash1, other_hash1, key1)
   local result2 = lookup_helper(entries, index2, hash2, other_hash2, key2)
   local result3 = lookup_helper(entries, index3, hash3, other_hash3, key3)
   local result4 = lookup_helper(entries, index4, hash4, other_hash4, key4)

   return result1, result2, result3, result4
end

function PodHashMap:prefetch(hash)
   return self.entries[hash_to_index(hash, self.scale)].hash
end

function PodHashMap:lookup_with_prefetch(hash, key, prefetch)
   assert(hash ~= HASH_MAX)
   return lookup_helper(self.entries, hash_to_index(hash, self.scale), hash, prefetch, key)
end

-- FIXME: Does NOT shrink max_displacement
function PodHashMap:remove_at(i)
   assert(not self:is_empty(i))

   local entries = self.entries
   local scale = self.scale

   self.occupancy = self.occupancy - 1
   entries[i].hash = HASH_MAX

   while true do
      local next = i + 1
      local next_hash = entries[next].hash
      if next_hash == HASH_MAX then break end
      if hash_to_index(next_hash, scale) == next then break end
      -- Give to the poor.
      entries[i] = entries[next]
      entries[next].hash = HASH_MAX
      i = next
   end

   if self.occupancy < self.size * self.min_occupancy_rate then
      self:resize(self.size / 2)
   end
end

function PodHashMap:is_empty(i)
   assert(i >= 0 and i < self.size*2)
   return self.entries[i].hash == HASH_MAX
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
   local function dump_one(index)
      io.write(index..':')
      local entry = self.entries[index]
      if (entry.hash == HASH_MAX) then
         io.write('\n')
      else
         local distance = index - hash_to_index(entry.hash, self.scale)
         io.write(' hash: '..entry.hash..' (distance: '..distance..')\n')
         io.write('    key: '..tostring(entry.key)..'\n')
         io.write('  value: '..tostring(entry.value)..'\n')
      end
   end
   for index=0,self.size-1 do dump_one(index) end
   for index=self.size,self.size*2-1 do
      if self.entries[index].hash == HASH_MAX then break end
      dump_one(index)
   end
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

   -- Unset the low bit, to distinguish valid hashes from HASH_MAX.
   i32 = lshift(i32, 1)
   -- Project result to u32 range.
   return i32 - INT32_MIN
end

local murmur = require('lib.hash.murmur').MurmurHash3_x86_32:new()
local vptr = ffi.new("uint8_t [4]")
function murmur_hash_i32(i32)
   ffi.cast("int32_t*", vptr)[0] = i32
   local h = murmur:hash(vptr, 4, 0ULL).u32[0]

   -- Unset the low bit, to distinguish valid hashes from HASH_MAX.
   local i32 = lshift(i32, 1)
   -- Project result to u32 range.
   return i32 - INT32_MIN
end
