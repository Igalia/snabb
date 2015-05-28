module(..., package.seeall)

local bit    = require("bit")

-- Utils

local function uint32(a, b, c, d)
   return a * 2^24 + b * 2^16 + c * 2^8 + d
end

local function uint16(a, b)
   return a * 2^8 + b
end

-- IP

local function ip_str(a, b, c, d)
   return ("%d.%d.%d.%d"):format(a, b, c, d)
end

local function src_ip_str(p)
   return ip_str(p[26], p[27], p[28], p[29])
end

local function dst_ip_str(p)
   return ip_str(p[30], p[31], p[32], p[33])
end

local function length(p)
   return uint16(p[16], p[17])
end

local function protocol(p)
   return p[23]
end

-- TCP

local PROTO = {
   TCP = 0x06,
   UDP = 0x11
}

local function src_port(p)
   return uint16(p[34], p[35])
end

local function dst_port(p)
   return uint16(p[36], p[37])
end

local function seq(p)
   return uint32(p[38], p[39], p[40], p[41])
end

local function ack(p)
   return uint32(p[42], p[43], p[44], p[45])
end

-- TCP_FLAGS

local TCP_FIN     = 0x01
local TCP_SYN     = 0x02
local TCP_RST     = 0x04
local TCP_PSH     = 0x08
local TCP_ACK     = 0x10
local TCP_URG     = 0x20
local TCP_ECE     = 0x40
local TCP_CWR     = 0x80
local TCP_NS      = 0xFF

local function flag(p)
   return bit.band(p[47], 0xFF)
end

local function tcpflags(p, flag)
   return bit.band(bit.band(p[47], 0x3F), flag) == flag
end

-- TCP connection negotiation

local function is_fin(p)
   return tcpflags(p, TCP_FIN)
end

local function is_syn(p)
   return tcpflags(p, TCP_SYN)
end

local function is_rst(p)
   return tcpflags(p, TCP_RST)
end

local function is_psh(p)
   return tcpflags(p, TCP_PSH)
end

local function is_ack(p)
   return tcpflags(p, TCP_ACK)
end

local function is_urg(p)
   return tcpflags(p, TCP_URG)
end

local function is_ece(p)
   return tcpflags(p, TCP_ECE)
end

local function is_cwr(p)
   return tcpflags(p, TCP_CWR)
end

--

local DEBUG = true

local function debug(str)
   if DEBUG then print("### "..str) end
end

Conntrack = {}

function Conntrack:new(arg)
   local o = {}
   o.conns = {}
   o.three_way_handshake = {}
   o.stats = {
      conns = {
         udp = 0,
         tcp = {
            opened = 0,
            closed = 0,
         },
      },
      packets = {
         any = 0,
         udp = 0,
         tcp = 0
      },
      timestart = os.time(),
   }
   return setmetatable(o, { __index = Conntrack })
end

local connection_id = (function()
   local count = 0
   return function()
      count = count + 1
      return "conn_"..count
   end
end)()

-- A packet id is defined by the tuple { src_ip; src_port; dst_ip; dst_port }
local function packet_id(p, opts)
   opts = opts or {}
   local src = src_ip_str(p)..":"..src_port(p)
   local dst = dst_ip_str(p)..":"..dst_port(p)
   if opts.dst_src then
      return dst.."-"..src
   end
   return src.."-"..dst
end

function Conntrack:has_connection(packet)
   self.stats.packets.any = self.stats.packets.any + 1

   local p = packet.data      -- Get payload
   if protocol(p) == PROTO.TCP then
      return self:has_connection_tcp(p)
   else
      return self:has_connection_udp(p)
   end
end

function Conntrack:has_connection_udp(p, p_id)
   self.stats.packets.udp = self.stats.packets.udp + 1
   local exists, p_id = self:connection_exists(p)
   if not exists then
      self.conns[p_id] = connection_id()
      self.stats.conns.udp = self.stats.conns.udp + 1
   end
   return true
end

function Conntrack:connection_exists(p)
   local p_id = packet_id(p)
   if self.conns[p_id] then return true end
   p_id = packet_id(p, { dst_src = true })
   return self.conns[p_id], p_id
end

function Conntrack:remove_connection(p)
   local function remove(p_id)
      if self.conns[p_id] then
         self.conns[p_id] = nil
         return p_id
      end
   end
   local p_id = remove(packet_id(p))
   if not p_id then
      return remove(packet_id(p, { dst_src = true }))
   end
   return p_id
end

function Conntrack:has_connection_tcp(p)
   self.stats.packets.tcp = self.stats.packets.tcp + 1
   local p_id = packet_id(p)
   -- Receive ACK and SYN-RECEIVED
   if is_ack(p) and self.three_way_handshake[p_id] then
      self.three_way_handshake[p_id] = nil
      if self:create_connection_tcp(p) then
         self.stats.conns.tcp.opened = self.stats.conns.tcp.opened + 1
      end
      return true
   -- From CLOSED to SYN-SENT
   elseif is_syn(p) then
      print("syn: "..p_id)
   elseif is_syn(p) and not is_ack(p) then
      self.three_way_handshake[p_id] = seq(p) + 1
   -- From SYN-SENT to SYN-RECEIVED
   elseif is_syn(p) and is_ack(p) then
      p_id = packet_id(p, { dst_src = true })
      if self.three_way_handshake[p_id] == ack(p) then
         self.three_way_handshake[p_id] = seq(p) + 1
      elseif not self.three_way_handshake[p_id] then
         p_id = packet_id(p)
         if self.three_way_handshake[p_id] == ack(p) then
            self.three_way_handshake[p_id] = seq(p) + 1
         else
            local expected = self.three_way_handshake[p_id] or ""
            local real = ack(p) or ""
            -- print("p_id: "..p_id.."; real: "..real.."; expected: "..expected)
         end
      else
         local expected = self.three_way_handshake[p_id] or ""
         local real = ack(p) or ""
         -- print("else")
         -- print("p_id: "..p_id.."; real: "..real.."; expected: "..expected)
      end
   -- FIN-WAIT-1 or CLOSE-WAIT
   elseif is_fin(p) and is_ack(p) then
      if self:remove_connection(p) then
         self.stats.conns.tcp.closed = self.stats.conns.tcp.closed + 1
      end
   elseif is_rst(p) then
      if self:remove_connection(p) then
         self.stats.conns.tcp.closed = self.stats.conns.tcp.closed + 1
      end
   else
      return self:connection_exists(p)
   end
   return false
end

function Conntrack:create_connection_tcp(p)
   local exists, p_id = self:connection_exists(p)
   if not exists then
      self.conns[p_id] = connection_id()
      self.three_way_handshake[p_id] = nil
      return true
   end
end

function Conntrack:n_packets()
   return self.stats.packets.any
end

function Conntrack:n_packets_tcp()
   return self.stats.packets.tcp
end

function Conntrack:n_packets_udp()
   return self.stats.packets.udp
end

function Conntrack:n_conns_tcp_opened()
   return self.stats.conns.tcp.opened
end

function Conntrack:n_conns_tcp_closed()
   return self.stats.conns.tcp.closed
end

function Conntrack:n_conns_udp()
   return self.stats.conns.udp
end

function Conntrack:timestart()
   return self.stats.timestart
end

return Conntrack
