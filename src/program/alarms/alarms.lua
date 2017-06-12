-- TODO: This is a mock alarms program. It simply loads a alarms configuration
-- instance as a leader process. On running it prints out its PID on stdout.
-- Later a "snabb config" program should be able to query this instance by PID.

module(..., package.seeall)

local Follower = require('apps.config.follower').Follower
local Leader = require('apps.config.leader').Leader
local S = require('syscall')
local basic_apps = require('apps.basic.basic_apps')
local yang = require('lib.yang.yang')

local function mktemp (mode)
   if not mode then mode = '0664' end
   local tmpname = "/tmp/tmp."..os.time()..".txt"
   local fd, err = S.open(tmpname, "creat, wronly, excl", mode)
   if not fd then error(err) end
   fd:close()
   return tmpname
end

local function load_alarms_config (filename)
   return yang.load_configuration(filename, {schema_name='ietf-alarms'})
end

local function load_alarms_config_raw (text)
   local filename = mktemp()
   local fd, err = io.open(filename, "w+")
   if not fd then error(err) end
   fd:write(text)
   fd:close()
   return load_alarms_config(filename)
end

function run (args)
   local function setup_fn()
      local c = config.new()
      config.app(c, "source", basic_apps.Source, {})
      config.app(c, "sink", basic_apps.Sink, {})
      config.link(c, "source.foo -> sink.bar")
      return c
   end

   local alarms_conf = load_alarms_config_raw([[
      alarms {
         control {
            max-alarm-status-changes 16;
            notify-status-changes true;
         }
      }
   ]])

   local c = config.new()
   config.app(c, "leader", Leader,
                 {setup_fn=setup_fn, follower_pids = { S.getpid() },
                  schema_name='ietf-alarms', initial_configuration = alarms_conf})
   config.app(c, "follower", Follower , {})

   local pid = S.getpid()
   print("PID:\t"..pid)
   print(("query:\tsudo ./snabb config get %s /alarms"):format(pid))

   engine.configure(c)
   engine.main()
end
