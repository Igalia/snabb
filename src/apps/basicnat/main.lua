local config = require("core.config")
local app = require("core.app")
local link = require("core.link")

local pcap = require("apps.pcap.pcap")
local BasicNAT = require("apps.basicnat.basicnat").BasicNAT

local function usage()
   print([[
Usage: apps.basicnat.basicnat <input.pcap> <output.pcap> <public_ip> <private_ip> <private_network>

   <input.pcap>      Input file
   <output.pcap>     Output file
   <public_ip>       Public IP used as source address in outbound packets
   <private_ip>      Private IP used as destination address in inbound packtes
   <private_network> Private network address in CIDR format, i.e: 10.0.0.0./8
]])
   os.exit()
end

function run (parameters)
   if not (#parameters == 5) then usage() end
   local input, output, public_ip, private_ip, network = unpack(parameters)

   print(("Changing: SRC(%s) => SRC(%s)"):format(private_ip, public_ip))
   print(("Changing: DST(%s) => DST(%s)"):format(public_ip, private_ip))
   local c = config.new()
   config.app(c, "incoming", pcap.PcapReader, input)
   config.app(c, "basicnat", BasicNAT, {
      public_ip  = public_ip,
      private_ip = private_ip,
      network = network,
   })
   config.app(c, "outgoing", pcap.PcapWriter, output)

   config.link(c, "incoming.output -> basicnat.input")
   config.link(c, "basicnat.output -> outgoing.input")

   app.configure(c)
   app.main({duration=1, report={showlinks = true}})
end

run(main.parameters)
