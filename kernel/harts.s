# Harts: starting the others at boot and as they are plugged in, waking
# one that waits for work, and letting one go when the platform asks.
#
# Hot-plug events reach hart 0, the controller's event hart, which can
# never be removed. An added hart in the middle nine is started. A hart
# asked to go is marked leaving; at its next scheduling point (pick) it
# puts its process back, gives the lock up and stops itself, and the
# platform removes it. In the kernel, tp holds the hart's number h
# (from the firmware at entry, from the process record on a trap); hart h
# uses index h + HART_MAX in per-hart tables.

        .compress
# start_harts: start every other hart of the middle nine that is present.
# Clobbers a0, a1, t0..t4.
start_harts:
        mv    t4, ra
        li    a1, -HART_MAX
1:      call  start_hart               # hart 0 is running: left alone
        addi  a1, a1, 1
        li    t0, HART_MAX
        ble   a1, t0, 1b
        jalr  zero, 0(t4)

# start_hart: start hart a1 if it is in the middle nine, present and
# stopped. It enters the firmware like hart 0, with a0 = ksecondary, and
# waits for the kernel lock there. a0 = 1 if it was started, else 0.
# Clobbers t0..t3.
start_hart:
        li    a0, 0
        li    t0, HART_MAX
        bgt   a1, t0, 9f
        neg   t0, t0
        blt   a1, t0, 9f
        li    t0, 27
        mul   t0, a1, t0
        li    t1, V_HARTS
        add   t0, t0, t1               # t0: its slot
        lw    t1, HC_STATE(t0)
        bnez  t1, 9f                   # absent, or running already
        li    t1, boot                 # the firmware runs untranslated
        sw    t1, HC_START_PC(t0)
        li    t1, ksecondary
        sw    t1, HC_START_ARG(t0)
        addi  t2, a1, HART_MAX         # a fresh start: not leaving, whatever
        li    t3, 3                    # an earlier life of the hart was asked
        mul   t2, t2, t3
        la    t3, leaving
        add   t2, t2, t3
        sw    zero, 0(t2)
        li    t1, 1
        sw    t1, HC_CONTROL(t0)
        li    a0, 1
9:      ret

# hotplug_events: take every queued hot-plug event and act on it. Only
# hart 0 receives them. Clobbers a0, a1, s2 and t0..t5.
hotplug_events:
        addi  sp, sp, -3
        sw    ra, 0(sp)
1:      li    t0, V_HART
        lw    s2, HC_EVENT(t0)
        beqz  s2, 9f
        tex   t0, s2, 0, 1             # the kind, in the lowest trit
        sub   a1, s2, t0
        li    t1, 3
        div   a1, a1, t1               # the hart
        bltz  t0, 2f
        call  start_hart               # added
        beqz  a0, 1b                   # outside the middle nine, or started already
        la    a0, msg_hart
        call  kputs
        mv    a0, a1
        call  kputn
        la    a0, msg_joined
        call  kputs
        j     1b
2:      call  ask_to_leave
        j     1b
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# ask_to_leave: mark hart a1 leaving, and wake it if it waits for work,
# so it gets to pick and stops. A hart outside the middle nine was never
# started, and the platform removes a stopped hart by itself. Clobbers
# t0..t3.
ask_to_leave:
        li    t0, HART_MAX
        bgt   a1, t0, 9f
        neg   t0, t0
        blt   a1, t0, 9f
        addi  t0, a1, HART_MAX
        li    t1, 3
        mul   t0, t0, t1
        la    t1, leaving
        add   t1, t1, t0
        li    t2, 1
        sw    t2, 0(t1)
        la    t1, idle_harts
        add   t1, t1, t0
        lw    t2, 0(t1)
        beqz  t2, 9f
        sw    zero, 0(t1)
        li    t2, 27
        mul   t2, a1, t2
        li    t3, V_HARTS
        add   t2, t2, t3
        li    t3, 1
        sw    t3, HC_SEND(t2)
9:      ret

# hart_leave: this hart was asked to go (t0: its leaving entry). Whatever
# it ran is back in the table, so hand that to a waiting hart, let the
# lock go and stop. Does not return.
hart_leave:
        sw    zero, 0(t0)
        la    a0, msg_hart
        call  kputs
        mv    a0, tp
        call  kputn
        la    a0, msg_left
        call  kputs
        call  wake_one
        call  klock_give
        li    t0, -1
        li    t1, V_HART
        sw    t0, HC_CONTROL(t1)       # the hart stops here
1:      j     1b

# wake_one: something became ready to run; ring the doorbell of one hart
# waiting for work, if any, and take it off the waiting list so the next
# wake-up goes to another. Clobbers t0..t3.
wake_one:
        la    t0, idle_harts
        li    t1, 0
1:      lw    t2, 0(t0)
        bnez  t2, 2f
        addi  t0, t0, 3
        addi  t1, t1, 1
        li    t2, NHART
        blt   t1, t2, 1b
        ret                            # every hart is busy
2:      sw    zero, 0(t0)
        addi  t1, t1, -HART_MAX        # its hart number
        li    t2, 27
        mul   t1, t1, t2
        li    t2, V_HARTS
        add   t1, t1, t2
        li    t2, 1
        sw    t2, HC_SEND(t1)
        ret
        .nocompress
