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
local function load_alarm_inventory (alarms, t)
   alarms.alarm_inventory = {}
   local alarm_inventory = alarms.alarm_inventory
   for _, row in ipairs(t) do
      add_row_to_alarm_inventory(alarm_inventory, row)
   end
end

local function table_size (t)
   local ret = 0
   for _ in pairs(t) do ret = ret + 1 end
   return ret
end

local function init_alarm_inventory (alarm_inventory)
   state.alarm_inventory = alarm_inventory
   load_alarm_inventory(state.alarm_inventory, alarm_inventory_table)
end

function init (current_configuration)
   local softwire_config = current_configuration.softwire_config
   local softwire_state = current_configuration.softwire_state
   config.control = softwire_config.alarms.control
   init_alarm_inventory(softwire_state.alarms.alarm_inventory)
   state.summary = softwire_state.alarms.summary
   state.alarm_list = softwire_state.alarms.alarm_list
   state.shelved_alarms = softwire_state.alarms.shelved_alarms
end

-- Helper function for debugging purposes.
local function show_alarm_inventory (alarm_inventory)
   local function pp(t)
      for k,v in pairs(t) do
         if type(v) == 'table' then
            io.stdout:write(k..':\n  ')
            pp(v)
         else
            if type(v) == 'boolean' then 
               v = v and 'true' or 'false'
               elseif type(v) == 'nil' then
                  v = 'nil'
               end
               print(k..': '..v)
            end
         end
      end
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
   print('set_alarm')
end

-- to be called by the leader.
function clear_alarm (key, args)
   print('clear_alarm')
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

   -- Test load alarm inventory.
   local alarms = conf.softwire_state.alarms
   load_alarm_inventory(alarms, alarm_inventory_table)
   assert(table_size(alarms.alarm_inventory.alarm_type) == 2)
end
