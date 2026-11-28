# Program 2: spin first, with no system calls, so only the timer can let
# ping run; then receive three messages.

        .compress
        .section prog2, (P_PROG0 + 2) * PAGE, V_USER
        .gp   USER_GP                  # set by spawn

        .equ  SPIN, QUANTUM            # rounds of 3 steps: past a slice

pong:   li    a0, SYS_NAME             # for ps: a program of the image
        la    a1, pong_myname          # has no argv[0] to name it
        sys
        li    s1, 0
1:      addi  s1, s1, 1
        li    t0, SPIN
        blt   s1, t0, 1b
        li    s0, 0
2:      li    a0, SYS_RECV
        sys
        la    a1, pong_msg
        addi  t0, a0, '0'
        st    t0, PONG_DIGIT(a1)
        li    a0, SYS_PUTS
        sys
        addi  s0, s0, 1
        li    t0, 3
        blt   s0, t0, 2b
        li    a0, SYS_EXIT
        li    a1, 0
        sys

        .equ  PONG_DIGIT, 10
pong_msg: .string "pong: got ?\n"
pong_myname: .string "pong"
        .nocompress
