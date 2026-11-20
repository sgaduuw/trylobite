# Harts: starting the others at boot, and waking one that waits for work. In the kernel, tp holds the hart's number h
# (from the firmware at entry, from the process record on a trap); hart h
# uses index h + HART_MAX in per-hart tables.

# start_harts: start every other hart of the middle nine that is present.
# Each enters the firmware like hart 0, with a0 = ksecondary, and waits
# for the kernel lock there. Clobbers t0..t3.
start_harts:
        li    t3, -HART_MAX
1:      beqz  t3, 2f                   # hart 0 is us
        li    t0, 27
        mul   t0, t3, t0
        li    t1, V_HARTS
        add   t0, t0, t1               # t0: hart t3's slot
        lw    t1, HC_STATE(t0)
        bnez  t1, 2f                   # absent (or running already)
        li    t1, boot                 # the firmware runs untranslated
        sw    t1, HC_START_PC(t0)
        li    t1, ksecondary
        sw    t1, HC_START_ARG(t0)
        li    t1, 1
        sw    t1, HC_CONTROL(t0)
2:      addi  t3, t3, 1
        li    t0, HART_MAX
        ble   t3, t0, 1b
        ret

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
