# The IP server: the first layer of the network stack above the network
# server. It registers as "ip", protocol IP_PROTOCOL, once it has found
# "net", learned the interface's address and become its listener
# (NT_LISTEN); clients find it by that name (SYS_LOOKUP).
#
# It speaks ARP, ICMP echo and UDP over IPv4: it answers ARP requests
# for its own address and keeps what ARP tells it in a small cache, it
# answers pings, and IP_PING sends one for a client (include/layout.s).
# Its address is 10.0.0.2/24 with gateway 10.0.0.1 until IP_CONFIG says
# otherwise.
#
# UDP: a process binds one port (IP_BIND), sends from it (IP_SEND) and
# receives what comes to it (IP_RECEIVE). A datagram for a process with
# no receive waiting is kept in one of IPD_SLOTS slots in the server's
# block window 0, and given to its next receive, oldest first; one that
# finds no free slot is dropped, as UDP allows. A datagram to port 7
# that no process has bound is sent straight back: the echo service.
# A send to a host whose Ethernet address is not known waits for ARP;
# one such send waits at a time.
#
# Like every server it waits only in its own receive. The network server
# notifies it (NOTE_SIGNAL) when a frame waits, and its NT_RECEIVE then
# takes the frame at once; a ping's time limit is its alarm (SYS_ALARM),
# which comes as NOTE_ALARM, set for the earliest of everything that
# waits for a time (ip_rearm). One ping is under way at a time: it waits
# for the next hop's address first, if the cache lacks it, then for the
# echo reply. What waits for ARP is looked at again before each receive.
#
# Frames are octets, one per tryte, as the network server's are; fields
# of more than one octet are big-endian, and ip_getn and ip_putn read
# and write them.
#
# Not a program on its own: a build includes it in a program's section.
# Its labels all start with ip_, and its constants with IPD_, since it
# shares the build's symbols.

        .compress
        .gp   USER_GP

        .equ  IPD_NONE, -1             # no process, no hop, no entry
        .equ  IPD_ARP, 1               # ip_pstate: waiting for the hop's address
        .equ  IPD_ECHO, 2              # ... for the echo reply
        .equ  IPD_LIMIT, 4294967296    # 2^32: addresses are below it
        .equ  IPD_ADDR, 167772162      # 10.0.0.2
        .equ  IPD_GATEWAY, 167772161   # 10.0.0.1
        .equ  IPD_PREFIX, 24
        .equ  IPD_TTL, 64
        .equ  IPD_DATA, 56             # octets of data a ping carries
        .equ  IPD_ARPS, 8              # entries in the ARP cache
        .equ  IPD_BROADCAST, 16777215  # ff:ff:ff, half an address
        .equ  IPD_TARP, 2054           # Ethernet types: 0x0806,
        .equ  IPD_TIP, 2048            # and 0x0800
        .equ  IPD_AFORM, 134219268     # ARP for IPv4 on Ethernet: 0800 06 04
        .equ  IPD_UDP, 17              # the IP protocols: UDP,
        .equ  IPD_ICMP, 1              # and ICMP
        .equ  IPD_ECHOPORT, 7          # the echo service's port
        .equ  IPD_EPHEMERAL, 49152     # bind(0) chooses from here up
        .equ  IPD_ARPWAIT, 100000      # ticks a send waits for ARP
        .equ  IPD_UMAX, 1472           # octets of data a datagram carries
        .equ  IPD_SLOTS, 12            # datagrams kept for later receives,
        .equ  IPD_SLOT, 1600           # each in this many trytes of window 0
        .equ  IPD_QBASE, V_BLOCK + BLOCK_T0   # where slot 0 starts
        .assert IPD_SLOTS * IPD_SLOT <= PAGE, "the UDP slots overflow window 0"
        .assert IPD_UMAX + 6 <= IPD_SLOT, "a UDP slot holds a whole datagram"

        # Where things are in a frame: the Ethernet header,
        .equ  IPD_DST, 0
        .equ  IPD_SRC, 6
        .equ  IPD_TYPE, 12
        .equ  IPD_HDR, 14
        # an ARP message after it,
        .equ  IPD_AHW, 14
        .equ  IPD_APROTO, 16           # the protocol and both sizes: IPD_AFORM
        .equ  IPD_AOP, 20              # 1 a request, 2 a reply
        .equ  IPD_ASHA, 22
        .equ  IPD_ASPA, 28
        .equ  IPD_ATHA, 32
        .equ  IPD_ATPA, 38
        .equ  IPD_ALEN, 42
        # or an IPv4 header,
        .equ  IPD_VHL, 14
        .equ  IPD_TOS, 15
        .equ  IPD_TOTAL, 16
        .equ  IPD_IDENT, 18
        .equ  IPD_FRAG, 20
        .equ  IPD_TTLAT, 22
        .equ  IPD_PROTO, 23            # 1 for ICMP
        .equ  IPD_CSUM, 24
        .equ  IPD_ISRC, 26
        .equ  IPD_IDST, 30
        .equ  IPD_IHDR, 34             # past a header without options
        # and an ICMP message after that, from its start.
        .equ  IPD_CTYPE, 0             # 8 an echo request, 0 its reply
        .equ  IPD_CCSUM, 2
        .equ  IPD_CID, 4
        .equ  IPD_CSEQ, 6
        .equ  IPD_CDATA, 8
        # A UDP header, from its start, and the data after it.
        .equ  IPD_USPORT, 0
        .equ  IPD_UDPORT, 2
        .equ  IPD_ULEN, 4
        .equ  IPD_UCSUM, 6
        .equ  IPD_UDATA, 8
        # A client's datagram: the other end's address and port, then data.
        .equ  IPD_CLIENT, IPD_IHDR + IPD_UDATA - 6   # where ip_tx holds one

ip_main:
        li    a0, SYS_NAME             # for ps: a program of the image
        la    a1, ip_myname            # has no argv[0] to name it
        sys
        li    a0, SYS_LOOKUP
        la    a1, ip_netname
        li    a2, LOOKUP_WAIT
        sys
        bltz  a0, ip_quit
        sw    a0, ip_net
        li    t0, NET_PROTOCOL
        beq   a1, t0, 1f
        li    a0, E_INVAL              # a network server it would misread
        j     ip_quit
