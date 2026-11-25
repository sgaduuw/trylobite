# The IP server: the first layer of the network stack above the network
# server. It registers as "ip", protocol IP_PROTOCOL, once it has found
# "net", learned the interface's address and become its listener
# (NT_LISTEN); clients find it by that name (SYS_LOOKUP).
#
# It speaks ARP, ICMP echo, UDP and TCP over IPv4: it answers ARP requests
# for its own address and keeps what ARP tells it in a small cache, it
# answers pings, and IP_PING sends one for a client (include/layout.s).
# Its address is 10.0.0.2/24 with gateway 10.0.0.1 until IP_CONFIG says
# otherwise. It keeps the name server's address for resolvers
# (IP_NAMESERVER, 10.0.0.3 until set) but asks it nothing itself.
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
# TCP: a connection is a descriptor this server gives (SYS_GIVE), its
# handle the connection's number: IP_CONNECT makes one, IP_LISTEN and
# IP_ACCEPT take them, and IO_READ, IO_WRITE and IO_SHUTDOWN reach it
# through the descriptor; its last descriptor closing (NOTE_CLOSED)
# closes it. A connection to port 7 that nobody listens on is the echo
# service. See "TCP" below.
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
        .equ  IPD_NAMESERVER, 167772163 # 10.0.0.3
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
        .equ  IPD_TX, V_BLOCK + PAGE + BLOCK_T0   # window 1: the frame being sent,
        .equ  IPD_RX, IPD_TX + FRAME_MAX   # the frame being looked at,
        .equ  IPD_TBUFS, IPD_RX + FRAME_MAX   # and each connection's octets to send;
        .equ  IPD_RBUFS, V_BLOCK + 2 * PAGE + BLOCK_T0   # window 2: those it has received
        .equ  IPD_TCP, 6               # the IP protocol
        .equ  IPD_NTCP, 8              # connections, their handles 0 to 7
        .equ  IPD_TBUF, 1460           # octets a connection holds each way: one
                                       # segment, the most we take (our MSS)
        .equ  IPD_MSS, 536             # a segment, when the other end does not say
        .equ  IPD_RTO, 300000          # ticks before a segment is sent again,
        .equ  IPD_TRIES, 6             # how many times, before giving up
        .equ  IPD_LINGER, 600000       # ticks a closed connection waits for the
                                       # other end's FIN
        .assert 2 * FRAME_MAX + IPD_NTCP * IPD_TBUF <= PAGE, "window 1 overflows"
        .assert IPD_NTCP * IPD_TBUF <= PAGE, "window 2 overflows"
        .assert IPD_NTCP <= NHANDLE, "a connection's handle is its number"
        # A connection's state (IT_STATE):
        .equ  IPD_TFREE, 0
        .equ  IPD_TARPW, 1             # waiting for ARP before its SYN
        .equ  IPD_TSYNSENT, 2          # SYN sent, waiting for SYN+ACK
        .equ  IPD_TSYNRCVD, 3          # SYN+ACK sent, waiting for the ACK
        .equ  IPD_TEST, 4              # established
        .equ  IPD_TDEAD, 5             # reset or timed out: IT_ERR says which
        # TCP flags, as the header's octet 13 adds them
        .equ  IPD_FFIN, 1
        .equ  IPD_FSYN, 2
        .equ  IPD_FRST, 4
        .equ  IPD_FPSH, 8
        .equ  IPD_FACK, 16
        # A held call (ip_hkind), one per process at most, as a process waits
        # in one call at a time:
        .equ  IPD_HREAD, 1
        .equ  IPD_HWRITE, 2
        .equ  IPD_HACCEPT, 3
        # A connection's record in ip_tcbs, a word per field:
        .equ  IT_STATE, 0
        .equ  IT_LPORT, 3              # our port,
        .equ  IT_RADDR, 6              # the other end's address,
        .equ  IT_RPORT, 9              # its port,
        .equ  IT_MACHI, 12             # and the next hop's Ethernet address
        .equ  IT_MACLO, 15
        .equ  IT_HOP, 18               # the next hop, while ARP is asked
        .equ  IT_UNA, 21               # the oldest octet not acknowledged
        .equ  IT_NXT, 24               # the next octet to send
        .equ  IT_RCV, 27               # the next octet expected
        .equ  IT_WND, 30               # the other end's window
        .equ  IT_MSS, 33               # and its largest segment
        .equ  IT_LEN, 36               # octets in the transmit buffer, from IT_UNA
        .equ  IT_DEAD, 39              # when to send again (0 for nothing)
        .equ  IT_TRIES, 42             # times sent so far
        .equ  IT_RLEN, 45              # octets received, not yet read
        .equ  IT_FINSENT, 48           # 1 once our FIN is sent,
        .equ  IT_FINACKED, 51          # acknowledged,
        .equ  IT_FINRCVD, 54           # and once the other end's has come
        .equ  IT_SHUT, 57              # 1 once its last descriptor has closed:
                                       # what comes for it is dropped
        .equ  IT_PARENT, 60            # the listener plus 1 until accepted, or 0
        .equ  IT_CPID, 63              # the connecting process plus 1 until
                                       # answered, or 0
        .equ  IT_ERR, 66               # IPD_TDEAD: E_RESET, E_TIMEDOUT, E_REFUSED
        .equ  IT_WDONE, 69             # 1 once nothing more will be written: our
                                       # FIN follows what is
        .equ  IT_ECHO, 72              # 1 for the echo service's connection
        .equ  IT_SIZE, 75
        # A TCP header, from its start.
        .equ  IPD_TSPORT, 0
        .equ  IPD_TDPORT, 2
        .equ  IPD_TSEQ, 4
        .equ  IPD_TACK, 8
        .equ  IPD_TOFF, 12             # its length in words, times 16
        .equ  IPD_TFLAGS, 13
        .equ  IPD_TWND, 14
        .equ  IPD_TCSUM, 16
        .equ  IPD_TURG, 18
        .equ  IPD_TCPHDR, 20           # past a header without options

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
        .equ  IPD_CLIENT, IPD_IHDR + IPD_UDATA - 6   # where IPD_TX holds one

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
        li    s1, 0                    # windows: 0 for the UDP slots, 1 for
1:      li    a0, SYS_WINDOW           # frames and what connections send, 2
        mv    a1, s1                   # for what they receive
        sys
        bltz  a0, ip_quit
        addi  s1, s1, 1
        li    t0, 3
        blt   s1, t0, 1b
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
        call  ip_tserve                # move what connections can move
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
        li    t0, IP_CONNECT
        beq   a1, t0, ip_connect
        li    t0, IP_LISTEN
        beq   a1, t0, ip_listen
        li    t0, IP_ACCEPT
        beq   a1, t0, ip_accept
        li    t0, IP_NAMESERVER
        beq   a1, t0, ip_nameserver
        li    t0, IO_READ
        beq   a1, t0, ip_tread
        li    t0, IO_WRITE
        beq   a1, t0, ip_twrite
        li    t0, IO_SHUTDOWN
        beq   a1, t0, ip_tshutdown
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

