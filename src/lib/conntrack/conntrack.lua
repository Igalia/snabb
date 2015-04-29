module(..., package.seeall)

local app = require("core.app")
local config = require("core.config")
local pcap = require("apps.pcap.pcap")
local link = require("core.link")
local packet = require("core.packet")
local bit = require("bit")

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

local TCP_SYN     = 0x02
local TCP_ACK     = 0x10
local TCP_SYN_ACK = 0x12

local function tcpflags(p, flag)
   return bit.band(p[47], 0x3F) == flag
end

-- TCP connection negotiation

local function is_syn(p)
   return tcpflags(p, TCP_SYN)
end

local function is_ack(p)
   return tcpflags(p, TCP_ACK)
end

local function is_syn_ack(p)
   return tcpflags(p, TCP_SYN_ACK)
end

--

Conntrack = {}

function Conntrack:new(arg)
   local o = {}
   o.conns = {}   
   o.three_way_handshake = {}
   o._n_connections = 0
   o._n_packets = 0
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

function Conntrack:is_registered(p)
   local p_id = packet_id(p)
   if self.conns[p_id] then return true end
   p_id = packet_id(p, { dst_src = true })
   return self.conns[p_id]
end

function Conntrack:has_connection(packet)
   self._n_packets = self._n_packets + 1

   local p = packet.data      -- Get payload
   local p_id = packet_id(p)  -- Get packet id 

   if protocol(p) == PROTO.TCP then
      return self:has_connection_tcp(p_id, p)
   else
      return self:has_connection_udp(p_id, p)
   end
end

function Conntrack:has_connection_udp(p_id, p)
   if not self.conns[p_id] then
      self.conns[p_id] = connection_id()
      -- Create new connection
      self._n_connections = self._n_connections + 1
   end
   return true
end

function Conntrack:has_connection_tcp(p_id, p)
   if self.three_way_handshake[p_id] then
      if is_syn_ack(p) then
         if (self.three_way_handshake[p_id] == ack(p)) then
            self.three_way_handshake[p_id] = seq(p) + 1
            return false
         end
      end
      if is_ack(p) then
         if (self.three_way_handshake[p_id] == seq(p)) then
            -- The connection was established, create a new connection indexed by id
            self.conns[p_id] = connection_id()
            self._n_connections = self._n_connections + 1
            self.three_way_handshake[p_id] = nil
            return false
         end
      end
   elseif is_syn(p) then
      self.three_way_handshake[p_id] = seq(p) + 1
   else 
      return self:is_registered(p)
   end
   return false
end

function Conntrack:n_connections()
   return self._n_connections
end

function Conntrack:n_packets()
   return self._n_packets
end

return Conntrack