1:      li    a0, SYS_CALL
        lw    a1, ip_net
        li    a2, NT_ADDRESS
        sys
        bltz  a0, ip_quit
        sw    a1, ip_machi
        sw    a2, ip_maclo
        li    a0, SYS_CALL
        lw    a1, ip_net
        li    a2, NT_LISTEN
        sys
        bltz  a0, ip_quit
        li    a0, SYS_WINDOW           # for the UDP slots
        li    a1, 0
        sys
        bltz  a0, ip_quit
        li    a0, SYS_REGISTER
        la    a1, ip_name
        li    a2, IP_PROTOCOL
        sys
        bgez  a0, ip_wait
ip_quit:                               # a0: why it cannot serve
        mv    a1, a0
        li    a0, SYS_EXIT
        sys

ip_wait:
        li    sp, USER_SP
        lw    t0, ip_spid              # a send that ARP has answered for
        bltz  t0, 1f
        lw    a0, ip_shop
        call  ip_lookup
        bgez  a0, ip_usendnow
1:      lw    t0, ip_pstate            # a ping that ARP has answered for
        li    t1, IPD_ARP
        bne   t0, t1, 2f
        lw    a0, ip_hop
        call  ip_lookup
        bgez  a0, ip_echo
2:      li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, ip_notice
        mv    s0, a0                   # s0: the caller
        li    a5, E_INVAL
        li    t0, IP_PING
        beq   a1, t0, ip_ping
        li    t0, IP_ADDRESS
        beq   a1, t0, ip_address
        li    t0, IP_BIND
        beq   a1, t0, ip_bind
        li    t0, IP_SEND
        beq   a1, t0, ip_usend
        li    t0, IP_RECEIVE
        beq   a1, t0, ip_urecv
        li    t0, IP_CONFIG
        bne   a1, t0, ip_answer
        blez  a2, ip_answer            # config: an address,
        li    t0, IPD_LIMIT
        bge   a2, t0, ip_answer
        bltz  a3, ip_answer            # a prefix length,
        li    t0, 32
        bgt   a3, t0, ip_answer
        bltz  a4, ip_answer            # and a gateway or 0
        li    t0, IPD_LIMIT
        bge   a4, t0, ip_answer
        sw    a2, ip_addr
        sw    a3, ip_prefix
        sw    a4, ip_gateway
        li    a5, 0

# ip_answer: reply a5 to process s0, and go back to waiting.
ip_answer:
        li    a0, SYS_REPLY
        mv    a1, s0
        mv    a2, a5
        sys
        j     ip_wait

ip_address:
        li    a0, SYS_REPLY
        mv    a1, s0
        li    a2, 0
        lw    a3, ip_addr
        lw    a4, ip_prefix
        lw    a5, ip_gateway
        sys
        j     ip_wait

# ip_ping: ping(address a2, seq a3, wait a4) for process s0.
ip_ping:
        li    a5, E_BUSY
        lw    t0, ip_pinger
        bgez  t0, ip_answer
        li    a5, E_INVAL
        blez  a2, ip_answer
        li    t0, IPD_LIMIT
        bge   a2, t0, ip_answer
        bltz  a3, ip_answer
        li    t0, 65535
        bgt   a3, t0, ip_answer
        blez  a4, ip_answer
        sw    a2, ip_target
        sw    a3, ip_seq
        mv    s1, a4                   # s1: how long it may take
        mv    a0, a2
        call  ip_route
        li    a5, E_NOROUTE
        bltz  a0, ip_answer
        sw    a0, ip_hop
        sw    s0, ip_pinger
        csrr  t0, time
        add   t0, t0, s1
        sw    t0, ip_pdead
        call  ip_rearm
        lw    a0, ip_hop
        call  ip_lookup
        bgez  a0, ip_echo              # its address is known
        li    t0, IPD_ARP
        sw    t0, ip_pstate
        li    a0, 1                    # ask for it
        lw    a3, ip_hop
        call  ip_arpsend
        mv    a5, a0
        bltz  a0, ip_done
        j     ip_wait

# ip_echo: send the ping's echo request to the hop at Ethernet address
# a1 (high half), a2 (low half), and wait for its reply.
ip_echo:
        la    s1, ip_tx
        mv    a0, s1
        call  ip_putmac
        call  ip_ethtail
        li    a0, IPD_IHDR - IPD_HDR + IPD_CDATA + IPD_DATA
        li    a1, 1
        lw    a2, ip_target
        call  ip_iphead
        addi  s2, s1, IPD_IHDR         # s2: the ICMP message
        li    t0, 8
        st    t0, IPD_CTYPE(s2)
        st    zero, IPD_CTYPE + 1(s2)  # its code
        st    zero, IPD_CCSUM(s2)
        st    zero, IPD_CCSUM + 1(s2)
        addi  a0, s2, IPD_CID          # the identifier: the caller
        lw    a1, ip_pinger
        li    a2, 2
        call  ip_putn
        addi  a0, s2, IPD_CSEQ
        lw    a1, ip_seq
        li    a2, 2
        call  ip_putn
        li    t0, 0                    # the data: 0, 1, 2, ...
1:      add   t1, s2, t0
        st    t0, IPD_CDATA(t1)
        addi  t0, t0, 1
        li    t1, IPD_DATA
        blt   t0, t1, 1b
        mv    a0, s2
        li    a1, IPD_CDATA + IPD_DATA
        li    a2, 0
        call  ip_sum
        mv    a1, a0
        addi  a0, s2, IPD_CCSUM
        li    a2, 2
        call  ip_putn
        li    t0, IPD_ECHO
        sw    t0, ip_pstate
        csrr  t0, time
        sw    t0, ip_start
        li    a4, IPD_IHDR + IPD_CDATA + IPD_DATA
        call  ip_send
        mv    a5, a0
        bltz  a0, ip_done
        j     ip_wait

# ip_done: answer the ping with a5, and forget it.
ip_done:
        li    a0, SYS_REPLY
        lw    a1, ip_pinger
        mv    a2, a5
        sys
ip_forget:
        li    t0, IPD_NONE
        sw    t0, ip_pinger
        sw    zero, ip_pstate
        call  ip_rearm
        j     ip_wait

