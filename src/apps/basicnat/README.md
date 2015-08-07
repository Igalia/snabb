# BasicNAT App (app.basicnat.basicnat)

The `BasicNAT` app implements basic NAT according to RFC1631 [1].

## Configuration

The `ports.cfg` describes a network layout similar to the one that is used as an
example in the Section 2 of RFC1631.

                               \ | /
                             +---------------+
                             |Regional Router|
                             +---------------+
                           WAN |           | WAN
                               |           |
           Stub A .............|....   ....|............ Stub B
                               |           |
             {s=198.76.29.7,^  |           |  v{s=198.76.29.7,
              d=198.76.28.4}^  |           |  v d=198.76.28.4}
               +-----------------+       +-----------------+
               |Stub Router w/NAT|       |Stub Router w/NAT|
               +-----------------+       +-----------------+
                     |                         |
                     |  LAN               LAN  |
               -------------             -------------
                         |                 |
       {s=10.33.96.5, ^  |                 |  v{s=198.76.29.7,
        d=198.76.28.4}^ +--+             +--+ v d=10.81.13.22}
                        |--|             |--|
                       /____\           /____\
                     10.33.96.5       10.81.13.22

With the difference that Stub B is simplified, being a single host.

## Ports

Contents of `ports.cfg`:

```lua
return {
  -- Private host
  { vlan = 431,
    mac_address = "52:54:00:00:00:01",
    port_id = "A",
  },
  -- VMB
  -- Private network
  { vlan = 431,
    mac_address = "52:54:00:00:00:02",
    port_id = "B1",
  },
  -- VMB
  -- Public network
  { vlan = 432,
    mac_address = "52:54:00:00:00:03",
    port_id = "B2",
    basicnat = {
      public_ip  = "198.76.29.7",
      private_ip = "10.33.96.5",   -- VMA
      network    = "10.33.96.0/24",
    }
  },
  -- Public host
  { vlan = 432,
    mac_address = "52:54:00:00:00:04",
    port_id = "C",
  },
}
```

VMB is the host doing the NAT. To do NAT, it's necessary that the host counts
with 2 network interfaces: one for the private network, another one with a
public IP address. The port doing the NAT should be configured with the
following parameters:

* `public_ip`: Public address that will be used as source address for outbound
packets. This address is the same as VMB/eth1 (interface with a public IP address).
* `private_ip`: Private address that will be used as destination address for
inbound packets. This address is the same as VMA/eht0 (masqueraded host).
* `network`: Address of the private network VMA belongs to.

### Running it in SnabbNFV

Launch 3 VMs (VMA, VMB, VMC) with the following command:

```
sudo \
    numactl --cpunodebind=0 --membind=0 \
        /home/igalia/dpino/snabb-nfv/qemu/x86_64-softmmu/qemu-system-x86_64 \
            -m 1024 -kernel /opt/bench/bzImage \
                -append 'earlyprintk root=/dev/vda rw console=ttyS0 ip=fe80::5054:ff:fe00:0' \
            -numa node,memdev=mem \
                -object memory-backend-file,id=mem,size=1024M,mem-path=/hugetlbfs,share=on \
            -netdev type=vhost-user,id=net0,chardev=char0 -chardev socket,
                id=char0,path=/home/igalia/dpino/socket/vhost_A.sock,server \
                -device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:01 \
            -M pc -smp 1 -cpu host --enable-kvm \
            -serial telnet:localhost:6060,server,nowait \
            -drive if=virtio,file=/home/igalia/dpino/test/vma.img -nographic
```

The VM doing the NAT (VMB) should be configured with two network cards:

```
sudo \
    numactl --cpunodebind=0 --membind=0 \
        /home/igalia/dpino/snabb-nfv/qemu/x86_64-softmmu/qemu-system-x86_64 \
            -m 1024 -kernel /opt/bench/bzImage \
                -append 'earlyprintk root=/dev/vda rw console=ttyS0 ip=fe80::5054:ff:fe00:1' \
            -numa node,memdev=mem \
                -object memory-backend-file,id=mem,size=1024M,mem-path=/hugetlbfs,share=on \
            -netdev type=vhost-user,id=net0,chardev=char0 -chardev socket,
                id=char0,path=/home/igalia/dpino/socket/vhost_B1.sock,server \
                -device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:02 \
            -netdev type=vhost-user,id=net1,chardev=char1 -chardev socket,
                id=char1,path=/home/igalia/dpino/socket/vhost_B2.sock,server \
                -device virtio-net-pci,netdev=net1,mac=52:54:00:00:00:03 \
            -M pc -smp 1 -cpu host --enable-kvm \
            -serial telnet:localhost:6061,server,nowait \
            -drive if=virtio,file=/home/igalia/dpino/test/vmb.img -nographic
```

Once the VMs were launches, run `snabb traffic`:

```
 sudo numactl --cpunodebind=0 --membind=0 \
    snabb snabbnfv traffic -k 10 0000:04:00.0 ports.cfg \
    /home/igalia/dpino/socket/vhost_%s.sock
```

Were 0000:04:00.0 is the id of the 10-Gbps network card.

Once snabbnfv is running, log into VMA and ping VMC:

```
telnet localhost 6060

$ ping 198.76.29.4
```

## Running it locally

It is also possible to run it locally for testing purposes, using an input
`.pcap` file.

There are two example .pcap files at apps/basicnat/pcap:
* `echo-request.pcap`
* `echo-reply.pcap`

```
sudo ./snabb snsh apps/basicnat/main.lua \
    apps/basicnat/pcap/echo-request.pcap /tmp/out.pcap \
    198.76.29.7 10.33.96.5 10.33.96.0/24
```

```
sudo ./snabb snsh apps/basicnat/main.lua \
    apps/basicnat/pcap/echo-reply.pcap /tmp/out.pcap \
    198.76.29.7 10.33.96.5 10.33.96.0/24
```

Example:

```
$ sudo ./snabb snsh apps/basicnat/main.lua apps/basicnat/pcap/echo-reply.pcap \
    /tmp/out.pcap 198.76.29.7 10.33.96.5 10.33.96.0/24
Changing: SRC(10.33.96.5) => SRC(198.76.29.7)
Changing: DST(198.76.29.7) => DST(10.33.96.5)
link report:
    24 sent on basicnat.output -> outgoing.input (loss rate: 0%)
    24 sent on incoming.output -> basicnat.input (loss rate: 0%)
```

[1] The IP Network Address Translator (NAT) https://tools.ietf.org/html/rfc1631
