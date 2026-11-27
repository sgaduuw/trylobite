# Harts: a hart the platform asked to go leaves here. Starting harts,
# hot-plug events and waking an idle hart are the Rust's
# (kernel/rust/trykern/src/harts.rs).

        .compress
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
        call  rk_wake_one
        call  klock_give
        li    t0, -1
        li    t1, V_HART
        sw    t0, HC_CONTROL(t1)       # the hart stops here
1:      j     1b
        .nocompress
