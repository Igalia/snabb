module(..., package.seeall)

local CSVStatsTimer = require("lib.csv_stats").CSVStatsTimer
local ethernet      = require("lib.protocol.ethernet")
local Tap           = require("apps.tap.tap").Tap
local RawSocket     = require("apps.socket.raw").RawSocket
local setup         = require("program.lwaftr.setup")
local lib           = require("core.lib")
local S             = require("syscall")

local function check(flag, fmt, ...)
   if not flag then
      io.stderr:write(fmt:format(...), "\n")
      main.exit(1)
   end
end

local function file_exists(path)
   local stat = S.stat(path)
   return stat and stat.isreg
end

local function parse_args(args)
   local device_kind_map = {
      tap = { app = Tap, tx = "output", rx = "input" };
      raw = { app = RawSocket, tx = "tx", rx = "rx" };
   }
   local verbosity, debug = 0, false
   local bt_file, conf_file, b4_if, b4_if_kind, inet_if, inet_if_kind
   local handlers = {
      v = function ()
         verbosity = verbosity + 1
      end;
      c = function (arg)
         check(arg, "argument to '--conf' not specified")
         check(file_exists(arg), "no such file '%s'", arg)
         conf_file = arg
      end;
      b = function (arg)
         check(arg, "argument to '--bt' not specified")
         check(file_exists(arg), "no such file '%s'", arg)
         bt_file = arg
      end;
      B = function (arg)
         check(arg, "argument to '--b4-if' not specified")
         b4_if_kind, b4_if = arg:match("^([a-z]+):([^%s]+)$")
         check(b4_if,
               "invalid/missing device name in '%s'", arg)
         check(b4_if_kind and device_kind_map[b4_if_kind],
               "invalid/missing device kind in '%s'", arg)
         b4_if_kind = device_kind_map[b4_if_kind]
      end;
      I = function (arg)
         check(arg, "argument to '--inet-if' not specified")
         inet_if_kind, inet_if = arg:match("^([a-z]+):([^%s]+)$")
         check(inet_if,
               "invalid/missing device name in '%s'", arg)
         check(inet_if_kind and device_kind_map[inet_if_kind],
               "invalid/missing device kind in '%s'", arg)
         inet_if_kind = device_kind_map[inet_if_kind]
      end;
      D = function ()
         debug = true
      end;
      h = function (arg)
         print(require("program.lwaftr.run_nohw.README_inc"))
         main.exit(0)
      end;
   }
   lib.dogetopt(args, handlers, "b:c:B:I:vDh", {
      help = "h", conf = "c", verbose = "v", debug = "D", bt = "b",
      ["b4-if"] = "B", ["inet-if"] = "I",
   })
   check(conf_file, "no configuration specified (--conf/-c)")
   check(b4_if, "no B4-side interface specified (--b4-if/-B)")
   check(inet_if, "no Internet-side interface specified (--inet-if/-I)")
   return verbosity, bt_file, conf_file, b4_if, b4_if_kind, inet_if, inet_if_kind, debug
end


function run(parameters)
   local verbosity, bt_file, conf_file, b4_if, b4_if_kind, inet_if, inet_if_kind, debug = parse_args(parameters)
   local conf = require("apps.lwaftr.conf").load_lwaftr_config(conf_file)
   conf.debug = debug

   local c = config.new()
   setup.lwaftr_app(c, conf)
   config.app(c, "b4if", b4_if_kind.app, b4_if)
   config.app(c, "inet", inet_if_kind.app, inet_if)
   setup.link_source(c, "b4if." .. b4_if_kind.tx, "inet." .. inet_if_kind.tx)
   setup.link_sink  (c, "b4if." .. b4_if_kind.rx, "inet." .. inet_if_kind.rx)
   engine.configure(c)

   if verbosity >= 2 then
      local function lnicui_info()
         app.report_apps()
      end
      timer.activate(timer.new("report", lnicui_info, 1e9, "repeating"))
   end

   if verbosity >= 1 then
      local csv = CSVStatsTimer.new()
      csv:add_app("inet", { inet_if_kind.tx, inet_if_kind.rx }, {
         [inet_if_kind.tx] = "IPv4 TX",
         [inet_if_kind.rx] = "IPv4 RX"
      })
      csv:add_app("b4if", { b4_if_kind.tx, b4_if_kind.rx }, {
         [b4_if_kind.tx] = "IPv6 TX",
         [b4_if_kind.rx] = "IPv6 RX"
      })
      csv:activate()
   end

   engine.main {
      report = {
         showlinks = true;
      }
   }
end
