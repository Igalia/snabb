module(..., package.seeall)

local data = require('lib.yang.data')
local util = require('lib.yang.util')

local state = {
   alarm_inventory = {},
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

local function load_default_configuration (filename)
   filename = filename or "lib/yang/lwaftr-default-alarms.conf"
   local content = util.readfile(filename)
   local conf = assert(data.load_data_for_schema_by_name('ietf-alarms', content))
   return conf.alarms
end

function init ()
   local default = load_default_configuration()
   state.alarm_inventory = default.alarm_inventory
end

---

function raise_alarm (key, args)
   print('raise_alarm')
   assert(type(key) == 'table')
   assert(type(args) == 'table')
end

function clear_alarm (key)
   print('clear alarm')
   assert(type(key) == 'table')
end

---

function selftest ()
   print("selftest: alarms")
   local function table_size (t)
      local size = 0
      for _ in pairs(t) do size = size + 1 end
      return size
   end

   init()
   assert(table_size(state.alarm_inventory.alarm_type) > 0)

   print("ok")
end
