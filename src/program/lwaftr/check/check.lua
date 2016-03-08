module(..., package.seeall)

local app = require("core.app")
local config = require("core.config")
local lib = require("core.lib")
local log = require("apps.lwaftr.log")
local setup = require("program.lwaftr.setup")

function show_usage(code)
   print(require("program.lwaftr.check.README_inc"))
   main.exit(code)
end

function parse_args(args)
   local handlers = {}
   handlers["log-level"] = function (arg)
      if not arg then
         log.fatal("No parameter passed to '--log-level'")
         main.exit(1)
      end
      if not log[arg] then
         log.fatal("Invalid log level '${}'", arg)
         main.exit(1)
      end
      log.level = arg
   end
   function handlers.h() show_usage(0) end
   args = lib.dogetopt(args, handlers, "h", { help="h", ["log-level"] = 1 })
   if #args ~= 5 then show_usage(1) end
   return unpack(args)
end

function run(args)
   local conf_file, inv4_pcap, inv6_pcap, outv4_pcap, outv6_pcap =
      parse_args(args)

   local conf = require('apps.lwaftr.conf').load_lwaftr_config(conf_file)

   local c = config.new()
   setup.load_check(c, conf, inv4_pcap, inv6_pcap, outv4_pcap, outv6_pcap)
   app.configure(c)
   app.main({duration=0.10})
   print("done")
end
