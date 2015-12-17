module(..., package.seeall)

local ethernet = require("lib.protocol.ethernet")
local ffi = require("ffi")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local acl = require("apps.lwaftr.acl")

local bt = require("apps.lwaftr.binding_table")

policies = {
   DROP = 1,
   ALLOW = 2
}

local aftrconf

local function dirname(filename)
   return filename:match("(.*)%/.*$")
end

-- Compiles ACL file and adds filters to conf file.
local function compile_acl_file(conf, filename)
   local filters = acl.compile(filename, {skip_header = true})
   conf.ipv4_ingress_filter = filters.ipv4_ingress_filter
   conf.ipv6_ingress_filter = filters.ipv6_ingress_filter
   conf.ipv4_egress_filter = filters.ipv4_egress_filter
   conf.ipv6_egress_filter = filters.ipv6_egress_filter
end

-- TODO: rewrite this after netconf integration
local function read_conf(conf_file)
   local input = io.open(conf_file)
   local conf_vars = input:read('*a')
   local full_config = ([[
      function _conff(policies, ipv4, ipv6, ethernet, bt)
         return {%s}
      end
      return _conff
   ]]):format(conf_vars)
   local f = assert(loadstring(full_config))()
   local conf = f(policies, ipv4, ipv6, ethernet, bt)
   if conf.acl then
      local acl_file = ("%s/%s"):format(dirname(conf_file), conf.acl)
      compile_acl_file(conf, acl_file)
   end
   return conf
end

function get_aftrconf(conf_file)
   if not aftrconf then
      aftrconf = read_conf(conf_file)
   end
   return aftrconf
end
