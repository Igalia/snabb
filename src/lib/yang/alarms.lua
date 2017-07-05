module(..., package.seeall)

local function set (t)
   local ret = {}
   for _, k in ipairs(t) do ret[k] = true end
   return ret
end

-- Supported common-alarm-parameters and resource-alarm-parameters.
local alarm_params = set{'alt_resource', 'impacted_resource',
   'root_cause_resource', 'is_cleared', 'last_changed', 'perceived_severity',
   'alarm_text'}

local alarms = {
   list = {},
   shelved = {},
   summary = {},
}

Alarm = {}

function Alarm.new (key, params)
   assert(key.resource and key.alarm_type_id and key.alarm_type_qualifier,
      'Not valid alarm key')
   local o = {}
   for k,v in pairs(key) do
      o[k] = v
   end
   for k,v in pairs(params or {}) do
      assert(alarm_params[k], 'Not valid alarm param: '..k)
      o[k] = v
   end
   return setmetatable(o, {__index = Alarm})
end

-- Q: What's an alarm?
-- A: The data associated with an alarm is the data specified in the yang schema.

-- to be called by the data plane.
function set_alarm (key, params)
   local alarm = Alarm.new(key, params)
   table.insert(alarms.list, alarm)
end

local function equals_key (key1, key2)
   return key1.resource == key2.resource and
          key1.alarm_type_id == key2.alarm_type_id and
          key1.alarm_type_qualifier == key2.alarm_type_qualifier
end

-- does it indicate which schema name.
function get_alarm (key)
   for _, alarm in ipairs(alarms.list) do
      if equals_key(alarm, key) then
         return alarm
      end
   end
end

-- to be called by the config leader.
--   This operation requests the server to compress entries in the
--   alarm list by removing all but the latest state change for all
--   alarms.  Conditions in the input are logically ANDed.  If no
--   input condition is given, all alarms are compressed.
function compress_alarms ()
   return 0
end

-- to be called by the config leader.
--   This operation requests the server to delete entries from the
--   alarm list according to the supplied criteria.  Typically it
--   can be used to delete alarms that are in closed operator state
--   and older than a specified time.  The number of purged alarms
--   is returned as an output parameter
function purge_alarms ()
   return 0
end

function selftest ()
   local key = {
      resource = 'resource1',
      alarm_type_id = 'alarm_type1',
      alarm_type_qualifier = 'alarm_type_qualifier1',
   }
   set_alarm(key)
   assert(get_alarm(key))
end