ip_notice:
        li    t0, NOTE_SIGNAL
        beq   a1, t0, ip_frame
        li    t0, NOTE_ALARM
        beq   a1, t0, ip_alarm
        li    t0, NOTE_ENDED
        bne   a1, t0, ip_wait
        lw    t0, ip_net
        li    a0, E_IO                 # the network server is gone
        beq   a2, t0, ip_quit
        mv    s0, a2                   # what it held goes with it
        call  ip_unbind
        lw    t0, ip_spid
        bne   t0, s0, 1f
        li    t0, IPD_NONE
        sw    t0, ip_spid
1:      lw    t0, ip_pinger
        beq   s0, t0, ip_forget        # nobody to answer now
        call  ip_rearm
        j     ip_wait

# ip_alarm: the time has come for something: fail each receive, send or
# ping whose time is up.
ip_alarm:
        csrr  s1, time                 # s1: now
        li    s0, 0                    # s0: a process
1:      li    t0, 3
        mul   s2, s0, t0
        la    t0, ip_usize
        add   t0, t0, s2
        lw    t1, 0(t0)
        beqz  t1, 2f                   # no receive waits
        la    t1, ip_udead
        add   t1, t1, s2
        lw    t1, 0(t1)
        beqz  t1, 2f                   # it waits for ever
        bgt   t1, s1, 2f
        sw    zero, 0(t0)
        li    a0, SYS_REPLY
        mv    a1, s0
        li    a2, E_TIMEDOUT
        sys
2:      addi  s0, s0, 1
        li    t0, NPROC
        blt   s0, t0, 1b
        lw    a1, ip_spid
        bltz  a1, 3f
        lw    t0, ip_sdead
        bgt   t0, s1, 3f
        li    t0, IPD_NONE             # ARP never answered
        sw    t0, ip_spid
        li    a0, SYS_REPLY
        li    a2, E_TIMEDOUT
        sys
3:      lw    t0, ip_pinger
        bltz  t0, 4f
        lw    t0, ip_pdead
        bgt   t0, s1, 4f
        li    a5, E_TIMEDOUT           # the ping has run out of time
        j     ip_done
4:      call  ip_rearm
        j     ip_wait

# ip_frame: the network server has a frame for us: take it, and see
# what it is.
ip_frame:
        lw    t0, ip_net
        bne   a2, t0, ip_wait
        li    a0, SYS_CALL
        lw    a1, ip_net
        li    a2, NT_RECEIVE
        la    a3, ip_rx
        li    a4, FRAME_MAX
        sys
        mv    s2, a0                   # s2: its length
        li    t0, IPD_HDR
        blt   s2, t0, ip_wait          # a failure is negative
        la    s1, ip_rx                # s1: the frame
        addi  a0, s1, IPD_TYPE
        li    a1, 2
        call  ip_getn
        li    t0, IPD_TARP
        beq   a0, t0, ip_arp
        li    t0, IPD_TIP
        beq   a0, t0, ip_ipv4
        j     ip_wait

# ip_arp: an ARP message in frame s1, s2 long. Learn the sender if it
# speaks to us, and answer a request.
ip_arp:
        li    t0, IPD_ALEN
        blt   s2, t0, ip_wait
        addi  a0, s1, IPD_AHW
        li    a1, 2
        call  ip_getn
        li    t0, 1                    # Ethernet
        bne   a0, t0, ip_wait
        addi  a0, s1, IPD_APROTO
        li    a1, 4
        call  ip_getn
        li    t0, IPD_AFORM
        bne   a0, t0, ip_wait
        addi  a0, s1, IPD_ATPA
        li    a1, 4
        call  ip_getn
        lw    t0, ip_addr
        bne   a0, t0, ip_wait          # not for us
        addi  a0, s1, IPD_ASPA
        li    a1, 4
        call  ip_getn
        mv    s3, a0                   # s3: the sender's address
        addi  a0, s1, IPD_ASHA
        li    a1, 3
        call  ip_getn
        mv    s4, a0                   # s4, s5: its Ethernet address
        addi  a0, s1, IPD_ASHA + 3
        li    a1, 3
        call  ip_getn
        mv    s5, a0
        mv    a0, s3
        mv    a1, s4
        mv    a2, s5
        call  ip_learn
        addi  a0, s1, IPD_AOP
        li    a1, 2
        call  ip_getn
        li    t0, 1
        bne   a0, t0, 1f
        li    a0, 2                    # a request: reply
        mv    a1, s4
        mv    a2, s5
        mv    a3, s3
        call  ip_arpsend
1:      j     ip_wait                  # which carries on what waited for it

# ip_ipv4: an IPv4 packet in frame s1, s2 long. Only ICMP and UDP to
# our own address are for us. ICMP: answer an echo request, and take the
# reply the ping waits for.
ip_ipv4:
        li    t0, IPD_IHDR
        blt   s2, t0, ip_wait
        lt    t0, IPD_VHL(s1)
        li    t1, 16
        div   t2, t0, t1
        li    t3, 4                    # version 4
        bne   t2, t3, ip_wait
        rem   s3, t0, t1
        li    t1, 4
        mul   s3, s3, t1               # s3: the header's length
        li    t0, IPD_IHDR - IPD_HDR
        blt   s3, t0, ip_wait
        addi  a0, s1, IPD_TOTAL
        li    a1, 2
        call  ip_getn
        mv    s4, a0                   # s4: the packet's
        blt   s4, s3, ip_wait
        addi  t0, s2, -IPD_HDR
        bgt   s4, t0, ip_wait          # longer than the frame
        addi  a0, s1, IPD_IDST
        li    a1, 4
        call  ip_getn
        lw    t0, ip_addr
        bne   a0, t0, ip_wait
        addi  a0, s1, IPD_HDR
        mv    a1, s3
        li    a2, 0
        call  ip_sum
        bnez  a0, ip_wait              # damaged
        lt    t0, IPD_PROTO(s1)
        li    t1, IPD_UDP
        beq   t0, t1, ip_udp
        li    t1, IPD_ICMP
        bne   t0, t1, ip_wait
        add   s5, s1, s3
        addi  s5, s5, IPD_HDR          # s5: the ICMP message
        sub   s4, s4, s3               # s4: its length
        li    t0, IPD_CDATA
        blt   s4, t0, ip_wait
        mv    a0, s5
        mv    a1, s4
        li    a2, 0
        call  ip_sum
        bnez  a0, ip_wait
        addi  a0, s1, IPD_ISRC
        li    a1, 4
        call  ip_getn
        mv    s3, a0                   # s3: who sent it
        lt    t0, IPD_CTYPE(s5)
        li    t1, 8
        beq   t0, t1, ip_pong
        bnez  t0, ip_wait
        lw    t0, ip_pstate            # an echo reply: the ping's?
        li    t1, IPD_ECHO
        bne   t0, t1, ip_wait
        lw    t0, ip_target
        bne   t0, s3, ip_wait
        addi  a0, s5, IPD_CID
        li    a1, 2
        call  ip_getn
        lw    t0, ip_pinger
        bne   a0, t0, ip_wait
        addi  a0, s5, IPD_CSEQ
        li    a1, 2
        call  ip_getn
        lw    t0, ip_seq
        bne   a0, t0, ip_wait
        csrr  a5, time
        lw    t0, ip_start
        sub   a5, a5, t0
        j     ip_done

