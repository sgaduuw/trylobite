# The kernel lock. A hart takes it once a trap has saved the process's
# registers and gives it back just before returning to a process, so only
# one hart at a time runs kernel code: it guards the process table, the
# page allocator, the console and the rest of kernel data. The kernel is
# small and short-running, so one lock costs little.
#
# The kernel stack is kernel data too: the harts share one, used only by
# the hart holding the lock. Nothing touches it before klock_take.

# klock_take: wait until this hart holds the lock. While another hart
# holds it, this one sleeps in wrs on the reserved lock word instead of
# spinning; the holder's store in klock_give breaks the reservation and
# wakes it. A release between the lr and the wrs has broken the
# reservation already, so wrs returns at once and no wake-up is lost.
#
# sie is cleared while waiting: a pending enabled interrupt ends a wrs,
# and a hart entering on a timer trap has its timer pending until
# on_timer, under the lock, moves stimecmp on. Interrupts are off in the
# kernel anyway, so sie only decides what ends a wait. Clobbers t0..t2.
klock_take:
        li    t1, 0                    # csrw from zero would only read
        csrrw t2, sie, t1
        la    t0, klock
1:      lr    t1, (t0)
        beqz  t1, 2f
        wrs   zero                     # held: sleep until it is written
        j     1b
2:      li    t1, 1
        sc.aq t1, t1, (t0)             # 0: ours
        bnez  t1, 1b
        csrw  sie, t2
        ret

# klock_give: let the lock go. Clobbers t0.
klock_give:
        la    t0, klock
        amoswap.rl zero, zero, (t0)
        ret
