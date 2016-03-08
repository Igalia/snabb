local log = {
   usecolor = true;
   level    = "warn";
   output   = io.stderr;
   format   = {};
}

local modes = {
   { name = "trace", color = "\27[34m" };
   { name = "debug", color = "\27[36m" };
   { name = "info" , color = "\27[32m" };
   { name = "warn" , color = "\27[33m" };
   { name = "error", color = "\27[31m" };
   { name = "fatal", color = "\27[35m" };
}

local debug_getinfo = debug.getinfo
local string_format = string.format
local string_match = string.match
local string_gsub = string.gsub
local string_sub = string.sub
local os_date = os.date
local table_insert, table_concat = table.insert, table.concat
local _tostring, _tonumber, _pairs, _type = tostring, tonumber, pairs, type


-- TODO: Handle cycles in tables.
local function do_pprint (value)
   if _type(value) == "table" then
      local items = {}
      for k, v in _pairs(value) do
         table_insert(items, string_format("%s=%s", k, do_pprint(v)))
      end
      return "{ " .. table_concat(items, ", ") .. " }"
   elseif _type(value) == "string" then
      return string_format("%q", value)
   else
      return _tostring(value)
   end
end
log.format.linepp = do_pprint


local function do_pprint_indent (value, indent)
   if _type(value) == "table" then
      local items = {}
      for k, v in _pairs(value) do
         table_insert(items, string_format("%s = %s", k, do_pprint_indent(v, indent .. "  ")))
      end
      return "{\n  " .. indent .. table_concat(items, ",\n  " .. indent) .. "\n" .. indent .. "}"
   elseif _type(value) == "string" then
      return string_format("%q", value)
   else
      return _tostring(value)
   end
end
log.format.pp = function (value) return do_pprint_indent(value, "") end


local msgformat = "%s[%-6s%s]%s %s:%d: %s\n"
local spec_pattern = "^([^%%]*)%%?(.*)$"
local levels = {}

local function interpolate (fmtstring, ...)
   local current_index = 1
   local args = { ... }

   return (string_gsub(fmtstring, "%$%{(.-)}", function (spec)
      local element, conversion = string_match(spec, spec_pattern)

      local value
      if #element == 0 then
         -- Pick from current_index without increment
         value = args[current_index]
      elseif element == "." then
         -- Current index with increment
         value = args[current_index]
         current_index = current_index + 1
      else
         local index = _tonumber(element)
         if index then
            -- Numeric index
            value = args[index]
         else
            -- Named index
            local table = args[current_index]
            if string_sub(element, 1, 1) == "." then
               value = table[string_sub(element, 2)]
               current_index = current_index + 1
            else
               value = table[element]
            end
         end
      end

      if #conversion == 0 then
         return _tostring(value)
      elseif log.format[conversion] then
         return log.format[conversion](value)
      else
         return string_format("%" .. conversion, value)
      end
   end))
end

for i, v in ipairs(modes) do
   levels[v.name] = i
   local name_upper = v.name:upper()

   log[v.name] = function (fmtstring, arg1, ...)
      if i < levels[log.level] then
         return
      end

      local message
      if _type(arg1) == "function" then
         -- Arguments are retrieved by invoking the function
         message = interpolate(fmtstring, arg1())
      else
         message = interpolate(fmtstring, arg1, ...)
      end

      local dinfo = debug_getinfo(2, "Sl")

      log.output:write(string_format(msgformat,
                                     log.usecolor and v.color or "",
                                     name_upper,
                                     os_date("%H:%M:%S"),
                                     log.usecolor and "\27[0m" or "",
                                     dinfo.short_src,
                                     dinfo.currentline,
                                     message))
      log.output:flush()
   end
end


log.interpolate = interpolate
return log