# ip_pong: answer the echo request s5, s4 long, from address s3 in frame
# s1 with the same message as an echo reply.
ip_pong:
        addi  a0, s1, IPD_SRC          # back where it came from
        li    a1, 3
        call  ip_getn
        mv    s6, a0
        addi  a0, s1, IPD_SRC + 3
        li    a1, 3
        call  ip_getn
        mv    a2, a0
        mv    a1, s6
        la    s1, ip_tx                # s1: the reply now
        mv    a0, s1
        call  ip_putmac
        call  ip_ethtail
        addi  a0, s4, IPD_IHDR - IPD_HDR
        li    a1, 1
        mv    a2, s3
        call  ip_iphead
        li    t0, 0
1:      add   t1, s5, t0
        lt    t2, 0(t1)
        add   t1, s1, t0
        st    t2, IPD_IHDR(t1)
        addi  t0, t0, 1
        blt   t0, s4, 1b
        addi  s2, s1, IPD_IHDR         # s2: its ICMP message
        st    zero, IPD_CTYPE(s2)
        st    zero, IPD_CCSUM(s2)
        st    zero, IPD_CCSUM + 1(s2)
        mv    a0, s2
        mv    a1, s4
        li    a2, 0
        call  ip_sum
        mv    a1, a0
        addi  a0, s2, IPD_CCSUM
        li    a2, 2
        call  ip_putn
        addi  a4, s4, IPD_IHDR
        call  ip_send
        j     ip_wait

# ip_bind: bind(port a2) for process s0: 0 chooses a free port.
ip_bind:
        bltz  a2, ip_answer
        li    t0, 65535
        bgt   a2, t0, ip_answer
        mv    s1, a2                   # s1: the port
        bnez  s1, 2f
        li    s2, 65536 - IPD_EPHEMERAL   # s2: how many are left to try
1:      lw    s1, ip_ephem
        addi  t0, s1, 1
        li    t1, 65536
        blt   t0, t1, 3f
        li    t0, IPD_EPHEMERAL
3:      sw    t0, ip_ephem
        mv    a0, s1
        call  ip_owner
        bltz  a0, 5f
        addi  s2, s2, -1
        bnez  s2, 1b
        li    a5, E_BUSY               # every one is taken
        j     ip_answer
2:      mv    a0, s1
        call  ip_owner
        li    a5, E_BUSY
        bltz  a0, 5f
        bne   a0, s0, ip_answer        # another process has it
5:      call  ip_unbind                # its old port, and what came to it
        li    t0, 3
        mul   t0, s0, t0
        la    t1, ip_uport
        add   t1, t1, t0
        sw    s1, 0(t1)
        mv    a5, s1
        j     ip_answer

# ip_usend: send(buffer a2, n a3) for process s0.
ip_usend:
        call  ip_myport
        blez  a0, ip_answer            # no port to send from
        li    t0, 6
        blt   a3, t0, ip_answer
        li    t0, IPD_UMAX + 6
        bgt   a3, t0, ip_answer
        mv    s1, a2                   # s1: the buffer
        mv    s2, a3                   # s2: its length
        call  ip_ucopy
        li    a5, E_FAULT
        bnez  a0, ip_answer
        la    a0, ip_tx
        addi  a0, a0, IPD_CLIENT
        li    a1, 4
        call  ip_getn
        li    a5, E_INVAL
        blez  a0, ip_answer
        li    t0, IPD_LIMIT
        bge   a0, t0, ip_answer
        call  ip_route
        li    a5, E_NOROUTE
        bltz  a0, ip_answer
        mv    s4, a0                   # s4: the hop
        call  ip_lookup
        bltz  a0, 1f
        call  ip_myport
        mv    a3, a0
        call  ip_uout
        mv    a5, a0
        j     ip_answer
1:      li    a5, E_BUSY               # it waits for ARP: one may
        lw    t0, ip_spid
        bgez  t0, ip_answer
        li    a0, 1
        mv    a3, s4
        call  ip_arpsend
        mv    a5, a0
        bltz  a0, ip_answer
        sw    s0, ip_spid
        sw    s1, ip_sbuf
        sw    s2, ip_slen
        sw    s4, ip_shop
        csrr  t0, time
        li    t1, IPD_ARPWAIT
        add   t0, t0, t1
        sw    t0, ip_sdead
        call  ip_rearm
        j     ip_wait

# ip_usendnow: ARP has told the waiting send's hop, at a1, a2: send it.
ip_usendnow:
        mv    s4, a1
        mv    s5, a2
        lw    s0, ip_spid
        lw    s1, ip_sbuf
        lw    s2, ip_slen
        li    t0, IPD_NONE
        sw    t0, ip_spid
        call  ip_ucopy                 # the buffer again: ip_tx has been used
        li    s3, E_FAULT
        bnez  a0, 1f
        call  ip_myport
        mv    a3, a0
        mv    a1, s4
        mv    a2, s5
        call  ip_uout
        mv    s3, a0
1:      call  ip_rearm
        mv    a5, s3
        j     ip_answer

