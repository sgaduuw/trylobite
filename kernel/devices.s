# Device interrupts, on hart 0 under the kernel lock. Every source is
# routed to hart 0 (the controller's reset value), and enabled only while
# something wants it.

        .compress
# device_irqs: serve every device source that wants attention. Clobbers
# a0, a1, s1, s2 and t0..t4.
device_irqs:
        addi  sp, sp, -3
        sw    ra, 0(sp)
1:      li    t0, V_IRQ
        lw    s2, IRQ_CLAIM(t0)
        beqz  s2, 9f
        li    t1, SRC_CONSOLE
        bne   s2, t1, 2f
        call  console_irq
2:      li    t1, SRC_DISK
        bne   s2, t1, 3f
        call  disk_irq
3:      li    t0, V_IRQ
        sw    s2, IRQ_COMPLETE(t0)
        j     1b
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# --- the disk ------------------------------------------------------------------
# One command at a time, each a process's: a bread or bwrite, or a block
# the cache lacks (kernel/cache.s), held in its PCB_DBLOCK, PCB_DPAGE and
# PCB_DCMD. A process asking while another's command is in flight waits
# as ST_DISK until that one finishes; disk_irq then starts the next, in
# table order after the one that finished.

# bread(block, window), bwrite(block, window): move one block between the
# disk and one of the caller's block windows, window k a page of its own
# at V_BLOCK + PAGE * k made on first use. a1 = the block, a2 = the
# window, a3 = BLOCK_READ or BLOCK_WRITE.
sys_block:
        bltz  a1, 8f
        li    t0, V_DISK
        lw    t0, DISK_BLOCKS(t0)
        bge   a1, t0, 8f               # past the end, or no disk at all
        bltz  a2, 8f
        li    t0, NWIN
        bge   a2, t0, 8f
        li    t0, 3
        mul   s1, a2, t0
        add   s1, s1, s0               # s1: its PCB_WINS entry, less PCB_WINS
        lw    t0, PCB_WINS(s1)
        bnez  t0, 1f
        lw    t0, free_count
        beqz  t0, 9f
        mv    s2, a3                   # alloc_page clobbers every t
        call  alloc_page
        sw    a0, PCB_WINS(s1)
        li    t1, PAGE                 # leaf entry k + 1: the window
        mul   t2, a0, t1
        li    t1, USER_FLAGS
        add   t2, t2, t1
        lw    a0, PCB_LEAFPG(s0)
        call  kva
        lw    t0, PCB_A2(s0)
        li    t1, 3
        mul   t0, t0, t1
        add   a0, a0, t0
        sw    t2, 3(a0)
        lw    a1, PCB_A1(s0)
        mv    a3, s2
1:      sw    a1, PCB_DBLOCK(s0)
        sw    a3, PCB_DCMD(s0)
        lw    t0, PCB_WINS(s1)
        sw    t0, PCB_DPAGE(s0)
        j     disk_queue
8:      li    a0, E_NOBLOCK
        j     sys_return
9:      li    a0, E_NOMEM
        j     sys_return

# disk_queue: the process in s0 has its command in PCB_D*: wait for it,
# starting it now if the disk is free. Does not return.
disk_queue:
        li    t0, ST_DISK
        sw    t0, PCB_STATE(s0)
        lw    t0, disk_user
        bnez  t0, 1f                   # busy: disk_irq starts it later
        mv    s1, s0
        call  disk_start
1:      j     schedule

# disk_start: give the disk the command of the waiting process in s1.
# Clobbers t0, t1.
disk_start:
        sw    s1, disk_user
        lw    t1, PCB_DPAGE(s1)
        la    t0, disk_list
        sw    t1, 0(t0)
        li    t1, KOFF
        add   t1, t0, t1               # the list's physical address
        li    t0, V_DISK
        sw    t1, DISK_LIST(t0)
        lw    t1, PCB_DBLOCK(s1)
        sw    t1, DISK_BLOCK(t0)
        li    t1, 1
        sw    t1, DISK_COUNT(t0)
        lw    t1, PCB_DCMD(s1)
        sw    t1, DISK_COMMAND(t0)
        ret

# disk_irq: the command in flight has finished. Tell its process how it
# went, and start the next waiting one. Clobbers a0, s1 and t0..t5.
disk_irq:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    t0, V_DISK
        lw    t1, DISK_STATUS(t0)
        sw    zero, DISK_ACK(t0)
        lw    s1, disk_user
        beqz  s1, 9f                   # nothing was asked of it
        sw    zero, disk_user
        li    a0, 0
        li    t0, BLOCK_FAILED
        bne   t1, t0, 1f
        li    a0, E_IO
1:      sw    a0, PCB_A0(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        call  wake_one
        la    t3, procs + NPROC * PCB_SIZE
        li    t4, NPROC
2:      addi  s1, s1, PCB_SIZE         # the next waiting process, s1's turn last
        blt   s1, t3, 3f
        la    s1, procs
3:      lw    t0, PCB_STATE(s1)
        li    t1, ST_DISK
        bne   t0, t1, 4f
        call  disk_start
        j     9f
4:      addi  t4, t4, -1
        bnez  t4, 2b
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret
        .nocompress
