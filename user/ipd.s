# The IP server: the first layer of the network stack above the network
# server. It registers as "ip", protocol IP_PROTOCOL, once it has found
# "net", learned the interface's address and become its listener
# (NT_LISTEN); clients find it by that name (SYS_LOOKUP).
#
# It speaks ARP and ICMP echo over IPv4: it answers ARP requests for its
# own address and keeps what ARP tells it in a small cache, it answers
# pings, and IP_PING sends one for a client (include/layout.s). Its
# address is 10.0.0.2/24 with gateway 10.0.0.1 until IP_CONFIG says
# otherwise.
#
# Like every server it waits only in its own receive. The network server
# notifies it (NOTE_SIGNAL) when a frame waits, and its NT_RECEIVE then
# takes the frame at once; a ping's time limit is its alarm (SYS_ALARM),
# which comes as NOTE_ALARM. One ping is under way at a time: it waits
# for the next hop's address first, if the cache lacks it, then for the
# echo reply.
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
        li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, ip_notice
        mv    s0, a0                   # s0: the caller
        li    a5, E_INVAL
        li    t0, IP_PING
        beq   a1, t0, ip_ping
        li    t0, IP_ADDRESS
        beq   a1, t0, ip_address
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
        csrr  a1, time
        add   a1, a1, s1
        li    a0, SYS_ALARM
        sys
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
        li    a0, SYS_ALARM
        li    a1, NO_ALARM
        sys
        j     ip_wait

ip_notice:
        li    t0, NOTE_SIGNAL
        beq   a1, t0, ip_frame
        li    t0, NOTE_ALARM
        bne   a1, t0, 1f
        lw    t0, ip_pinger            # the ping has run out of time
        bltz  t0, ip_wait
        li    a5, E_TIMEDOUT
        j     ip_done
1:      li    t0, NOTE_ENDED
        bne   a1, t0, ip_wait
        lw    t0, ip_net
        li    a0, E_IO                 # the network server is gone
        beq   a2, t0, ip_quit
        lw    t0, ip_pinger
        beq   a2, t0, ip_forget        # nobody to answer now
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
# speaks to us, answer a request, and send a ping waiting for the
# sender's address on its way.
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
1:      lw    t0, ip_pstate
        li    t1, IPD_ARP
        bne   t0, t1, ip_wait
        lw    t0, ip_hop
        bne   t0, s3, ip_wait
        mv    a1, s4                   # the ping's hop: on with it
        mv    a2, s5
        j     ip_echo

# ip_ipv4: an IPv4 packet in frame s1, s2 long. Only ICMP to our own
# address is for us: answer an echo request, and take the reply the
# ping waits for.
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
        call  ip_sum
        bnez  a0, ip_wait              # damaged
        lt    t0, IPD_PROTO(s1)
        li    t1, 1
        bne   t0, t1, ip_wait
        add   s5, s1, s3
        addi  s5, s5, IPD_HDR          # s5: the ICMP message
        sub   s4, s4, s3               # s4: its length
        li    t0, IPD_CDATA
        blt   s4, t0, ip_wait
        mv    a0, s5
        mv    a1, s4
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
        call  ip_sum
        mv    a1, a0
        addi  a0, s2, IPD_CCSUM
        li    a2, 2
        call  ip_putn
        addi  a4, s4, IPD_IHDR
        call  ip_send
        j     ip_wait

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

# ip_sum: a0 = the Internet checksum of the a1 octets at a0: the ones'
# complement of their ones'-complement sum, as 16-bit words, an odd last
# octet padded with 0. Over a header or message holding its own checksum
# it is 0 when that is right. Clobbers a1, t0, t1, t3.
ip_sum:
        li    t3, 0                    # t3: the sum
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
ip_arps:    .words 3 * IPD_ARPS        # address, Ethernet address halves
ip_tx:      .zero FRAME_MAX            # the frame being sent
ip_rx:      .zero FRAME_MAX            # the frame being looked at
ip_name:    .string "ip"
ip_netname: .string "net"
ip_myname:  .string "ipd"
        .nocompress
