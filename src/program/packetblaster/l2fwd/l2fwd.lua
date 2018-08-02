-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)

local PcapReader = require("apps.pcap.pcap").PcapReader
local basic_apps = require("apps.basic.basic_apps")
local lib        = require("core.lib")
local packetblaster = require("program.packetblaster.packetblaster")

local long_opts = {
   duration     = "D",
   help         = "h",
}

local function show_usage (code)
   print(require("program.packetblaster.l2fwd.README_inc"))
   main.exit(code)
end

function run (args)
   local c = config.new()
   local handlers = {}
   local opts = {}
   function handlers.D (arg)
      opts.duration = assert(tonumber(arg), "duration is not a number!")
   end
   function handlers.h ()
      show_usage(0)
   end
   args = lib.dogetopt(args, handlers, "hD:", long_opts)
   if #args < 2 then show_usage(1) end
   if opts.duration == 0 then return end
   if not opts.duration then opts.duration = 1 end
   local filename = table.remove(args, 1)

   config.app(c, "pcap", PcapReader, filename)
   config.app(c, "source", basic_apps.Tee)
   config.app(c, "loop", basic_apps.Repeater)

   config.link(c, "pcap.output -> loop.input")
   config.link(c, "loop.output -> source.input")

   packetblaster.run_l2fwd(c, args, opts)
end
