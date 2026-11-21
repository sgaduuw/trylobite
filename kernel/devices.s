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
2:      li    t0, V_IRQ
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
