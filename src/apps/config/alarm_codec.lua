-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(...,package.seeall)

local S = require("syscall")
local channel = require("apps.config.channel")
local codec = require("apps.config.codec")

local alarm_names = { 'set_alarm', 'clear_alarm', 'commit' }
local alarm_codes = {}
for i, name in ipairs(alarm_names) do alarm_codes[name] = i end

local alarms = {}

function alarms.set_alarm (codec, id)
   local id = codec:string(id)
   return codec:finish(id)
end
function alarms.commit (codec, id)
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

--[[
-- FIXME:
-- The problem of adding an alarm to a list that is later processed is that it's the data-plane (follower) which calls set_alarm. The alarms is added to the follower's variable 'outgoing_alarm_events'. Then the leader calls 'send_pending_alarms' and iterates 'outgoing_alarm_events'. The problem is that the list that the leader iterates is empty, because the alarm event was added to the follower's 'outgoing_alarm_events'. So actually to process the pending alarms events in the follower it would be necessary that the leader sends a message to the follower.
-- Instead I make set_alarm to directly put a message in the follower's channel.
--]]
--[[
local outgoing_alarm_events = {}

function set_alarm (id)
   table.insert(outgoing_alarm_events, {'set_alarm', {id}})
end

function send_pending_alarms (channel)
   print("follower.send_pending_alarms")
   for _,alarm_event in ipairs(outgoing_alarm_events) do
      local buf, len = encode(alarm_event)
      channel:put_message(buf, len)
   end
   local buf, len = encode({'commit', {}})
   channel:put_message(buf, len)
   outgoing_alarm_events = {}
end
--]]

local verbose = true

local alarms_channel = (function ()
   local ret
   local name = '/'..S.getpid()..'/alarms-follower-channel'
   return function ()
      if ret then return ret end
      ret = channel.open(name)
      return ret
   end
end)()

function set_alarm (id)
   local buf, len = encode({'set_alarm', {id}})
   alarms_channel():put_message(buf, len)
   buf, len = encode({'commit', {id}})
   alarms_channel():put_message(buf, len)
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
   local id = 'id'
   -- Because lib.equal only returns true when comparing cdata of
   -- exactly the same type, here we have to use uint8_t[?].
   test_alarm({'set_alarm', {id}})
   test_alarm({'clear_alarm', {id}})
   print('selftest: ok')
end
