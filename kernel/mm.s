# Physical pages and address spaces: the page allocator, spawn, spawnw,
# window, brk, phys and release (kernel/rust/trykern/src/mm.rs). The
# system calls hand the Rust the caller's record; it leaves the result
# there.

        .compress
sys_spawn:
        mv    a0, s0
        call  rk_sys_spawn
        j     resume

sys_spawnw:
        mv    a0, s0
        call  rk_sys_spawnw
        j     resume

sys_window:
        mv    a0, s0
        call  rk_sys_window
        j     resume

sys_brk:
        mv    a0, s0
        call  rk_sys_brk
        j     resume

sys_phys:
        mv    a0, s0
        call  rk_sys_phys
        j     resume

# release: end the process in s0, return its pages, and bury it (wait.s).
# Its saved a0 and a1 say how it ended. It leaves its address space
# first: freeing a page writes the free-list link into its centre word,
# which in a root table is entry 0, and done while that table is live the
# next walk would read garbage. Does not return.
release:
        li    t0, PTBR_BOOT
        csrw  ptbr, t0
        mv    a0, s0
        call  rk_release
        j     bury

# uva: a0 = the kernel address of address a1 in the process whose record
# is in a0, and a1 = how many trytes its page has from there, or a0 = 0
# when the process has nothing there (mem::user_at in Rust, for puts): its own page, a page of its image
# above that, a block window or a page of heap it has. Clobbers t0..t2.
uva:
        li    t0, V_USER - 9841
        sub   t1, a1, t0               # t1: trytes from the page's first
        bltz  t1, 8f
        li    t0, PAGE
        div   t2, t1, t0               # t2: 0 its page, k the k-th above it
        mul   t0, t2, t0
        sub   t1, t1, t0               # t1: trytes into that page, 0 to PAGE - 1
        beqz  t2, 1f
        li    t0, NXPAGE + NWIN        # image pages, then windows
        bgt   t2, t0, 3f
        li    t0, 3
        mul   t2, t2, t0
        add   t2, t2, a0
        addi  t2, t2, -3
        lw    t2, PCB_XPAGES(t2)       # PCB_WINS follows on from it
        beqz  t2, 8f
        j     2f
1:      lw    t2, PCB_USERPG(a0)
2:      li    t0, PAGE
        sub   a1, t0, t1
        mul   a0, t2, t0
        li    t0, DMAP - 9841
        add   a0, a0, t0
        add   a0, a0, t1
        ret
3:      addi  t2, t2, -HEAP_LEAF       # t2: which page of its heap
        bltz  t2, 8f
        lw    t0, PCB_HEAP(a0)
        bge   t2, t0, 8f
        li    t0, 3
        mul   t2, t2, t0
        lw    a0, PCB_LEAFPG(a0)       # its leaf entry says which page
        li    t0, PAGE
        mul   a0, a0, t0
        add   a0, a0, t2
        li    t0, DMAP + 3 * HEAP_LEAF
        add   a0, a0, t0
        lw    t2, 0(a0)
        li    t0, USER_FLAGS
        sub   t2, t2, t0
        li    t0, PAGE
        div   t2, t2, t0
        j     2b
8:      li    a0, 0
        ret

        .nocompress
