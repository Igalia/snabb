module(..., package.seeall)

local constants = require("apps.lwaftr.constants")

local bit = require("bit")
local ffi = require("ffi")

local band, rshift, bswap = bit.band, bit.rshift, bit.bswap
local cast = ffi.cast

local uint16_ptr_t = ffi.typeof("uint16_t*")
local uint32_ptr_t = ffi.typeof("uint32_t*")

function get_ihl_from_offset(pkt, offset)
   local ver_and_ihl = pkt.data[offset]
   return band(ver_and_ihl, 0xf) * 4
end

-- The rd16/wr16/rd32/wr32 functions are provided for convenience.
-- They do NO conversion of byte order; that is the caller's responsibility.
function rd16(offset)
   return cast(uint16_ptr_t, offset)[0]
end

function wr16(offset, val)
   cast(uint16_ptr_t, offset)[0] = val
end

function rd32(offset)
   return cast(uint32_ptr_t, offset)[0]
end

function wr32(offset, val)
   cast(uint32_ptr_t, offset)[0] = val
end

local to_uint32_buf = ffi.new('uint32_t[1]')
local function to_uint32(x)
   to_uint32_buf[0] = x
   return to_uint32_buf[0]
end

function htons(s) return rshift(bswap(s), 16) end
function htonl(s) return to_uint32(bswap(s)) end

function keys(t)
   local result = {}
   for k,_ in pairs(t) do
      table.insert(result, k)
   end
   return result
end

local uint64_ptr_t = ffi.typeof('uint64_t*')
function ipv6_equals(a, b)
   local a, b = ffi.cast(uint64_ptr_t, a), ffi.cast(uint64_ptr_t, b)
   return a[0] == b[0] and a[1] == b[1]
end

-- Local bindings for constants that are used in the hot path of the
-- data plane.  Not having them here is a 1-2% performance penalty.
local o_ethernet_ethertype = constants.o_ethernet_ethertype
local n_ethertype_ipv4 = constants.n_ethertype_ipv4
local n_ethertype_ipv6 = constants.n_ethertype_ipv6

function is_ipv6(pkt)
   return rd16(pkt.data + o_ethernet_ethertype) == n_ethertype_ipv6
end
function is_ipv4(pkt)
   return rd16(pkt.data + o_ethernet_ethertype) == n_ethertype_ipv4
end


-- The following functions make any table an element of a linked list:
--
--  * Members "_linked_list_next", and "_linked_list_prev" are used to
--    keep the links between items -- do not modify them manually.
--
--  * Functions which modify the list return the (possibly updated)
--    list first item. Make sure to assign the return value from them
--    to your reference to the "list head item".
--
function linked_list_append(list_head, list_item)
   if list_head then
      list_item._linked_list_next = list_head
      list_item._linked_list_prev = list_head._linked_list_prev
      list_item._linked_list_prev._linked_list_next = list_item
      list_head._linked_list_prev = list_item
   else
      -- Empty list
      list_item._linked_list_next = list_item
      list_item._linked_list_prev = list_item
      list_head = list_item
   end
   return list_head
end

function linked_list_remove(list_head, list_item)
   if list_item == list_item._linked_list_prev then
      -- There's only one element in the list.
      list_head = nil
   else
      list_item._linked_list_prev._linked_list_next = list_item._linked_list_next
      list_item._linked_list_next._linked_list_prev = list_item._linked_list_prev
      if list_item == list_head then
         list_head = list_item._linked_list_next
      end
   end

   list_item._linked_list_next = nil
   list_item._linked_list_prev = nil
   return list_head
end

function linked_list_first(list_head)
   return list_head
end

function linked_list_last(list_head)
   return list_head._linked_list_prev
end

function linked_list_is_empty(list_head)
   return not list_head
end

function linked_list_next(list_head, list_item)
   if list_item == linked_list_last(list_head) then
      return nil
   else
      return list_item._linked_list_next
   end
end

function linked_list_prev(list_head, list_item)
   if list_item == linked_list_first(list_head) then
      return nil
   else
      return list_item._linked_list_prev
   end
end


function selftest()
   print("linked_list_* functions")
   do
      local function check_list_links(l)
         if l then
            local item, last = linked_list_first(l), linked_list_last(l)
            while item do
               assert(item._linked_list_next)
               assert(item._linked_list_next._linked_list_prev == item)
               assert(item._linked_list_prev)
               assert(item._linked_list_prev._linked_list_next == item)
               item = linked_list_next(l, item)
            end
         end
         return l
      end

      print("  append (empty)")
      local l = nil
      l = assert(check_list_links(linked_list_append(l, { item=1 })))
      assert(not linked_list_is_empty(l))
      assert(l == linked_list_last(l))
      assert(l.item == 1)

      print("  append (non-empty)")
      local i = { item=2 }
      l = assert(check_list_links(linked_list_append(l, i)))
      assert(not linked_list_is_empty(l))
      assert(i == linked_list_last(l))

      print("  remove (last item)")
      l = assert(check_list_links(linked_list_remove(l, i)))
      assert(linked_list_last(l) == linked_list_first(l))

      print("  remove (last item, leave empty)")
      l = linked_list_remove(l, linked_list_last(l))
      assert(linked_list_is_empty(l))
      assert(l == nil)

      print("  remove (all)")
      for i, _ in ipairs { 1, 2, 3, 4 } do
         l = assert(check_list_links(linked_list_append(l, { item=i })))
      end
      i = 0
      while not linked_list_is_empty(l) do
         l = check_list_links(linked_list_remove(l, linked_list_last(l)))
         i = i + 1
      end
      assert(i == 4)
      assert(l == nil)

      print("  remove (first item)")
      for i, _ in ipairs { 1, 2, 3, 4 } do
         l = assert(check_list_links(linked_list_append(l, { item=i })))
      end
      l = assert(check_list_links(linked_list_remove(l, linked_list_first(l))))
      i = 0
      while not linked_list_is_empty(l) do
         l = linked_list_remove(l, linked_list_last(l))
         i = i + 1
      end
      assert(i == 3)
      assert(l == nil)

      print("  remove (first item, one-item list)")
      l = assert(check_list_links(linked_list_append(l, { item=1 })))
      l = linked_list_remove(l, linked_list_first(l))
      assert(linked_list_is_empty(l))
      assert(l == nil)

      print("  remove (item in the middle)")
      l = assert(check_list_links(linked_list_append(l, { item=1 })))
      i = { item = 2 }
      l = assert(check_list_links(linked_list_append(l, i)))
      l = assert(check_list_links(linked_list_append(l, { item=3 })))
      l = assert(check_list_links(linked_list_remove(l, i)))
      i = 0
      while not linked_list_is_empty(l) do
         l = linked_list_remove(l, linked_list_last(l))
         i = i + 1
      end
      assert(i == 2)
      assert(l == nil)
   end
end
