module(..., package.seeall)

local util = require("lib.yang.util")

local csv_to_table = util.csv_to_table
local iso_8601 = util.iso_8601

local state = {
   alarm_inventory = {},
   alarm_list = {
      alarm = {},
      number_of_alarms = 0,
   },
}

function get_state ()
   return {
      alarm_inventory = state.alarm_inventory,
   }
end

-- Single point to access alarm type keys.
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

function load_alarm_type (filename)
   filename = filename or 'lib/yang/alarm_type.csv'
   local ret = {}
   for _, row in ipairs(csv_to_table(filename, {sep='|'})) do
      local key = alarm_type_keys:fetch(row.alarm_type_id, row.alarm_type_qualifier)
      ret[key] = row
   end
   return ret
end

state.alarm_inventory.alarm_type = load_alarm_type()

-- Single point to access alarm keys.
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

-- Keeps a list indexed by alarm key of predefined alarms.
local alarm_db

local function load_alarm_db (filename)
   filename = filename or 'lib/yang/alarm_list.csv'
   local ret = {}
   for _, row in ipairs(csv_to_table(filename, {sep='|'})) do
      local key_str = alarm_keys:normalize(row)
      ret[key_str] = row
   end
   return ret
end

local function retrieve_alarm_from_db (key, args)
   local function lookup (key)
      alarm_db = alarm_db or load_alarm_db()
      return alarm_db[key]
   end
   local function copy (src, args)
      local ret = {}
      for k,v in pairs(src) do ret[k] = args[k] or v end
      return ret
   end
   local alarm = lookup(key)
   if alarm then
      return copy(alarm, args or {})
   end
end

-- The entry with latest time-stamp in this list MUST correspond to the leafs
-- 'is-cleared', 'perceived-severity' and 'alarm-text' for the alarm.
-- The time-stamp for that entry MUST be equal to the 'last-changed' leaf.
local function add_status_change (alarm, status)
   alarm.status_change = alarm.status_change or {}
   alarm.perceived_severity = status.perceived_severity
   alarm.alarm_text = status.alarm_text
   alarm.last_changed = status.time
   state.alarm_list.last_changed = status.time
   table.insert(alarm.status_change, status)
end

-- Creates a new alarm.
--
-- The alarm is retrieved from the db of predefined alarms. Default values got
-- overridden by args. Additional fields are initialized too and an initial
-- status change is added to the alarm.
local function create_alarm (key, args)
   local ret = assert(retrieve_alarm_from_db(key, args), 'Not supported alarm')
   local status = {
      time = iso_8601(),
      perceived_severity = args.perceived_severity or ret.perceived_severity,
      alarm_text = args.alarm_text or ret.alarm_text,
   }
   add_status_change(ret, status)
   ret.last_changed = assert(status.time)
   ret.time_created = assert(ret.last_changed)
   ret.is_cleared = args.is_cleared
   ret.operator_state_change = {}
   state.alarm_list.number_of_alarms = state.alarm_list.number_of_alarms + 1
   return ret
end

-- Adds alarm to state.alarm_list.
local function add_alarm (key, args)
   local alarm = assert(create_alarm(key, args))
   state.alarm_list.alarm[key] = alarm
end

-- The following state changes creates a new status change:
--   - changed severity (warning, minor, major, critical).
--   - clearance status, this also updates the 'is-cleared' leaf.
--   - alarm text update.
local function needs_status_change (alarm, args)
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

-- An alarm gets updated if it needs a status change.  A status change implies
-- to add a new status change to the alarm and update the alarm 'is_cleared'
-- flag.
local function update_alarm (alarm, args)
   if needs_status_change(alarm, args) then
      local status = {
         time = assert(iso_8601()),
         perceived_severity = assert(args.perceived_severity or alarm.perceived_severity),
         alarm_text = assert(args.alarm_text or alarm.alarm_text),
      }
      add_status_change(alarm, status)
      alarm.is_cleared = args.is_cleared
   end
end

-- Check up if the alarm already exists in state.alarm_list.
local function lookup_alarm (key)
   return state.alarm_list.alarm[key]
end

function raise_alarm (key, args)
   assert(key)
   args = args or {}
   args.is_cleared = false
   key = alarm_keys:normalize(key)
   local alarm = lookup_alarm(key)
   if not alarm then
      add_alarm(key, args)
   else
      update_alarm(alarm, args)
   end
end

function clear_alarm (key, args)
   assert(key)
   args = args or {}
   args.is_cleared = true
   key = alarm_keys:normalize(key)
   local alarm = lookup_alarm(key)
   if not alarm then
      add_alarm(key, args)
   else
      update_alarm(alarm, args)
   end
end

function selftest ()
   print("selftest: alarms")
   local function table_size (t)
      local size = 0
      for _ in pairs(t) do size = size + 1 end
      return size
   end
   local function sleep (seconds)
      os.execute("sleep "..tonumber(seconds))
   end
   local function check_status_change (alarm)
      local status_change = alarm.status_change
      for k, v in pairs(status_change) do
         assert(v.perceived_severity)
         assert(v.time)
         assert(v.alarm_text)
      end
   end

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
   assert(alarm.perceived_severity == 'minor')
   assert(last_changed ~= alarm.last_changed)
   assert(table_size(alarm.status_change) == number_of_status_change + 1)
   check_status_change(alarm)

   -- Raise alarm again with same severity. Should not produce changes.
   local alarm = state.alarm_list.alarm[key]
   local last_changed = alarm.last_changed
   local number_of_status_change = table_size(alarm.status_change)
   raise_alarm(key, {perceived_severity='minor'})
   assert(alarm.perceived_severity == 'minor')
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

   print("ok")
end
