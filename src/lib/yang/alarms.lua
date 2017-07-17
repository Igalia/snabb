module(..., package.seeall)

local S = require("syscall")

local config = {
   control = nil,
}

local state = {
   alarm_inventory = nil,
   summary = nil,
   alarm_list = nil,
   shelved_alarms = nil,
}

-- Static alarm_inventory list.
local alarm_inventory_table = {
   { alarm_type_id='arp-resolution', alarm_type_qualifier='', resource={'external-interface'}, has_clear=true, description=''},
   { alarm_type_id='ndp-resolution', alarm_type_qualifier='', resource={'internal-interface'}, has_clear=true, description=''},
}

-- Static alarm_list.
local alarm_list_table = {
   ['external-interface|arp-resolution|'] = {
      resource='external-interface',
      alarm_type_id='arp-resolution',
      alarm_type_qualifier='',
      perceived_severity='critical',
      alarm_text=[[
         Make sure you can resolved external-inteface.next-hop.ip from the lwAFTR.
         If cannot resolve it, consider using the MAC address of the next-hop
         directly.  To do it so, set external-interface.next-hop.mac to the
         value of the MAC address.
      ]]
   },
   ['internal-interface|ndp-resolution|'] = {
      resource='internal-interface',
      alarm_type_id='ndp-resolution',
      alarm_type_qualifier='',
      perceived_severity='critical',
      alarm_text=[[
         Make sure you can resolved internal-inteface.next-hop.ip from the lwAFTR.
         If cannot resolve it, consider using the MAC address of the next-hop
         directly.  To do it so, set internal-interface.next-hop.mac to the
         value of the MAC address.
      ]]
   },
}

local function add_row_to_alarm_inventory (alarm_inventory, row)
   if not alarm_inventory.alarm_type then alarm_inventory.alarm_type = {} end
   local alarm_type = alarm_inventory.alarm_type
   local key = {alarm_type_id=row.alarm_type_id,alarm_type_qualifier=row.alarm_type_qualifier}
   if not alarm_type[key] then
      local value = {
         alarm_type_id=row.alarm_type_id,
         alarm_type_qualifier=row.alarm_type_qualifier,
         resource=row.resource,
         has_clear=row.has_clear,
         description=row.description,
      }
      alarm_type[key] = value
   end
end

-- The alarms inventory is always initialized with a preset of alarm inventory
-- The reason is that it doesn't really matter is an user defines new alarm
-- types in a configuration.  The system will only rises a predefined set of
-- alarms.  For the same reason, there's an static list of alarms.
local function load_alarm_inventory (alarm_inventory, t)
   assert(alarm_inventory)
   for _, row in ipairs(t) do
      add_row_to_alarm_inventory(alarm_inventory, row)
   end
end

local function table_size (t)
   local ret = 0
   for _ in pairs(t) do ret = ret + 1 end
   return ret
end

local function init_alarm_inventory (alarms)
   alarms.alarm_inventory = {}
   state.alarm_inventory = alarms.alarm_inventory
   load_alarm_inventory(state.alarm_inventory, alarm_inventory_table)
end

local function set_if_empty (t, f, v)
   t[f] = t[f] or v
end

local function init_alarm_list (alarms)
   alarms.alarm_list = alarms.alarm_list or {}
   alarms.alarm_list.alarm = alarms.alarm_list.alarm or {}
   state.alarm_list = alarms.alarm_list
   set_if_empty(state.alarm_list, 'number_of_alarms', 0)
end

function init (current_configuration)
   local softwire_config = current_configuration.softwire_config
   local softwire_state = current_configuration.softwire_state
   config.control = softwire_config.alarms.control
   init_alarm_inventory(softwire_state.alarms)
   state.summary = softwire_state.alarms.summary
   init_alarm_list(softwire_state.alarms)
   state.shelved_alarms = softwire_state.alarms.shelved_alarms
end

local function pp(t, indent)
   indent = indent or ''
   for k,v in pairs(t) do
      if type(v) == 'table' then
         if type(k) == 'table' then
            local t = {}
            for _,v in pairs(k) do
               if #v > 0 then table.insert(t, v) end
            end
            k = table.concat(t, '|')
         end
         io.stdout:write(k..':\n')
         pp(v, indent..'  ')
      else
         if type(v) == 'boolean' then
            v = v and 'true' or 'false'
         elseif type(v) == 'nil' then
               v = 'nil'
         end
         print(indent..k..': '..v)
      end
   end
