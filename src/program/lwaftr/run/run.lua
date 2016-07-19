module(..., package.seeall)

local S          = require("syscall")
local config     = require("core.config")
local csv_stats  = require("program.lwaftr.csv_stats")
local lib        = require("core.lib")
local numa       = require("lib.numa")
local setup      = require("program.lwaftr.setup")

local function show_usage(exit_code)
   print(require("program.lwaftr.run.README_inc"))
   if exit_code then main.exit(exit_code) end
end

local function fatal(msg)
   show_usage()
   print('error: '..msg)
   main.exit(1)
end

local function file_exists(path)
   local stat = S.stat(path)
   return stat and stat.isreg
end

function parse_args(args)
   if #args == 0 then show_usage(1) end
   local conf_file, v4, v6
   local ring_buffer_size, virtio_net
   local opts = { verbosity = 0 }
   local handlers = {}
   local cpu
   function handlers.v () opts.verbosity = opts.verbosity + 1 end

   function handlers.i ()
      io.stderr:write("Parameter '--virtio' is deprecated: ",
         "use '--v4 virtio:<pci-addr>' and '--v6 virtio:<pci-addr>' instead.\n")
      virtio_net = true
   end

   function handlers.D (arg)
      opts.duration = assert(tonumber(arg), "duration must be a number")
   end
   function handlers.c(arg)
      conf_file = arg
      if not arg then
         fatal("Argument '--conf' was not set")
      end
      if not file_exists(conf_file) then
         fatal(("Couldn't locate configuration file at %s"):format(conf_file))
      end
   end
   function handlers.cpu(arg)
      cpu = tonumber(arg)
      if not cpu or cpu ~= math.floor(cpu) or cpu < 0 then
         fatal("Invalid cpu number: "..arg)
      end
   end
   handlers['real-time'] = function(arg)
      if not S.sched_setscheduler(0, "fifo", 1) then
         fatal('Failed to enable real-time scheduling.  Try running as root.')
      end
   end
   function handlers.v4 (arg)
      if not arg then fatal("Argument '--v4' was not set") end
      v4 = arg
   end
   handlers["v4-pci"] = function(arg)
      print("WARNING: Deprecated argument '--v4-pci'. Use '--v4' instead.")
      handlers.v4(arg)
   end
   function handlers.v6 (arg)
      if not arg then fatal("Argument '--v6' was not set") end
      v6 = arg
   end
   handlers["v6-pci"] = function(arg)
      print("WARNING: Deprecated argument '--v6-pci'. Use '--v6' instead.")
      handlers.v6(arg)
   end
   function handlers.r (arg)
      ring_buffer_size = tonumber(arg)
      if not ring_buffer_size then fatal("bad ring size: " .. arg) end
      if ring_buffer_size > 32*1024 then
         fatal("ring size too large for hardware: " .. ring_buffer_size)
      end
      if math.log(ring_buffer_size)/math.log(2) % 1 ~= 0 then
         fatal("ring size is not a power of two: " .. arg)
      end
   end
   function handlers.h() show_usage(0) end
   lib.dogetopt(args, handlers, "b:c:vD:hir:",
      { conf = "c", v4 = 1, v6 = 1, ["v4-pci"] = 1, ["v6-pci"] = 1,
        verbose = "v", duration = "D", help = "h",
        virtio = "i", ["ring-buffer-size"] = "r", cpu = 1,
        ["real-time"] = 0 })
   if ring_buffer_size ~= nil then
      if virtio_net then
         fatal("setting --ring-buffer-size does not work with --virtio")
      end
      -- TODO: Only do this when one of the chosen devices is intel10g
      require('apps.intel.intel10g').num_descriptors = ring_buffer_size
   end
   if not conf_file then fatal("Missing required --conf argument.") end
   if not v4 then fatal("Missing required --v4 argument.") end
   if not v6 then fatal("Missing required --v6 argument.") end
   if cpu then numa.bind_to_cpu(cpu) end
   numa.check_affinity_for_pci_addresses({ v4, v6 })
   if virtio_net then
      v4, v6 = "virtio:" .. v4, "virtio:" .. v6
   end
   return opts, conf_file, v4, v6
end

function run(args)
   local opts, conf_file, v4, v6 = parse_args(args)
   local conf = require('apps.lwaftr.conf').load_lwaftr_config(conf_file)

   local c, err = setup.load_gen(conf, "inetNic", v4, "b4sideNic", v6)
   if not c then
      fatal(err)
   end
   engine.configure(c)

   if opts.verbosity >= 2 then
      local function lnicui_info() engine.report_apps() end
      local t = timer.new("report", lnicui_info, 1e9, 'repeating')
      timer.activate(t)
   end

   if opts.verbosity >= 1 then
      local csv = csv_stats.CSVStatsTimer.new()
      csv:add_app('inetNic', { 'tx', 'rx' }, { tx='IPv4 RX', rx='IPv4 TX' })
      csv:add_app('b4sideNic', { 'tx', 'rx' }, { tx='IPv6 RX', rx='IPv6 TX' })
      csv:activate()
   end

   engine.busywait = true
   if opts.duration then
      engine.main({duration=opts.duration, report={showlinks=true}})
   else
      engine.main({report={showlinks=true}})
   end
end
