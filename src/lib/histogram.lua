-- histogram.lua -- a histogram with logarithmic buckets
--
-- API:
--   histogram.new(min, max) => histogram
--     Make a new histogram, with buckets covering the range from MIN to MAX.
--     The range between MIN and MAX will be divided logarithmically.
--
--   histogram.add(histogram, measurement)
--     Add a measurement to a histogram.
--
--   histogram.report(histogram, prev)
--     Print out non-empty buckets and their ranges.  If PREV is given,
--     it should be a snapshot of the previous version of the histogram.
--
--   histogram.snapshot(a, b)
--     Copy out the contents of A into B and return B.  If B is not given,
--     the result will be a fresh histogram.
--
--   histogram.clear(a)
--     Clear the counters in A.
--
--   histogram.wrap_thunk(histogram, thunk, now)
--     Return a closure that wraps THUNK, but which measures the difference
--     between calls to NOW before and after the thunk, recording that
--     difference into HISTOGRAM.
--
module(...,package.seeall)

local app  = require("core.app")
local ffi = require("ffi")

-- Fill a 4096-byte page with buckets.  4096/8 = 512, minus the three
-- header words means 509 buckets.  The first and last buckets are catch-alls.
local histogram_t = ffi.typeof([[struct {
   double minimum;
   double growth_factor_log;
   uint64_t count;
   uint64_t buckets[509];
}]])

function new(minimum, maximum)
   assert(minimum > 0)
   assert(maximum > minimum)
   -- 507 buckets for precise steps within minimum and maximum, 2 for
   -- the catch-alls.
   local growth_factor_log = math.log(maximum / minimum) / 507
   return histogram_t(minimum, growth_factor_log)
end

local log, floor, max, min = math.log, math.floor, math.max, math.min
function add(histogram, measurement)
   local bucket
   if measurement <= 0 then
      bucket = 0
   else
      bucket = log(measurement / histogram.minimum)
      bucket = bucket / histogram.growth_factor_log
      bucket = floor(bucket) + 1
      bucket = max(0, bucket)
      bucket = min(508, bucket)
   end
   histogram.count = histogram.count + 1
   histogram.buckets[bucket] = histogram.buckets[bucket] + 1
end

function report(histogram, prev)
   local lo, hi = 0, histogram.minimum
   local factor = math.exp(histogram.growth_factor_log)
   local total = histogram.count
   if prev then total = total - prev.total end
   total = tonumber(total)
   for bucket = 0, 508 do
      local count = histogram.buckets[bucket]
      if prev then count = count - prev.buckets[bucket] end
      if count ~= 0 then
         print(string.format('%.3e - %.3e: %u (%.5f%%)', lo, hi, tonumber(count),
                             tonumber(count) / total * 100.))
      end
      lo, hi = hi, hi * factor
   end
end

function snapshot(a, b)
   b = b or histogram_t()
   ffi.copy(b, a, ffi.sizeof(a))
   return b
end

function clear(histogram)
   histogram.count = 0
   for bucket = 0, 508 do histogram.buckets[bucket] = 0 end
end

function wrap_thunk(histogram, thunk, now)
   return function()
      local start = now()
      thunk()
      histogram:add(now() - start)
   end
end

ffi.metatype(histogram_t, {__index = {
   add = add,
   report = report,
   snapshot = snapshot,
   wrap_thunk = wrap_thunk,
   clear = clear
}})

function selftest ()
   print("selftest: histogram")

   local h = new(1e-6, 1e0)
   assert(ffi.sizeof(h) == 4096)

   h:add(1e-7)
   assert(h.buckets[0] == 1)
   h:add(1e-6 + 1e-9)
   assert(h.buckets[1] == 1)
   h:add(1.0 - 1e-9)
   assert(h.buckets[507] == 1)
   h:add(1.5)
   assert(h.buckets[508] == 1)

   assert(h.count == 4)
   assert(h:snapshot().count == 4)

   h:report()

   h:clear()
   assert(h.count == 0)
   assert(h.buckets[508] == 0)

   print("selftest ok")
end

