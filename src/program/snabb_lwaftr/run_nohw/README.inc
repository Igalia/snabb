Usage: run-nohw --help
       run-nohw --bt PATH --conf PATH --b4-if DEVICE --inet-if DEVICE [-v]

       --bt, -b PATH         Path to the file containing the binding table.
       --conf, -c PATH       Path to the lwAFTR configuration file.
       --b4-if, -B DEVICE    Name of the B4-side network interface.
       --inet-if, -I DEVICE  Name of the Internet-side network interface.
       --verbose, -v         Be verbose. Can be used multiple times.
       --help, -h            Show this help message.

    DEVICEs arguments have the form KIND:NAME, where the NAME is the name of
    an existing network interface, as seen by the operating system, and KIND
    one of the following:

       tap  The device is a TUN/TAP interface. It must be created before
            running the lwAFTR, and configured using using ip(8).

       raw  The device is any NIC which can be accessed at the link layer
            using RAW sockets.
