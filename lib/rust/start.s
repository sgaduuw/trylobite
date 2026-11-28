# Start code and runtime for a Rust program (detrytus docs/rust.md).
# tools/fs.py has `detrytus ll` translate the program with
# include/layout.s and this file included ahead of it.
#
# spawnw starts a process at V_USER with a0 = argc, a1 = argv, a block
# of words. Rust lays out an array of pointers 4 bytes (trytes) apiece,
# each byte 0..255, so the start code copies argv that way onto the
# stack and calls main(argc, argv). What main returns, an i32 held as
# its unsigned value, is the exit code.

        .equ  RUST_PANIC, 101          # the exit code of a panic, as Rust's
        .equ  I32_MASK, 4294967295     # 2^32 - 1
        .equ  I32_SIGN, 2147483648     # 2^31

        .section program, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw
_start: la    tp, rt$more              # the first thread's own words (sys)
        mv    s1, a0
        mv    s2, a1
        li    t0, 4                    # room for argc pointers, in words
        mul   t1, a0, t0
        addi  t1, t1, 2
        li    t0, 3
        div   t1, t1, t0
        mul   t1, t1, t0
        sub   sp, sp, t1
        addi  s3, sp, -1               # the copy: its lowest tryte
        li    t2, 255
        li    t3, -8
        mv    t4, s3                   # where the next pointer goes
        mv    t5, s2                   # the next word of argv
        li    t6, 0
1:      bge   t6, s1, 3f
        lw    a2, 0(t5)
        li    a3, 4
2:      band  a4, a2, t2               # a pointer's bytes, low first
        st    a4, 0(t4)
        bsh   a2, a2, t3
        addi  t4, t4, 1
        addi  a3, a3, -1
        bnez  a3, 2b
        addi  t5, t5, 3
        addi  t6, t6, 1
        j     1b
3:      la    t0, rt$argc              # for trystd's env::args
        sw    s1, 0(t0)
        sw    s3, 3(t0)
        mv    a0, s1
        mv    a1, s3
        call  main
        li    t0, I32_SIGN             # the i32 as a signed value
        bxor  a0, a0, t0
        sub   a1, a0, t0
        li    a0, SYS_EXIT
        sys

# abort(): what a panic does.
abort:  li    a1, RUST_PANIC
        li    a0, SYS_EXIT
        sys

# exit(code): end the program; code is an i32.
exit:   li    t0, I32_SIGN
        bxor  a0, a0, t0
        sub   a1, a0, t0
        li    a0, SYS_EXIT
        sys

# write(fd, buf, n) and read(fd, buf, n): how many bytes, or a negative
# error, as an isize (held as its unsigned 32-bit value).
write:  li    t0, SYS_WRITE
        j     1f
read:   li    t0, SYS_READ
1:      mv    a3, a2
        mv    a2, a1
        mv    a1, a0
2:      mv    a0, t0                   # again after a signal's E_INTR (sysu)
        sys
        li    t1, E_INTR
        beq   a0, t1, 2b
        li    t0, I32_MASK
        band  a0, a0, t0
        ret

# brk(end): the break, the first address past the heap, once it reaches
# end (SYS_BRK; BRK_QUERY asks), or a negative error, as an isize.
brk:    mv    a1, a0
        li    a0, SYS_BRK
        sys
        li    t0, I32_MASK
        band  a0, a0, t0
        ret

# sys(n, a, b, c, d, e): system call n with a to e in a1 to a5, each an
# i32 taken signed (so -1 is FOR_SELF, not 2^32 - 1), and an address
# below 2^31 as it is: a0 as an i32. sysu(n, a, b, c, d, e) is the same
# with a to e taken unsigned, for an IPv4 address of 2^31 or more. What
# the call leaves in a1 to a3 is kept for sys_more(k) (lib/rust/trystd),
# in three words at tp: each thread's own, so that threads calling at
# once do not take each other's (rt$more for the first, which _start
# points tp at; trystd's thread::spawn gives each other its own).
sys:    li    t0, I32_SIGN
        bxor  a1, a1, t0
        sub   a1, a1, t0
        bxor  a2, a2, t0
        sub   a2, a2, t0
        bxor  a3, a3, t0
        sub   a3, a3, t0
        bxor  a4, a4, t0
        sub   a4, a4, t0
        bxor  a5, a5, t0
        sub   a5, a5, t0
sysu:   mv    t1, a0
1:      sys
        li    t2, E_INTR               # a caught signal cut it short: its
        bne   a0, t2, 2f               # handler has run, and the call had
        mv    a0, t1                   # not happened, so it goes again, as
        j     1b                       # with SA_RESTART
2:      sw    a1, 0(tp)
        sw    a2, 3(tp)
        sw    a3, 6(tp)
        li    t0, I32_MASK
        band  a0, a0, t0
        ret

# clock(): the time of day (SYS_CLOCK), split for Rust, whose i64 is
# two limbs: the seconds' low 32 bits as a u32; after it, sys_more(0)
# is their high part (the seconds >> 32, an i32) and sys_more(1) the
# microseconds.
clock:  li    a0, SYS_CLOCK
        sys
        li    t0, I32_MASK
        band  t1, a0, t0
        sub   a0, a0, t1
        li    t2, 4294967296           # 2^32: exact, the low bits are gone
        div   a0, a0, t2
        la    t0, rt$more
        sw    a0, 0(t0)
        sw    a1, 3(t0)
        mv    a0, t1
        ret

