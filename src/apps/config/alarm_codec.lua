-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(...,package.seeall)

local S = require("syscall")
local channel = require("apps.config.channel")
local codec = require("apps.config.codec")

local alarm_names = { 'set_alarm', 'clear_alarm' }
local alarm_codes = {}
for i, name in ipairs(alarm_names) do alarm_codes[name] = i end

local verbose = false
local alarms = {}

function alarms.set_alarm (codec, id)
   local id = codec:string(id)
   return codec:finish(id)
end
function alarms.clear_alarm (codec, id)
   local id = codec:string(id)
   return codec:finish(id)
end

function encode (alarm)
   local name, args = unpack(alarm)
   local encoder = codec.encoder()
   encoder:uint32(assert(alarm_codes[name], name))
   return assert(alarms[name], name)(encoder, unpack(args))
end

function decode (buf, len)
   local codec = codec.decoder(buf, len)
   local name = assert(alarm_names[codec:uint32()])
   return { name, assert(alarms[name], name)(codec) }
end

local alarms_channel = (function()
   local ret
   local name = '/'..S.getpid()..'/alarms-follower-channel'
   return function ()
      if ret then return ret end
      local success, value = pcall(channel.open, name)
      if success then ret = value end
      return ret
   end
end)()

local function put_message (buf, len)
   local channel = alarms_channel()
   if verbose and not channel then print("Could not get channel") end
   if channel then channel:put_message(buf, len) end
end

function set_alarm (id)
   local buf, len = encode({'set_alarm', {id}})
   put_message(buf, len)
end

function selftest ()
   print('selftest: apps.config.action_codec')
   local lib = require("core.lib")
   local ffi = require("ffi")
   local function test_alarm(alarm)
      local encoded, len = encode(alarm)
      local decoded = decode(encoded, len)
      assert(lib.equal(alarm, decoded))
   end
   local id = "1"
   -- Because lib.equal only returns true when comparing cdata of
   -- exactly the same type, here we have to use uint8_t[?].
   test_alarm({'set_alarm', {id}})
   test_alarm({'clear_alarm', {id}})
   print('selftest: ok')
end