# ip_nameserver: nameserver(address a2) for process s0.
ip_nameserver:
        li    t0, IPD_LIMIT
        bge   a2, t0, ip_answer        # E_INVAL
        lw    a5, ip_dns               # the answer is the one it was,
        bltz  a2, ip_answer            # and NS_KEEP keeps it
        sw    a2, ip_dns
        j     ip_answer

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
        li    s1, IPD_TX
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
        li    t0, NOTE_CLOSED
        beq   a1, t0, ip_tclosed
        li    t0, NOTE_ENDED
        bne   a1, t0, ip_wait
        lw    t0, ip_net
        li    a0, E_IO                 # the network server is gone
        beq   a2, t0, ip_quit
        mv    s0, a2                   # what it held goes with it
        call  ip_unbind
        call  ip_tended
        lw    t0, ip_spid
        bne   t0, s0, 1f
        li    t0, IPD_NONE
        sw    t0, ip_spid
1:      lw    t0, ip_pinger
        beq   s0, t0, ip_forget        # nobody to answer now
        call  ip_rearm
        j     ip_wait

# ip_alarm: the time has come for something: fail each receive, send or
# ping whose time is up, and send again what a connection has waited
# too long to see acknowledged.
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
        call  ip_ttimers               # and each connection's
        csrr  s1, time
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
        li    a3, IPD_RX
        li    a4, FRAME_MAX
        sys
        mv    s2, a0                   # s2: its length
        li    t0, IPD_HDR
        blt   s2, t0, ip_wait          # a failure is negative
        li    s1, IPD_RX               # s1: the frame
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

# ip_ipv4: an IPv4 packet in frame s1, s2 long. Only ICMP, UDP and TCP to
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
        li    t1, IPD_TCP
        beq   t0, t1, ip_tcp
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
        li    s1, IPD_TX               # s1: the reply now
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
        li    a0, IPD_TX
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
        call  ip_ucopy                 # the buffer again: IPD_TX has been used
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
        li    a3, IPD_UDP
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
        li    t0, IPD_TX
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

# ip_uout: send the client's datagram at IPD_TX + IPD_CLIENT, s2 long,
# from port a3 to Ethernet address a1, a2: a0 is how it went. Clobbers
# a1..a5, s1, s3..s5, t0..t5.
ip_uout:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a3, ip_usport
        li    s1, IPD_TX
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
        li    a3, IPD_UDP
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

# ip_ucopy: a0 = copyin of process s0's s1, s2 long, to IPD_TX +
# IPD_CLIENT: 0, or how it failed.
ip_ucopy:
        li    a0, SYS_COPYIN
        mv    a1, s0
        mv    a2, s1
        li    a3, IPD_TX
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
# ARP wait of a send, each receive's time limit and each connection's
# time to send again; cancel it if none
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
        la    t3, ip_tcbs              # and each connection's
        li    t1, IPD_NTCP
7:      lw    t0, IT_STATE(t3)
        beqz  t0, 9f
        lw    t0, IT_DEAD(t3)
        beqz  t0, 9f
        bltz  a1, 8f
        bge   t0, a1, 9f
8:      mv    a1, t0
9:      addi  t3, t3, IT_SIZE
        addi  t1, t1, -1
        bnez  t1, 7b
        li    a0, SYS_ALARM
        sys
        ret

# ip_pseudo: a2 = the sum of the pseudo-header for a UDP datagram or
# TCP segment (protocol a3) a1 long between us and address a0, for
# ip_sum to start from. Clobbers a0, t0, t1.
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
        add   a2, a2, a3
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
1:      li    s1, IPD_TX
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

# ip_ethtail: finish IPD_TX's Ethernet header: from us, carrying IPv4.
# Clobbers a0..a2, t0..t4.
ip_ethtail:
        mv    t5, ra
        li    a0, IPD_TX
        addi  a0, a0, IPD_SRC
        lw    a1, ip_machi
        lw    a2, ip_maclo
        call  ip_putmac
        li    a0, IPD_TX
        addi  a0, a0, IPD_TYPE
        li    a1, IPD_TIP
        li    a2, 2
        call  ip_putn
        jalr  zero, 0(t5)

# ip_iphead: write IPD_TX's IPv4 header, without options: a packet a0
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
        li    t2, IPD_TX               # t2: the frame (ip_putn spares it)
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
        li    a0, IPD_TX
        addi  a0, a0, IPD_CSUM
        li    a2, 2
        call  ip_putn
        lw    ra, 0(sp)
        lw    s1, 3(sp)
        lw    s2, 6(sp)
        lw    s3, 9(sp)
        addi  sp, sp, 12
        ret

# ip_send: put a4 octets of IPD_TX on the wire: a0 is how it went.
ip_send:
        li    a0, SYS_CALL
        lw    a1, ip_net
        li    a2, NT_SEND
        li    a3, IPD_TX
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

# --- TCP ----------------------------------------------------------------
# A connection is a record in ip_tcbs; its number is the handle its
# descriptor names, and indexes its two buffers: IPD_TBUF octets to send
# in window 1, from the oldest not yet acknowledged, and as many
# received and not yet read in window 2. One segment is in flight at a
# time: the next goes once the last is acknowledged, and it is sent
# again after IPD_RTO ticks without. Sequence numbers are modulo 2^32
# (ip_tmod). There is no TIME-WAIT: a connection is forgotten once both
# FINs are acknowledged and its descriptor has closed.
#
# Calls wait as held calls, one per process: a read, a write or an
# accept (ip_hkind), or a connect (IT_CPID). ip_tserve, before each
# receive, moves what it can for each and answers those that are done.

# ip_connect: connect(address a2, port a3) for process s0.
ip_connect:
        blez  a2, ip_answer
        li    t0, IPD_LIMIT
        bge   a2, t0, ip_answer
        blez  a3, ip_answer
        li    t0, 65535
        bgt   a3, t0, ip_answer
        mv    s1, a2                   # s1: the address
        mv    s2, a3                   # s2: the port
        mv    a0, a2
        call  ip_route
        li    a5, E_NOROUTE
        bltz  a0, ip_answer
        mv    s4, a0                   # s4: the hop
        call  ip_talloc
        li    a5, E_NOSPC
        beqz  s3, ip_answer
        call  ip_tport
        beqz  a0, ip_answer            # every port is in use
        sw    a0, IT_LPORT(s3)
        sw    s1, IT_RADDR(s3)
        sw    s2, IT_RPORT(s3)
        sw    s4, IT_HOP(s3)
        addi  t0, s0, 1
        sw    t0, IT_CPID(s3)
        li    t0, IPD_MSS
        sw    t0, IT_MSS(s3)
        call  ip_tisn
        li    t0, IPD_TARPW            # ip_tserve sends the SYN once the
        sw    t0, IT_STATE(s3)         # hop's address is known
        call  ip_ttime
        mv    a0, s4
        call  ip_lookup
        bgez  a0, ip_wait
        li    a0, 1
        mv    a3, s4
        call  ip_arpsend
        mv    a5, a0
        bgez  a0, ip_wait
        sw    zero, IT_STATE(s3)       # no link
        j     ip_answer

# ip_listen: listen(port a2) for process s0.
ip_listen:
        bltz  a2, ip_answer
        li    t0, 65535
        bgt   a2, t0, ip_answer
        beqz  a2, 2f
        li    a5, E_BUSY
        la    t0, ip_tlport
        li    t1, 0                    # t1: a process
1:      lw    t2, 0(t0)
        bne   t2, a2, 3f
        bne   t1, s0, ip_answer        # another listens there
3:      addi  t0, t0, 3
        addi  t1, t1, 1
        li    t2, NPROC
        blt   t1, t2, 1b
2:      li    t0, 3
        mul   t0, s0, t0
        la    t1, ip_tlport
        add   t1, t1, t0
        sw    a2, 0(t1)
        li    a5, 0
        j     ip_answer

