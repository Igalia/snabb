local app = require("core.app")
local config = require("core.config")
local pcap = require("apps.pcap.pcap")
local link = require("core.link")
local packet = require("core.packet")
local conntrack = require("apps.conntrack.conntrack")

local arg = {}
for _, v in pairs(...) do
   table.insert(arg, v)
end

if #arg == 0 then
   -- Default pcap file
   table.insert("apps/conntrack/tests/techcrunch.pcap")
end

local output_file = "/tmp/output.pcap"

local c = config.new()
config.app(c, "capture", pcap.PcapReader, arg[1])
config.app(c, "conntrack_app", conntrack.ConntrackApp)
config.app(c, "output_file", pcap.PcapWriter, output_file)

config.link(c, "capture.output -> conntrack_app.input")
config.link(c, "conntrack_app.output -> output_file.input")

print(("Results written at: %s"):format(output_file))

app.configure(c)
app.main({duration=1})
