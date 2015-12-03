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

local try_huge_pages = true
function PodHashMap:resize(size)
   assert(size >= (self.occupancy / self.max_occupancy_rate))
   local old_entries = self.entries
   local old_size = self.size

   local byte_size = size * 2 * ffi.sizeof(self.type, 1)
   local mem, err
   if try_huge_pages and byte_size > 1e6 then
      mem, err = S.mmap(nil, byte_size, 'read, write',
                              'private, anonymous, hugetlb')
      if not mem then
         print("hugetlb mmap failed ("..tostring(err)..'), falling back.')
         try_use_huge_pages = false
      end
   end
   if not mem then
      mem, err = S.mmap(nil, byte_size, 'read, write',
                        'private, anonymous')
      if not mem then error("mmap failed: " .. tostring(err)) end
   end

   self.size = size
   self.scale = self.size / HASH_MAX
   self.occupancy = 0
   self.max_displacement = 0
   self.entries = ffi.cast(ffi.typeof('$*', self.entry_type), mem)
   self.occupancy_hi = floor(self.size * self.max_occupancy_rate)
   self.occupancy_lo = floor(self.size * self.min_occupancy_rate)
   for i=0,self.size*2-1 do self.entries[i].hash = HASH_MAX end

   ffi.gc(self.entries, function (ptr) S.munmap(ptr, byte_size) end)

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

function PodHashMap:prefetch(hash)
   return self.entries[hash_to_index(hash, self.scale)].hash
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

function PodHashMap:selfcheck(hash_fn)
   local occupancy = 0
   local max_displacement = 0

   local function fail(expected, op, found, what, where)
      if where then where = 'at '..where..': ' else where = '' end
      error(where..what..' check: expected '..expected..op..'found '..found)
   end
   local function expect_eq(expected, found, what, where)
      if expected ~= found then fail(expected, '==', found, what, where) end
   end
   local function expect_le(expected, found, what, where)
      if expected > found then fail(expected, '<=', found, what, where) end
   end

   local prev = 0
   for i = 0,self.size*2-1 do
      local entry = self.entries[i]
      local hash = entry.hash
      if hash ~= 0xffffffff then
         expect_eq(hash_fn(entry.key), hash, 'hash', i)
         local index = hash_to_index(hash, self.scale)
         if prev == 0xffffffff then
            expect_eq(index, i, 'undisplaced index', i)
         else
            expect_le(prev, hash, 'displaced hash', i)
         end
         occupancy = occupancy + 1
         max_displacement = max(max_displacement, i - index)
      end
      prev = hash
   end

   expect_eq(occupancy, self.occupancy, 'occupancy')
   -- Compare using <= because remove_at doesn't update max_displacement.
   expect_le(max_displacement, self.max_displacement, 'max_displacement')
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

function selfcheck()
   local pmu = require('lib.pmu')
   local has_pmu_counters, err = pmu.is_available()
   if not has_pmu_counters then
      print('No PMU available: '..err)
      print('Measuring nanoseconds instead of cycles.')
   end

   local function count_cycles(f, iterations)
      pmu.setup({"ref_cycles"})
      local set = pmu.new_counter_set()
      pmu.switch_to(set)
      local res = f(iterations)
      pmu.switch_to(nil)
      return pmu.to_table(set).ref_cycles, res
   end

   local function count_ns(f, iterations)
      local start = C.get_time_ns()
      local res = f(iterations)
      local stop = C.get_time_ns()
      return tonumber(stop-start), res
   end

   local function check_perf(f, iterations, max, measure, unit, what)
      io.write(tostring(what or f)..': ')
      io.flush()
      local total, res = measure(f, iterations)
      local per_iteration = total / iterations
      io.write(per_iteration..' '..unit..'/iteration (result: '..tostring(res)..')\n')
      if per_iteration > max then
         error('perfmark failed: exceeded maximum '..max)
      end
      return res
   end

   local function assert_cycles_or_ns_le(f, iterations, cycles, ns, what)
      require('jit').flush()
      if has_pmu_counters then
         return check_perf(f, iterations, cycles, count_cycles, 'cycles', what)
      else
         return check_perf(f, iterations, ns, count_ns, 'ns', what)
      end
   end

   local function test_jenkins(iterations)
      local result
      for i=1,iterations do result=hash_i32(i) end
      return result
   end

   local function test_murmur(iterations)
      local result
      for i=1,iterations do result=murmur_hash_i32(i) end
      return result
   end

   assert_cycles_or_ns_le(test_jenkins, 1e8, 15, 4, 'jenkins hash')
   assert_cycles_or_ns_le(test_murmur, 1e8, 30, 8, 'murmur hash (32 bit)')

   local rhh = PodHashMap.new(ffi.typeof('uint32_t'), ffi.typeof('int32_t'))
   rhh:resize(1e7 / 0.4 + 1)

   local function test_insertion(count)
      for i = 1, count do
         local h = hash_i32(i)
         local v = bnot(i)
         rhh:add(h, i, v)
      end
   end

   local function test_lookup(count)
      local result
      for i = 1, count do
         result = rhh:lookup(hash_i32(i), i)
      end
      return result
   end

   local function test_lookup_with_2x_prefetch(count)
      local r1, r2
      for i = 1, count, 2 do
         local h1, h2 = hash_i32(i), hash_i32(i+1)
         rhh:prefetch(h1)
         rhh:prefetch(h2)
         r1, r2 = rhh:lookup(h1, i), rhh:lookup(h2, i+1)
      end
      return r2
   end

   assert_cycles_or_ns_le(test_insertion, 1e7, 400, 100,
                          'insertion (40% occupancy)')
   print('max displacement: '..rhh.max_displacement)
   io.write('selfcheck: ')
   io.flush()
   rhh:selfcheck(hash_i32)
   io.write('pass\n')

   io.write('population check: ')
   io.flush()
   for i = 1, 1e7 do
      local offset = rhh:lookup(hash_i32(i), i)
      assert(rhh:val_at(offset) == bnot(i))
   end
   rhh:selfcheck(hash_i32)
   io.write('pass\n')

   assert_cycles_or_ns_le(test_lookup, 1e7, 300, 100,
                          'lookup (40% occupancy)')
   assert_cycles_or_ns_le(test_lookup_with_2x_prefetch, 1e7, 300, 100,
                          'lookup with 2x prefetch (40% occupancy)')

   local stride = 1
   repeat
      local keys, results = rhh:prepare_lookup_bufs(stride)
      local function test_lookup_with_bufs(count)
         local result
         for i = 1, count, stride do
            local n = math.min(stride, count-i+1)
            for j = 0, n-1 do
               keys[j].hash = hash_i32(i+j)
               keys[j].key = i+j
            end
            rhh:fill_lookup_bufs(keys, results, n)
            for j = 0, n-1 do
               result = rhh:lookup_from_bufs(keys, results, j)
            end
         end
         return result
      end
      -- Note that "result" is an index into `results', not the phm, and
      -- so we expect the results to be different from rhh:lookup().
      assert_cycles_or_ns_le(test_lookup_with_bufs, 1e7, 1000, 100,
                             'lookup, stride='..stride)
      stride = stride * 2
   until stride > 256
end
