# Process 0: send 1, 2 and 3 to process 1. A full mailbox means pong has
# not caught up, so yield and try again.

        .section user0, P_USER0 * PAGE, V_USER   # loaded here, runs at V_USER

ping:   li    s0, 1
1:      la    a1, ping_msg
        addi  t0, s0, '0'
        st    t0, PING_DIGIT(a1)               # patch the number into the line
        li    a0, SYS_PUTS
        sys
2:      li    a0, SYS_SEND
        li    a1, 1
        mv    a2, s0
        sys
        beqz  a0, 3f
        li    a0, SYS_YIELD
        sys
        j     2b
3:      addi  s0, s0, 1
        li    t0, 4
        blt   s0, t0, 1b
        li    a0, SYS_EXIT
        li    a1, 0
        sys

        .equ  PING_DIGIT, 14                   # the ? below
ping_msg: .string "ping: sending ?\n"
