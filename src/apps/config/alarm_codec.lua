-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(...,package.seeall)

local S = require("syscall")
local channel = require("apps.config.channel")
local codec = require("apps.config.codec")

local alarm_names = { 'raise_alarm', 'clear_alarm' }
local alarm_codes = {}
for i, name in ipairs(alarm_names) do alarm_codes[name] = i end

local alarms_channel

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

local function get_channel ()
   if alarms_channel then return alarms_channel end
   local name = '/'..S.getpid()..'/alarms-follower-channel'
   local success, value = pcall(channel.open, name)
   if success then
      alarms_channel = value
   end
   return alarms_channel
end

-- To be called by the data-plane to signal an alarm was raised.
-- XXX: Limiting mechanism to avoid sending messages too often.
function raise_alarm (key, args)
   local channel = get_channel()
   if channel then
      args = args or {}
      args.is_cleared = false
      local buf, len = encode({'raise_alarm', {key, args}})
      channel:put_message(buf, len)
   end
end
-- To be called by the data-plane to signal an alarm was cleared.
-- XXX: Limiting mechanism to avoid sending messages too often.
function clear_alarm (key, args)
   local channel = get_channel()
   if channel then
      args = args or {}
      args.is_cleared = true
      local buf, len = encode({'clear_alarm', {key, args}})
      channel:put_message(buf, len)
   end
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
