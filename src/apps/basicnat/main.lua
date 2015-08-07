local app = require("core.app")
local config = require("core.config")
local pcap = require("apps.pcap.pcap")
local basicnat = require("apps.basicnat.basicnat")
--local usage = require("program.example.replay.README_inc") -- TODO
local usage="thisapp in.pcap out.pcap external_ip internal_net"

local function bytes_to_uint32(a, b, c, d)
   return a * 2^24 + b * 2^16 + c * 2^8 + d
end

local function str_ip_to_uint32(ip)
   local a, b, c, d = ip:match("([0-9]+).([0-9]+).([0-9]+).([0-9]+)")
   return bytes_to_uint32(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

function run (parameters)
   if not (#parameters == 4) then print(usage) main.exit(1) end
   local in_pcap = parameters[1]
   local out_pcap = parameters[2]
   local external_ip = str_ip_to_uint32(parameters[3])
   local internal_ip = str_ip_to_uint32(parameters[4])

   local c = config.new()
   config.app(c, "capture", pcap.PcapReader, in_pcap)
   config.app(c, "basicnat_app", basicnat.BasicNAT,
                  {external_ip = external_ip, internal_ip = internal_ip})
   config.app(c, "output_file", pcap.PcapWriter, out_pcap)

   config.link(c, "capture.output -> basicnat_app.input")
   config.link(c, "basicnat_app.output -> output_file.input")

   app.configure(c)
   app.main({duration=1, report = {showlinks=true}})
end

run(main.parameters)