# ip_urecv: receive(buffer a2, size a3, wait a4) for process s0.
ip_urecv:
        call  ip_myport
        blez  a0, ip_answer
        li    t0, 6
        blt   a3, t0, ip_answer
        bltz  a4, ip_answer
        mv    s1, a2                   # s1: the buffer
        mv    s2, a3                   # s2: its size
        mv    s3, a4                   # s3: how long it may wait
        call  ip_oldest
        bltz  a0, 1f
        mv    s4, a0                   # s4: a datagram kept for it
        li    t0, 3
        mul   t0, s4, t0
        la    t1, ip_qowner
        add   t1, t1, t0
        sw    zero, 0(t1)              # given, or too long: gone either way
        la    t1, ip_qlen
        add   t1, t1, t0
        lw    s5, 0(t1)
        li    a5, E_NOROOM
        bgt   s5, s2, ip_answer
        li    a0, SYS_COPYOUT
        mv    a1, s0
        li    t0, IPD_SLOT
        mul   a2, s4, t0
        li    t0, IPD_QBASE
        add   a2, a2, t0
        mv    a3, s1
        mv    a4, s5
        sys
        mv    a5, s5
        beqz  a0, ip_answer
        li    a5, E_FAULT
        j     ip_answer
1:      li    t0, 3                    # nothing yet: hold the call
        mul   t0, s0, t0
        la    t1, ip_ubuf
        add   t1, t1, t0
        sw    s1, 0(t1)
        la    t1, ip_usize
        add   t1, t1, t0
        addi  t2, s2, 1
        sw    t2, 0(t1)
        li    t2, 0                    # for ever,
        beqz  s3, 2f
        csrr  t2, time                 # or until then
        add   t2, t2, s3
2:      la    t1, ip_udead
        add   t1, t1, t0
        sw    t2, 0(t1)
        call  ip_rearm
        j     ip_wait

# ip_udp: a UDP datagram in frame s1: s3 the IP header's length, s4 the
# packet's. Give it to the receive waiting on its port, or keep it for
# the next; to port 7 with nobody on it, send it back.
ip_udp:
        add   s5, s1, s3
        addi  s5, s5, IPD_HDR          # s5: the UDP header
        sub   s4, s4, s3               # s4: what the IP header says follows
        li    t0, IPD_UDATA
        blt   s4, t0, ip_wait
        addi  a0, s5, IPD_ULEN
        li    a1, 2
        call  ip_getn
        mv    s6, a0                   # s6: the UDP length
        li    t0, IPD_UDATA
        blt   s6, t0, ip_wait
        bgt   s6, s4, ip_wait
        addi  a0, s1, IPD_ISRC
        li    a1, 4
        call  ip_getn
        mv    s3, a0                   # s3: who sent it
        addi  a0, s5, IPD_UCSUM
        li    a1, 2
        call  ip_getn
        beqz  a0, 1f                   # sent without a checksum
        mv    a0, s3
        mv    a1, s6
        call  ip_pseudo
        mv    a0, s5
        mv    a1, s6
        call  ip_sum
        bnez  a0, ip_wait              # damaged
1:      addi  a0, s5, IPD_UDPORT
        li    a1, 2
        call  ip_getn
        mv    s4, a0                   # s4: the port it is for
        addi  a0, s5, IPD_USPORT
        li    a1, 2
        call  ip_getn
        mv    s7, a0                   # s7: the port it came from
        addi  a0, s5, IPD_UDATA - 6    # as a client sees it: the sender's
        mv    a1, s3                   # address and port, then the data
        li    a2, 4
        call  ip_putn
        addi  a0, s5, IPD_UDATA - 2
        mv    a1, s7
        li    a2, 2
        call  ip_putn
        addi  s5, s5, IPD_UDATA - 6    # s5: the datagram as a client sees it
        addi  s6, s6, 6 - IPD_UDATA    # s6: its length
        mv    a0, s4
        call  ip_owner
        bltz  a0, ip_uecho
        mv    s0, a0                   # s0: whose port
        li    t0, 3
        mul   t0, s0, t0
        la    t1, ip_usize
        add   t1, t1, t0
        lw    s2, 0(t1)
        beqz  s2, ip_keep              # no receive waits: keep it
        sw    zero, 0(t1)
        addi  s2, s2, -1               # s2: the receive's size
        la    t1, ip_ubuf
        add   t1, t1, t0
        lw    a3, 0(t1)
        li    a2, E_NOROOM
        bgt   s6, s2, 2f
        li    a0, SYS_COPYOUT
        mv    a1, s0
        mv    a2, s5
        mv    a4, s6
        sys
        mv    a2, s6
        beqz  a0, 2f
        li    a2, E_FAULT
2:      li    a0, SYS_REPLY
        mv    a1, s0
        sys
        call  ip_rearm
        j     ip_wait

# ip_keep: keep datagram s5, s6 long, for process s0's next receive, in
# a free slot; with none free it is dropped.
ip_keep:
        li    t0, 0                    # t0: a slot
1:      li    t1, 3
        mul   t1, t0, t1
        la    t2, ip_qowner
        add   t2, t2, t1
        lw    t3, 0(t2)
        beqz  t3, 2f
        addi  t0, t0, 1
        li    t3, IPD_SLOTS
        blt   t0, t3, 1b
        j     ip_wait
2:      addi  t3, s0, 1
        sw    t3, 0(t2)
        la    t2, ip_qlen
        add   t2, t2, t1
        sw    s6, 0(t2)
        lw    t3, ip_qnext
        la    t2, ip_qseq
        add   t2, t2, t1
        sw    t3, 0(t2)
        addi  t3, t3, 1
        sw    t3, ip_qnext
        li    t1, IPD_SLOT
        mul   t1, t0, t1
        li    t2, IPD_QBASE
        add   t1, t1, t2               # t1: the slot's first tryte
        li    t0, 0
3:      add   t2, s5, t0
        lt    t3, 0(t2)
        add   t2, t1, t0
        st    t3, 0(t2)
        addi  t0, t0, 1
        blt   t0, s6, 3b
        j     ip_wait

# ip_uecho: the echo service: send datagram s5, s6 long, from frame s1
# and for port s4, back where it came from, if s4 is port 7.
ip_uecho:
        li    t0, IPD_ECHOPORT
        bne   s4, t0, ip_wait
        la    t0, ip_tx
        addi  t0, t0, IPD_CLIENT
        li    t1, 0
