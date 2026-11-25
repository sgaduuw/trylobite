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
_start: mv    s1, a0
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
3:      mv    a0, s1
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
        mv    a0, t0
        sys
        li    t0, I32_MASK
        band  a0, a0, t0
        ret

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
# byte that differs is lower, the same or higher in a.
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
        ret
