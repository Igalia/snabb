-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(..., package.seeall)

local lib = require("core.lib")
local shm = require("core.shm")
local yang = require("lib.yang.yang")
local yang_data = require("lib.yang.data")

local counter_directory = "/apps"

local function flatten(val)
   local rtn = {}
   for k, v in pairs(val) do
      if type(v) == "table" then
         v = flatten(v)
         for k1, v1 in pairs(v) do rtn[k1] = v1 end
      else
         rtn[k] = v
      end
   end
   return rtn
end

local function find_counters(pid)
   local path = shm.root.."/"..pid..counter_directory
   local apps = {}
   for _, c in pairs(lib.files_in_directory(path)) do
      local counters = {}
      local counterdir = "/"..pid..counter_directory.."/"..c
      for k,v in pairs(shm.open_frame(counterdir)) do
         if type(v) == "cdata" then
            counters[k] = v.c
         end
      end
      apps[c] = counters
   end
   return apps
end

local function collect_state_leaves(schema)
   -- Iterate over schema looking fo state leaves at a specific path into the
   -- schema. This should return a dictionary of leaf to lua path.
   local function collection(scm, path)
      local function newpath(oldpath)
         return lib.deepcopy(oldpath)
      end
      if path == nil then path = {} end
      table.insert(path, scm.id)

      if scm.kind == "container" then
         -- Iterate over the body and recursively call self on all children.
         local rtn = {}
         for _, child in pairs(scm.body) do
            local leaves = collection(child, newpath(path))
            table.insert(rtn, leaves)
         end
         return rtn
      elseif scm.kind == "leaf" then
         if scm.config == false then
            local rtn = {}
            rtn[path] = scm.id
            return rtn
         end
      elseif scm.kind == "module" then
         local rtn = {}
         for _, v in pairs(scm.body) do
            -- We deliberately don't want to include the module in the path.
            table.insert(rtn, collection(v, {}))
         end
         return rtn
      end
      return {}
   end

   local leaves = collection(schema)
   if leaves == nil then return {} end
   leaves = flatten(leaves)
   return function () return leaves end
end

local function set_data_value(data, path, value)
   local head = yang_data.normalize_id(table.remove(path, 1))
   if #path == 0 then
      data[head] = value
      return
   end
   if data[head] == nil then data[head] = {} end
   set_data_value(data[head], path, value)
end

function show_state(scm, pid)
   local schema = yang.load_schema_by_name(scm)
   local counters = find_counters(pid)

   local data = {}

   -- Lookup the specific schema element that's being addressed by the path
   --[[
   local leaves = collect_state_leaves(schema)()
   local data = {}
   for leaf_path, leaf in pairs(leaves) do
      for _, counter in pairs(counters) do
         if counter[leaf] then
            set_data_value(data, leaf_path, counter[leaf])
         end
      end
   end
   --]]


   --[[
   local leaves = collect_alarm_leaves('softwire-state/alarms')
   for path, value in pairs(leaves) do
      set_data_value(data, path, value)
   end
   --]]

   set_data_value(data, {'softwire-state', 'alarms', 'test', 'test' }, 'hello')

   return data
end

local alarms = require('lib.yang.alarms')

local function collect_alarm_leaves (t, path)
   path = path or ''
   local visit
   local leaves = {}
   local function visit_leaf (v, path)
      leaves[path] = v
   end
   local function is_hash (t)
      if type(t) == 'table' then
         for k,_ in pairs(t) do
            if not tonumber(k) then return true end
         end
      end
   end
   local function is_array (t)
      if type(t) == 'table' then
         for k, v in ipairs(t) do return true end
      end
   end
   local function flat_key (key)
      local ret = {}
      for k, v in pairs(key) do
         table.insert(ret, '['..k..'='..v..']')
      end
      return table.concat(ret)
   end
   local function visit_array (t, path)
      for i, v in ipairs(t) do
         if type(v) == 'table' then
            visit(v, path..'[position()='..i..']')
         else
            visit_leaf(v, path..'[position()='..i..']')
         end
      end
   end
   visit = function (t, path)
      path = path or ''
      for k, v in pairs(t) do
         if is_array(v) then
            visit_array(v, path..'/'..k)
         elseif type(v) == 'table' then
            if is_hash(k) then
               visit(v, path..flat_key(k))
            else
               visit(v, path..'/'..k)
            end
         else
            if is_hash(k) then
               visit_leaf(v, path..flat_key(k))
            else
               visit_leaf(v, path..'/'..k)
            end
         end
      end
   end
   visit(t, path)
   return leaves
end

function selftest ()
   print("selftest: lib.yang.state")
   local simple_router_schema_src = [[module snabb-simple-router {
      namespace snabb:simple-router;
      prefix simple-router;

      import ietf-inet-types {prefix inet;}

      leaf active { type boolean; default true; }
      leaf-list blocked-ips { type inet:ipv4-address; }

      container routes {
         list route {
            key addr;
            leaf addr { type inet:ipv4-address; mandatory true; }
            leaf port { type uint8 { range 0..11; } mandatory true; }
         }
      }

      container state {
         config false;

         leaf total-packets {
            type uint64 {
               default 0;
            }
         }

         leaf dropped-packets {
            type uint64 {
               default 0;
            }
         }
      }

      grouping detailed-counters {
         leaf dropped-wrong-route {
            type uint64 { default 0; }
         }
         leaf dropped-not-permitted {
            type uint64 { default 0; }
         }
      }

      container detailed-state {
         config false;
         uses "detailed-counters";
      }
   }]]
   local function table_length(tbl)
      local rtn = 0
      for k,v in pairs(tbl) do rtn = rtn + 1 end
      return rtn
   end
   local function in_array(needle, haystack)
      for _, i in pairs(haystack) do if needle == i then return true end end
      return false
   end

   local simple_router_schema = yang.load_schema(simple_router_schema_src,
      "state-test")
   local leaves = collect_state_leaves(simple_router_schema)()

   -- Check the correct number of leaves have been found
   assert(table_length(leaves) == 4)

   -- Check it's found every state path.
   local state_leaves = {
      "total-packets",
      "dropped-packets",
      "dropped-wrong-route",
      "dropped-not-permitted"
   }
   for _, leaf in pairs(leaves) do
      assert(in_array(leaf, state_leaves))
   end

   -- Check flatten produces a single dimentional table with all the elements.
   local multi_dimentional = {{hello="hello"}, {world="world"}}
   assert(flatten(multi_dimentional), {hello="hello", world="world"})

   -- Test alarms collection.
   local state = {
      alarm_list = {
         number_of_alarms = 2,
      },
      resources = {'resource1', 'resource2','resource3'},
      alarm_types = {},
   }
   local key1 = {alarm_type_id='id1', alarm_type_qualifier='qa1'}
   state.alarm_types[key1] = 'hi'

   local leaves = collect_alarm_leaves(state, 'softwire-state/alarms')
   assert(leaves['softwire-state/alarms/alarm_list/number_of_alarms'] == 2)
   assert(leaves['softwire-state/alarms/resources[position()=2]'] == 'resource2')
   assert(leaves['softwire-state/alarms/alarm_types[alarm_type_qualifier=qa1][alarm_type_id=id1]'] == 'hi')

   print("selftest: ok")
end