# ip_accept: accept() for process s0: hold it for ip_tserve.
ip_accept:
        li    t0, 3
        mul   t0, s0, t0
        la    t1, ip_tlport
        add   t1, t1, t0
        lw    t1, 0(t1)
        beqz  t1, ip_answer            # not listening
        li    s4, IPD_HACCEPT
        j     ip_thold

# ip_tread, ip_twrite: a descriptor's read or write (handle a2, buffer
# a3, n a4) for process s0: hold it for ip_tserve. ip_tshutdown: its
# shutdown(handle a2): our FIN goes after what was written.
ip_tread:
        li    s4, IPD_HREAD
        j     1f
ip_tshutdown:
        li    s4, 0
        j     1f
ip_twrite:
        li    s4, IPD_HWRITE
1:      li    a5, E_BADF
        bltz  a2, ip_answer
        li    t0, IPD_NTCP
        bge   a2, t0, ip_answer
        mv    a0, a2
        call  ip_tcb
        lw    t0, IT_STATE(a0)
        beqz  t0, ip_answer
        bnez  s4, 2f
        li    t0, 1                    # shutdown
        sw    t0, IT_WDONE(a0)
        li    a5, 0
        j     ip_answer
2:      li    t0, IPD_HWRITE
        bne   s4, t0, 3f
        lw    t0, IT_WDONE(a0)
        li    a5, E_PIPE
        bnez  t0, ip_answer            # shut down for writing
3:      li    a5, E_INVAL
        bltz  a4, ip_answer
        li    a5, 0
        beqz  a4, ip_answer            # nothing asked: nothing to wait for
ip_thold:                              # hold call s4 of process s0
        li    t0, 3
        mul   t0, s0, t0
        la    t1, ip_hkind
        add   t1, t1, t0
        sw    s4, 0(t1)
        la    t1, ip_htcb
        add   t1, t1, t0
        sw    a2, 0(t1)
        la    t1, ip_hbuf
        add   t1, t1, t0
        sw    a3, 0(t1)
        la    t1, ip_hn
        add   t1, t1, t0
        sw    a4, 0(t1)
        la    t1, ip_hdone
        add   t1, t1, t0
        sw    zero, 0(t1)
        j     ip_wait

# ip_tclosed: handle a2 has no descriptor left: close its connection
# once what was written has gone, and drop what comes for it.
ip_tclosed:
        bltz  a2, ip_wait
        li    t0, IPD_NTCP
        bge   a2, t0, ip_wait
        mv    a0, a2
        call  ip_tcb
        li    t0, 1
        sw    t0, IT_SHUT(a0)
        sw    t0, IT_WDONE(a0)
        sw    zero, IT_RLEN(a0)
        j     ip_wait

# ip_tended: process s0 has ended: forget its listening port and held
# call, and the connections it was making or had not yet accepted.
# Clobbers s1..s3, a0..a5, t0..t5.
ip_tended:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    t0, 3
        mul   t0, s0, t0
        la    t1, ip_hkind
        add   t1, t1, t0
        sw    zero, 0(t1)
        la    t1, ip_tlport
        add   t1, t1, t0
        sw    zero, 0(t1)
        addi  s1, s0, 1                # s1: its mark
        la    s3, ip_tcbs
        li    s2, IPD_NTCP
1:      lw    t0, IT_STATE(s3)
        beqz  t0, 3f
        lw    t0, IT_CPID(s3)
        beq   t0, s1, 2f
        lw    t0, IT_PARENT(s3)
        bne   t0, s1, 3f
2:      lw    t0, IT_STATE(s3)
        li    t1, IPD_TSYNRCVD         # the other end knows of it
        blt   t0, t1, 4f
        li    t1, IPD_TDEAD
        beq   t0, t1, 4f
        call  ip_trst
4:      sw    zero, IT_STATE(s3)
3:      addi  s3, s3, IT_SIZE
        addi  s2, s2, -1
        bnez  s2, 1b
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# ip_tserve: move what can be moved for each held call, then for each
# connection: send its SYN once ARP has answered, give a connecting
# process its descriptor, send what waits to be sent, and forget a
# connection that has finished. Then set the alarm. Clobbers s0, s3..s8,
# a0..a5, t0..t5.
ip_tserve:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    s0, 0                    # s0: a process
ip_tsv1:
        li    t0, 3
        mul   s7, s0, t0               # s7: its entries' offset
        la    t0, ip_hkind
        add   t0, t0, s7
        lw    s4, 0(t0)                # s4: its held call
        beqz  s4, ip_tsvnext
        li    t0, IPD_HACCEPT
        beq   s4, t0, ip_tsvaccept
        la    t0, ip_htcb
        add   t0, t0, s7
        lw    a0, 0(t0)
        call  ip_tcb
        mv    s3, a0                   # s3: its connection
        li    t0, IPD_HWRITE
        beq   s4, t0, ip_tsvwrite
        lw    s5, IT_RLEN(s3)          # a read: data,
        bnez  s5, 2f
        lw    t0, IT_FINRCVD(s3)       # or the end,
        li    a2, 0
        bnez  t0, ip_tsvreply
        lw    t0, IT_STATE(s3)         # or what went wrong,
        li    t1, IPD_TDEAD
        bne   t0, t1, ip_tsvnext       # or nothing yet
        lw    a2, IT_ERR(s3)
        j     ip_tsvreply
2:      la    t0, ip_hn
        add   t0, t0, s7
        lw    t1, 0(t0)
        ble   s5, t1, 3f
        mv    s5, t1                   # s5: how much: what it holds, or n
3:      call  ip_tbuf
        mv    s6, a1                   # s6: the receive buffer
        li    a0, SYS_COPYOUT
        mv    a1, s0
        mv    a2, s6
        la    t0, ip_hbuf
        add   t0, t0, s7
        lw    a3, 0(t0)
        mv    a4, s5
        sys
        mv    s8, a0                   # s8: how the copy went
        lw    a1, IT_RLEN(s3)
        sub   t0, a1, s5
        sw    t0, IT_RLEN(s3)
        mv    a0, s6
        mv    a2, s5
        call  ip_tshift
        lw    t0, IT_STATE(s3)
        li    t1, IPD_TEST
        bne   t0, t1, 4f
        lw    t0, IT_FINRCVD(s3)
        bnez  t0, 4f
        call  ip_tack                  # tell the other end there is room
4:      mv    a2, s5
        beqz  s8, ip_tsvreply
        li    a2, E_FAULT
ip_tsvreply:                           # answer process s0's held call: a2
        la    t0, ip_hkind
        add   t0, t0, s7
        sw    zero, 0(t0)
        li    a0, SYS_REPLY
        mv    a1, s0
        sys
ip_tsvnext:
        addi  s0, s0, 1
        li    t0, NPROC
        blt   s0, t0, ip_tsv1
        j     ip_tsv2

ip_tsvwrite:                           # a write: room for some of the rest
        lw    t0, IT_STATE(s3)
        li    t1, IPD_TDEAD
        bne   t0, t1, 1f
        lw    a2, IT_ERR(s3)
        j     ip_tsvreply
