# echo: say the arguments after the command on standard output, a space
# between each and a newline after, as Unix's echo does; exit with 0, or
# with 1 if output fails. The simplest use of a program's arguments:
# a0 is how many there are, the command included, and a1 the address of
# a word per argument, each the address of its string (ARG_MAX in
# include/layout.s).

        .include "../include/layout.s"
        .compress
        .section echo, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

echo:   addi  s0, a0, -1               # s0: arguments left, past the command
        addi  s1, a1, 3                # s1: the next one's word
        li    s2, 0                    # s2: 1 once output has failed
        blez  s0, 3f
1:      lw    a2, 0(s1)
        mv    a3, a2                   # its length
2:      lt    t0, 0(a3)
        beqz  t0, 0f
        addi  a3, a3, 1
        j     2b
0:      sub   a3, a3, a2
        call  ec_out
        addi  s1, s1, 3
        addi  s0, s0, -1
        blez  s0, 3f
        la    a2, ec_space
        li    a3, 1
        call  ec_out
        j     1b
3:      la    a2, ec_newline
        li    a3, 1
        call  ec_out
        mv    a1, s2
        li    a0, SYS_EXIT
        sys

# ec_out: write a3 trytes from a2 to standard output, and set s2 if that
# fails. Clobbers a0..a5.
ec_out: li    a0, SYS_WRITE
        li    a1, STDOUT
        sys
        bgez  a0, 1f
        li    s2, 1
1:      ret

ec_space:   .string " "
ec_newline: .string "\n"
        .nocompress
