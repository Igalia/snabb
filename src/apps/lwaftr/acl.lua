module(...,package.seeall)

local filter = require("lib.pcap.filter")

local INGRESS_FILTER_IPV4 = 1
local INGRESS_FILTER_IPV6 = 2
local EGRESS_FILTER_IPV4  = 3
local EGRESS_FILTER_IPV6  = 4

local function trim(s)
  return s:gsub("^%s*(.-)%s*$", "%1")
end

local function columns(content, sep)
   local function iter(state)
      local token, pos = state.content:match(state.regex, state.start)
      if not pos then return nil end
      state.start = pos
      return token
   end
   sep = sep or ","
   local regex = ("([^%s]+)()%s"):format(sep, sep)
   local state = { content = content, regex = regex, start = 0 }
   return iter, state
end

local function compile_filter(expr)
   local function filter_to_str(filter)
      return table.concat(filter, " and ")
   end
   return filter:new(filter_to_str(expr))
end

local function as_filter_table(filters)
   return {
      ingress_filter = {
         ipv4 = compile_filter(filters[INGRESS_FILTER_IPV4]),
         ipv6 = compile_filter(filters[INGRESS_FILTER_IPV6]),
      },
      egress_filter = {
         ipv4 = compile_filter(filters[EGRESS_FILTER_IPV4]),
         ipv6 = compile_filter(filters[EGRESS_FILTER_IPV6]),
      }
   }
end

function compile(filename, args)
   args = args or {}
   local filters = { 
      {}, -- IPv4 ingress filter
      {}, -- IPv6 ingress filter 
      {}, -- IPv4 egress filter
      {}, -- IPV6 egress filter
   }
   local i = 1
   for line in io.lines(filename) do
      -- Skip header if requested 
      if args.skip_header then
         if i == 1 then 
            i = i + 1
            goto continue 
         end
      end
      local j = 1
      for column in columns(line) do
         column = trim(column)
         if #column > 0 then
            table.insert(filters[j], column)
         end
         j = j + 1
      end
      i = i + 1
      ::continue::
   end
   return as_filter_table(filters)
end
