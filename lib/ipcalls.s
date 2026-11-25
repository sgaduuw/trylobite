# ip_server(): the IP server's process number, or E_NOPROC when there
# is no IP server or it speaks another protocol than IP_PROTOCOL.
# ip_query(ip, words): IP server ip's address, prefix length and gateway
# in words[0] to words[2]; a0 is how the call went. In assembly because
# the answers come in several registers. For Trice programs, through
# lib/ip.tc.

        .global ip_server, ip_query
ip_server:
        li    a0, SYS_LOOKUP
        la    a1, ip$name
        li    a2, LOOKUP_NOW
        sys
        bltz  a0, 1f
        li    t0, IP_PROTOCOL
        beq   a1, t0, 2f
1:      li    a0, E_NOPROC
2:      ret

ip_query:
        mv    t1, a1                   # a system call leaves t1 as it was
        mv    a1, a0
        li    a0, SYS_CALL
        li    a2, IP_ADDRESS
        sys
        sw    a1, 0(t1)
        sw    a2, 3(t1)
        sw    a3, 6(t1)
        ret
ip$name: .string "ip"
        .align 1
