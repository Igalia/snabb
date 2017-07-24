module(..., package.seeall)

local S = require("syscall")
local util = require('lib.yang.util')

local csv_to_table = util.csv_to_table

config = {}
state = {
   alarm_inventory = nil,
   summary = nil,
   alarm_list = nil,
   shelved_alarms = nil,
}
local alarm_list_table

function get_state ()
   return state
end

-- Single point access to alarm keys.
alarm_keys = {}

function alarm_keys:fetch (...)
   self.cache = self.cache or {}
   local function lookup (resource, alarm_type_id, alarm_type_qualifier)
      if not self.cache[resource] then
         self.cache[resource] = {}
      end
      if not self.cache[resource][alarm_type_id] then
         self.cache[resource][alarm_type_id] = {}
      end
      return self.cache[resource][alarm_type_id][alarm_type_qualifier]
   end
   local resource, alarm_type_id, alarm_type_qualifier = unpack({...})
   assert(resource and alarm_type_id)
   alarm_type_qualifier = alarm_type_qualifier or ''
   local key = lookup(resource, alarm_type_id, alarm_type_qualifier)
   if not key then
      key = {resource=resource, alarm_type_id=alarm_type_id,
             alarm_type_qualifier=alarm_type_qualifier}
      self.cache[resource][alarm_type_id][alarm_type_qualifier] = key
   end
   return key
end
function alarm_keys:normalize (key)
   local resource = assert(key.resource)
   local alarm_type_id = assert(key.alarm_type_id)
   local alarm_type_qualifier = key.alarm_type_qualifier or ''
   return self:fetch(resource, alarm_type_id, alarm_type_qualifier)
end
function alarm_keys:tostring (key)
   key = self:normalize(key)
   return ("%s|%s|%s"):format(key.resource, key.alarm_type_id, key.alarm_type_qualifier)
end

-- Single point access to alarm type keys.
alarm_type_keys = {}

function alarm_type_keys:fetch (...)
   self.cache = self.cache or {}
   local function lookup (alarm_type_id, alarm_type_qualifier)
      if not self.cache[alarm_type_id] then
         self.cache[alarm_type_id] = {}
      end
      return self.cache[alarm_type_id][alarm_type_qualifier]
   end
   local alarm_type_id, alarm_type_qualifier = unpack({...})
   assert(alarm_type_id)
   alarm_type_qualifier = alarm_type_qualifier or ''
   local key = lookup(alarm_type_id, alarm_type_qualifier)
   if not key then
      key = {alarm_type_id=alarm_type_id, alarm_type_qualifier=alarm_type_qualifier}
      self.cache[alarm_type_id][alarm_type_qualifier] = key
   end
   return key
end
function alarm_type_keys:normalize (key)
   local alarm_type_id = assert(key.alarm_type_id)
   local alarm_type_qualifier = key.alarm_type_qualifier
   return self:fetch(alarm_type_id, alarm_type_qualifier)
end

local function load_alarm_list (filename)
   filename = filename or 'lib/yang/alarm_list.csv'
   local ret = {}
   for _, row in ipairs(csv_to_table(filename, {sep='|'})) do
      local key_str = alarm_keys:normalize(row)
      ret[key_str] = row
   end
   return ret
end

local function load_alarm_inventory (filename)
   filename = filename or 'lib/yang/alarm_inventory.csv'
   local ret = {}
   for _, row in ipairs(csv_to_table(filename, {sep='|'})) do
      local key = alarm_type_keys:fetch(row.alarm_type_id, row.alarm_type_qualifier)
      ret[key] = row
   end
   return ret
end

function init (current_configuration)
   -- The alarms inventory is always initialized with a predefined list of
   -- alarm types.
   config = current_configuration.softwire_config.alarms.control
   state = {
      alarm_inventory = {
         alarm_type = load_alarm_inventory(),
      },
      alarm_list = {
         number_of_alarms = 0,
         alarm = {},
      },
   }
   alarm_list_table = load_alarm_list()
end

-- Helper function for debugging purposes.
local function show_alarm_inventory (alarm_inventory)
   local alarm_type = alarm_inventory.alarm_type or {}
   for k,v in pairs(alarm_inventory.alarm_type) do
      pp(v)
      print("--")
   end
end

local function new_status_change (alarm, args)
   assert(alarm and args)
   if alarm.is_cleared ~= args.is_cleared then
      return true
   elseif args.perceived_severity and
          alarm.perceived_severity ~= args.perceived_severity then
      return true
   elseif args.alarm_text and alarm.alarm_text ~= args.alarm_text then
      return true
   end
   return false
