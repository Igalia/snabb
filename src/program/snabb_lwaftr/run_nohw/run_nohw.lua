module(..., package.seeall)

local CSVStatsTimer = require("lib.csv_stats").CSVStatsTimer
local ethernet = require("lib.protocol.ethernet")
local Tap = require("program.snabb_lwaftr.run_nohw.tap").Tap
local RawSocket = require("apps.socket.raw").RawSocket
local LwAftr = require("apps.lwaftr.lwaftr").LwAftr
local conf = require("apps.lwaftr.conf")
local bt = require("apps.lwaftr.binding_table")
local lib = require("core.lib")
local S = require("syscall")

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
   local verbosity = 0
   local bt_file, conf_file, b4_if, b4_if_kind, inet_if, inet_if_kind
   local handlers = {
      v = function ()
         verbosity = verbosity + 1
      end;
      b = function (arg)
         check(arg, "argument to '--bt' not specified")
         check(file_exists(arg), "no such file '%s'", arg)
         bt_file = arg
      end;
      c = function (arg)
         check(arg, "argument to '--conf' not specified")
         check(file_exists(arg), "no such file '%s'", arg)
         conf_file = arg
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
      h = function (arg)
		print(require("program.snabb_lwaftr.run_nohw.README_inc"))
		main.exit(0)
	  end;
   }
   lib.dogetopt(args, handlers, "b:c:B:I:vh", {
      help = "h", bt = "b", conf = "c", verbose = "v",
      ["b4-if"] = "B", ["inet-if"] = "I",
   })
   check(bt_file, "no binding table specified (--bt/-b)")
   check(conf_file, "no configuration specified (--conf/-c)")
   check(b4_if, "no B4-side interface specified (--b4-if/-B)")
   check(inet_if, "no Internet-side interface specified (--inet-if/-I)")
   return verbosity, bt_file, conf_file, b4_if, b4_if_kind, inet_if, inet_if_kind
end


function run(parameters)
   local verbosity, bt_file, conf_file, b4_if, b4_if_kind, inet_if, inet_if_kind = parse_args(parameters)
   local c = config.new()

   -- AFTR
   bt.get_binding_table(bt_file)
   local aftrconf = conf.get_aftrconf(conf_file)
   aftrconf.bt_file = bt_file
   config.app(c, "aftr", LwAftr, aftrconf)

   -- B4 side interface
   config.app(c, "b4if", b4_if_kind.app, b4_if)

   -- Internet interface
   config.app(c, "inet", inet_if_kind.app, inet_if)

   -- Connect apps
   config.link(c, "inet." .. inet_if_kind.tx .. " -> aftr.v4")
   config.link(c, "b4if." .. b4_if_kind.tx .. " -> aftr.v6")
   config.link(c, "aftr.v4 -> inet." .. inet_if_kind.rx)
   config.link(c, "aftr.v6 -> b4if." .. b4_if_kind.rx)

   if verbosity >= 1 then
      local csv = CSVStatsTimer.new()
      csv:add_app("inet", {"tx", "rx"}, {
         [inet_if_kind.tx] = "IPv4 TX",
         [inet_if_kind.rx] = "IPv4 RX"
      })
      csv:add_app("b4if", {"tx", "rx"}, {
         [b4_if_kind.tx] = "IPv6 TX",
         [b4_if_kind.rx] = "IPv6 RX"
      })
      csv:activate()

      if verbosity >= 2 then
         timer.activate(timer.new("report", function ()
            app.report_apps()
         end, 1e9, "repeating"))
      end
   end

   engine.configure(c)
   engine.main {
      report = {
         showlinks = true;
      }
   }
end
