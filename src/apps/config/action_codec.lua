-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(...,package.seeall)

local codec = require("apps.config.codec")

local action_names = { 'unlink_output', 'unlink_input', 'free_link',
                       'new_link', 'link_output', 'link_input', 'stop_app',
                       'start_app', 'reconfig_app',
                       'call_app_method_with_blob', 'send_pending_alarms',
                       'commit' }
local action_codes = {}
for i, name in ipairs(action_names) do action_codes[name] = i end

local actions = {}

function actions.send_pending_alarms (codec)
   return codec:finish()
end
function actions.unlink_output (codec, appname, linkname)
   local appname = codec:string(appname)
   local linkname = codec:string(linkname)
   return codec:finish(appname, linkname)
end
function actions.unlink_input (codec, appname, linkname)
   local appname = codec:string(appname)
   local linkname = codec:string(linkname)
   return codec:finish(appname, linkname)
end
function actions.free_link (codec, linkspec)
   local linkspec = codec:string(linkspec)
   return codec:finish(linkspec)
end
function actions.new_link (codec, linkspec)
   local linkspec = codec:string(linkspec)
   return codec:finish(linkspec)
end
function actions.link_output (codec, appname, linkname, linkspec)
   local appname = codec:string(appname)
   local linkname = codec:string(linkname)
   local linkspec = codec:string(linkspec)
   return codec:finish(appname, linkname, linkspec)
end
function actions.link_input (codec, appname, linkname, linkspec)
   local appname = codec:string(appname)
   local linkname = codec:string(linkname)
   local linkspec = codec:string(linkspec)
   return codec:finish(appname, linkname, linkspec)
end
function actions.stop_app (codec, appname)
   local appname = codec:string(appname)
   return codec:finish(appname)
end
function actions.start_app (codec, appname, class, arg)
   local appname = codec:string(appname)
   local _class = codec:class(class)
   local config = codec:config(class, arg)
   return codec:finish(appname, _class, config)
end
function actions.reconfig_app (codec, appname, class, arg)
   local appname = codec:string(appname)
   local _class = codec:class(class)
   local config = codec:config(class, arg)
   return codec:finish(appname, _class, config)
end
function actions.call_app_method_with_blob (codec, appname, methodname, blob)
   local appname = codec:string(appname)
   local methodname = codec:string(methodname)
   local blob = codec:blob(blob)
   return codec:finish(appname, methodname, blob)
end
function actions.commit (codec)
   return codec:finish()
end

function encode(action)
   local name, args = unpack(action)
   local encoder = codec.encoder()
   encoder:uint32(assert(action_codes[name], name))
   return assert(actions[name], name)(encoder, unpack(args))
end

function decode(buf, len)
   local codec = codec.decoder(buf, len)
   local name = assert(action_names[codec:uint32()])
   return { name, assert(actions[name], name)(codec) }
end

function selftest ()
   print('selftest: apps.config.action_codec')
   local lib = require("core.lib")
   local ffi = require("ffi")
   local function test_action(action)
      local encoded, len = encode(action)
      local decoded = decode(encoded, len)
      assert(lib.equal(action, decoded))
   end
   local appname, linkname, linkspec = 'foo', 'bar', 'foo.a -> bar.q'
   local class, arg = require('apps.basic.basic_apps').Tee, {}
   -- Because lib.equal only returns true when comparing cdata of
   -- exactly the same type, here we have to use uint8_t[?].
   local methodname, blob = 'zog', ffi.new('uint8_t[?]', 3, 1, 2, 3)
   test_action({'unlink_output', {appname, linkname}})
   test_action({'unlink_input', {appname, linkname}})
   test_action({'free_link', {linkspec}})
   test_action({'new_link', {linkspec}})
   test_action({'link_output', {appname, linkname, linkspec}})
   test_action({'link_input', {appname, linkname, linkspec}})
   test_action({'stop_app', {appname}})
   test_action({'start_app', {appname, class, arg}})
   test_action({'reconfig_app', {appname, class, arg}})
   test_action({'call_app_method_with_blob', {appname, methodname, blob}})
   test_action({'commit', {}})
   print('selftest: ok')
end