end

-- Q: What's an alarm?
-- A: The data associated with an alarm is the data specified in the yang schema.

local function gmtime ()
   local now = os.time()
   local utcdate = os.date("!*t", now)
   local localdate = os.date("*t", now)
   localdate.isdst = false
   local timediff = os.difftime(os.time(utcdate), os.time(localdate))
   return now + timediff
end

local function iso_8601 (time)
   time = time or gmtime()
   return os.date("%Y-%m-%dT%H:%M:%SZ", time)
end

-- The entry with latest time-stamp in this list MUST correspond to the leafs
-- 'is-cleared', 'perceived-severity' and 'alarm-text' for the alarm.
-- The time-stamp for that entry MUST be equal to the 'last-changed' leaf.
local function create_status_change (alarm, status)
   if not alarm.status_change then
      alarm.status_change = {}
   end
   alarm.perceived_severity = status.perceived_severity
   alarm.alarm_text = status.alarm_text
   alarm.last_changed = status.time
   state.alarm_list.last_changed = status.time
   table.insert(alarm.status_change, status)
end

-- The following state changes creates an entry in this list:
--   - changed severity (warning, minor, major, critical)
--   - clearance status, this also updates the 'is-cleared' leaf
--   - alarm text update
local function create_status_change_if_needed (alarm, args)
   if new_status_change(alarm, args) then
      local status = {
         time = iso_8601(),
         perceived_severity = args.perceived_severity or alarm.perceived_severity,
         alarm_text = args.alarm_text or alarm.alarm_text,
      }
      create_status_change(alarm, status)
      alarm.is_cleared = args.is_cleared
   end
end

local function flat_copy (src, args)
   args = args or {}
   local ret = {}
   for k,v in pairs(src) do
      ret[k] = args[k] or v
   end
   return ret
end

local function fetch_alarm_from_table (key)
   local key_str = alarm_keys:normalize(key)
   return alarm_list_table[key_str]
end

local function create_alarm (key, args)
   local alarm = assert(fetch_alarm_from_table(key), 'Not supported alarm')
   local ret = flat_copy(alarm, args)
   local status = {
      time = iso_8601(),
      perceived_severity = args.perceived_severity or ret.perceived_severity,
      alarm_text = args.alarm_text or ret.alarm_text,
   }
   create_status_change(ret, status)
   ret.last_changed = assert(status.time)
   ret.time_created = assert(ret.last_changed)
   ret.is_cleared = args.is_cleared
   ret.operator_state_change = {}
   state.alarm_list.number_of_alarms = state.alarm_list.number_of_alarms + 1
   return ret
end

local function create_or_update_alarm(key, args)
   assert(state.alarm_list.alarm)
   assert(key.resource and key.alarm_type_id and key.alarm_type_qualifier)
   assert(args and args.is_cleared ~= nil)
   local alarm = state.alarm_list.alarm[key]
   if not alarm then
      state.alarm_list.alarm[key] = create_alarm(key, args)
   else
      create_status_change_if_needed(alarm, args)
   end
end

-- Returns true if a new alarm should be created or,  in case it already exists
-- if a new alarm status should be added.
local function should_update (key, args)
   key = alarm_keys:normalize(key)
   local alarm = state.alarm_list.alarm[key]
   if not alarm then return true end
   return new_status_change(alarm, args)
end

-- To be called by the leader.
function raise_alarm (key, args)
   args = args or {}
   args.is_cleared = false
   key = alarm_keys:normalize(key)
   if should_update(key, args) then
      print('create_or_update_alarm')
      create_or_update_alarm(key, args)
   end
end

-- To be called by the leader.
function clear_alarm (key)
   local args = {}
   args.is_cleared = true
   key = alarm_keys:normalize(key)
   if should_update(key, args) then
      create_or_update_alarm(key, args)
   end
end

local function set (t)
   local ret = {}
   for _,k in ipairs(t) do ret[k] = true end
   return ret
end

local operator_states = {none=1, ack=2, closed=3, shelved=4, ['un-shelved']=5}

-- to be called by the config leader.
function set_operator_state (key, args)
   local alarm = state.alarm_list.alarm[key]
   if not alarm then
      -- Return error. Could not locate alarm.
      return false, 'Set operate state operation failed. Could not locate alarm.'
   end
   if not alarm.operator_state_change then
      alarm.operator_state_change = {}
   end
   assert(args.state and operator_states[args.state], 'Not a valid operator state')
   local time = iso_8601()
   local operator_state_change = {
      time = time,
      operator = args.operator or 'admin',
      state = args.state,
      text = args.text,
   }
   alarm.operator_state_change[time] = operator_state_change
   return true, alarm
