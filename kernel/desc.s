# Descriptors: read, write, iocall, close, dup2, give and fdflags, and
# what spawn and bury need of them (kernel/rust/trykern/src/desc.rs).
# The system calls hand the Rust the caller's record; it leaves the
# result there.

        .compress
# read, write and iocall become a call to the descriptor's server; the
# Rust says 1 when the caller sleeps in it.
sys_read:
        mv    a0, s0
        call  rk_sys_read
        j     1f
sys_write:
        mv    a0, s0
        call  rk_sys_write
        j     1f
sys_iocall:
        mv    a0, s0
        call  rk_sys_iocall
1:      bnez  a0, schedule
        j     resume

sys_close:
        mv    a0, s0
        call  rk_sys_close
        j     resume

sys_dup2:
        mv    a0, s0
        call  rk_sys_dup2
        j     resume

sys_give:
        mv    a0, s0
        call  rk_sys_give
        j     resume

sys_fdflags:
        mv    a0, s0
        call  rk_sys_fdflags
        j     resume

# desc_ended: process t4, in s0, has ended (bury): its descriptors close,
# and those naming it go. Keeps t4 and the a and s registers.
desc_ended:
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
        mv    a0, s0
        mv    a1, t4
        call  rk_desc_ended
        j     rk_restore

# desc_inherit: give the record in s1, which is all zeros, copies of the
# descriptors of process a2, its parent, if it has one (a2 >= 0). Keeps
# every register but t0..t3, as spawn needs.
desc_inherit:
        bltz  a2, 9f                   # Rust takes an i32 as its unsigned value
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
        mv    a0, s1
        mv    a1, a2
        call  rk_desc_inherit
        j     rk_restore
9:      ret
        .nocompress
