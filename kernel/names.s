# Server names: register and lookup (kernel/rust/trykern/src/names.rs).
# These hand the Rust the caller's record; it leaves the result there.

        .compress
sys_register:
        mv    a0, s0
        call  rk_sys_register
        j     resume

# lookup sleeps when the Rust says 1: it has made the caller ST_LOOKUP.
sys_lookup:
        mv    a0, s0
        call  rk_sys_lookup
        bnez  a0, schedule
        j     resume

# srv_ended: process t4 has ended (bury): its names go, and whoever
# waits in lookup looks again. Keeps t4 and the a and s registers, as
# bury needs.
srv_ended:
        addi  sp, sp, -30
        sw    ra, 0(sp)
        sw    t4, 3(sp)
        sw    a0, 6(sp)
        sw    a1, 9(sp)
        sw    a2, 12(sp)
        sw    a3, 15(sp)
        sw    a4, 18(sp)
        sw    a5, 21(sp)
        sw    t5, 24(sp)
        sw    t6, 27(sp)
        mv    a0, t4
        call  rk_srv_ended
        j     rk_restore
        .nocompress