end

-- Helper function for debugging purposes.
local function show_alarm_inventory (alarm_inventory)
   local alarm_type = alarm_inventory.alarm_type or {}
   for k,v in pairs(alarm_inventory.alarm_type) do
      pp(v)
      print("--")
   end
end

-- Q: What's an alarm?
-- A: The data associated with an alarm is the data specified in the yang schema.

-- to be called by the leader.
function set_alarm (key, args)
   local id = unpack(args)
   print('set_alarm: '..id)
end

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

local function update_alarm (alarm, args)
   alarm.last_changed = args.time
   alarm.perceived_severity = args.perceived_severity
   alarm.alarm_text = args.alarm_text
   alarm.is_cleared = args.is_cleared
   state.alarm_list.last_changed = args.time
end

-- The entry with latest time-stamp in this list MUST correspond to the leafs
-- 'is-cleared', 'perceived-severity' and 'alarm-text' for the alarm.
-- The time-stamp for that entry MUST be equal to the 'last-changed' leaf.
local function create_status_change (alarm, args)
   local status = {
      time = args.time,
      perceived_severity = args.perceived_severity,
      alarm_text = args.alarm_text,
   }
   if not alarm.status_change then
      alarm.status_change = {}
   end
   table.insert(alarm.status_change, status)
   -- alarm.last_change must be equals to the most recent status change.
   alarm.last_changed = status.time
end

-- The following state changes creates an entry in this list:
--   - changed severity (warning, minor, major, critical)
--   - clearance status, this also updates the 'is-cleared' leaf
--   - alarm text update
local function create_status_change_if_needed (alarm, args)
   local new_status_change = false
   args.perceived_severity = args.perceived_severity or alarm.perceived_severity
   args.alarm_text = args.alarm_text or alarm.alarm_text
   new_status_change = alarm.is_cleared ~= args.is_cleared or
                       alarm.perceived_severity ~= args.perceived_severity or
                       alarm.alarm_text ~= args.alarm_text
   if new_status_change then
      args.time = iso_8601()
      create_status_change(alarm, args)
      update_alarm(alarm, args)
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
   local resource = assert(key.resource)
   local alarm_type_id = assert(key.alarm_type_id)
   local alarm_type_qualifier = key.alarm_type_qualifier or ''
   local str_key = table.concat({resource, alarm_type_id, alarm_type_qualifier}, '|')
   return alarm_list_table[str_key]
end

local function create_alarm (key, args)
   local alarm = assert(fetch_alarm_from_table(key), 'Not supported alarm')
   local ret = flat_copy(alarm, args)
   create_status_change(ret, {alarm.perceived_severity, alarm.alarm_text})
   ret.time_created = assert(ret.last_changed)
   ret.is_cleared = args.is_cleared
   ret.operator_state_change = {}
   state.alarm_list.number_of_alarms = state.alarm_list.number_of_alarms + 1
   return ret
end

local alarm_key = (function ()
   local cache = {}
   return function (resource, alarm_type_id, alarm_qualifier)
      resource = resource or ''
      alarm_type_id = alarm_type_id or ''
      alarm_qualifier = alarm_qualifier or ''
      if not cache[resource] then
         cache[resource] = {}
      end
      if not cache[resource][alarm_type_id] then
         cache[resource][alarm_type_id] = {}
      end
      local v = cache[resource][alarm_type_id][alarm_qualifier]
      if v then return v end
      v = {resource=resource, alarm_type_id=alarm_type_id, alarm_qualifier=alarm_qualifier}
      cache[resource][alarm_type_id][alarm_qualifier] = v
      return v
   end
end)()

local function create_or_update_alarm(key, args)
   assert(state.alarm_list.alarm)
   assert(key.resource and key.alarm_type_id and key.alarm_qualifier)
   assert(args and args.is_cleared ~= nil)
   local alarm = state.alarm_list.alarm[key]
   if not alarm then
      state.alarm_list.alarm[key] = create_alarm(key, args)
   else
      create_status_change_if_needed(alarm, args)
   end
end

-- to be called by the leader.
function raise_alarm (key, args)
   args = args or {}
   args.is_cleared = false
   create_or_update_alarm(key, args)
