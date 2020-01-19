module(..., package.seeall)

local lib = require("core.lib")
local pci = require("lib.hardware.pci")

local ffi = require("ffi")
local C = ffi.C

local long_opts = {
   duration = "D",
   help = "h",
   pciaddr = 1,
   virtio = 1,
}

local L2Fwd = {}

function L2Fwd.new ()
   return setmetatable({tmp=ffi.new("uint8_t[6]")}, {__index=L2Fwd})
end

function L2Fwd:push ()
   local i, o = self.input.input, self.output.output

   while not link.empty(i) do
      local pkt = link.receive(i)
      self:eth_swap(pkt)
      link.transmit(o, pkt)
   end
end

function L2Fwd:eth_swap (pkt)
   C.memcpy(self.tmp, pkt.data, 6)
   C.memcpy(pkt.data, pkt.data + 6, 6)
   C.memcpy(pkt.data + 6, self.tmp, 6)
end

local function usage (exit_code)
   print("Usage: l2fwd [-D|--duration <N>] [--pciaddr <pciaddr>]")
   main.exit(exit_code)
end

local function parse_args (args)
   local opts = {}
   local handlers = {}
   function handlers.pciaddr (arg)
      opts.pciaddr = arg
   end
   function handlers.virtio (arg)
      opts.virtio = arg
   end
   function handlers.D (arg)
      opts.duration = assert(tonumber(arg), "Duration must be a number")
   end
   function handlers.h ()
      usage(0)
   end
   args = lib.dogetopt(args, handlers, "hD:", long_opts)
   if not (opts.pciaddr or opts.virtio) then usage(1) end
   return args, opts
end

function run (args)
   local args, opts = parse_args(args)

   local c = config.new()
   config.app(c, "l2fwd", L2Fwd)

   local device
   if opts.pciaddr then
      device = pci.device_info(opts.pciaddr)
      config.app(c, "nic", require(device.driver).driver, {
         pciaddr = opts.pciaddr
      })
   elseif opts.virtio then
      device = {driver="apps.virtio_net.virtio_net", tx="tx", rx="rx"}
      config.app(c, "nic", require(device.driver).VirtioNet, {
         pciaddr = opts.virtio
      })
   else
      error("Unreachable")
   end

   config.link(c, "nic."..device.tx.." -> l2fwd.input")
   config.link(c, "l2fwd.output -> nic."..device.rx)

   engine.configure(c)
   engine.main({duration=opts.duration, report={showlinks=true}})
end
