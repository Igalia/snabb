-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(...,package.seeall)

local S = require("syscall")
local channel = require("apps.config.channel")
local codec = require("apps.config.codec")
local alarm_model = require("lib.yang.alarms")

local alarm_names = { 'raise_alarm', 'clear_alarm' }
local alarm_codes = {}
for i, name in ipairs(alarm_names) do alarm_codes[name] = i end

local verbose = false
local alarms = {}

function alarms.raise_alarm (codec, key, args)
   key = codec:table(key)
   args = codec:table(args)
   return codec:finish(key, args)
end
function alarms.clear_alarm (codec, key, args)
   key = codec:table(key)
   args = codec:table(args)
   return codec:finish(key, args)
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

function raise_alarm (key, args)
   -- TODO: Manage raise messages are not sent too often.
   args = args or {}
   local buf, len = encode({'raise_alarm', {key, args}})
   put_message(buf, len)
end
function clear_alarm (key, args)
   -- TODO: Manage clear messages are not sent too often.
   args = args or {}
   local buf, len = encode({'clear_alarm', {key, args}})
   put_message(buf, len)
end

function set_alarm (id)
   local buf, len = encode({'set_alarm', {id}})
   put_message(buf, len)
end

function selftest ()
   print('selftest: apps.config.alarm_codec')
   local lib = require("core.lib")
   local ffi = require("ffi")
   local function test_alarm(alarm)
      local encoded, len = encode(alarm)
      local decoded = decode(encoded, len)
      assert(lib.equal(alarm, decoded))
   end
   local key = {resource='resource', alarm_type_id='alarm_type_id',
                alarm_type_qualifier='alarm_type_qualifier'}
   local args = {}
   test_alarm({'raise_alarm', {key, args}})
   test_alarm({'clear_alarm', {key, args}})
   print('selftest: ok')
end
