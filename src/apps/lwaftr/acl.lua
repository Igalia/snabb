module(...,package.seeall)

local filter = require("lib.pcap.filter")

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

--[[
'filename' is an ACL file. It's encoded as a CSV with the following structure:

   ipv4_ingress_filter,ipv6_ingress_filter,ipv4_egress_filter,ipv6_egress_filter
   rule11,rule21,,rule41
   rule12,rules22,,
   rule13,,,

Each column represents a filter composed of several cells of the same column.
The result of processing such a file will be a set of filters containing each filter
an array of rules:

   ingress_filter_ipv4 = array(rule11, rule12, rule13)
   ingress_filter_ipv6 = array(rule21, rule22)
   egress_filter_ipv4 = array()
   egress_filter_ipv6 = array(rule41)

Later each filter will be combined into a single pflang expression concatenated
by 'and'. Finally, these rules are compiled into Lua functions via the filter module.
]]--
local function compose_filters(filename, args)
   args = args or {}
   local filters = {{},{},{},{}}
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
      assert(j <= 4, ("Too many columns in line: %d"):format(i))
      i = i + 1
      ::continue::
   end
   return filters
end

local function compile_filter(expr)
   local function filter_to_str(array)
      return table.concat(array, " and ")
   end
   return filter:new(filter_to_str(expr))
end

local function compile_filters(filters)
   return {
      ipv4_ingress_filter = compile_filter(filters[1]),
      ipv6_ingress_filter = compile_filter(filters[2]),
      ipv4_egress_filter = compile_filter(filters[3]),
      ipv6_egress_filter = compile_filter(filters[4]),
   }
end

function compile(filename, args)
   return compile_filters(compose_filters(filename, args))
end
