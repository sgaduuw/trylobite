# Device interrupts, on hart 0 under the kernel lock, and the drivers
# that take them. Every source is routed to hart 0 (the controller's
# reset value), and enabled only while something wants it: the console
# while the kernel wants input (input.s), any other source while its
# driver has armed it.

        .compress
# device_irqs: serve every device source that wants attention: the
# console here, others by telling their driver. Clobbers a0, a1, s1, s2
# and t0..t4.
device_irqs:
        addi  sp, sp, -3
        sw    ra, 0(sp)
1:      li    t0, V_IRQ
        lw    s2, IRQ_CLAIM(t0)
        beqz  s2, 9f
        li    t1, SRC_CONSOLE
        bne   s2, t1, 2f
        call  console_irq
        j     3f
2:      call  drv_irq
3:      li    t0, V_IRQ
        sw    s2, IRQ_COMPLETE(t0)
        j     1b
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# --- drivers -------------------------------------------------------------------
# A device other than the console belongs to the process that drives it
# (drivers, a record per source, 0 for none): its registers are mapped
# into that process, and the kernel only passes its interrupts on. The
# driver arms a source when it expects an interrupt; the interrupt masks
# it again, and receive hands the driver a NOTE_IRQ notice. irq_armed
# counts the armed sources, so that pick waits for them instead of
# calling a client stuck while its server waits on the device.

# drive(source): make the caller source a1's driver, and map the
# device's registers at V_DEVICE + PAGE * (a1 - 1).
sys_drive:
        li    t0, SRC_DISK             # the console stays the kernel's
        bne   a1, t0, 7f
        lw    t0, PCB_FILE(s0)
        bnez  t0, 8f
        call  drv_slot
        lw    t1, 0(t0)
        beq   t1, s0, 6f               # its own already
        bnez  t1, 9f
        sw    s0, 0(t0)
        lw    a0, PCB_LEAFPG(s0)
        call  kva
        li    t0, 3                    # leaf entry NWIN + a1
        mul   t0, a1, t0
        add   a0, a0, t0
        li    t1, P_DISK * PAGE + PTE_LEAF + PTE_R + PTE_W + PTE_U + PTE_A + PTE_D
        sw    t1, 3 * NWIN(a0)
6:      li    a0, 0
        j     sys_return
7:      li    a0, E_INVAL
        j     sys_return
8:      li    a0, E_PERM
        j     sys_return
9:      li    a0, E_BUSY
        j     sys_return

# arm(source): let source a1, which the caller drives, interrupt once.
sys_arm:
        blez  a1, 8f                   # drv_slot needs a source that is one
        li    t0, NSRC
        bgt   a1, t0, 8f
        call  drv_slot
        lw    t1, 0(t0)
        bne   t1, s0, 8f
        li    t0, 9
        mul   t0, a1, t0
        li    t1, V_IRQ
        add   t0, t0, t1
        lw    t1, IRQ_ENABLE(t0)
        bnez  t1, 1f                   # armed already
        li    t1, 1
        sw    t1, IRQ_ENABLE(t0)
        lw    t1, irq_armed
        addi  t1, t1, 1
        sw    t1, irq_armed
1:      li    a0, 0
        j     sys_return
8:      li    a0, E_PERM
        j     sys_return

# phys(address): the physical address of the caller's address a1, which
# only a driver needs: to give a device memory to move to or from.
sys_phys:
        la    t0, drivers
        li    t1, NSRC
1:      lw    t2, 0(t0)
        beq   t2, s0, 2f
        addi  t0, t0, 3
        addi  t1, t1, -1
        bnez  t1, 1b
        li    a0, E_PERM
        j     sys_return
2:      mv    a0, s0
        call  uva
        beqz  a0, 8f
        li    t0, DMAP
        sub   a0, a0, t0
        j     sys_return
8:      li    a0, E_FAULT
        j     sys_return

# drv_slot: t0 = the address of source a1's entry in drivers; a1 is 1 to
# NSRC. Clobbers t1.
drv_slot:
        li    t0, 3
        mul   t0, a1, t0
        la    t1, drivers - 3
        add   t0, t0, t1
        ret

# drv_irq: source s2 has interrupted. Mask it, and tell its driver: wake
# it if it sleeps in receive. A source nobody drives is only masked.
# Clobbers a1, s1 and t0..t3.
drv_irq:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    t0, 9
        mul   t0, s2, t0
        li    t1, V_IRQ
        add   t0, t0, t1
        li    t1, 0
        sw    t1, IRQ_ENABLE(t0)
        lw    t1, irq_armed
        addi  t1, t1, -1
        sw    t1, irq_armed
        mv    a1, s2
        call  drv_slot
        lw    s1, 0(t0)
        beqz  s1, 9f
        add   t0, s1, s2
        li    t1, 1
        st    t1, PCB_IRQS - 1(t0)
        call  rouse
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# drv_ended: the process in s0 has ended (bury): it drives nothing now,
# and what it armed is masked. Its mapping went with its page tables.
# Clobbers t0..t3.
drv_ended:
        la    t0, drivers
        li    t1, 1                    # t1: the source
1:      lw    t2, 0(t0)
        bne   t2, s0, 2f
        sw    zero, 0(t0)
        li    t2, 9
        mul   t2, t1, t2
        li    t3, V_IRQ
        add   t2, t2, t3
        lw    t3, IRQ_ENABLE(t2)
        beqz  t3, 2f
        li    t3, 0
        sw    t3, IRQ_ENABLE(t2)
        lw    t3, irq_armed
        addi  t3, t3, -1
        sw    t3, irq_armed
2:      addi  t0, t0, 3
        addi  t1, t1, 1
        li    t2, NSRC
        ble   t1, t2, 1b
        ret
        .nocompress
