-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)

local ffi = require("ffi")
local C = ffi.C
local lib = require("core.lib")
local shm = require("core.shm")
local counter = require("core.counter")
local S = require("syscall")
local histogram = require("core.histogram")
local usage = require("program.top.README_inc")
local fiber = require("lib.fibers.fiber")
local sleep = require("lib.fibers.sleep")
local inotify = require("lib.ptree.inotify")
local op = require("lib.fibers.op")
local cond = require("lib.fibers.cond")
local channel = require("lib.fibers.channel")

function clearterm () io.write('\027[2J') end
function move(x,y)    io.write(string.format('\027[%d;%dH', x, y)) end
function dsr()        io.write(string.format('\027[6n')) end
function newline()    io.write('\027[K\027[E') end
function println(fmt, ...)
   io.write(fmt:format(...))
   newline()
   io.flush()
end
function sgr(fmt,...) io.write('\027['..fmt:format(...)..'m') end
function scroll(n)    io.write(string.format('\027[%dS', n)) end

function bgcolordefault(n) sgr('49') end
function fgcolordefault(n) sgr('39') end
function bgcolor8(n) sgr('48;5;%d', n) end
function fgcolor8(n) sgr('38;5;%d', n) end
function bgcolor24(r,g,b) sgr('48;2;%d;%d;%d', r, g, b) end
function fgcolor24(r,g,b) sgr('38;2;%d;%d;%d', r, g, b) end

local snabb_state = { instances={}, counters={} }
local ui = { instance=nil, wake=cond.new(), rows=24, cols=80 }

function needs_redisplay() ui.wake:signal() end

function makeraw (tc)
   local ret = S.t.termios()
   ffi.copy(ret, tc, ffi.sizeof(S.t.termios))
   ret:makeraw()
   return ret
end

local function read_int()
   local ret = 0
   for c in io.stdin.peek_char, io.stdin do
      local dec = c:byte() - ("0"):byte()
      if 0 <= dec and dec <= 9 then
         io.stdin:read_char()
         ret = ret * 10 + dec
      else
         return ret
      end
   end
end

local function refresh()
   move(1,1)
   clearterm()
   println('screen size %dx%d', ui.rows, ui.cols)
   for pid, instance in pairs(snabb_state.instances) do
      println("instance %s", pid)
      if instance.name then println("  name: %s", instance.name) end
      if instance.group then println("  group: %s", instance.group) end
      for k,v in pairs(snabb_state.stats[pid] or {}) do
         println("  %s = %d", k, tonumber(v))
      end
   end
   --local new_stats = get_stats(counters)
   --print_global_metrics(new_stats, last_stats)
   --io.write("\n")
   --print_latency_metrics(new_stats, last_stats)
   --print_link_metrics(new_stats, last_stats)
   --io.flush()
end

local function request_dimensions() move(1000, 1000); dsr() end

local function read_counters()
   local ret = {}
   for pid,_ in pairs(snabb_state.counters) do
      ret[pid] = {}
      for k,v in pairs(snabb_state.counters[pid]) do
         ret[pid][k] = counter.read(v)
      end
   end
   return ret
end

function show_ui()
   request_dimensions()
   while true do
      local s = snabb_state
      s.prev_stats_time, s.prev_stats = s.stats_time, s.stats
      s.stats_time, s.stats = C.get_monotonic_time(), read_counters()
      refresh()
      ui.wake:wait()
      ui.wake = cond.new()
      -- Limit UI refresh rate to 40 Hz.
      sleep.sleep(0.025)
   end
end

local function is_dir(name)
   local stat = S.lstat(name)
   return stat and stat.isdir
end

local function dirsplit(name)
   return name:match("^(.*)/([^/]+)$")
end

local function instance_monitor()
   local tx = channel.new()
   local by_name_root = shm.root..'/by-name'
   local by_pid = inotify.directory_inventory_events(shm.root)
   local by_name = inotify.directory_inventory_events(by_name_root)
   local either = op.choice(by_pid:get_operation(), by_name:get_operation())
   fiber.spawn(function()
      local by_pid, by_name = {}, {}
      for event in either.perform, either do
         if event.kind == 'mkdir' or event.kind == 'rmdir' then
            -- Ignore; this corresponds to the directories being monitored.
         elseif event.kind == 'add' then
            local dirname, basename = dirsplit(event.name)
            if dirname == shm.root then
               local pid = tonumber(basename)
               if pid and is_dir(event.name) and not by_pid[pid] then
                  by_pid[pid] = {name=nil}
                  tx:put({kind="new-instance", pid=pid})
               end
            elseif dirname == by_name_root then
               local pid_dir = S.readlink(event.name)
               if pid_dir then
                  local root, pid_str = dirsplit(pid_dir)
                  local pid = pid_str and tonumber(pid_str)
                  if pid and root == shm.root and not by_name[basename] then
                     by_name[basename] = pid
                     tx:put({kind="new-name", name=basename, pid=pid})
                  end
               end
            end
         elseif event.kind == 'remove' then
            local dirname, basename = dirsplit(event.name)
            if dirname == shm.root then
               local pid = tonumber(basename)
               if pid and by_pid[pid] then
                  by_pid[pid] = nil
                  tx:put({kind="instance-gone", pid=pid})
               end
            elseif dirname == by_name_root then
               local pid = by_name[basename]
               if pid then
                  by_name[basename] = nil
                  tx:put({kind="name-gone", name=basename, pid=pid})
               end
            end
         else
            println('unexpected event: %s', event.kind, name)
         end
      end
   end)
   return tx
