# Physical pages and address spaces.
#
# Free pages form a list threaded through the pages themselves: each free
# page's centre word holds the next free page's number. The kernel reaches
# any physical page through the direct map. Page 0 is the boot page and is
# never free, so 0 also means "none".

        .compress
# kva: a0 = the kernel virtual address of physical page a0's centre.
# Clobbers t0.
kva:
        li    t0, PAGE
        mul   a0, a0, t0
        li    t0, DMAP
        add   a0, a0, t0
        ret

# page_init: put pages P_FREE .. RAM_PAGES on the free list.
page_init:
        mv    t6, ra                   # free_page leaves t4..t6 alone
        li    t5, P_FREE
1:      li    t4, RAM_PAGES
        bgt   t5, t4, 2f
        mv    a0, t5
        call  free_page
        addi  t5, t5, 1
        j     1b
2:      jalr  zero, 0(t6)

# free_page: return physical page a0 to the free list. Clobbers a0, t0..t3.
free_page:
        mv    t3, a0
        li    t0, PAGE
        mul   t1, t3, t0
        li    t0, DMAP
        add   t1, t1, t0               # t1: the page's centre
        lw    t2, free_head
        sw    t2, 0(t1)                # link it to the old head
        sw    t3, free_head
        lw    t2, free_count
        addi  t2, t2, 1
        sw    t2, free_count
        ret

# alloc_page: a0 = a zeroed page from the free list. The caller checks
# free_count first. Clobbers t0..t5.
alloc_page:
        mv    t5, ra
        call  take_page
        addi  t4, t2, -9840            # the page's lowest word
        addi  t3, t2, 9840             # and its highest
1:      sw    zero, 0(t4)
        addi  t4, t4, 3
        ble   t4, t3, 1b
        jalr  zero, 0(t5)

# take_page: a0 = a page from the free list, not cleared, and t2 = its
# centre's kernel virtual address. For a page about to be overwritten
# whole. Clobbers t0..t2.
take_page:
        lw    a0, free_head
        li    t1, PAGE
        mul   t2, a0, t1
        li    t1, DMAP
        add   t2, t2, t1               # t2: the page's centre
        lw    t1, 0(t2)
        sw    t1, free_head            # unlink it
        lw    t1, free_count
        addi  t1, t1, -1
        sw    t1, free_count
        ret

# copy_page: copy physical page a1 over physical page a0. Clobbers t0..t5.
copy_page:
        li    t0, PAGE
        mul   t1, a0, t0
        mul   t2, a1, t0
        li    t0, DMAP
        add   t1, t1, t0
        add   t2, t2, t0
        addi  t4, t1, -9840
        addi  t5, t1, 9840
        addi  t2, t2, -9840
1:      lw    t0, 0(t2)
        sw    t0, 0(t4)
        addi  t2, t2, 3
        addi  t4, t4, 3
        ble   t4, t5, 1b
        ret

# do_spawn: start program a1 in a free slot, as a child of process a2 (or
# NO_PARENT). a0 = its process number, or E_NOSLOT, E_NOPROG or E_NOMEM.
# Clobbers a0..a2, s1..s6 and every t register; keeps s0.
do_spawn:
        bltz  a1, 1f
        li    t0, NPROG
        bge   a1, t0, 1f
        addi  s5, a1, P_PROG0          # s5: the program image's page
        li    s6, 0                    # copied whole
        j     spawn_page
1:      li    a0, E_NOPROG
        ret

# spawn_page: start a program, as do_spawn does: when s6 is 0, the whole
# page image in physical page s5; when s6 is 1, the program file in the
# caller's block windows from window PCB_A1 on (spawnw has checked it),
# whose image takes s5 pages above the process's own. a0 = its process
# number, or E_NOSLOT or E_NOMEM. Clobbers as do_spawn.
spawn_page:
        addi  sp, sp, -3
        sw    ra, 0(sp)

        # Find a free slot, starting after the last one handed out, so a
        # process number is not reused until the table wraps: a message
        # meant for a process that just exited should not reach a new one.
        la    t2, procs
        li    t0, NPROC * PCB_SIZE
        add   t3, t2, t0               # t3: just past the table
        lw    s1, next_slot
        li    t4, NPROC
