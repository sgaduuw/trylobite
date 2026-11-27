# Processes as system tools see them: proc, name, sleep and alarm
# (kernel/rust/trykern/src/procinfo.rs). These hand the Rust the
# caller's record; it leaves the result there.

        .compress
sys_proc:
        mv    a0, s0
        call  rk_sys_proc
        j     resume

sys_name:
        mv    a0, s0
        call  rk_sys_name
        j     resume

# sleep schedules when the Rust says 1: it has made the caller ST_SLEEP.
sys_sleep:
        mv    a0, s0
        call  rk_sys_sleep
        bnez  a0, schedule
        j     resume

sys_alarm:
        mv    a0, s0
        call  rk_sys_alarm
        j     resume

# proc_name: name the process whose record is s1 after the string at
# kernel address a0, with a1 (> 0) trytes of it mapped: its part after
# the last /, PROC_NAME_MAX code points of it at most, 0-padded (spawnw).
# Keeps every register but t0..t3.
proc_name:
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
        mv    a2, a1
        mv    a1, a0
        mv    a0, s1
        call  rk_proc_name
        j     rk_restore
        .nocompress
