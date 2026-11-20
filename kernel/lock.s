# The kernel lock. A hart takes it once a trap has saved the process's
# registers and gives it back just before returning to a process, so only
# one hart at a time runs kernel code: it guards the process table, the
# page allocator, the console and the rest of kernel data. The kernel is
# small and short-running, so one lock costs little.
#
# The kernel stack is kernel data too: the harts share one, used only by
# the hart holding the lock. Nothing touches it before klock_take.

# klock_take: spin until this hart holds the lock. Clobbers t0, t1.
klock_take:
        la    t0, klock
1:      li    t1, 1
        amoswap.aq t1, t1, (t0)
        bnez  t1, 1b
        ret

# klock_give: let the lock go. Clobbers t0.
klock_give:
        la    t0, klock
        amoswap.rl zero, zero, (t0)
        ret
