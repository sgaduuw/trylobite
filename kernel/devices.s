# Device interrupts, on hart 0 under the kernel lock. Every source is
# routed to hart 0 (the controller's reset value), and enabled only while
# something waits on it.

# device_irqs: serve every device source that wants attention. Clobbers
# a0, s1, s2 and t0..t4.
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

# console_irq: input has come, or the console has closed. Give a code
# point to each reader waiting in getc while there are any, or
# GETC_NONE to every one once it is closed; then mask the source if
# nobody waits any more. Clobbers a0, s1 and t0..t4.
console_irq:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    s1, procs
        li    t4, 0                    # t4: readers still waiting
1:      lw    t0, PCB_STATE(s1)
        li    t1, ST_GETC
        bne   t0, t1, 3f
        li    t0, V_CONSOLE
        lw    a0, CONSOLE_IN(t0)
        bgez  a0, 2f
        li    t0, CONSOLE_EMPTY
        beq   a0, t0, 4f               # nothing for this one yet
        li    a0, GETC_NONE
2:      sw    a0, PCB_A0(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        call  wake_one
        j     3f
4:      addi  t4, t4, 1
3:      addi  s1, s1, PCB_SIZE
        la    t0, procs + NPROC * PCB_SIZE
        blt   s1, t0, 1b
        bnez  t4, 9f
        li    t0, V_IRQ + 9 * SRC_CONSOLE
        sw    zero, IRQ_ENABLE(t0)
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# --- the disk ------------------------------------------------------------------
# One command at a time. A process asking while another's command is in
# flight waits as ST_DISK until that one finishes; disk_irq then starts
# the next, in table order after the one that finished.

# bread(block), bwrite(block): move one block between the disk and the
# caller's block window, a page of its own at V_BLOCK made on first use.
# a1 = the block, a2 = BLOCK_READ or BLOCK_WRITE.
sys_block:
        bltz  a1, 8f
        li    t0, V_DISK
        lw    t0, DISK_BLOCKS(t0)
        bge   a1, t0, 8f               # past the end, or no disk at all
        lw    t0, PCB_BLOCKPG(s0)
        bnez  t0, 1f
        la    t0, free_count
        lw    t0, 0(t0)
        beqz  t0, 9f
        sw    a2, PCB_A2(s0)           # alloc_page clobbers every t
        call  alloc_page
        sw    a0, PCB_BLOCKPG(s0)
        li    t1, PAGE                 # leaf entry +1: the window
        mul   t2, a0, t1
        li    t1, USER_FLAGS
        add   t2, t2, t1
        lw    a0, PCB_LEAFPG(s0)
        call  kva
        sw    t2, 3(a0)
        lw    a1, PCB_A1(s0)
        lw    a2, PCB_A2(s0)
1:      sw    a2, PCB_A2(s0)
        li    t0, ST_DISK
        sw    t0, PCB_STATE(s0)
        la    t0, disk_user
        lw    t0, 0(t0)
        bnez  t0, 2f                   # busy: disk_irq starts it later
        mv    s1, s0
        call  disk_start
2:      j     schedule
8:      li    a0, E_NOBLOCK
        j     sys_return
9:      li    a0, E_NOMEM
        j     sys_return

# disk_start: give the disk the command of the waiting process in s1.
# Clobbers t0, t1.
disk_start:
        la    t0, disk_user
        sw    s1, 0(t0)
        la    t0, disk_list
        lw    t1, PCB_BLOCKPG(s1)
        sw    t1, 0(t0)
        li    t1, KOFF
        add   t1, t0, t1               # the list's physical address
        li    t0, V_DISK
        sw    t1, DISK_LIST(t0)
        lw    t1, PCB_A1(s1)
        sw    t1, DISK_BLOCK(t0)
        li    t1, 1
        sw    t1, DISK_COUNT(t0)
        lw    t1, PCB_A2(s1)
        sw    t1, DISK_COMMAND(t0)
        ret

# disk_irq: the command in flight has finished. Tell its process how it
# went, and start the next waiting one. Clobbers a0, s1 and t0..t4.
disk_irq:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    t0, V_DISK
        lw    t1, DISK_STATUS(t0)
        sw    zero, DISK_ACK(t0)
        la    t0, disk_user
        lw    s1, 0(t0)
        beqz  s1, 9f                   # nothing was asked of it
        sw    zero, 0(t0)
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