1:      lw    s5, IT_LEN(s3)           # s5: what the buffer holds
        li    t0, IPD_TBUF
        sub   s6, t0, s5               # s6: its room
        beqz  s6, ip_tsvnext
        la    t0, ip_hn
        add   t0, t0, s7
        lw    t1, 0(t0)
        la    t0, ip_hdone
        add   t0, t0, s7
        lw    s8, 0(t0)                # s8: written so far
        sub   t1, t1, s8               # t1: the rest
        ble   s6, t1, 2f
        mv    s6, t1                   # s6: how much: the room, or the rest
2:      call  ip_tbuf
        add   a3, a0, s5
        li    a0, SYS_COPYIN
        mv    a1, s0
        la    t0, ip_hbuf
        add   t0, t0, s7
        lw    a2, 0(t0)
        add   a2, a2, s8
        mv    a4, s6
        sys
        li    a2, E_FAULT
        bnez  a0, ip_tsvreply
        add   t0, s5, s6
        sw    t0, IT_LEN(s3)
        add   s8, s8, s6
        la    t0, ip_hdone
        add   t0, t0, s7
        sw    s8, 0(t0)
        la    t0, ip_hn
        add   t0, t0, s7
        lw    a2, 0(t0)
        beq   s8, a2, ip_tsvreply      # all of it
        j     ip_tsvnext

ip_tsvaccept:                          # an accept: a connection established
        addi  t2, s0, 1                # for it, not yet accepted
        la    s3, ip_tcbs
        li    s6, 0                    # s6: its number
1:      lw    t0, IT_PARENT(s3)
        bne   t0, t2, 2f
        lw    t0, IT_STATE(s3)
        li    t1, IPD_TEST
        beq   t0, t1, 3f
2:      addi  s3, s3, IT_SIZE
        addi  s6, s6, 1
        li    t0, IPD_NTCP
        blt   s6, t0, 1b
        j     ip_tsvnext
3:      sw    zero, IT_PARENT(s3)
        li    a0, SYS_GIVE
        mv    a1, s0
        mv    a2, s6
        sys
        bgez  a0, 4f
        mv    s5, a0                   # no descriptor for it: reset it
        call  ip_trst
        sw    zero, IT_STATE(s3)
        mv    a2, s5
        j     ip_tsvreply
4:      la    t0, ip_hkind
        add   t0, t0, s7
        sw    zero, 0(t0)
        mv    a2, a0
        lw    a3, IT_RADDR(s3)
        lw    a4, IT_RPORT(s3)
        li    a0, SYS_REPLY
        mv    a1, s0
        sys
        j     ip_tsvnext

ip_tsv2:
        la    s3, ip_tcbs              # s3: a connection
        li    s6, 0                    # s6: its number
ip_tsv3:
        lw    s4, IT_STATE(s3)         # s4: its state
        beqz  s4, ip_tsv4
        li    t0, IPD_TARPW
        bne   s4, t0, 1f
        lw    a0, IT_HOP(s3)           # waiting for ARP: has it answered?
        call  ip_lookup
        bltz  a0, ip_tsv4
        sw    a1, IT_MACHI(s3)
        sw    a2, IT_MACLO(s3)
        li    t0, IPD_TSYNSENT
        sw    t0, IT_STATE(s3)
        sw    zero, IT_TRIES(s3)
        call  ip_ttime
        call  ip_tsyn
        j     ip_tsv4
1:      lw    t0, IT_CPID(s3)          # a connect waits for it:
        beqz  t0, 3f
        addi  s0, t0, -1               # s0: the process
        li    t1, IPD_TEST
        beq   s4, t1, 2f
        li    t1, IPD_TDEAD
        bne   s4, t1, ip_tsv4
        li    a0, SYS_REPLY            # it failed: say why, and forget it
        mv    a1, s0
        lw    a2, IT_ERR(s3)
        sys
        sw    zero, IT_STATE(s3)
        j     ip_tsv4
2:      sw    zero, IT_CPID(s3)        # it is open: give it the descriptor
        li    a0, SYS_GIVE
        mv    a1, s0
        mv    a2, s6
        sys
        mv    s5, a0
        bgez  a0, 21f
        call  ip_trst
        sw    zero, IT_STATE(s3)
21:     li    a0, SYS_REPLY
        mv    a1, s0
        mv    a2, s5
        sys
        lw    s4, IT_STATE(s3)
3:      li    t0, IPD_TDEAD
        bne   s4, t0, 4f
        lw    t0, IT_SHUT(s3)          # dead, and nobody can see it now
        bnez  t0, 31f
        lw    t0, IT_ECHO(s3)
        bnez  t0, 31f
        lw    t0, IT_PARENT(s3)
        beqz  t0, ip_tsv4
31:     sw    zero, IT_STATE(s3)
        j     ip_tsv4
4:      li    t0, IPD_TEST
        bne   s4, t0, ip_tsv4
        lw    t0, IT_ECHO(s3)
        beqz  t0, 41f
        call  ip_techo
41:        lw    t0, IT_UNA(s3)
        lw    t1, IT_NXT(s3)
        bne   t0, t1, ip_tsv4          # a segment is in flight
        call  ip_tpush
        lw    t0, IT_UNA(s3)
        lw    t1, IT_NXT(s3)
        bne   t0, t1, ip_tsv4          # it sent one
        lw    t0, IT_SHUT(s3)
        beqz  t0, ip_tsv4
        lw    t0, IT_FINACKED(s3)
        beqz  t0, ip_tsv4
        lw    t0, IT_FINRCVD(s3)
        beqz  t0, 5f
        sw    zero, IT_STATE(s3)       # closed both ways: done
        j     ip_tsv4
5:      lw    t0, IT_DEAD(s3)          # ours is closed: wait a while for
        bnez  t0, ip_tsv4              # the other end's FIN
        csrr  t0, time
        li    t1, IPD_LINGER
        add   t0, t0, t1
        sw    t0, IT_DEAD(s3)
ip_tsv4:
        addi  s3, s3, IT_SIZE
        addi  s6, s6, 1
        li    t0, IPD_NTCP
        blt   s6, t0, ip_tsv3
        call  ip_rearm
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# ip_techo: connection s3 is the echo service's: move what it received
# to what it sends, and close it once the other end has. Clobbers
# a0..a2, t0..t2, s5.
ip_techo:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        lw    s5, IT_RLEN(s3)          # s5: how much: what came,
        lw    t0, IT_LEN(s3)
        li    t1, IPD_TBUF
        sub   t1, t1, t0
        ble   s5, t1, 1f
        mv    s5, t1                   # or the room to send it
1:      beqz  s5, 2f
        call  ip_tbuf
        lw    t0, IT_LEN(s3)
        add   t0, a0, t0
        mv    a0, a1
        mv    a1, t0
        mv    a2, s5
        call  ip_tcopy
        lw    t0, IT_LEN(s3)
        add   t0, t0, s5
        sw    t0, IT_LEN(s3)
        call  ip_tbuf
        mv    a0, a1
        lw    a1, IT_RLEN(s3)
        sub   t0, a1, s5
        sw    t0, IT_RLEN(s3)
        mv    a2, s5
        call  ip_tshift
2:      lw    t0, IT_FINRCVD(s3)
        beqz  t0, 3f
        lw    t0, IT_RLEN(s3)
        bnez  t0, 3f
        li    t0, 1                    # all of it is on its way back
        sw    t0, IT_WDONE(s3)
        sw    t0, IT_SHUT(s3)
3:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# ip_ttimers: the alarm has gone off: for each connection whose time has
# come, send its segment again, or give up on it after IPD_TRIES. A
# closed one that has lingered is forgotten. Clobbers s3, s4, s6,
# a0..a5, t0..t5.
ip_ttimers:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    s3, ip_tcbs
        li    s6, IPD_NTCP
