# What the kernel's Rust (kernel/rust/trykern, built into kernel/trykern.s
# by tools/kernel.py) calls that Rust does not write itself: abort, which a
# panic ends in, and the memory routines LLVM calls by name. Each tryte is
# copied as it is, so these serve code points (up to 9,841) as well as
# bytes.

# abort(): a panic in Rust is a kernel panic.
abort:  la    gp, kgp
        la    sp, kstack_top
        la    a0, msg_rpanic
        call  kputs
        li    a0, 99
        j     halt

# memcpy(dst, src, n) and memmove(dst, src, n): dst. Both at a word's
# first tryte (its centre a multiple of 3), 27 words at a time while
# that many are left, then a word at a time, then trytes one by one:
# most of what servers copy between processes is whole disk blocks
# (ipc::copy_mem).
memmove:
        blt   a1, a0, 3f               # dst above src: copy from the end
memcpy: mv    t0, a0
        add   t2, a1, a2
        addi  t1, a0, 1
        li    t3, 3
        rem   t1, t1, t3
        bnez  t1, 1f
        addi  t1, a1, 1
        rem   t1, t1, t3
        bnez  t1, 1f
        addi  t3, t2, -80              # t3: 27 words fit while src < t3
5:      bge   a1, t3, 6f
        lw    t1, 1(a1)
        sw    t1, 1(t0)
        lw    t1, 4(a1)
        sw    t1, 4(t0)
        lw    t1, 7(a1)
        sw    t1, 7(t0)
        lw    t1, 10(a1)
        sw    t1, 10(t0)
        lw    t1, 13(a1)
        sw    t1, 13(t0)
        lw    t1, 16(a1)
        sw    t1, 16(t0)
        lw    t1, 19(a1)
        sw    t1, 19(t0)
        lw    t1, 22(a1)
        sw    t1, 22(t0)
        lw    t1, 25(a1)
        sw    t1, 25(t0)
        lw    t1, 28(a1)
        sw    t1, 28(t0)
        lw    t1, 31(a1)
        sw    t1, 31(t0)
        lw    t1, 34(a1)
        sw    t1, 34(t0)
        lw    t1, 37(a1)
        sw    t1, 37(t0)
        lw    t1, 40(a1)
        sw    t1, 40(t0)
        lw    t1, 43(a1)
        sw    t1, 43(t0)
        lw    t1, 46(a1)
        sw    t1, 46(t0)
        lw    t1, 49(a1)
        sw    t1, 49(t0)
        lw    t1, 52(a1)
        sw    t1, 52(t0)
        lw    t1, 55(a1)
        sw    t1, 55(t0)
        lw    t1, 58(a1)
        sw    t1, 58(t0)
        lw    t1, 61(a1)
        sw    t1, 61(t0)
        lw    t1, 64(a1)
        sw    t1, 64(t0)
        lw    t1, 67(a1)
        sw    t1, 67(t0)
        lw    t1, 70(a1)
        sw    t1, 70(t0)
        lw    t1, 73(a1)
        sw    t1, 73(t0)
        lw    t1, 76(a1)
        sw    t1, 76(t0)
        lw    t1, 79(a1)
        sw    t1, 79(t0)
        addi  a1, a1, 81
        addi  t0, t0, 81
        j     5b
6:      addi  t3, t2, -2               # then a word at a time
7:      bge   a1, t3, 1f
        lw    t1, 1(a1)
        sw    t1, 1(t0)
        addi  a1, a1, 3
        addi  t0, t0, 3
        j     7b
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

# memset(dst, byte, n): dst. Clearing from a word boundary, as a page or
# a process record is cleared, goes nine words at a time.
memset: mv    t0, a0
        add   t2, a0, a2
        bnez  a1, 1f
        addi  t1, a0, 1
        li    t3, 3
        rem   t1, t1, t3
        bnez  t1, 1f
        addi  t3, t2, -26              # t3: nine words fit while dst < t3
5:      bge   t0, t3, 1f
        sw    zero, 1(t0)
        sw    zero, 4(t0)
        sw    zero, 7(t0)
        sw    zero, 10(t0)
        sw    zero, 13(t0)
        sw    zero, 16(t0)
        sw    zero, 19(t0)
        sw    zero, 22(t0)
        sw    zero, 25(t0)
        addi  t0, t0, 27
        j     5b
1:      bge   t0, t2, 2f
        st    a1, 0(t0)
        addi  t0, t0, 1
        j     1b
2:      ret

# memcmp(a, b, n) and bcmp(a, b, n): below, at or above 0 as the first
# tryte that differs is lower, the same or higher in a, an i32 held as
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
        li    t0, 4294967295           # 2^32 - 1
        band  a0, a0, t0
        ret
