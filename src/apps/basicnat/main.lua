local config = require("core.config")
local app = require("core.app")
local link = require("core.link")

local pcap = require("apps.pcap.pcap")
local BasicNAT = require("apps.basicnat.basicnat").BasicNAT

local function usage()
   print("Usage: apps.basicnat.basicnat <input.pcap> <output.pcap> <public_ip> <private_ip>")
   os.exit()
end

function run (parameters)
   if not (#parameters == 4) then usage() end
   local input, output, public_ip, private_ip = unpack(parameters)

   print(("Changing: DST(%s) => DST(%s); SRC(%s) => SRC(%s)"):format(
      public_ip, private_ip, private_ip, public_ip))
   local c = config.new()
   config.app(c, "incoming", pcap.PcapReader, input)
   config.app(c, "basicnat", BasicNAT, {
      public  = public_ip,
      private = private_ip,
   })
   config.app(c, "outgoing", pcap.PcapWriter, output)

   config.link(c, "incoming.output -> basicnat.input")
   config.link(c, "basicnat.output -> outgoing.input")

   app.configure(c)
   app.main({duration=1, report={showlinks = true}})
end

run(main.parameters)