1:      blt   s1, t3, 0f
        mv    s1, t2                   # wrap around
0:      lw    t0, PCB_STATE(s1)
        beqz  t0, 2f
        addi  s1, s1, PCB_SIZE
        addi  t4, t4, -1
        bnez  t4, 1b
        li    a0, E_NOSLOT
        j     7f

2:      li    t1, PAGES_PER_PROCESS    # check memory before taking any
        beqz  s6, 0f
        add   t1, t1, s5               # and the image's pages above its own
0:      lw    t0, free_count
        blt   t0, t1, 9f

        mv    t0, s1                   # clear the slot's record
        addi  t1, s1, PCB_SIZE
3:      sw    zero, 0(t0)
        addi  t0, t0, 3
        blt   t0, t1, 3b
        sw    a2, PCB_PARENT(s1)
        sw    s6, PCB_FILE(s1)         # a program file may not drive a device
        la    t0, fpu_owner            # no hart's coprocessor bank is its yet:
        li    t1, NHART                # it starts from its zeroed PCB_FPU, not
5:      lw    t2, 0(t0)                # what the slot's last tenant left
        bne   t2, s1, 6f
        sw    zero, 0(t0)
6:      addi  t0, t0, 3
        addi  t1, t1, -1
        bnez  t1, 5b
        call  desc_inherit             # its parent's descriptors (desc.s)

        call  alloc_page
        sw    a0, PCB_ROOTPG(s1)
        mv    s2, a0
        call  alloc_page
        sw    a0, PCB_MIDPG(s1)
        mv    s3, a0
        call  alloc_page
        sw    a0, PCB_LEAFPG(s1)
        mv    s4, a0
        bnez  s6, 4f
        call  take_page                # copied over whole: no need to clear it
        sw    a0, PCB_USERPG(s1)
        mv    a1, s5
        call  copy_page                # the program, into its own page
        j     5f
4:      call  alloc_page               # zeroed: copy_mem fills in the image
        sw    a0, PCB_USERPG(s1)
        mv    a1, s5                   # a1: pages above it still to make
        addi  a2, s1, PCB_XPAGES
0:      blez  a1, 5f
        call  alloc_page
        sw    a0, 0(a2)
        addi  a2, a2, 3
        addi  a1, a1, -1
        j     0b
5:

        # Root entry 0 -> the mid table.
        mv    a0, s2
        call  kva
        li    t1, PAGE
        mul   t2, s3, t1
        addi  t2, t2, PTE_PTR
        sw    t2, 0(a0)
        # Mid entries: -1 the direct map, 0 the kernel, +1 the process.
        mv    a0, s3
        call  kva
        li    t2, DMAP_PTE
        sw    t2, -3(a0)
        li    t2, KLEAF_PTR
        sw    t2, 0(a0)
        li    t1, PAGE
        mul   t2, s4, t1
        addi  t2, t2, PTE_PTR
        sw    t2, 3(a0)
        # Leaf entry 0: the process's page, at V_USER.
        mv    a0, s4
        call  kva
        lw    t2, PCB_USERPG(s1)
        li    t1, PAGE
        mul   t2, t2, t1
        li    t1, USER_FLAGS
        add   t2, t2, t1
        sw    t2, 0(a0)
        addi  t3, s1, PCB_XPAGES       # entries 1 to NXPAGE: its image's
        li    t4, NXPAGE               # pages above it, if any
0:      lw    t2, 0(t3)
        beqz  t2, 1f
        li    t1, PAGE
        mul   t2, t2, t1
        li    t1, USER_FLAGS
        add   t2, t2, t1
        sw    t2, 3(a0)
