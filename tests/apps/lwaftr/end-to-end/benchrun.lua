#! /usr/bin/env luajit

if #arg ~= 2 then
	io.stderr:write("Usage: benchrun.lua N command\n")
	os.exit(1)
end
local rounds = tonumber(arg[1])
local command = arg[2]

local ffi = require("ffi")
ffi.cdef("int isatty(int)")

local report_progress
local highlight
if ffi.C.isatty(1) ~= 0 then
	report_progress = function (round, last_value)
		io.stdout:write(string.format("\rProgress: %d%% (%d/%d)",
			round / rounds * 100, round, rounds))
		if last_value ~= nil then
			io.stdout:write(", last value: " .. tostring(last_value))
		end
		io.stdout:flush()
	end
	highlight = function (str)
		return "[1;1m" .. str .. "[0;0m"
	end
else
	report_progress = function (round, last_value)
		io.stdout:write(".")
		io.stdout:flush()
	end
	highlight = function (str)
		return str
	end
end


local function average(values)
	local sum = 0.0
	for _, value in ipairs(values) do
		sum = sum + value
	end
	return sum / #values
end

local function stderror(values)
	local avg = average(values)
	local diffsum = 0.0
	for _, value in ipairs(values) do
		local diff = (value - avg)
		diffsum = diffsum + (diff * diff)
	end
	local stddev = math.sqrt(diffsum / #values)
	return stddev / math.sqrt(#values)
end


local function new(base_table, table)
	return setmetatable(table or {}, { __index = base_table })
end

-- A sample_set is a table where the numeric indexes contain numeric values,
-- plus some additional methods to query and calculate statistics from them.
local sample_set_report_fmt = highlight("%s") .. [[:
  min: %g
  max: %g
  avg: %g
  err: %g
]]
local sample_set = {
	name = "(unnamed)";

	new = new;
	min = function (self) return math.min(unpack(self)) end;
	max = function (self) return math.max(unpack(self)) end;
	average = average;
	stderror = stderror;

	report = function (self)
		io.stdout:write(sample_set_report_fmt:format(tostring(self.name),
			self:min(), self:max(), self:average(), self:stderror()))
	end;

	add_sample = table.insert;
}


local sample_sets = {}

-- Rate: N.M MPPS
local match_rate_line_pattern = "^[Rr]ate[^%d]*([%d%.]+)"
local rate_line_matcher = {
	_sample_set = 0;

	start = function (self)
		self._sample_set = 1
	end;

	finish = function (self)
		-- no-op
	end;

	feed_line = function (self, line)
		local value = line:match(match_rate_line_pattern)
		if value == nil then
			return false
		end
		if sample_sets[self._sample_set] == nil then
			sample_sets[self._sample_set] = sample_set:new {
				name = "rate[" .. tostring(self._sample_set) .. "].mpps"
			}
		end
		sample_sets[self._sample_set]:add_sample(tonumber(value))
		self._sample_set = self._sample_set + 1
		return true
	end;
}

-- vN_stats: 1.1012 MPPS, 4.778 Gbps.
--   where N = 4|6
local match_vN_stats_line_pattern = "^(v[46]_stats):%s*([%d%.]+)%s*MPPS[,%s]+([%d%.]+)%s*Gbps"
vN_stats_line_matcher = {
	start = function (self)
		-- no-op
	end;
	finish = function (self)
		-- no-op
	end;

	feed_line = function (self, line)
		local name, mpps, gbps = line:match(match_vN_stats_line_pattern)
		if name == nil then
			return false
		end

		local mpps_key, gbps_key = name .. ".mpps", name .. ".gbps"
		if sample_sets[mpps_key] == nil then
			sample_sets[mpps_key] = sample_set:new { name = mpps_key }
		end
		if sample_sets[gbps_key] == nil then
			sample_sets[gbps_key] = sample_set:new { name = gbps_key }
		end
		sample_sets[gbps_key]:add_sample(tonumber(gbps))
		sample_sets[mpps_key]:add_sample(tonumber(mpps))
		return true;
	end;
}


local matchers = {
	rate_line_matcher,
	vN_stats_line_matcher,

	start = function (self)
		for _, matcher in ipairs(self) do
			matcher:start()
		end
	end;

	finish = function (self)
		for _, matcher in ipairs(self) do
			matcher:finish()
		end
	end;

	feed_line = function (self, line)
		local matched = false
		for _, matcher in ipairs(self) do
			matched = matched or matcher:feed_line(line)
		end
		return matched
	end;
}


local last_match = nil
for i = 1, rounds do
	matchers:start()

	report_progress(i, last_match)
	local proc = io.popen(command, "r")
	local sample_set = 1
	for line in proc:lines() do
		if matchers:feed_line(line) then
			last_match = line
		end
	end
	proc:close()

	matchers:finish()
end
io.stdout:write("\n")


for setnum, samples in ipairs(sample_sets) do
	samples:report()
end
if #sample_sets > 1 then
	local sum_samples = sample_set:new { name = "rate[sum].mpps" }
	for i = 1, #sample_sets[1] do
		local v = 0.0
		for _, samples in ipairs(sample_sets) do
			v = v + samples[1]
		end
		sum_samples:add_sample(v)
	end
	sum_samples:report()
end

for setname, samples in pairs(sample_sets) do
	if type(setname) == "string" then
		samples:report()
	end
end
