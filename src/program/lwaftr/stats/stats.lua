module(..., package.seeall)

local common = require("program.config.common")
local lib = require("core.lib")

function show_usage (code)
   print(require("program.lwaftr.stats.README_inc"))
   main.exit(code)
end

function parse_args (args)
   local opts = {}
   local handlers = {}
   function handlers.h () show_usage(0) end
   function handlers.f (arg)
      opts.format = assert(arg)
   end
   args = lib.dogetopt(args, handlers, "hf:", { help="h", format="f" })
   if #args ~= 1 then show_usage(1) end
   return opts, unpack(args)
end

local function split (str, sep)
   sep = sep or " "
   local ret = {}
   local regex = "[^"..sep.."]+"
   for each in str:gmatch(regex) do
      table.insert(ret, each)
   end
   return ret
end

local printer = {}

function printer.influxdb (text)
   local ret = {}
   local sep = " "
   for line in text:gmatch("[^\n]+") do
      line = line:gsub("[/%[%]]", sep)
      local parts = split(line, sep)
      local key = {parts[5], parts[3], parts[2].."="..parts[4]}
      local value = "value="..parts[6]
      table.insert(ret, table.concat(key, ",").." "..value)
   end
   print(table.concat(ret, "\n"))
end

local function print_and_exit(response, response_prop, format)
   format = format or "influxdb"
   if response.error then
      print(response.error)
   elseif response_prop then
      printer[format](response[response_prop])
   end
   main.exit(response.status)
end

function run(args)
   local opts, instance_id = parse_args(args)
   args = {
      instance_id = instance_id,
      schema_name = 'snabb-softwire-v2',
      format = 'xpath',
      path = '/softwire-config/instance',
   }
   local response = common.call_leader(
      args.instance_id, 'get-state',
      { schema = args.schema_name, revision = args.revision_date,
        path = args.path, print_default = args.print_default,
        format = args.format })
   print_and_exit(response, "state", opts.format)
end
