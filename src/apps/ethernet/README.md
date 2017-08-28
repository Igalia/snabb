# Ethernet Apps

Sometimes Ethernet headers are just a bother.  If you're writing a
layer-3 network function, after NDP or ARP it doesn't much matter what
the ethernet headers are on a packet.  Pure L3 apps would sometimes like
to be able to deal with a packet just from L3 headers onward.  In those
cases, you can use the `apps.ethernet.ethernet.Remove` to cheaply strip
Ethernet headers from incoming packets, and
`apps.ethernet.ethernet.Insert` to re-add headers before sending out
packets.

Additionally, there are three VLAN related apps: `Tagger`, `Untagger`
and `VlanMux`.  The `Tagger` and `Untagger` apps add or remove a VLAN
tag whereas the `VlanMux` app can multiplex and demultiplex packets to
different output ports based on tag.

## Insert (apps.ethernet.ethernet)

The `Insert` app adds an Ethernet header to packets received on its
`input` port and transmits them on its `output` port.

### Configuration

—  Key **ether_type**

*Required*.  Ethernet type with which to tag incoming packets.  May be
given as a number, for example `0x0800` for IPv4, or as a string, for
example `"IPv4"`, `"ARP"`, or `"IPv6"`.  Strings are not case-sensitive;
`"ipv4"` works too.

—  Key **src_addr**

*Optional*.  Source address to write to the inserted Ethernet header.
Defaults to a randomly generated locally administered unicast address.
May be given as a string, for example `"00:01:02:03:04:05"`, or as an
FFI array of 6 bytes.
 
—  Key **dst_addr**

*Optional*.  Destination address to write to the inserted Ethernet
header.  Defaults to `00:00:00:00:00:00`.
 
## Remove (apps.ethernet.ethernet)

The `Remove` app strips ethernet headers from packets received on its
`input` and transmits the stripped packets on the `output` port.  It
checks to make sure that incoming packets are of the correct type;
packets that aren't of the correct type will be dropped, incrementing
the `drop` counter.

### Configuration

—  Key **ether_type**

*Required*.  Ethernet type to expect on incoming packets.  May be given
as a number, for example `0x0800` for IPv4, or as a string, for example
`"IPv4"`, `"ARP"`, or `"IPv6"`.  Strings are not case-sensitive;
`"ipv4"` works too.

## Tagger (apps.vlan.vlan)

The `Tagger` app adds a VLAN tag, with the configured value, to packets
received on its `input` port and transmits them on its `output` port.

### Configuration

—  Key **tag**

*Required*. VLAN tag to add or remove from the packet.


## Untagger (apps.vlan.vlan)

The `Untagger` app checks packets received on its `input` port for a VLAN tag,
removes it if it matches with the configured VLAN tag and transmits them on its
`output` port. Packets with other VLAN tags than the configured tag will be
dropped.

### Configuration

—  Key **tag**

*Required*. VLAN tag to add or remove from the packet.


## VlanMux (apps.vlan.vlan)

Despite the name, the `VlanMux` app can act both as a multiplexer, i.e. receive
packets from multiple different input ports, add a VLAN tag and transmit them
out onto one, as well as receiving packets from its `trunk` port and
demultiplex it over many output ports based on the VLAN tag of the received
packet.

Packets received on its `trunk` input port with Ethernet type 0x8100 are
inspected for the VLAN tag and transmitted on an output port `vlanX` where *X*
is the VLAN tag parsed from the packet. If no such output port exists the
packet is dropped. Received packets with an Ethernet type other than 0x8100 are
transmitted on its `native` output port,

Packets received on its `native` input port are transmitted verbatim on its
`trunk` output port.

Packets received on input ports named `vlanX`, where *X* is a VLAN tag, will
have the VLAN tag *X* added and then be transmitted on its `trunk` output port.

There is no configuration for the `VlanMux` app, simply connect it to your
other apps and it will base its actions on the name of the ports.
