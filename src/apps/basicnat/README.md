# BasicNAT App (app.basicnat.basicnat)

The `BasicNAT` app implements basic NAT according to XXX.

## Configuration

For each port, BasicNAT accepts a public IP address (external) and a private IP address (internal):

- If `IP.destination` == `external IP` then `IP.destination` = `internal IP`.
- If `IP.source` == `internal IP` then `IP.source` = `external IP`.

In order to run it in SnabbNFV, it's necessary to pass a configuration file such as this (See `ports_example.cfg`):

```lua
return { 
	{ vlan = 431,
      mac_address = "52:54:00:00:00:01",
      port_id = "A",
      basicnat = {
		  proxy   = "192.168.0.1",
		  public  = "10.10.10.7",
		  private = "192.168.0.2",
	  }
   },
   { vlan = 431,
     mac_address = "52:54:00:00:00:02",
     port_id = "B",
     basicnat = {
         proxy   = "10.10.10.2",
         public  = "10.10.10.7",
         private = "192.168.0.2",
     }
   },
}
```

## Running locally

It is also possible to run it locally for testing purposes, using an input .pcap file.

```
sudo ./snabb snsh app.basicnat.basicnat input.pcap output.pcap <public> <private>
```

Example:

```
$ sudo ./snabb snsh apps/basicnat/main.lua icmp.pcap output.pcap 192.168.2.4 10.10.10.10
Changing: DST(192.168.2.4) => DST(10.10.10.10); SRC(10.10.10.10) => SRC(192.168.2.4)
link report:
	32 sent on basicnat.output -> outgoing.input (loss rate: 0%)
	32 sent on incoming.output -> basicnat.input (loss rate: 0%)
```
