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
