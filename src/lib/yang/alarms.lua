module(..., package.seeall)

local util = require("lib.yang.util")

local csv_to_table = util.csv_to_table

local state = {
   alarm_inventory = {},
}

function get_state ()
   return {
      alarm_inventory = state.alarm_inventory,
   }
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

function selftest ()
   print("selftest: alarms")
   local function table_size (t)
      local size = 0
      for _ in pairs(t) do size = size + 1 end
      return size
   end
   local state = {
      alarm_inventory = {
         alarm_type = load_alarm_type(),
      }
   }
   assert(table_size(state.alarm_inventory.alarm_type) == 2)
   print("ok")
end