end

function monitor_snabb_instance(pid, instance, counters)
   local dir = shm.root..'/'..pid
   local rx = inotify.recursive_directory_inventory_events(dir)
   fiber.spawn(function ()
      for event in rx.get, rx do
         local name = event.name:sub(#dir + 2):match('^(.*)%.counter$')
         if name then
            if event.kind == 'creat' then
               local ok, c = pcall(counter.open, event.name:sub(#shm.root+1))
               if ok then counters[name] = c end
               needs_redisplay()
               --println('%s, %s, %s', tostring(ok), name, tostring(c))
            elseif event.kind == 'rm' then
               pcall(counter.delete, counters[name])
               counters[name] = nil
               needs_redisplay()
            end
         elseif event.name == dir..'/group' then
            local target = S.readlink(event.name)
            if target and event.kind == 'creat' then
               local dir, group = dirsplit(target)
               local root, pid = dirsplit(dir)
               instance.group = tonumber(pid)
            else
               instance.group = nil
            end
            needs_redisplay()
         end
      end
   end)
end

function update_snabb_state()
   local rx = instance_monitor()
   local pending = {}
   local instances, counters = snabb_state.instances, snabb_state.counters
   for event in rx.get, rx do
      local kind, name, pid = event.kind, event.name, event.pid
      if kind == 'new-instance' then
         instances[pid], pending[pid] = { name = pending[pid] }, nil
         counters[pid] = {}
         monitor_snabb_instance(pid, instances[pid], counters[pid])
      elseif kind == 'instance-gone' then
         instances[pid], pending[pid] = nil, nil
         counters[pid] = nil
      elseif kind == 'new-name' then
         if instances[pid] then instances[pid].name = name
         else pending[pid] = name end
      elseif kind == 'name-gone' then
         instances[pid].name, pending[pid] = nil, nil
      end
      needs_redisplay()
   end
end

global_handlers = {}
local function bind_keys(k, f, handlers)
   for i=1,#k do (handlers or global_handlers)[k:sub(i,i)] = f end
end

function debug_keypress(c)
   println('read char: %s (%d)', c, string.byte(c))
end

escape_handlers = {}
function unknown_escape_sequence(c)
   println('unknown escape sequence: %s (%d)', c, string.byte(c))
end
for i=0,255 do
   bind_keys(string.char(i), fiber.stop, escape_handlers)
end
for i=0x40,0x5f do
   bind_keys(string.char(i), unknown_escape_sequence, escape_handlers)
end

function unknown_csi(kind, ...)
   println('unknown escape sequence: %s (%d)', kind, string.byte(kind))
end
function handle_csi_current_position(kind, rows, cols)
   ui.rows, ui.cols = rows or 24, cols or 80
   ui.wake:signal()
end

csi_handlers = {}
function handle_csi()
   local args = {}
   while true do
      local ch = io.stdin:peek_char()
      if not ch then break end
      if not ch:match('[%d;]') then break end
      table.insert(args, read_int())
      if io.stdin:peek_char() == ';' then io.stdin:read_char() end
   end
   -- FIXME: there are some allowable characters here
   local kind = io.stdin:read_char()
   csi_handlers[kind](kind, unpack(args))
end
for i=0,255 do bind_keys(string.char(i), unknown_csi, csi_handlers) end
bind_keys("R", handle_csi_current_position, csi_handlers)
function handle_escape_sequence()
   if io.stdin.rx:is_empty() then
      -- In theory we should see if stdin is readable, and if not wait
      -- for a small timeout.  However since the input buffer is
      -- relatively large, it's unlikey that we'd read an ESC without
      -- more bytes unless it's the user wanting to quit the program.
      return fiber.stop()
   end
   local kind = io.stdin:read_char()
   escape_handlers[kind](kind)
end

bind_keys("[", handle_csi, escape_handlers)

for i=0,255 do bind_keys(string.char(i), debug_keypress) end
bind_keys("q\3\31\4", fiber.stop)
bind_keys("\27", handle_escape_sequence)

function handle_input ()
   for c in io.stdin.read_char, io.stdin do
      global_handlers[c](c)
   end
   fiber.stop()
end

function redisplay()
end

function run (args)
   local opt = {}
   function opt.h (arg) print(usage) main.exit(1) end
   args = lib.dogetopt(args, opt, "h", {help='h'})

   if #args > 1 then print(usage) main.exit(1) end
   --local target_pid = select_snabb_instance(args[1])

   require('lib.fibers.file').install_poll_io_handler()
   require('lib.stream.compat').install()

   ui.interactive = S.stdin:isatty() and S.stdout:isatty()
   if ui.interactive then
      ui.saved_tc = assert(S.tcgetattr(S.stdin))
      local new_tc = makeraw(ui.saved_tc)
      assert(S.tcsetattr(S.stdin, 'drain', new_tc))
      scroll(1000)
   end

   fiber.spawn(update_snabb_state)
   fiber.spawn(handle_input)
   fiber.spawn(show_ui)

   if ui.interactive then
      fiber.main()
      assert(S.tcsetattr(S.stdin, 'drain', ui.saved_tc))
      bgcolordefault()
      fgcolordefault()
      io.stdout:write_chars('\n')
   else
      local sched = fiber.current_scheduler
      while #sched.next > 0 do
         sched:run()
         sched:schedule_tasks_from_sources()
      end
   end
end

function open_link_counters (counters, tree)
   -- Unmap and clear existing link counters.
   for _, link_frame in pairs(counters.links) do
      shm.delete_frame(link_frame)
   end
   counters.links = {}
   -- Open current link counters.
   for _, linkspec in ipairs(shm.children(tree.."/links")) do
      counters.links[linkspec] = shm.open_frame(tree.."/links/"..linkspec)
   end
end

function get_stats (counters)
   local new_stats = {}
   for _, name in ipairs({"configs", "breaths", "frees", "freebytes"}) do
      new_stats[name] = counter.read(counters.engine[name])
   end
   if counters.engine.latency then
      new_stats.latency = counters.engine.latency:snapshot()
   end
   new_stats.links = {}
   for linkspec, link in pairs(counters.links) do
      new_stats.links[linkspec] = {}
      for _, name
      in ipairs({"rxpackets", "txpackets", "rxbytes", "txbytes", "txdrop" }) do
         new_stats.links[linkspec][name] = counter.read(link[name])
      end
   end
   return new_stats
end

local global_metrics_row = {15, 15, 15}
function print_global_metrics (new_stats, last_stats)
   local frees = tonumber(new_stats.frees - last_stats.frees)
   local bytes = tonumber(new_stats.freebytes - last_stats.freebytes)
   local breaths = tonumber(new_stats.breaths - last_stats.breaths)
   print_row(global_metrics_row, {"Kfrees/s", "freeGbytes/s", "breaths/s"})
   print_row(global_metrics_row,
             {float_s(frees / 1000), float_s(bytes / (1000^3)), tostring(breaths)})
end

function summarize_latency (histogram, prev)
   local total = histogram.total
   if prev then total = total - prev.total end
   if total == 0 then return 0, 0, 0 end
   local min, max, cumulative = nil, 0, 0
   for count, lo, hi in histogram:iterate(prev) do
      if count ~= 0 then
	 if not min then min = lo end
	 max = hi
	 cumulative = cumulative + (lo + hi) / 2 * tonumber(count)
      end
   end
   return min, cumulative / tonumber(total), max
end

function print_latency_metrics (new_stats, last_stats)
   local cur, prev = new_stats.latency, last_stats.latency
   if not cur then return end
   local min, avg, max = summarize_latency(cur, prev)
   print_row(global_metrics_row,
             {"Min breath (us)", "Average", "Maximum"})
   print_row(global_metrics_row,
             {float_s(min*1e6), float_s(avg*1e6), float_s(max*1e6)})
   print("\n")
end

local link_metrics_row = {31, 7, 7, 7, 7, 7}
function print_link_metrics (new_stats, last_stats)
   print_row(link_metrics_row,
             {"Links (rx/tx/txdrop in Mpps)", "rx", "tx", "rxGb", "txGb", "txdrop"})
   for linkspec, link in pairs(new_stats.links) do
      if last_stats.links[linkspec] then
         local rx = tonumber(new_stats.links[linkspec].rxpackets - last_stats.links[linkspec].rxpackets)
         local tx = tonumber(new_stats.links[linkspec].txpackets - last_stats.links[linkspec].txpackets)
         local rxbytes = tonumber(new_stats.links[linkspec].rxbytes - last_stats.links[linkspec].rxbytes)
         local txbytes = tonumber(new_stats.links[linkspec].txbytes - last_stats.links[linkspec].txbytes)
         local drop = tonumber(new_stats.links[linkspec].txdrop - last_stats.links[linkspec].txdrop)
         print_row(link_metrics_row,
                   {linkspec,
                    float_s(rx / 1e6), float_s(tx / 1e6),
                    float_s(rxbytes / (1000^3)), float_s(txbytes / (1000^3)),
                    float_s(drop / 1e6)})
      end
   end
end

function pad_str (s, n, no_pad)
   local padding = math.max(n - s:len(), 0)
   return ("%s%s"):format(s:sub(1, n), (no_pad and "") or (" "):rep(padding))
end

function print_row (spec, args)
   for i, s in ipairs(args) do
      io.write((" %s"):format(pad_str(s, spec[i], i == #args)))
   end
   io.write("\n")
end

function float_s (n)
   return ("%.2f"):format(n)
end
