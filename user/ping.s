# Program 1: learn pong's process number from a message, then send it 1, 2
# and 3. A full mailbox means pong has not caught up: yield and retry.

        .section prog1, P_PROG1 * PAGE, V_USER

ping:   li    a0, SYS_RECV
        sys
        mv    s1, a0                   # s1: pong
        li    s0, 1
1:      la    a1, ping_msg
        addi  t0, s0, '0'
        st    t0, PING_DIGIT(a1)       # patch the number into the line
        li    a0, SYS_PUTS
        sys
2:      li    a0, SYS_SEND
        mv    a1, s1
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