# sleep_ticks(n): wait n ticks of the time CSR. SYS_SLEEP takes the
# time to wake at, a word, which outgrows an i32 after 35 minutes, so
# the sum is made here.
sleep_ticks:
        csrr  a1, time
        add   a1, a1, a0
1:      li    a0, SYS_SLEEP            # until then, a signal or not
        sys
        li    t0, E_INTR
        beq   a0, t0, 1b
        ret

# alarm_ticks(n, how): SYS_ALARM n ticks from now, n a u32: the time
# to ring at is a word, made here as sleep_ticks makes its own.
alarm_ticks:
        mv    a2, a1
        csrr  a1, time
        add   a1, a1, a0
        li    a0, SYS_ALARM
        sys
        ret

# sys_more(k): a1 (k = 0), a2 or a3 as the last sys or sysu left it,
# as an i32.
sys_more:
        li    t0, 3
        mul   a0, a0, t0
        add   t0, tp, a0
        lw    a0, 0(t0)
        li    t0, I32_MASK
        band  a0, a0, t0
        ret

# word_at(address): the word at an aligned address, as an i32, such as
# one of the ST_ words stat leaves.
word_at:
        lw    a0, 0(a0)
        li    t0, I32_MASK
        band  a0, a0, t0
        ret

# word_split(address): the word at an aligned address whole, which may
# not fit an i32 (a count of ticks): a0 = its low 32 bits, and
# sys_more(0) the rest, as clock splits its seconds.
word_split:
        lw    a0, 0(a0)
        li    t0, I32_MASK
        band  t1, a0, t0
        sub   a0, a0, t1
        li    t2, 4294967296           # 2^32: exact, the low bits are gone
        div   a0, a0, t2
        la    t0, rt$more
        sw    a0, 0(t0)
        mv    a0, t1
        ret

# ticks(): the time CSR, split as word_split splits a word.
ticks:  csrr  a0, time
        li    t0, I32_MASK
        band  t1, a0, t0
        sub   a0, a0, t1
        li    t2, 4294967296
        div   a0, a0, t2
        la    t0, rt$more
        sw    a0, 0(t0)
        mv    a0, t1
        ret

# sleep_until(low, high): SYS_SLEEP until the time high * 2^32 + low,
# low a u32 and high an i32: a time of ticks past what an i32 holds.
sleep_until:
        li    t0, I32_SIGN
        bxor  a1, a1, t0
        sub   a1, a1, t0
        li    t0, 4294967296
        mul   a1, a1, t0
        add   a1, a1, a0
1:      li    a0, SYS_SLEEP            # until then, a signal or not
        sys
        li    t0, E_INTR
        beq   a0, t0, 1b
        ret

# alarm_until(low, high): SYS_ALARM at that time, given as sleep_until's,
# for a NOTE_ALARM notice from receive (ALARM_NOTICE, not a signal).
alarm_until:
        li    t0, I32_SIGN
        bxor  a1, a1, t0
        sub   a1, a1, t0
        li    t0, 4294967296
        mul   a1, a1, t0
        add   a1, a1, a0
        li    a2, ALARM_NOTICE
        li    a0, SYS_ALARM
        sys
        ret

# argc() and argv(): main's arguments, as start passed them.
argc:   la    t0, rt$argc
        lw    a0, 0(t0)
        ret
argv:   la    t0, rt$argc
        lw    a0, 3(t0)
        ret

        .align 1
rt$more: .word 0                        # a1, a2 and a3 (sys), the first thread's
        .word 0
        .word 0
rt$argc: .word 0                        # argc, then argv
        .word 0

# strlen(s)
strlen: mv    t0, a0
1:      lt    t1, 0(t0)
        beqz  t1, 2f
        addi  t0, t0, 1
        j     1b
2:      sub   a0, t0, a0
        ret

# memcpy(dst, src, n) and memmove(dst, src, n): dst.
memmove:
        blt   a1, a0, 3f               # dst above src: copy from the end
memcpy: mv    t0, a0
        add   t2, a1, a2
1:      bge   a1, t2, 2f
        lt    t1, 0(a1)
        st    t1, 0(t0)
        addi  a1, a1, 1
        addi  t0, t0, 1
        j     1b
2:      ret
3:      add   t0, a0, a2
        add   a1, a1, a2
4:      beq   t0, a0, 2b
        addi  t0, t0, -1
        addi  a1, a1, -1
        lt    t1, 0(a1)
        st    t1, 0(t0)
        j     4b

# memset(dst, byte, n): dst.
memset: mv    t0, a0
        add   t2, a0, a2
1:      bge   t0, t2, 2f
        st    a1, 0(t0)
        addi  t0, t0, 1
        j     1b
2:      ret

# memcmp(a, b, n) and bcmp(a, b, n): below, at or above 0 as the first
# byte that differs is lower, the same or higher in a, an i32 held as
# its unsigned value, as the translated code holds every i32.
bcmp:
memcmp: add   t2, a0, a2
1:      bge   a0, t2, 2f
        lt    t0, 0(a0)
        lt    t1, 0(a1)
        bne   t0, t1, 3f
        addi  a0, a0, 1
        addi  a1, a1, 1
        j     1b
2:      li    a0, 0
        ret
3:      sub   a0, t0, t1
        li    t0, I32_MASK
        band  a0, a0, t0
        ret