end

local function compress_alarm(alarm)
   assert(alarm.status_change)
   local latest_status_change = alarm.status_change[#alarm.status_change]
   alarm.status_change = {latest_status_change}
end

local function alarm_key_matches(key1, resource, alarm_type_id, alarm_type_qualifier)
   if resource and resource ~= key1.resource then
      return false
   elseif alarm_type_id and alarm_type_id ~= key.alarm_type_id then
      return false
   elseif alarm_type_qualifier and alarm_type_qualifier ~= key.alarm_type_qualifier then
      return false
   end
   return true
end

-- to be called by the config leader.
--   This operation requests the server to compress entries in the
--   alarm list by removing all but the latest state change for all
--   alarms.  Conditions in the input are logically ANDed.  If no
--   input condition is given, all alarms are compressed.
function compress_alarms (resource, alarm_type_id, alarm_type_qualifier)
   local count = 0
   for k, v in pairs(state.alarm_list.alarm) do
      if alarm_key_matches(k, resource, alarm_type_id, alarm_type_qualifier) then
         compress_alarm(v)
         count = count + 1
      end
   end
   return count
end

local ages = {seconds=1, minutes=60, hours=3600, days=3600*24, weeks=3600*24*7}

local function sleep(n)
   os.execute("sleep " .. tonumber(n))
end

local function parse_iso8601 (date)
   assert(type(date) == 'string')
   -- XXX: ISO 8601 can be more complex. We asumme date is always in GTM+0.
   local pattern = "(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z"
   return assert(date:match(pattern))
end

local function toseconds (date)
   if type(date) == 'table' then
      assert(date.age_spec and date.value, "Not a valid 'older_than' data type")
      local multiplier = assert(ages[date.age_spec],
                                "Not a valid 'age_spec' value: "..date.age_spec)
      return date.value * multiplier
   elseif type(date) == 'string' then
      local t = {}
      t.year, t.month, t.day, t.hour, t.minute, t.second = parse_iso8601(date)
      return os.time(t)
   else
      error('Wrong data type: '..type(date))
   end
end

-- to be called by the config leader.
--   This operation requests the server to delete entries from the
--   alarm list according to the supplied criteria.  Typically it
--   can be used to delete alarms that are in closed operator state
--   and older than a specified time.  The number of purged alarms
--   is returned as an output parameter
--
--  args: {status, older_than, severity, operator_state}
function purge_alarms (args)
   local alarms = state.alarm_list.alarm
   local function purge_alarm (key)
      alarms[key] = nil
   end
   local function by_status (alarm, args)
      if not args.status then return false end
      local values = set{'any', 'cleared', 'not-cleared'}
      assert(values[args.status], 'Not a valid status value: '..args.status)
      local status = args.status
      if status == 'any' then return true end
      if status == 'cleared' then return alarm.is_cleared end
      if status == 'not-cleared' then return not alarm.is_cleared end
      return false
   end
   local function by_older_than (alarm, args)
      if not args.older_than then return false end
      local alarm_time = toseconds(alarm.time_created)
      local threshold = toseconds(args.older_than)
      return gmtime() - alarm_time >= threshold
   end
   local function by_severity (alarm, args)
      if not args.severity then return false end
      local values = {indeterminate=2, minor=3 , warning=4, major=5, critical=6}
      local function tonumber(severity)
         return values[severity]
      end
      local severity = args.severity
      assert(type(severity) == 'table' and severity.sev_spec and severity.value,
             'Not valid severity data type')
      local sev_spec, value = severity.sev_spec, severity.value
      local severity = tonumber(value)
      local alarm_severity = tonumber(alarm.perceived_severity)
      if sev_spec == 'below' then
         return alarm_severity < severity
      elseif sev_spec == 'is' then
         return alarm_severity == severity
      elseif sev_spec == 'above' then
         return alarm_severity > severity
      else
         error('Not valid sev-spec value: '..sev_spec)
      end
      return false
   end
   local function by_operator_state (alarm, args)
      if not args.operator_state then return false end
      local function tonumber (value)
         return value and operator_states[value]
      end
      local state, user = args.operator_state.state, args.operator_state.user
      if state or user then
         for _, state_change in pairs(alarm.operator_state_change or {}) do
            if state and tonumber(state_change.state) == tonumber(state) then
               return true
            elseif user and state_change.user == user then
               return true
            end
         end
      end
      return false
   end
   local filter = {}
   function filter:apply (alarm, args, fns)
      for _, fn in ipairs(fns) do
         if fn(alarm, args) then return true end
      end
      return false
   end
   local count = 0
   local fns = {by_status, by_older_than, by_severity, by_operator_state}
   for key, alarm in pairs(alarms) do
      if filter:apply(alarm, args, fns) then
         purge_alarm(key)
         count = count + 1
      end
   end
   return count
end

local function table_size (t)
   local ret = 0
   for _ in pairs(t) do ret = ret + 1 end
   return ret
end

function selftest ()
   print("selftest: lib.yang.alarms")

   -- Reads lwaftr.conf file.
   local capabilities = {
      ['ietf-softwire']={feature={'binding', 'br'}},
      ['ietf-alarms']={feature={'operator-actions', 'alarm-shelving', 'alarm-history'}},
   }
   require('lib.yang.schema').set_default_capabilities(capabilities)

   local data = require("lib.yang.data")
   local conf = [[
      softwire-config {
         binding-table {
            softwire {
               ipv4 178.79.150.3;
               psid 4;
               b4-ipv6 127:14:25:36:47:58:69:128;
               br-address 1e:2:2:2:2:2:2:af;
               port-set {
                  psid-length 6;
               }
            }
         }
         external-interface {
            allow-incoming-icmp false;
            error-rate-limiting {
               packets 600000;
            }
            ip 10.10.10.10;
            mac 12:12:12:12:12:12;
            next-hop {
               mac 68:68:68:68:68:68;
            }
            reassembly {
               max-fragments-per-packet 40;
            }
         }
         internal-interface {
            allow-incoming-icmp false;
            error-rate-limiting {
               packets 600000;
            }
            ip 8:9:a:b:c:d:e:f;
            mac 22:22:22:22:22:22;
            next-hop {
               mac 44:44:44:44:44:44;
            }
            reassembly {
               max-fragments-per-packet 40;
            }
         }
         alarms {
            control {
               notify-status-changes true;
            }
         }
      }
      softwire-state {
         alarms {
            summary {
               alarm-summary {
                 severity minor;
                 total 32;
                 cleared 100;
                 cleared-not-closed 10;
               }
            }
         }
      }
   ]]

   local filename = 'lib/yang/alarm_list.csv'
   local t = csv_to_table(filename, {sep='|'})
   assert(#t > 0)
   assert(t[1].resource, "#t: "..#t)

   local conf = data.load_data_for_schema_by_name('snabb-softwire-v2', conf)
   assert(conf.softwire_config.alarms.control.notify_status_changes)

   -- Init.
   init(conf)
   assert(config == conf.softwire_config.alarms.control)
   assert(type(state.alarm_inventory) == 'table')
   assert(type(state.alarm_inventory.alarm_type) == 'table')
   assert(type(state.alarm_list) == 'table')
   assert(type(state.alarm_list.alarm) == 'table')

   -- Check alarm inventory has been loaded.
   assert(table_size(state.alarm_inventory.alarm_type) == 2)

   -- Check number of alarms is zero.
   assert(state.alarm_list.number_of_alarms == 0)

   -- Raising an alarm when alarms is empty, creates an alarm.
   local key = alarm_keys:fetch('external-interface', 'arp-resolution')
   raise_alarm(key)
   local alarm = assert(state.alarm_list.alarm[key])
   assert(table_size(alarm.status_change) == 1)
   assert(state.alarm_list.number_of_alarms == 1)

   -- Raise same alarm again. Since there are not changes, everything remains the same.
   local alarm = state.alarm_list.alarm[key]
   local last_changed = alarm.last_changed
   local number_of_status_change = table_size(alarm.status_change)
   local number_of_alarms = state.alarm_list.number_of_alarms
   sleep(1)
   raise_alarm(key)
   assert(state.alarm_list.alarm[key].last_changed == last_changed)
   assert(table_size(alarm.status_change) == number_of_status_change)
   assert(state.alarm_list.number_of_alarms == number_of_alarms)

   -- Raise alarm again but changing severity.
   local alarm = state.alarm_list.alarm[key]
   local last_changed = alarm.last_changed
   local number_of_status_change = table_size(alarm.status_change)
   raise_alarm(key, {perceived_severity='minor'})
   assert(last_changed ~= alarm.last_changed)
   assert(table_size(alarm.status_change) == number_of_status_change + 1)

   -- Raise alarm again with same severity. Should not produce changes.
   local alarm = state.alarm_list.alarm[key]
   local last_changed = alarm.last_changed
   local number_of_status_change = table_size(alarm.status_change)
   raise_alarm(key, {perceived_severity='minor'})
   assert(last_changed == alarm.last_changed)
   assert(table_size(alarm.status_change) == number_of_status_change)

   -- Raise alarm again but changing alarm_text. A new status change is added.
   local alarm = state.alarm_list.alarm[key]
   local number_of_status_change = table_size(alarm.status_change)
   raise_alarm(key, {alarm_text='new text'})
   assert(table_size(alarm.status_change) == number_of_status_change + 1)
   assert(alarm.alarm_text == 'new text')

   -- Clear alarm. Should clear alarm and create a new status change in the alarm.
   local alarm = state.alarm_list.alarm[key]
   local number_of_status_change = table_size(alarm.status_change)
   assert(not alarm.is_cleared)
   sleep(1)
   clear_alarm(key)
   assert(alarm.is_cleared)
   assert(table_size(alarm.status_change) == number_of_status_change + 1)

   -- Clear alarm again. Nothing should change.
   local alarm = state.alarm_list.alarm[key]
   local last_changed = alarm.last_changed
   local number_of_status_change = table_size(alarm.status_change)
   assert(alarm.is_cleared)
   clear_alarm(key)
   assert(alarm.is_cleared)
   assert(table_size(alarm.status_change) == number_of_status_change,
          table_size(alarm.status_change).." == "..number_of_status_change)
   assert(alarm.last_changed == last_changed)

   -- Set operator state change.
   assert(table_size(alarm.operator_state_change) == 0)
   local success, alarm = set_operator_state(key, {state='ack'})
   assert(success)
   assert(table_size(alarm.operator_state_change) == 1)

   -- Set operator state change again. Should create a new operator state change.
   sleep(1)
   local success, alarm = set_operator_state(key, {state='ack'})
   assert(success)
   assert(table_size(alarm.operator_state_change) == 2)

   -- Set operator state change on non existent alarm should fail.
   local key = alarm_keys:fetch('none', 'none')
   local success = set_operator_state(key, {state='ack'})
   assert(not success)

   local key1 = alarm_keys:fetch('external-interface', 'arp-resolution')
   local key2 = alarm_keys:fetch('external-interface', 'arp-resolution')
   assert(key1 == key2)

   -- Compress alarms.
   local key = alarm_keys:fetch('external-interface', 'arp-resolution')
   local alarm = state.alarm_list.alarm[key]
   assert(alarm)
   assert(table_size(alarm.status_change) == 4)
   compress_alarms('external-interface')
   assert(table_size(alarm.status_change) == 1)

   -- Test toseconds.
   assert(toseconds({age_spec='weeks', value=1}) == 3600*24*7)
   assert(toseconds('1970-01-01T00:00:00Z') == 0)

   -- Purge alarms by status.
   assert(table_size(state.alarm_list.alarm) == 1)
   assert(purge_alarms({status = 'any'}) == 1)
   assert(table_size(state.alarm_list.alarm) == 0)
   assert(purge_alarms({status = 'any'}) == 0)

   -- Purge alarms filtering by older_than.
   local key = alarm_keys:fetch('external-interface', 'arp-resolution')
   raise_alarm(key)
   sleep(1)
   assert(purge_alarms({older_than={age_spec='seconds', value='1'}}) == 1)

   -- Purge alarms by severity.
   local key = alarm_keys:fetch('external-interface', 'arp-resolution')
   raise_alarm(key)
   assert(table_size(state.alarm_list.alarm) == 1)
   assert(purge_alarms({severity={sev_spec='is', value='minor'}}) == 0)
   assert(purge_alarms({severity={sev_spec='below', value='minor'}}) == 0)
   assert(purge_alarms({severity={sev_spec='above', value='minor'}}) == 1)

   raise_alarm(key, {perceived_severity='minor'})
   assert(purge_alarms({severity={sev_spec='is', value='minor'}}) == 1)

   raise_alarm(alarm_keys:fetch('external-interface', 'arp-resolution'))
   raise_alarm(alarm_keys:fetch('internal-interface', 'ndp-resolution'))
   assert(table_size(state.alarm_list.alarm) == 2)
   assert(purge_alarms({severity={sev_spec='above', value='minor'}}) == 2)

   -- Purge alarms by operator_state.
   local key = alarm_keys:fetch('external-interface', 'arp-resolution')
   raise_alarm(key)
   assert(table_size(state.alarm_list.alarm) == 1)
   local success, alarm = set_operator_state(key, {state='ack'})
   assert(success)
   assert(table_size(alarm.operator_state_change) == 1)
   assert(purge_alarms({operator_state={state='ack'}}) == 1)

   print("ok")
end