ip_tt1:
        lw    s4, IT_STATE(s3)
        beqz  s4, ip_tt2
        lw    t0, IT_DEAD(s3)
        beqz  t0, ip_tt2
        csrr  t1, time
        bgt   t0, t1, ip_tt2
        sw    zero, IT_DEAD(s3)
        li    t0, IPD_TEST
        bne   s4, t0, 1f
        lw    t0, IT_UNA(s3)
        lw    t1, IT_NXT(s3)
        bne   t0, t1, 1f
        sw    zero, IT_STATE(s3)       # lingered after closing: forget it
        j     ip_tt2
1:      lw    t0, IT_TRIES(s3)
        addi  t0, t0, 1
        sw    t0, IT_TRIES(s3)
        li    t1, IPD_TRIES
        bgt   t0, t1, 5f
        call  ip_ttime
        li    t0, IPD_TARPW
        bne   s4, t0, 2f
        li    a0, 1                    # ask ARP again
        lw    a3, IT_HOP(s3)
        call  ip_arpsend
        j     ip_tt2
2:      li    t0, IPD_TEST
        beq   s4, t0, 3f
        call  ip_tsyn
        j     ip_tt2
3:      call  ip_tresend
        j     ip_tt2
5:      li    t0, IPD_TSYNRCVD
        bne   s4, t0, 6f
        sw    zero, IT_STATE(s3)       # never finished its handshake
        j     ip_tt2
6:      li    t0, IPD_TEST
        bne   s4, t0, 7f
        call  ip_trst
7:      li    t0, IPD_TDEAD
        sw    t0, IT_STATE(s3)
        li    t0, E_TIMEDOUT
        sw    t0, IT_ERR(s3)
ip_tt2:
        addi  s3, s3, IT_SIZE
        addi  s6, s6, -1
        bnez  s6, ip_tt1
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# ip_tcp: a TCP segment in frame s1: s3 the IP header's length, s4 the
# packet's. Read its header into the ip_g words, then hand it to its
# connection, start a connection for a listener's SYN, or refuse it.
ip_tcp:
        add   s5, s1, s3
        addi  s5, s5, IPD_HDR          # s5: the TCP header
        sub   s4, s4, s3               # s4: the segment's length
        li    t0, IPD_TCPHDR
        blt   s4, t0, ip_wait
        addi  a0, s1, IPD_ISRC
        li    a1, 4
        call  ip_getn
        sw    a0, ip_gsrc
        mv    a1, s4
        li    a3, IPD_TCP
        call  ip_pseudo
        mv    a0, s5
        mv    a1, s4
        call  ip_sum
        bnez  a0, ip_wait              # damaged
        lt    t0, IPD_TOFF(s5)
        li    t1, 16
        div   t0, t0, t1
        li    t1, 4
        mul   s6, t0, t1               # s6: the header's length
        li    t0, IPD_TCPHDR
        blt   s6, t0, ip_wait
        bgt   s6, s4, ip_wait
        sub   t0, s4, s6
        sw    t0, ip_glen
        add   t0, s5, s6
        sw    t0, ip_gdata
        addi  a0, s5, IPD_TSPORT
        li    a1, 2
        call  ip_getn
        sw    a0, ip_gsport
        addi  a0, s5, IPD_TDPORT
        li    a1, 2
        call  ip_getn
        sw    a0, ip_gdport
        addi  a0, s5, IPD_TSEQ
        li    a1, 4
        call  ip_getn
        sw    a0, ip_gseq
        addi  a0, s5, IPD_TACK
        li    a1, 4
        call  ip_getn
        sw    a0, ip_gack
        addi  a0, s5, IPD_TWND
        li    a1, 2
        call  ip_getn
        sw    a0, ip_gwnd
        addi  a0, s1, IPD_SRC
        li    a1, 3
        call  ip_getn
        sw    a0, ip_gmachi
        addi  a0, s1, IPD_SRC + 3
        li    a1, 3
        call  ip_getn
        sw    a0, ip_gmaclo
        lt    t0, IPD_TFLAGS(s5)       # the flags, one bit at a time
        li    t1, 2
        rem   t2, t0, t1
        sw    t2, ip_gfin
        div   t0, t0, t1
        rem   t2, t0, t1
        sw    t2, ip_gsyn
        div   t0, t0, t1
        rem   t2, t0, t1
        sw    t2, ip_grst
        div   t0, t0, t1
        div   t0, t0, t1               # past PSH
        rem   t2, t0, t1
        sw    t2, ip_gackf
        li    t0, IPD_MSS
        sw    t0, ip_gmss
        lw    t0, ip_gsyn              # a SYN may say its MSS
        beqz  t0, 4f
        addi  s7, s5, IPD_TCPHDR       # s7: an option
        add   s8, s5, s6               # s8: past the last
1:      bge   s7, s8, 4f
        lt    t0, 0(s7)
        beqz  t0, 4f                   # the end of them
        li    t1, 1
        bne   t0, t1, 2f
        addi  s7, s7, 1                # no operation
        j     1b
2:      lt    s2, 1(s7)                # s2: its length
        li    t1, 2
        blt   s2, t1, 4f
        bne   t0, t1, 3f
        li    t1, 4
        bne   s2, t1, 3f
        addi  a0, s7, 2                # kind 2, the MSS
        li    a1, 2
        call  ip_getn
        blez  a0, 3f
        li    t0, IPD_TBUF
        ble   a0, t0, 5f
        mv    a0, t0                   # we never send more than we hold
5:      sw    a0, ip_gmss
3:      add   s7, s7, s2
        j     1b
4:      call  ip_tfind
        bnez  s3, ip_tseg
        lw    t0, ip_grst
        bnez  t0, ip_wait              # never answer a reset
        lw    t0, ip_gsyn
        beqz  t0, ip_treply
        lw    t0, ip_gackf
        bnez  t0, ip_treply
        lw    a0, ip_gdport
        call  ip_tlistener
        mv    s0, a0                   # s0: who listens
        bgez  a0, 1f
        lw    t0, ip_gdport            # nobody: the echo service takes
        li    t1, IPD_ECHOPORT         # port 7, and the rest are refused
        bne   t0, t1, ip_treply
1:      call  ip_talloc
        beqz  s3, ip_wait              # no room now; the SYN will come again
        addi  t0, s0, 1
        sw    t0, IT_PARENT(s3)
        bnez  t0, 2f
        li    t0, 1
        sw    t0, IT_ECHO(s3)
2:        lw    t0, ip_gdport
        sw    t0, IT_LPORT(s3)
        lw    t0, ip_gsrc
        sw    t0, IT_RADDR(s3)
        lw    t0, ip_gsport
        sw    t0, IT_RPORT(s3)
        lw    t0, ip_gmachi            # answer where it came from
        sw    t0, IT_MACHI(s3)
        lw    t0, ip_gmaclo
        sw    t0, IT_MACLO(s3)
        lw    t0, ip_gwnd
        sw    t0, IT_WND(s3)
        lw    t0, ip_gmss
        sw    t0, IT_MSS(s3)
        lw    a0, ip_gseq
        addi  a0, a0, 1
        call  ip_tmod
        sw    a0, IT_RCV(s3)
        call  ip_tisn
        li    t0, IPD_TSYNRCVD
        sw    t0, IT_STATE(s3)
        call  ip_ttime
        call  ip_tsyn
        j     ip_wait

