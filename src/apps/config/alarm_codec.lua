-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(...,package.seeall)

local codec = require("apps.config.codec")

local alarm_names = { 'set_alarm', 'clear_alarm' }
local alarm_codes = {}
for i, name in ipairs(alarm_names) do alarm_codes[name] = i end

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