1:      addi  a0, a0, 3
        addi  t3, t3, 3
        addi  t4, t4, -1
        bnez  t4, 0b

        beqz  s6, 0f                   # a program file: copy its image in,
        addi  sp, sp, -3               # from the caller's windows (copy_mem
        sw    s7, 0(sp)                # takes s7, which spawnw keeps)
        lw    t0, PCB_A1(s0)           # the first window
        li    t1, 3
        mul   t1, t0, t1
        add   t1, t1, s0
        lw    a0, PCB_WINS(t1)
        li    t1, PAGE
        mul   t0, t0, t1
        li    t1, V_BLOCK + EXEC_IMAGE - 1
        add   s3, t0, t1               # s3: the image's first tryte there
        call  kva
        lw    s6, EXEC_SIZE(a0)        # s6: its size
        mv    s2, s0
        mv    s4, s1
        li    s5, V_USER - 1           # where it runs from
        call  copy_mem
        lw    s7, 0(sp)
        addi  sp, sp, 3
        lw    s2, PCB_ROOTPG(s1)       # copy_mem left s1, but not s2

0:      la    t0, procs                # a0 = the process number
        sub   t0, s1, t0
        li    t1, PCB_SIZE
        div   a0, t0, t1
        addi  t2, a0, 1                # its ASID
        li    t1, PAGE
        mul   t3, s2, t1
        li    t1, 3
        mul   t4, t2, t1
        add   t3, t3, t4
        addi  t3, t3, 1                # mode +
        sw    t3, PCB_PTBR(s1)
        li    t0, V_USER
        sw    t0, PCB_PC(s1)
        li    t0, USER_SP
        sw    t0, 0(s1)
        li    t0, USER_GP              # programs address their data from gp
        sw    t0, PCB_GP(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        addi  t0, s1, PCB_SIZE         # the next spawn looks after this slot
        sw    t0, next_slot
        # The slot's last tenant had this ASID: a new epoch makes each hart
        # drop its translations before running the new one (see resume).
        la    t1, epochs
        li    t3, 3
        mul   t3, a0, t3
        add   t1, t1, t3
        lw    t3, 0(t1)
        addi  t3, t3, 1
        sw    t3, 0(t1)
        call  wake_one                 # a hart waiting for work can run it
        j     7f

9:      li    a0, E_NOMEM
7:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# window(k): give the caller block window a1, a zeroed page at V_BLOCK +
# PAGE * a1, unless it has one there already.
sys_window:
        bltz  a1, 7f
        li    t0, NWIN
        bge   a1, t0, 7f
        li    t0, 3
        mul   s1, a1, t0
        add   s1, s1, s0               # s1: its PCB_WINS entry, less PCB_WINS
        lw    t0, PCB_WINS(s1)
        bnez  t0, 6f
        lw    t0, free_count
        beqz  t0, 8f
        call  alloc_page
        sw    a0, PCB_WINS(s1)
        li    t1, PAGE                 # leaf entry NXPAGE + 1 + k: the window
        mul   t2, a0, t1
        li    t1, USER_FLAGS
        add   t2, t2, t1
        lw    a0, PCB_LEAFPG(s0)
        call  kva
        lw    t0, PCB_A1(s0)
        li    t1, 3
        mul   t0, t0, t1
        add   a0, a0, t0
        sw    t2, 3 * (NXPAGE + 1)(a0)
6:      li    a0, 0
        j     sys_return
7:      li    a0, E_INVAL
        j     sys_return
8:      li    a0, E_NOMEM
        j     sys_return

# release: end the process in s0, return its pages, and bury it (wait.s).
# Its saved a0 and a1 say how it ended. Does not return.
release:
        # Leave its address space first. Freeing a page writes the free-list
        # link into its centre word, which in a root table is entry 0: done
        # while that table is live, the next walk would read garbage.
        li    t0, PTBR_BOOT
        csrw  ptbr, t0
        lw    a0, PCB_ROOTPG(s0)
        call  free_page
        lw    a0, PCB_MIDPG(s0)
        call  free_page
        lw    a0, PCB_LEAFPG(s0)
        call  free_page
        lw    a0, PCB_USERPG(s0)
        call  free_page
        li    s1, NXPAGE + NWIN        # and its image's pages above its own
        mv    s2, s0                   # and its block windows
1:      lw    a0, PCB_XPAGES(s2)
        beqz  a0, 2f
        call  free_page
2:      addi  s2, s2, 3
        addi  s1, s1, -1
        bnez  s1, 1b
        j     bury
        .nocompress
