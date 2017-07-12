module(..., package.seeall)

local S = require("syscall")

local function set (t)
   local ret = {}
   for _, k in ipairs(t) do ret[k] = true end
   return ret
end

local config = {
   control = nil,
} 

local state = {
   alarm_inventory = nil,
   summary = nil,
   alarm_list = nil,
   shelved_alarms = nil,
}

function init (current_configuration)
   local softwire_config = current_configuration.softwire_config
   local softwire_state = current_configuration.softwire_state
   config.control = softwire_config.alarms.control
   state.alarm_inventory = softwire_state.alarms.alarm_inventory
   state.summary = softwire_state.alarms.summary
   state.alarm_list = softwire_state.alarms.alarm_list
   state.shelved_alarms = softwire_state.alarms.shelved_alarms
end

-- Statically create alarm_inventory and alarm_list.
local alarm_inventory = {

}

-- Summary should be read-only.

-- Shelved-alarms

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

-- to be called by the leader.
function set_alarm (key, args)
   -- alarms.list[key] = key
   config.control.notify_status_changes = false
   print('set_alarm')
   for k, v in pairs(args) do
      print(k, v)
   end
   --[[
   local alarm = Alarm.new(key, params)
   table.insert(alarms.list, alarm)
   --]]
end

-- to be called by the leader.
function clear_alarm (key, args)
   print('clear_alarm')
   for k, v in pairs(args) do
      print(k, v)
   end
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

--[[
function selftest ()
   local key = {
      resource = 'resource1',
      alarm_type_id = 'alarm_type1',
      alarm_type_qualifier = 'alarm_type_qualifier1',
   }
   set_alarm(key)
   assert(get_alarm(key))
end
--]]

function selftest ()
   -- Reads lwaftr.conf file.
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

         }
      }
   ]]
   local conf = data.load_data_for_schema_by_name('snabb-softwire-v2', conf)
   assert(conf.softwire_config.alarms.control.notify_status_changes)

   -- Do stuff with the alarm related containers.
end 

