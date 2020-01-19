-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)

local engine    = require("core.app")
local timer     = require("core.timer")
local lib       = require("core.lib")
local pci       = require("lib.hardware.pci")

local function is_device_suitable (pcidev, patterns)
   if not pcidev.usable or not pcidev.driver:match('intel') then
      return false
   end
   if #patterns == 0 then
      return true
   end
   for _, pattern in ipairs(patterns) do
      if pci.qualified(pcidev.pciaddress):gmatch(pattern)() then
         return true
      end
   end
end

local function loadgen (name)
   local path = name:match("intel_mp") and "apps.intel_mp.loadgen"
                                       or  "apps.intel.loadgen"
   return require(path).LoadGen
end

local function driver (path)
   return require(path).driver
end

function run_loadgen (c, patterns, opts)
   assert(type(opts) == "table")
   local use_loadgen = opts.loop == nil or opts.loop
   local nics = 0
   pci.scan_devices()
   for _,device in ipairs(pci.devices) do
      if is_device_suitable(device, patterns) then
         nics = nics + 1
         local name = "nic"..nics
         local pciaddr = device.pciaddress
         local info = pci.device_info(pciaddr)
         if use_loadgen then
            config.app(c, name, loadgen(info.driver), pciaddr)
         else
            config.app(c, name, driver(info.driver), {pciaddr = pciaddr})
         end
         config.link(c, "source."..tostring(nics).."->"..name..".input")
      end
   end
   assert(nics > 0, "<PCI> matches no suitable devices.")
   engine.busywait = true
   engine.configure(c)

   local report = {}
   if use_loadgen then
      local fn = function ()
         print("Transmissions (last 1 sec):")
         engine.report_apps()
      end
      local t = timer.new("report", fn, 1e9, 'repeating')
      timer.activate(t)
   else
      report = {showlinks = true}
   end

   if opts.duration then engine.main({duration=opts.duration, report=report})
   else             engine.main() end
end

local function devices ()
   pci.scan_devices()
   return pci.devices
end

function run_l2fwd (c, patterns, opts)
   assert(type(opts) == "table")

   local apps = {}
   local id = 0
   local devices = devices()
   for _,device in ipairs(devices) do
      if is_device_suitable(device, patterns) then
         id = id + 1
         local name = "nic"..id
         local pciaddr = device.pciaddress
         local info = pci.device_info(pciaddr)
         config.app(c, name, loadgen(info.driver), pciaddr)
         config.link(c, "source."..id.."->"..name..".input")
      end
   end
   assert(id > 0, "<PCI> matches no suitable devices.")
   engine.busywait = true
   engine.configure(c)

   -- Collect apps.
   local apps = {}
   for i=1,id do
      local app = engine.app_table["nic"..i]
      table.insert(apps, app)
   end

   -- Set warming up and duration.
   local warm_up = 15
   local threshold = os.time() + warm_up + opts.duration

   io.stdout:write(("Warming up for %d seconds..."):format(warm_up))
   io.stdout:flush()
   warm_up = os.time() + warm_up

   -- Global stats.
   local g_stats = {}
   local done = false
   local times = 0
   local collect_stats = function ()
      for _, app in ipairs(apps) do
         local stats = app:stats()
         if os.time() < warm_up then goto continue end
         if not done then
            done = true
            print("Done")
            print(("Running for %d seconds"):format(opts.duration))
         end
         local pciaddr = app.pciaddress
         if not g_stats[pciaddr] then
            g_stats[pciaddr] = {
               TXDGPC = 0,
               GOTCL  = 0,
               RXNFGPC = 0,
               RXDGPC = 0,
               GORCL  = 0,
               QPRDC = 0,
            }
         end
         g_stats[pciaddr].TXDGPC = g_stats[pciaddr].TXDGPC + stats.TXDGPC
         g_stats[pciaddr].GOTCL  = g_stats[pciaddr].GOTCL  + stats.GOTCL
         g_stats[pciaddr].RXNFGPC = g_stats[pciaddr].RXNFGPC + stats.RXNFGPC
         g_stats[pciaddr].RXDGPC = g_stats[pciaddr].RXDGPC + stats.RXDGPC
         g_stats[pciaddr].GORCL  = g_stats[pciaddr].GORCL  + stats.GORCL
         ::continue::
      end
      if done then times = times + 1 end
   end
   local t = timer.new("collect_stats", collect_stats, 1e9, 'repeating')
   timer.activate(t)

   local function report (pciaddr, stats)
      local function mpps (packets)
         return (packets / 1e6) / times
      end
      local function gbps (bytes)
         return (bytes * 8 / 1e9) / times
      end
      local function pkt_diff (stats)
         return lib.comma_value(math.max(stats.TXDGPC - stats.RXNFGPC, 0))
      end
      print("Device: "..pciaddr)
      print(("Packets sent: %.4f MPPS (%.4f Gbps)"):format(mpps(stats.TXDGPC),
                                                           gbps(stats.GOTCL)))
      print(("Packets received: %.4f MPPS (%.4f Gbps)"):format(mpps(stats.RXNFGPC),
                                                               gbps(stats.GORCL)))
      print(("Packet difference: %s"):format(pkt_diff(stats)))
   end

   local function done ()
      if threshold <= os.time() then
         -- Print stats for each device.
         for pciaddr, stats in pairs(g_stats) do
            report(pciaddr, stats)
         end
         return true
      end
   end

   if opts.duration then engine.main({done=done})
   else             engine.main() end
end

local function show_usage(exit_code)
   print(require("program.packetblaster.README_inc"))
   main.exit(exit_code)
end

function run(args)
   if #args == 0 then show_usage(1) end
   local command = string.gsub(table.remove(args, 1), "-", "_")
   local modname = ("program.packetblaster.%s.%s"):format(command, command)
   if not lib.have_module(modname) then
      show_usage(1)
   end
   require(modname).run(args)
end
