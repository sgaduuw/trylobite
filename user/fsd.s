# The file server (docs/filesystem.md): a process that owns the
# filesystem on the disk and answers other processes' calls to open,
# read, write, make and remove its files and directories. It is Rust,
# user/rust/fsd over lib/rust/tryfs, which the host's disk tool shares;
# tools/server.py translates it into user/fsd-rust.s, which this file
# includes after the start code and runtime the Rust calls. It registers
# as "fs", protocol FS_PROTOCOL, before it takes its first call.
#
# Not a program on its own: a build includes it in a program's section.
# Its image takes more than one page, which its first word says
# (IMAGE_PAGES), so the build starts the next program's section
# FS_PAGES pages after this one's. Every label here starts with fs_, and
# every one the translation defines with fs$, since a build has one
# symbol table.

        .equ  FS_I32_MASK, 4294967295  # 2^32 - 1
        .equ  FS_I32_SIGN, 2147483648  # 2^31

        .org  V_USER + IMAGE_PAGES     # how many pages the image takes
        .word FS_PAGES
        .org  V_USER

        .compress
        .gp   USER_GP

# Start: a stack below the image, and the Rust, which never returns.
fs_main:
        li    sp, USER_SP
        call  fs$fsd_main

# fs_exit(code): end, with code, an i32.
fs_exit:
        li    t0, FS_I32_SIGN
        bxor  a0, a0, t0
        sub   a1, a0, t0
        li    a0, SYS_EXIT
        sys

# A Rust abort: a panic. The server cannot go on.
fs$abort:
        li    a1, E_IO
        li    a0, SYS_EXIT
        sys

# fs_sys(n, a1, a2, a3, a4, a5): system call n, each argument an i32 the
# Rust holds as its unsigned value, made signed here: a0, as an i32.
# What the call left in a1 to a5 waits in fs_more_w for fs_more.
fs_sys:
        li    t0, FS_I32_SIGN
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
        sys
        la    t0, fs_more_w
        sw    a1, 0(t0)
        sw    a2, 3(t0)
        sw    a3, 6(t0)
        sw    a4, 9(t0)
        sw    a5, 12(t0)
        li    t0, FS_I32_MASK
        band  a0, a0, t0
        ret

# fs_more(k): a1 (k = 0) to a5 (k = 4) as the last fs_sys left it, an i32.
fs_more:
        li    t0, 3
        mul   a0, a0, t0
        la    t0, fs_more_w
        add   t0, t0, a0
        lw    a0, 0(t0)
        li    t0, FS_I32_MASK
        band  a0, a0, t0
        ret

# fs_clock(out): the time of day, whole words: the seconds at out and
# the microseconds at out + 3.
fs_clock:
        mv    t1, a0
        li    a0, SYS_CLOCK
        sys
        sw    a0, 0(t1)
        sw    a1, 3(t1)
        ret

# memcpy(dst, src, n) and memmove(dst, src, n): dst. A tryte at a time,
# whatever it holds: blocks are copied with these too.
fs$memmove:
        blt   a1, a0, 3f               # dst above src: copy from the end
fs$memcpy:
        mv    t0, a0
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
fs$memset:
        mv    t0, a0
        add   t2, a0, a2
1:      bge   t0, t2, 2f
        st    a1, 0(t0)
        addi  t0, t0, 1
        j     1b
2:      ret

# memcmp(a, b, n) and bcmp(a, b, n): below, at or above 0 as the first
# tryte that differs is lower, the same or higher in a, as an i32.
fs$bcmp:
fs$memcmp:
        add   t2, a0, a2
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
        li    t0, FS_I32_MASK
        band  a0, a0, t0
        ret
        .nocompress

# Word-aligned buffers, which Rust cannot lay out itself (sys.rs).
fs_more_w:  .words 5                   # a1 to a5 of the last call
fs_pathbuf: .words (PATH_MAX + 3) / 3  # a path coming in, PATH_MAX + 1 trytes
fs_words:   .words (PATH_MAX + 3) / 3  # what goes out: stat's words, a name,
                                       # the current directory's path

        .include "fsd-rust.s"
fs_end: .word 0                        # where the image ends
        .equ  FS_PAGES, 1 + (fs_end - V_USER - 9841 + PAGE - 1) / PAGE
        .assert FS_PAGES <= 1 + NXPAGE, "the file server's image takes more pages than a program may"