1:      add   t2, s5, t1
        lt    t3, 0(t2)
        add   t2, t0, t1
        st    t3, 0(t2)
        addi  t1, t1, 1
        blt   t1, s6, 1b
        addi  a0, s1, IPD_SRC
        li    a1, 3
        call  ip_getn
        mv    s7, a0
        addi  a0, s1, IPD_SRC + 3
        li    a1, 3
        call  ip_getn
        mv    a2, a0
        mv    a1, s7
        li    a3, IPD_ECHOPORT
        mv    s2, s6
        call  ip_uout
        j     ip_wait

# ip_uout: send the client's datagram at ip_tx + IPD_CLIENT, s2 long,
# from port a3 to Ethernet address a1, a2: a0 is how it went. Clobbers
# a1..a5, s1, s3..s5, t0..t5.
ip_uout:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a3, ip_usport
        la    s1, ip_tx
        mv    a0, s1
        call  ip_putmac
        call  ip_ethtail
        addi  a0, s1, IPD_CLIENT
        li    a1, 4
        call  ip_getn
        mv    s3, a0                   # s3: where to
        addi  a0, s1, IPD_CLIENT + 4
        li    a1, 2
        call  ip_getn
        mv    s4, a0                   # s4: its port
        addi  s5, s2, IPD_UDATA - 6    # s5: the UDP length
        addi  a0, s5, IPD_IHDR - IPD_HDR
        li    a1, IPD_UDP
        mv    a2, s3
        call  ip_iphead
        addi  s1, s1, IPD_IHDR         # s1: the UDP header
        addi  a0, s1, IPD_USPORT
        lw    a1, ip_usport
        li    a2, 2
        call  ip_putn
        addi  a0, s1, IPD_UDPORT
        mv    a1, s4
        li    a2, 2
        call  ip_putn
        addi  a0, s1, IPD_ULEN
        mv    a1, s5
        li    a2, 2
        call  ip_putn
        st    zero, IPD_UCSUM(s1)
        st    zero, IPD_UCSUM + 1(s1)
        mv    a0, s3
        mv    a1, s5
        call  ip_pseudo
        mv    a0, s1
        mv    a1, s5
        call  ip_sum
        bnez  a0, 1f
        li    a0, 65535                # 0 would say there is none
1:      mv    a1, a0
        addi  a0, s1, IPD_UCSUM
        li    a2, 2
        call  ip_putn
        addi  a4, s5, IPD_IHDR
        call  ip_send
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# ip_ucopy: a0 = copyin of process s0's s1, s2 long, to ip_tx +
# IPD_CLIENT: 0, or how it failed.
ip_ucopy:
        li    a0, SYS_COPYIN
        mv    a1, s0
        mv    a2, s1
        la    a3, ip_tx
        addi  a3, a3, IPD_CLIENT
        mv    a4, s2
        sys
        ret

# ip_myport: a0 = process s0's port, 0 for none. Clobbers t0, t1.
ip_myport:
        li    t0, 3
        mul   t0, s0, t0
        la    t1, ip_uport
        add   t1, t1, t0
        lw    a0, 0(t1)
        ret

# ip_owner: a0 = the process that has port a0, IPD_NONE for nobody.
# Clobbers t0..t2.
ip_owner:
        blez  a0, 3f                   # port 0 is nobody's
        la    t0, ip_uport
        li    t1, 0
1:      lw    t2, 0(t0)
        beq   t2, a0, 2f
        addi  t0, t0, 3
        addi  t1, t1, 1
        li    t2, NPROC
        blt   t1, t2, 1b
3:      li    a0, IPD_NONE
        ret
2:      mv    a0, t1
        ret

# ip_unbind: process s0 has no port now, no receive waiting, and nothing
# kept for it. Clobbers t0..t3.
ip_unbind:
        li    t0, 3
        mul   t0, s0, t0
        la    t1, ip_uport
        add   t1, t1, t0
        sw    zero, 0(t1)
        la    t1, ip_usize
        add   t1, t1, t0
        sw    zero, 0(t1)
        la    t0, ip_qowner
        li    t1, IPD_SLOTS
        addi  t2, s0, 1
1:      lw    t3, 0(t0)
        bne   t3, t2, 2f
        sw    zero, 0(t0)
2:      addi  t0, t0, 3
        addi  t1, t1, -1
        bnez  t1, 1b
        ret

# ip_oldest: a0 = the slot of the oldest datagram kept for process s0,
# IPD_NONE if none is. Clobbers a1, t0..t3.
ip_oldest:
        li    a0, IPD_NONE
        addi  t3, s0, 1                # t3: its mark in ip_qowner
        li    t0, 0                    # t0: a slot
1:      li    t1, 3
        mul   t1, t0, t1
        la    t2, ip_qowner
        add   t2, t2, t1
        lw    t2, 0(t2)
        bne   t2, t3, 3f
        la    t2, ip_qseq
        add   t2, t2, t1
        lw    t2, 0(t2)
        bltz  a0, 2f
        bge   t2, a1, 3f
2:      mv    a0, t0                   # a1: its number
        mv    a1, t2
3:      addi  t0, t0, 1
        li    t1, IPD_SLOTS
        blt   t0, t1, 1b
        ret

# ip_rearm: set the alarm for the earliest of the ping's time limit, the
# ARP wait of a send, and each receive's time limit; cancel it if none
# waits for a time. Clobbers a0..a5, t0..t3.
ip_rearm:
        li    a1, NO_ALARM             # a1: the earliest so far, or none
        lw    t0, ip_pinger
        bltz  t0, 1f
        lw    a1, ip_pdead
1:      lw    t0, ip_spid
        bltz  t0, 2f
        lw    t0, ip_sdead
        bltz  a1, 3f
        bge   t0, a1, 2f
3:      mv    a1, t0
2:      li    t1, 0                    # t1: a process
4:      li    t2, 3
        mul   t2, t1, t2
        la    t3, ip_usize
        add   t3, t3, t2
        lw    t3, 0(t3)
        beqz  t3, 6f
        la    t3, ip_udead
        add   t3, t3, t2
        lw    t0, 0(t3)
        beqz  t0, 6f                   # it waits for ever
        bltz  a1, 5f
        bge   t0, a1, 6f
5:      mv    a1, t0
6:      addi  t1, t1, 1
        li    t2, NPROC
        blt   t1, t2, 4b
        li    a0, SYS_ALARM
        sys
        ret

