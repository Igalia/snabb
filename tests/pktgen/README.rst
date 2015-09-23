pktgen - A declarative packet generator
=======================================

``pktgen`` is a packet generator which allows creating streams of network
packets using a declarative approach. Packet wrangling is done using Scapy_,
making it possible to easily generate almost any kind of packet supported by
it.

.. contents::


Features
--------

* Support most of the packet types supported by Scapy_.
* Additional `elements <available elements_>`__ which allow defining
  complex package sets. 
* Define contents of packet flows in a declarative way (see
  `spec file syntax`_ below for an glimpse of the syntax).
* Output of packet streams to ``pcap`` dump files, the same format used by
  ``tcpdump`` and supprted by many network tools which use ``libpcap``.


Local dependencies
------------------

The ``pktgen-localdeps`` script can be used to run ``pktgen`` with the
dependencies installed in a local virtualenv_, which will be created in the
``.env`` subdirectory automatically. The script forwards the arguments to
``pktgen``.

It is possible to specify which Python interpreter to use by defining the
``PYTHON`` environment variable::

    PYTHON=/usr/local/bin/python2.7 ./pktgen-localdeps [...]


Spec file syntax
----------------

Packet generation spec files are written in the HiPack_ format, like in the
following example::

    # Comments span to the end of lines
    ip {
        .src "1.2.3.4"
        .dst "5.6.7.8"
        tcp {
            .flags = ""
            randbytes {
                .size 50
            }
        }
    }

Items are interpreted in the following way:

* Blocks (HiPack dictionaries) describe an element.
* Keys starting with a period (e.g. ``.flags``) are attributes of the
  element.
* A key without a leading period (e.g. ``tcp``) names the kind of the
  child element.
* A number of elements map to their Scapy_ `equivalents <Scapy elements_>`__,
  and support all the attributes accepted their Scapy counterparts.


Available elements
------------------

``raw``
~~~~~~~
Generates payload for packets with fixed ``data``. The strings used to
specify the data may contain hex escapes, allowing to include any binary
data.

Example::

    raw {
        .data "Unicode networked computers icon: \01\F5\A7 (U+1F5A7)"
    }

Packets with no payload can be created by using an empty string::

    raw { .data "" }


``randbytes``
~~~~~~~~~~~~~
Generates a payload of random bytes, of a given ``size``. Optionally it is
possible to specify a ``deviation``, which makes the size to be taken as an
average sample of a Gaussian distribution with the given deviation.

Example::

    randbytes {
        .size 50
        .deviation 10
    }


``pdist``
~~~~~~~~~
Picks from several choices which have an associated probability of being
chosen.

Example::

    pdist [
        { .probability 0.33, raw { .data "A" } }
        { .probability 0.66, raw { .data "B" } }
    ]


``tcpip-ack``
~~~~~~~~~~~~~
For each TCP/IP packet, yields each original packet followed by the
corresponding ACK packet flowing in the opposite direction. Generated
ACK packets have no payload.

The packets used as input for the ``tcpip-ack`` element must have both
TCP and IP framing (both v4 and v6 are supported), as in the following
example::

    tcpip-ack {
        ip {
            .src "1.2.3.4"
            .dst "6.7.8.9"
            tcp {
                .sport 80
                .dport 32000
                raw { .data "payload" }
            }
        }
    }


Scapy elements
~~~~~~~~~~~~~~

========= ================== ===========================
Element   Scapy constructor  Aliases
--------- ------------------ ---------------------------
``ipv4``  ``IP()``           ``ip``, ``ip4``
``ipv6``  ``IPv6()``         ``ip6``
``tcp``   ``TCP()``
========= ================== ===========================

A description of the additions on top of Scapy_ follows.

``tcp``
^^^^^^^
The ``tcp`` element supports generating varying sequence numbers. This
is indicated by setting the ``.seq`` attribute to a string value (instead
of a number) with the name of the method to use. The following methods
are supported:

``increasing``
    The sequence number is increased by one for each packet, starting
    from zero.
``random``
    The sequence number is a random number between 0 and 16386.

Example::

    tcp {
        .seq "increasing"
        raw { .data "payload" }
    }


.. _HiPack: http://hipack.org
.. _virtualenv: https://virtualenv.pypa.io/
.. _scapy: http://www.secdev.org/projects/scapy/

