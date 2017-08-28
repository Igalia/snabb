# Ethernet Apps

Sometimes Ethernet headers are just a bother.  If you're writing a
layer-3 network function, after NDP or ARP it doesn't much matter what
the ethernet headers are on a packet.  Pure L3 apps would sometimes like
to be able to deal with a packet just from L3 headers onward.  In those
cases, you can use the `apps.ethernet.ethernet.Remove` to cheaply strip
Ethernet headers from incoming packets, and
`apps.ethernet.ethernet.Insert` to re-add headers before sending out
packets.

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