# ip_pseudo: a2 = the sum of the UDP pseudo-header for a datagram a1
# long between us and address a0, for ip_sum to start from. Clobbers
# a0, t0, t1.
ip_pseudo:
        li    t1, 65536
        div   a2, a0, t1
        rem   t0, a0, t1
        add   a2, a2, t0
        lw    a0, ip_addr
        div   t0, a0, t1
        add   a2, a2, t0
        rem   t0, a0, t1
        add   a2, a2, t0
        addi  a2, a2, IPD_UDP
        add   a2, a2, a1
        ret

# ip_arpsend: send ARP message a0 (1 a request, 2 a reply) about address
# a3: a request to everyone, a reply to Ethernet address a1, a2. a0 is
# how the send went. Clobbers a1..a5, t0..t4.
ip_arpsend:
        addi  sp, sp, -15
        sw    ra, 0(sp)
        sw    s1, 3(sp)
        sw    s2, 6(sp)
        sw    s3, 9(sp)
        sw    s4, 12(sp)
        mv    s2, a0                   # s2: the operation
        mv    s3, a1                   # s3, s4: the target's address, as far
        mv    s4, a2                   # as it is known
        sw    a3, ip_tpa
        li    t0, 1
        bne   s2, t0, 1f
        li    a1, IPD_BROADCAST
        li    a2, IPD_BROADCAST
        li    s3, 0
        li    s4, 0
1:      la    s1, ip_tx
        mv    a0, s1
        call  ip_putmac
        addi  a0, s1, IPD_SRC
        lw    a1, ip_machi
        lw    a2, ip_maclo
        call  ip_putmac
        addi  a0, s1, IPD_TYPE
        li    a1, IPD_TARP
        li    a2, 2
        call  ip_putn
        addi  a0, s1, IPD_AHW
        li    a1, 1
        li    a2, 2
        call  ip_putn
        addi  a0, s1, IPD_APROTO
        li    a1, IPD_AFORM
        li    a2, 4
        call  ip_putn
        addi  a0, s1, IPD_AOP
        mv    a1, s2
        li    a2, 2
        call  ip_putn
        addi  a0, s1, IPD_ASHA
        lw    a1, ip_machi
        lw    a2, ip_maclo
        call  ip_putmac
        addi  a0, s1, IPD_ASPA
        lw    a1, ip_addr
        li    a2, 4
        call  ip_putn
        addi  a0, s1, IPD_ATHA
        mv    a1, s3
        mv    a2, s4
        call  ip_putmac
        addi  a0, s1, IPD_ATPA
        lw    a1, ip_tpa
        li    a2, 4
        call  ip_putn
        li    a4, IPD_ALEN
        call  ip_send
        lw    ra, 0(sp)
        lw    s1, 3(sp)
        lw    s2, 6(sp)
        lw    s3, 9(sp)
        lw    s4, 12(sp)
        addi  sp, sp, 15
        ret

# ip_ethtail: finish ip_tx's Ethernet header: from us, carrying IPv4.
# Clobbers a0..a2, t0..t4.
ip_ethtail:
        mv    t5, ra
        la    a0, ip_tx
        addi  a0, a0, IPD_SRC
        lw    a1, ip_machi
        lw    a2, ip_maclo
        call  ip_putmac
        la    a0, ip_tx
        addi  a0, a0, IPD_TYPE
        li    a1, IPD_TIP
        li    a2, 2
        call  ip_putn
        jalr  zero, 0(t5)

# ip_iphead: write ip_tx's IPv4 header, without options: a packet a0
# octets long of protocol a1, from us to address a2. Clobbers a0..a2,
# t0..t3.
ip_iphead:
        addi  sp, sp, -12
        sw    ra, 0(sp)
        sw    s1, 3(sp)
        sw    s2, 6(sp)
        sw    s3, 9(sp)
        mv    s1, a0
        mv    s2, a1
        mv    s3, a2
        la    t2, ip_tx                # t2: the frame (ip_putn spares it)
        li    t0, 69                   # 0x45: version 4, five words long
        st    t0, IPD_VHL(t2)
        st    zero, IPD_TOS(t2)
        addi  a0, t2, IPD_TOTAL
        mv    a1, s1
        li    a2, 2
        call  ip_putn
        addi  a0, t2, IPD_IDENT
        lw    a1, ip_ident
        li    a2, 2
        call  ip_putn
        lw    t0, ip_ident
        addi  t0, t0, 1
        li    t1, 65536
        rem   t0, t0, t1
        sw    t0, ip_ident
        addi  a0, t2, IPD_FRAG
        li    a1, 0
        li    a2, 2
        call  ip_putn
        li    t0, IPD_TTL
        st    t0, IPD_TTLAT(t2)
        st    s2, IPD_PROTO(t2)
        st    zero, IPD_CSUM(t2)
        st    zero, IPD_CSUM + 1(t2)
        addi  a0, t2, IPD_ISRC
        lw    a1, ip_addr
        li    a2, 4
        call  ip_putn
        addi  a0, t2, IPD_IDST
        mv    a1, s3
        li    a2, 4
        call  ip_putn
        addi  a0, t2, IPD_HDR
        li    a1, IPD_IHDR - IPD_HDR
        li    a2, 0
        call  ip_sum
        mv    a1, a0
        la    a0, ip_tx
        addi  a0, a0, IPD_CSUM
        li    a2, 2
        call  ip_putn
        lw    ra, 0(sp)
        lw    s1, 3(sp)
        lw    s2, 6(sp)
        lw    s3, 9(sp)
        addi  sp, sp, 12
        ret

# ip_send: put a4 octets of ip_tx on the wire: a0 is how it went.
ip_send:
        li    a0, SYS_CALL
        lw    a1, ip_net
        li    a2, NT_SEND
        la    a3, ip_tx
        sys
        ret

# ip_sum: a0 = the Internet checksum of the a1 octets at a0, starting
# from the sum a2 (0, or ip_pseudo's): the ones' complement of their
# ones'-complement sum, as 16-bit words, an odd last octet padded with 0.
# Over a header or message holding its own checksum it is 0 when that is
# right. Clobbers a1, t0, t1, t3.
ip_sum:
        mv    t3, a2                   # t3: the sum
1:      li    t0, 2
        blt   a1, t0, 2f
        lt    t0, 0(a0)
        li    t1, 256
        mul   t0, t0, t1
        lt    t1, 1(a0)
        add   t0, t0, t1
        add   t3, t3, t0
        addi  a0, a0, 2
        addi  a1, a1, -2
        j     1b