end

-- to be called by the leader.
function clear_alarm (key)
   create_or_update_alarm(key, {is_cleared=true})
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

local function alarm_key_matches(key1, resource, alarm_type_id, alarm_qualifier)
   if resource and resource ~= key1.resource then
      return false
   elseif alarm_type_id and alarm_type_id ~= key.alarm_type_id then
      return false
   elseif alarm_qualifier and alarm_qualifier ~= key.alarm_qualifier then
      return false
   end
   return true
end

-- to be called by the config leader.
--   This operation requests the server to compress entries in the
--   alarm list by removing all but the latest state change for all
--   alarms.  Conditions in the input are logically ANDed.  If no
--   input condition is given, all alarms are compressed.
function compress_alarms (resource, alarm_type_id, alarm_qualifier)
   local count = 0
   for k, v in pairs(state.alarm_list.alarm) do
      if alarm_key_matches(k, resource, alarm_type_id, alarm_qualifier) then
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
      print("alarm.time_created: "..alarm.time_created)
      local alarm_time = toseconds(alarm.time_created)
      print("args.oldern_than")
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
         return operator_states[value]
      end
      local state, user = args.operator_state.state, args.operator_state.user
      if state and tonumber(state) == tonumber(alarm.operator_state_state) then
         return true
      elseif user and user == alarm.operator_state.user then
         return true
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
   local conf = data.load_data_for_schema_by_name('snabb-softwire-v2', conf)
   assert(conf.softwire_config.alarms.control.notify_status_changes)

   -- Init.
   init(conf)
   assert(conf.softwire_config.alarms.control == config.control)
   assert(conf.softwire_state.alarms.alarm_inventory == state.alarm_inventory)
   assert(conf.softwire_state.alarms.summary == state.summary)
   assert(conf.softwire_state.alarms.alarm_list == state.alarm_list)
   assert(conf.softwire_state.alarms.shelved_alarms == state.shelved_alarms)

   -- Check alarm inventory has been loaded.
   assert(table_size(state.alarm_inventory.alarm_type) == 2)

   -- Check number of alarms is zero.
   assert(state.alarm_list.number_of_alarms == 0)

   -- Raising an alarm when alarms is empty, creates an alarm.
   local key = alarm_key('external-interface', 'arp-resolution')
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
   assert(table_size(alarm.status_change) == number_of_status_change)
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
   local key = alarm_key('none', 'none')
   local success = set_operator_state(key, {state='ack'})
   assert(not success)

   -- Compress alarms.
   local key = alarm_key('external-interface', 'arp-resolution')
   local alarm = state.alarm_list.alarm[key]
   assert(table_size(alarm.status_change) == 4)
   compress_alarms('external-interface')
   assert(table_size(alarm.status_change) == 1)

   -- Test toseconds.
   assert(toseconds({age_spec='weeks', value=1}) == 3600*24*7)
   assert(toseconds('1970-01-01T00:00:00Z') == 0)

   -- Test purge alarms.
   assert(table_size(state.alarm_list.alarm) == 1)
   assert(purge_alarms({status = 'any'}) == 1)
   assert(table_size(state.alarm_list.alarm) == 0)
   assert(purge_alarms({status = 'any'}) == 0)

   local key = alarm_key('external-interface', 'arp-resolution')
   raise_alarm(key)
   assert(table_size(state.alarm_list.alarm) == 1)
   -- Perceived severity of {external-interface, arp-resolution} is 'critical'.
   assert(purge_alarms({severity={sev_spec='is', value='minor'}}) == 0)
   assert(purge_alarms({severity={sev_spec='below', value='minor'}}) == 0)
   assert(purge_alarms({severity={sev_spec='above', value='minor'}}) == 1)

   raise_alarm(key, {perceived_severity='minor'})
   assert(purge_alarms({severity={sev_spec='is', value='minor'}}) == 1)

   raise_alarm(alarm_key('external-interface', 'arp-resolution'))
   raise_alarm(alarm_key('internal-interface', 'ndp-resolution'))
   assert(table_size(state.alarm_list.alarm) == 2)
   assert(purge_alarms({severity={sev_spec='above', value='minor'}}) == 2)

   raise_alarm(key)
   sleep(1)
   print(purge_alarms({older_than={age_spec='seconds', value='1'}}))

   print("ok")
end