# ip_treply: answer the segment in the ip_g words, which has no
# connection, with a reset.
ip_treply:
        la    s3, ip_ttmp
        lw    t0, ip_gdport
        sw    t0, IT_LPORT(s3)
        lw    t0, ip_gsrc
        sw    t0, IT_RADDR(s3)
        lw    t0, ip_gsport
        sw    t0, IT_RPORT(s3)
        lw    t0, ip_gmachi
        sw    t0, IT_MACHI(s3)
        lw    t0, ip_gmaclo
        sw    t0, IT_MACLO(s3)
        li    t0, IPD_TBUF             # a window of 0
        sw    t0, IT_RLEN(s3)
        lw    t0, ip_gackf
        beqz  t0, 1f
        li    a0, IPD_FRST             # from where it says we are
        lw    a1, ip_gack
        j     2f
1:      lw    a0, ip_gseq              # acknowledging all of it
        lw    t0, ip_glen
        add   a0, a0, t0
        lw    t0, ip_gsyn
        add   a0, a0, t0
        lw    t0, ip_gfin
        add   a0, a0, t0
        call  ip_tmod
        sw    a0, IT_RCV(s3)
        li    a0, IPD_FRST + IPD_FACK
        li    a1, 0
2:      li    a3, 0
        call  ip_tsend
        j     ip_wait

# ip_tseg: the segment in the ip_g words is for connection s3.
ip_tseg:
        lw    s4, IT_STATE(s3)         # s4: its state
        li    t0, IPD_TDEAD
        beq   s4, t0, ip_wait
        li    t0, IPD_TSYNSENT
        beq   s4, t0, ip_tsynsent
        lw    t0, ip_grst
        beqz  t0, 1f
        lw    t0, ip_gseq              # a reset, if it is in order
        lw    t1, IT_RCV(s3)
        bne   t0, t1, ip_wait
        li    t0, IPD_TSYNRCVD
        bne   s4, t0, 11f
        sw    zero, IT_STATE(s3)       # never accepted: forget it
        j     ip_wait
11:     li    a0, E_RESET
        j     ip_tdie
1:      lw    t0, ip_gsyn
        beqz  t0, 2f
        li    t0, IPD_TSYNRCVD         # its SYN again: our answer was lost
        bne   s4, t0, 7f               # (or our ACK of its SYN+ACK)
        call  ip_tsyn
        j     ip_wait
2:      lw    t0, ip_gackf
        beqz  t0, ip_wait              # after a SYN, every segment has ACK
        li    t0, IPD_TSYNRCVD
        bne   s4, t0, 3f
        lw    t0, ip_gack              # the end of the handshake
        lw    t1, IT_NXT(s3)
        bne   t0, t1, ip_treply
        sw    t0, IT_UNA(s3)
        li    t0, IPD_TEST
        sw    t0, IT_STATE(s3)
        sw    zero, IT_DEAD(s3)
        sw    zero, IT_TRIES(s3)
        lw    t0, ip_gwnd
        sw    t0, IT_WND(s3)
        j     4f
3:      lw    a0, ip_gack              # what it acknowledges,
        lw    t0, IT_UNA(s3)
        sub   a0, a0, t0
        call  ip_tmod
        mv    s4, a0                   # s4: how much,
        lw    a0, IT_NXT(s3)
        lw    t0, IT_UNA(s3)
        sub   a0, a0, t0
        call  ip_tmod
        mv    s5, a0                   # s5: of what is in flight
        bgt   s4, s5, 4f               # more than was sent: ignore that
        lw    t0, ip_gwnd
        sw    t0, IT_WND(s3)
        bnez  t0, 6f
        sw    zero, IT_TRIES(s3)       # a closed window: probing it is no
6:      beqz  s4, 4f                   # sign the other end has gone
        lw    t0, ip_gack
        sw    t0, IT_UNA(s3)
        lw    t0, IT_FINSENT(s3)
        lw    t1, IT_FINACKED(s3)
        sub   t0, t0, t1
        sub   s5, s5, t0               # s5: the data in flight
        ble   s4, s5, 5f
        li    t0, 1                    # and our FIN
        sw    t0, IT_FINACKED(s3)
        mv    s4, s5
5:      call  ip_tbuf                  # those octets need not be kept
        lw    a1, IT_LEN(s3)
        sub   t0, a1, s4
        sw    t0, IT_LEN(s3)
        mv    a2, s4
        call  ip_tshift
        sw    zero, IT_TRIES(s3)
        sw    zero, IT_DEAD(s3)
        lw    t0, IT_UNA(s3)
        lw    t1, IT_NXT(s3)
        beq   t0, t1, 4f
        call  ip_ttime                 # some is still out
4:      lw    s4, ip_glen              # s4: its data's length
        lw    t0, ip_gfin
        add   t0, t0, s4
        beqz  t0, ip_wait              # nothing to take
        lw    t0, ip_gseq
        lw    t1, IT_RCV(s3)
        bne   t0, t1, 7f               # out of order, or again
        lw    t0, IT_FINRCVD(s3)
        bnez  t0, 7f
        lw    t0, IT_SHUT(s3)
        bnez  t0, 6f                   # nobody will read it: drop it all
        lw    t0, IT_RLEN(s3)
        li    t1, IPD_TBUF
        sub   t1, t1, t0               # t1: the room
        ble   s4, t1, 5f
        mv    s4, t1                   # s4: as much as fits
5:      call  ip_tbuf
        lw    t0, IT_RLEN(s3)
        add   a1, a1, t0
        lw    a0, ip_gdata
        mv    a2, s4
        call  ip_tcopy
        lw    t0, IT_RLEN(s3)
        add   t0, t0, s4
        sw    t0, IT_RLEN(s3)
6:      lw    a0, IT_RCV(s3)
        add   a0, a0, s4
        lw    t0, ip_glen
        bne   s4, t0, 8f               # not all of it: not its FIN either
        lw    t0, ip_gfin
        beqz  t0, 8f
        li    t0, 1
        sw    t0, IT_FINRCVD(s3)
        addi  a0, a0, 1
8:      call  ip_tmod
        sw    a0, IT_RCV(s3)
7:      call  ip_tack                  # say what we have
        j     ip_wait

# ip_tsynsent: the segment in the ip_g words is for connection s3,
# whose SYN is out: it should be the SYN+ACK.
ip_tsynsent:
        lw    t0, ip_gackf
        beqz  t0, ip_wait
        lw    t0, ip_gack
        lw    t1, IT_NXT(s3)
        beq   t0, t1, 1f
        lw    t0, ip_grst              # it acknowledges something else
        bnez  t0, ip_wait
        j     ip_treply
1:      lw    t0, ip_grst
        beqz  t0, 2f
        li    a0, E_REFUSED            # nothing listens there
        j     ip_tdie
2:      lw    t0, ip_gsyn
        beqz  t0, ip_wait
        lw    a0, ip_gseq
        addi  a0, a0, 1
        call  ip_tmod
        sw    a0, IT_RCV(s3)
        lw    t0, ip_gack
        sw    t0, IT_UNA(s3)
        lw    t0, ip_gwnd
        sw    t0, IT_WND(s3)
        lw    t0, ip_gmss
        sw    t0, IT_MSS(s3)
        li    t0, IPD_TEST
        sw    t0, IT_STATE(s3)
        sw    zero, IT_DEAD(s3)
        sw    zero, IT_TRIES(s3)
        call  ip_tack
        j     ip_wait