2:      beqz  a1, 3f
        lt    t0, 0(a0)
        li    t1, 256
        mul   t0, t0, t1
        add   t3, t3, t0
3:      li    t1, 65536                # fold the carries back in
4:      blt   t3, t1, 5f
        div   t0, t3, t1
        rem   t3, t3, t1
        add   t3, t3, t0
        j     4b
5:      li    a0, 65535
        sub   a0, a0, t3
        ret

# ip_getn: a0 = the big-endian number in the a1 octets at a0. Clobbers
# a1, t0, t1.
ip_getn:
        li    t0, 0
1:      li    t1, 256
        mul   t0, t0, t1
        lt    t1, 0(a0)
        add   t0, t0, t1
        addi  a0, a0, 1
        addi  a1, a1, -1
        bnez  a1, 1b
        mv    a0, t0
        ret

# ip_putn: write a1, not negative, as a2 big-endian octets at a0.
# Clobbers a0..a2, t0, t1.
ip_putn:
        add   a0, a0, a2
1:      addi  a0, a0, -1
        li    t0, 256
        rem   t1, a1, t0
        st    t1, 0(a0)
        div   a1, a1, t0
        addi  a2, a2, -1
        bnez  a2, 1b
        ret

# ip_putmac: write the Ethernet address a1 (high half), a2 (low) at a0.
# Clobbers a0..a2, t0..t4.
ip_putmac:
        mv    t2, a2
        mv    t3, ra
        mv    t4, a0
        li    a2, 3
        call  ip_putn
        addi  a0, t4, 3
        mv    a1, t2
        li    a2, 3
        call  ip_putn
        jalr  zero, 0(t3)

# ip_route: a0 = the hop on the way to address a0: itself if it is on
# our network, else the gateway; IPD_NONE if there is none. Clobbers
# t0..t2.
ip_route:
        lw    t0, ip_prefix
        li    t1, 32
        sub   t0, t1, t0               # t0: the bits of the host part
        li    t1, 1
1:      blez  t0, 2f
        li    t2, 2
        mul   t1, t1, t2
        addi  t0, t0, -1
        j     1b
2:      div   t0, a0, t1               # t1: 2 to that
        lw    t2, ip_addr
        div   t2, t2, t1
        beq   t0, t2, 3f
        lw    a0, ip_gateway
        bgtz  a0, 3f
        li    a0, IPD_NONE
3:      ret

# ip_lookup: the Ethernet address of address a0 in the ARP cache: a0 = 0
# and a1, a2 its halves, or a0 = IPD_NONE. Clobbers t0..t2.
ip_lookup:
        la    t0, ip_arps
        li    t1, IPD_ARPS
1:      lw    t2, 0(t0)
        beq   t2, a0, 2f
        addi  t0, t0, 9
        addi  t1, t1, -1
        bnez  t1, 1b
        li    a0, IPD_NONE
        ret
2:      lw    a1, 3(t0)
        lw    a2, 6(t0)
        li    a0, 0
        ret

# ip_learn: keep address a0 at Ethernet address a1, a2 in the ARP cache,
# in its entry if it has one, else in place of the oldest. Address 0
# (a host that does not know its own yet) is not kept. Clobbers t0..t2.
ip_learn:
        blez  a0, 3f
        la    t0, ip_arps
        li    t1, IPD_ARPS
1:      lw    t2, 0(t0)
        beq   t2, a0, 2f
        addi  t0, t0, 9
        addi  t1, t1, -1
        bnez  t1, 1b
        lw    t1, ip_arpnext
        li    t2, 9
        mul   t2, t1, t2
        la    t0, ip_arps
        add   t0, t0, t2
        addi  t1, t1, 1
        li    t2, IPD_ARPS
        rem   t1, t1, t2
        sw    t1, ip_arpnext
2:      sw    a0, 0(t0)
        sw    a1, 3(t0)
        sw    a2, 6(t0)
3:      ret

ip_net:     .word 0                    # the network server
ip_machi:   .word 0                    # the interface's Ethernet address
ip_maclo:   .word 0
ip_addr:    .word IPD_ADDR             # ours,
ip_prefix:  .word IPD_PREFIX           # how much of it names the network,
ip_gateway: .word IPD_GATEWAY          # and the way off it (0 for none)
ip_ident:   .word 0                    # the next packet's identification
ip_pinger:  .word IPD_NONE             # whose ping is under way
ip_pstate:  .word 0                    # IPD_ARP or IPD_ECHO while one is
ip_target:  .word 0                    # the address it pings,
ip_seq:     .word 0                    # with this sequence number,
ip_hop:     .word 0                    # through this hop
ip_start:   .word 0                    # when its request was sent
ip_tpa:     .word 0                    # ip_arpsend's address
ip_arpnext: .word 0                    # the ARP entry to replace next
ip_pdead:   .word 0                    # when the ping runs out of time
ip_spid:    .word IPD_NONE             # whose send waits for ARP,
ip_sbuf:    .word 0                    # its buffer,
ip_slen:    .word 0                    # how long,
ip_shop:    .word 0                    # the hop ARP is asked about,
ip_sdead:   .word 0                    # and until when
ip_usport:  .word 0                    # ip_uout's source port
ip_ephem:   .word IPD_EPHEMERAL        # the port bind(0) tries next
ip_qnext:   .word 0                    # the next kept datagram's number
ip_uport:   .words NPROC               # each process's port, 0 for none,
ip_ubuf:    .words NPROC               # its waiting receive's buffer,
ip_usize:   .words NPROC               # size plus 1 (0 for none),
ip_udead:   .words NPROC               # and time limit (0 for none)
ip_qowner:  .words IPD_SLOTS           # each slot's process plus 1 (0 free),
ip_qlen:    .words IPD_SLOTS           # its datagram's length,
ip_qseq:    .words IPD_SLOTS           # and number, the oldest least
ip_arps:    .words 3 * IPD_ARPS        # address, Ethernet address halves
ip_tx:      .zero FRAME_MAX            # the frame being sent
ip_rx:      .zero FRAME_MAX            # the frame being looked at
ip_name:    .string "ip"
ip_netname: .string "net"
ip_myname:  .string "ipd"
        .nocompress
