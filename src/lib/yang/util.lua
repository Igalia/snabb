-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(..., package.seeall)

local lib = require("core.lib")
local ffi = require("ffi")
local ipv4 = require("lib.protocol.ipv4")

ffi.cdef([[
unsigned long long strtoull (const char *nptr, const char **endptr, int base);
]])

function tointeger(str, what, min, max)
   if not what then what = 'integer' end
   local str = assert(str, 'missing value for '..what)
   local start = 1
   local is_negative
   local base = 10
   if str:match('^-') then start, is_negative = 2, true
   elseif str:match('^+') then start = 2 end
   if str:match('^0x', start) then base, start = 16, start + 2
   elseif str:match('^0', start) then base = 8 end
   str = str:lower()
   if start > str:len() then
      error('invalid numeric value for '..what..': '..str)
   end
   -- FIXME: check that res did not overflow the 64-bit number
   local res = ffi.C.strtoull(str:sub(start), nil, base)
   if is_negative then
      res = ffi.new('int64_t[1]', -1*res)[0]
      if res > 0 then
         error('invalid numeric value for '..what..': '..str)
      end
      if min and not (min <= 0 and min <= res) then
         error('invalid numeric value for '..what..': '..str)
      end
   else
      -- Only compare min and res if both are positive, otherwise if min
      -- is a negative int64_t then the comparison will treat it as a
      -- large uint64_t.
      if min and not (min <= 0 or min <= res) then
         error('invalid numeric value for '..what..': '..str)
      end
   end
   if max and res > max then
      error('invalid numeric value for '..what..': '..str)
   end
   -- Only return Lua numbers for values within int32 + uint32 range.
   -- The 0 <= res check is needed because res might be a uint64, in
   -- which case comparing to a negative Lua number will cast that Lua
   -- number to a uint64 :-((
   if (0 <= res or -0x8000000 <= res) and res <= 0xffffffff then
      return tonumber(res)
   end
   return res
end

function ffi_array(ptr, elt_t, count)
   local mt = {}
   local size = count or ffi.sizeof(ptr)/ffi.sizeof(elt_t)
   function mt:__len() return size end
   function mt:__index(idx)
      assert(1 <= idx and idx <= size)
      return ptr[idx-1]
   end
   function mt:__newindex(idx, val)
      assert(1 <= idx and idx <= size)
      ptr[idx-1] = val
   end
   function mt:__ipairs()
      local idx = -1
      return function()
         idx = idx + 1
         if idx >= size then return end
         return idx+1, ptr[idx]
      end
   end
   return ffi.metatype(ffi.typeof('struct { $* ptr; }', elt_t), mt)(ptr)
end

-- The yang modules represent IPv4 addresses as host-endian uint32
-- values in Lua.  See https://github.com/snabbco/snabb/issues/1063.
function ipv4_pton(str)
   return lib.ntohl(ffi.cast('uint32_t*', assert(ipv4:pton(str)))[0])
end

function ipv4_ntop(addr)
   return ipv4:ntop(ffi.new('uint32_t[1]', lib.htonl(addr)))
end

function string_output_file()
   local file = {}
   local out = {}
   function file:write(str) table.insert(out, str) end
   function file:flush(str) return table.concat(out) end
   return file
end

function memoize(f, max_occupancy)
   local cache = {}
   local occupancy = 0
   local argc = 0
   max_occupancy = max_occupancy or 10
   return function(...)
      local args = {...}
      if #args == argc then
         local walk = cache
         for i=1,#args do
            if walk == nil then break end
            walk = walk[args[i]]
         end
         if walk ~= nil then return unpack(walk) end
      else
         cache, occupancy, argc = {}, 0, #args
      end
      local ret = {f(...)}
      if occupancy >= max_occupancy then
         cache = {}
         occupancy = 0
      end
      local walk = cache
      for i=1,#args-1 do
         if not walk[args[i]] then walk[args[i]] = {} end
         walk = walk[args[i]]
      end
      walk[args[#args]] = ret
      occupancy = occupancy + 1
      return unpack(ret)
   end
end

-- Converts a csv file to a Lua table.
--
-- Columns may contain multivalue data, in that case the values should be
-- separated by hashes (#). Multivalue columns are converted to simple arrays.
function csv_to_table (filename, opts)
   assert(filename, 'Missing filename')
   opts = opts or {}
   local sep = opts.sep or ';'
   local fields = opts.fields
   local function split (str, sep)
      sep = sep or ';'
      local ret = {}
      local pattern = "([^"..sep.."]+)"
      for each in str:gmatch(pattern) do
         table.insert(ret, each)
      end
      return ret
   end
   local function trim (str)
      str = str or ''
      str = str:gsub("^%s+", "")
      str = str:gsub("%s+$", "")
      return str
   end
   local function parse_line (line)
      local ret = {}
      for _, val in ipairs(split(line, sep)) do
         table.insert(ret, trim(val))
      end
      return ret
   end
   local function parse_value (value)
      local type = type(value)
      if type == 'nil' then
         return nil
      elseif type == 'number' then
         return tonumber(value)
      elseif type == 'boolean' then
         return value:upper() == 'TRUE'
      elseif type == 'string' then
         return value:match('#') and split(value, '#') or value
      else
         error('Not supported type: '..type)
      end
   end
   local ret = {}
   local lineno = 0
   for line in io.lines(filename) do
      lineno = lineno + 1
      if lineno == 1 then
         fields = parse_line(line)
         goto continue
      end
      local values = parse_line(line)
      local row = {}
      for i=1,#fields do
         local field, value = fields[i], values[i]
         row[field] = parse_value(value)
      end
      table.insert(ret, row)
      ::continue::
   end
   local size = lineno - 1
   return ret, size
end

local function gmtime ()
   local now = os.time()
   local utcdate = os.date("!*t", now)
   local localdate = os.date("*t", now)
   localdate.isdst = false
   local timediff = os.difftime(os.time(utcdate), os.time(localdate))
   return now + timediff
end

function iso_8601 (time)
   time = time or gmtime()
   return os.date("%Y-%m-%dT%H:%M:%SZ", time)
end

function selftest()
   print('selftest: lib.yang.util')
   assert(tointeger('0') == 0)
   assert(tointeger('-0') == 0)
   assert(tointeger('10') == 10)
   assert(tostring(tointeger('10')) == '10')
   assert(tointeger('-10') == -10)
   assert(tointeger('010') == 8)
   assert(tointeger('-010') == -8)
   assert(tointeger('0xffffffff') == 0xffffffff)
   assert(tointeger('0xffffffffffffffff') == 0xffffffffffffffffULL)
   assert(tointeger('0x7fffffffffffffff') == 0x7fffffffffffffffULL)
   assert(tointeger('0xffffffffffffffff') == 0xffffffffffffffffULL)
   assert(tointeger('-0x7fffffffffffffff') == -0x7fffffffffffffffLL)
   assert(tointeger('-0x8000000000000000') == -0x8000000000000000LL)
   assert(ipv4_pton('255.0.0.1') == 255 * 2^24 + 1)
   assert(ipv4_ntop(ipv4_pton('255.0.0.1')) == '255.0.0.1')
   print('selftest: ok')
end