# ip_tdie: connection s3 has failed with a0: its calls get that.
ip_tdie:
        sw    a0, IT_ERR(s3)
        li    t0, IPD_TDEAD
        sw    t0, IT_STATE(s3)
        sw    zero, IT_DEAD(s3)
        j     ip_wait

# ip_tpush: connection s3, established and with nothing in flight: send
# what waits in its transmit buffer, as much as a segment and the other
# end's window take, and its FIN after the last octet once nothing more
# will be written. Clobbers a0..a5, t0..t5.
ip_tpush:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        lw    a3, IT_LEN(s3)           # a3: how much
        lw    t0, IT_MSS(s3)
        ble   a3, t0, 1f
        mv    a3, t0
1:      lw    t0, IT_WND(s3)
        bgtz  t0, 2f
        li    t0, 1                    # a closed window: probe it with one
2:      ble   a3, t0, 3f
        mv    a3, t0
3:      li    a4, 0                    # a4: 1 to send the FIN
        lw    t0, IT_WDONE(s3)
        beqz  t0, 4f
        lw    t0, IT_FINSENT(s3)
        bnez  t0, 4f
        lw    t0, IT_LEN(s3)
        bne   a3, t0, 4f
        li    a4, 1
        sw    a4, IT_FINSENT(s3)
4:      add   t0, a3, a4
        beqz  t0, 5f                   # nothing to send
        lw    a0, IT_UNA(s3)
        add   a0, a0, t0
        call  ip_tmod
        sw    a0, IT_NXT(s3)
        sw    zero, IT_TRIES(s3)
        call  ip_ttime
        call  ip_tdata
5:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# ip_tresend: send connection s3's segment in flight again. Clobbers
# a0..a5, t0..t5.
ip_tresend:
        lw    a0, IT_NXT(s3)
        lw    t0, IT_UNA(s3)
        sub   a0, a0, t0
        mv    t5, ra
        call  ip_tmod
        mv    ra, t5
        lw    a4, IT_FINSENT(s3)       # a4: 1 if that holds our FIN
        lw    t0, IT_FINACKED(s3)
        sub   a4, a4, t0
        sub   a3, a0, a4               # a3: and its data

# ip_tdata: send connection s3's segment at IT_UNA: a3 octets from its
# transmit buffer, and its FIN if a4 is 1. Clobbers a0..a5, t0..t5.
ip_tdata:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  ip_tbuf
        mv    a2, a0
        li    a0, IPD_FACK
        add   a0, a0, a4
        beqz  a3, 1f
        addi  a0, a0, IPD_FPSH
1:      lw    a1, IT_UNA(s3)
        call  ip_tsend
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# ip_tsyn: send connection s3's SYN, or SYN+ACK if it answers one.
# ip_tack: send connection s3 a bare ACK. ip_trst: reset connection s3.
# Clobber a0..a5, t0..t5.
ip_tsyn:
        li    a0, IPD_FSYN
        lw    t0, IT_STATE(s3)
        li    t1, IPD_TSYNRCVD
        bne   t0, t1, 1f
        li    a0, IPD_FSYN + IPD_FACK
1:      lw    a1, IT_UNA(s3)
        li    a3, 0
        j     ip_tsend
ip_tack:
        li    a0, IPD_FACK
        j     1f
ip_trst:
        li    a0, IPD_FRST + IPD_FACK
1:      lw    a1, IT_NXT(s3)
        li    a3, 0

# ip_tsend: send connection s3 a segment: flags a0, sequence number a1,
# a3 octets of data from a2, acknowledging IT_RCV if a0 has IPD_FACK,
# and with the MSS option if it has IPD_FSYN. a0 is how it went.
# Clobbers a1..a5, t0..t5.
ip_tsend:
        addi  sp, sp, -21
        sw    ra, 0(sp)
        sw    s1, 3(sp)
        sw    s2, 6(sp)
        sw    s4, 9(sp)
        sw    s5, 12(sp)
        sw    s6, 15(sp)
        sw    s7, 18(sp)
        mv    s4, a0                   # s4: the flags
        mv    s5, a1                   # s5: the sequence number
        mv    s6, a2                   # s6: the data
        mv    s7, a3                   # s7: its length
        li    s2, IPD_TCPHDR           # s2: the header's length
        li    t0, IPD_FSYN
        div   t1, s4, t0
        li    t0, 2
        rem   t1, t1, t0
        beqz  t1, 1f
        addi  s2, s2, 4                # the MSS option
1:      li    s1, IPD_TX
        mv    a0, s1
        lw    a1, IT_MACHI(s3)
        lw    a2, IT_MACLO(s3)
        call  ip_putmac
        call  ip_ethtail
        add   a0, s2, s7
        addi  a0, a0, IPD_IHDR - IPD_HDR
        li    a1, IPD_TCP
        lw    a2, IT_RADDR(s3)
        call  ip_iphead
        addi  s1, s1, IPD_IHDR         # s1: the TCP header
        addi  a0, s1, IPD_TSPORT
        lw    a1, IT_LPORT(s3)
        li    a2, 2
        call  ip_putn
        addi  a0, s1, IPD_TDPORT
        lw    a1, IT_RPORT(s3)
        li    a2, 2
        call  ip_putn
        addi  a0, s1, IPD_TSEQ
        mv    a1, s5
        li    a2, 4
        call  ip_putn
        li    a1, 0
        li    t0, IPD_FACK
        div   t1, s4, t0
        li    t0, 2
        rem   t1, t1, t0
        beqz  t1, 2f
        lw    a1, IT_RCV(s3)
2:      addi  a0, s1, IPD_TACK
        li    a2, 4
        call  ip_putn
        li    t0, 4
        div   t1, s2, t0
        li    t0, 16
        mul   t1, t1, t0
        st    t1, IPD_TOFF(s1)
        st    s4, IPD_TFLAGS(s1)
        lw    t0, IT_RLEN(s3)          # the window: the room to receive
        li    a1, IPD_TBUF
        sub   a1, a1, t0
        addi  a0, s1, IPD_TWND
        li    a2, 2
        call  ip_putn
        st    zero, IPD_TCSUM(s1)
        st    zero, IPD_TCSUM + 1(s1)
        st    zero, IPD_TURG(s1)
        st    zero, IPD_TURG + 1(s1)
        li    t0, IPD_TCPHDR
        beq   s2, t0, 3f
        li    t0, 2                    # kind 2, 4 long: our MSS
        st    t0, IPD_TCPHDR(s1)
        li    t0, 4
        st    t0, IPD_TCPHDR + 1(s1)
        addi  a0, s1, IPD_TCPHDR + 2
        li    a1, IPD_TBUF
        li    a2, 2
        call  ip_putn
3:      mv    a0, s6
        add   a1, s1, s2
        mv    a2, s7
        call  ip_tcopy
        lw    a0, IT_RADDR(s3)
        add   a1, s2, s7
        li    a3, IPD_TCP
        call  ip_pseudo
        mv    a0, s1
        add   a1, s2, s7
        call  ip_sum
        mv    a1, a0
        addi  a0, s1, IPD_TCSUM
        li    a2, 2
        call  ip_putn
        add   a4, s2, s7
        addi  a4, a4, IPD_IHDR
        call  ip_send
        lw    ra, 0(sp)
        lw    s1, 3(sp)
        lw    s2, 6(sp)
        lw    s4, 9(sp)
        lw    s5, 12(sp)
        lw    s6, 15(sp)
        lw    s7, 18(sp)
        addi  sp, sp, 21
        ret

# ip_tisn: give connection s3 its first sequence number, from the clock:
# its SYN's. Clobbers a0, t0.
ip_tisn:
        mv    t5, ra
        csrr  a0, time
        call  ip_tmod
        sw    a0, IT_UNA(s3)
        addi  a0, a0, 1
        call  ip_tmod
        sw    a0, IT_NXT(s3)
        jalr  zero, 0(t5)

# ip_ttime: connection s3 sends again IPD_RTO from now. Clobbers t0, t1.
ip_ttime:
        csrr  t0, time
        li    t1, IPD_RTO
        add   t0, t0, t1
        sw    t0, IT_DEAD(s3)
        ret

# ip_tmod: a0 = a0 modulo 2^32, from 0 up: sequence numbers. Clobbers t0.
ip_tmod:
        li    t0, IPD_LIMIT
        rem   a0, a0, t0
        bgez  a0, 1f
        add   a0, a0, t0
1:      ret

# ip_tcb: a0 = the record of connection a0. Clobbers t0.
ip_tcb:
        li    t0, IT_SIZE
        mul   t0, a0, t0
        la    a0, ip_tcbs
        add   a0, a0, t0
        ret

# ip_tbuf: a0 = connection s3's transmit buffer, a1 its receive buffer.
# Clobbers t0, t1.
ip_tbuf:
        la    t0, ip_tcbs
        sub   t0, s3, t0
        li    t1, IT_SIZE
        div   t0, t0, t1
        li    t1, IPD_TBUF
        mul   t0, t0, t1
        li    a0, IPD_TBUFS
        add   a0, a0, t0
        li    a1, IPD_RBUFS
        add   a1, a1, t0
        ret

# ip_tshift: drop the first a2 of the a1 trytes buffer a0 holds, moving
# the rest to its start. ip_tcopy: copy a2 trytes from a0 to a1, first
# to last, so a1 may be below a0 where they overlap. Clobber a0..a2,
# t0..t2.
ip_tshift:
        sub   t0, a1, a2
        mv    a1, a0
        add   a0, a0, a2
        mv    a2, t0
ip_tcopy:
        li    t0, 0
1:      bge   t0, a2, 2f
        add   t1, a0, t0
        lt    t1, 0(t1)
        add   t2, a1, t0
        st    t1, 0(t2)
        addi  t0, t0, 1
        j     1b
2:      ret

# ip_talloc: s3 = a free connection's record, all 0, or 0 if none is
# free. Clobbers t0..t2.
ip_talloc:
        la    s3, ip_tcbs
        li    t0, IPD_NTCP
1:      lw    t1, IT_STATE(s3)
        beqz  t1, 2f
        addi  s3, s3, IT_SIZE
        addi  t0, t0, -1
        bnez  t0, 1b
        li    s3, 0
        ret
2:      li    t1, 0
3:      add   t2, s3, t1
        sw    zero, 0(t2)
        addi  t1, t1, 3
        li    t2, IT_SIZE
        blt   t1, t2, 3b
        ret

# ip_tfind: s3 = the connection the segment in the ip_g words belongs
# to, 0 if none. Clobbers t0..t5.
ip_tfind:
        la    s3, ip_tcbs
        li    t0, IPD_NTCP
        lw    t3, ip_gdport
        lw    t4, ip_gsport
        lw    t5, ip_gsrc
1:      lw    t1, IT_STATE(s3)
        li    t2, IPD_TSYNSENT
        blt   t1, t2, 2f               # free, or no SYN out yet
        lw    t1, IT_LPORT(s3)
        bne   t1, t3, 2f
        lw    t1, IT_RPORT(s3)
        bne   t1, t4, 2f
        lw    t1, IT_RADDR(s3)
        beq   t1, t5, 3f
2:      addi  s3, s3, IT_SIZE
        addi  t0, t0, -1
        bnez  t0, 1b
        li    s3, 0
3:      ret

# ip_tlistener: a0 = the process listening on TCP port a0, IPD_NONE for
# nobody. Clobbers t0..t2.
ip_tlistener:
        la    t0, ip_tlport
        li    t1, 0
1:      lw    t2, 0(t0)
        beq   t2, a0, 2f
        addi  t0, t0, 3
        addi  t1, t1, 1
        li    t2, NPROC
        blt   t1, t2, 1b
        li    a0, IPD_NONE
        ret
2:      mv    a0, t1
        ret

# ip_tport: a0 = a TCP port from IPD_EPHEMERAL up that no connection or
# listener has, 0 if every one is taken. Clobbers a1, t0..t2.
ip_tport:
        li    a1, 65536 - IPD_EPHEMERAL   # a1: how many are left to try
1:      lw    a0, ip_ephem
        addi  t0, a0, 1
        li    t1, 65536
        blt   t0, t1, 2f
        li    t0, IPD_EPHEMERAL
2:      sw    t0, ip_ephem
        la    t0, ip_tcbs
        li    t1, IPD_NTCP
3:      lw    t2, IT_STATE(t0)
        beqz  t2, 4f
        lw    t2, IT_LPORT(t0)
        beq   t2, a0, 6f
4:      addi  t0, t0, IT_SIZE
        addi  t1, t1, -1
        bnez  t1, 3b
        la    t0, ip_tlport
        li    t1, NPROC
5:      lw    t2, 0(t0)
        beq   t2, a0, 6f
        addi  t0, t0, 3
        addi  t1, t1, -1
        bnez  t1, 5b
        ret
6:      addi  a1, a1, -1
        bnez  a1, 1b
        li    a0, 0
        ret

ip_net:     .word 0                    # the network server
ip_machi:   .word 0                    # the interface's Ethernet address
ip_maclo:   .word 0
ip_addr:    .word IPD_ADDR             # ours,
ip_prefix:  .word IPD_PREFIX           # how much of it names the network,
ip_gateway: .word IPD_GATEWAY          # and the way off it (0 for none)
ip_dns:     .word IPD_NAMESERVER       # the name server, for resolvers
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
ip_tlport:  .words NPROC               # each process's TCP listening port,
ip_hkind:   .words NPROC               # its held call on a connection (IPD_H...),
ip_htcb:    .words NPROC               # on which,
ip_hbuf:    .words NPROC               # its buffer,
ip_hn:      .words NPROC               # its n,
ip_hdone:   .words NPROC               # and, writing, how much has gone
ip_gsrc:    .word 0                    # the segment being looked at: from,
ip_gsport:  .word 0                    # its ports,
ip_gdport:  .word 0
ip_gseq:    .word 0                    # sequence number,
ip_gack:    .word 0                    # acknowledgment,
ip_gwnd:    .word 0                    # window,
ip_gmss:    .word 0                    # MSS,
ip_gdata:   .word 0                    # its data,
ip_glen:    .word 0                    # how long,
ip_gmachi:  .word 0                    # the Ethernet address it came from,
ip_gmaclo:  .word 0
ip_gfin:    .word 0                    # and its flags, 1 or 0 each
ip_gsyn:    .word 0
ip_grst:    .word 0
ip_gackf:   .word 0
ip_ttmp:    .words IT_SIZE / 3         # ip_treply's connection
ip_tcbs:    .words IPD_NTCP * IT_SIZE / 3   # the connections
ip_name:    .string "ip"
ip_netname: .string "net"
ip_myname:  .string "ipd"
        .nocompress
