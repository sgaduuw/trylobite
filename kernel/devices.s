# Devices: drive and arm (kernel/rust/trykern/src/devices.rs, which also
# takes their interrupts on hart 0 and forgets a driver that ends). The
# system calls hand the Rust the caller's record; it leaves the result
# there.

        .compress
sys_drive:
        mv    a0, s0
        call  rk_sys_drive
        j     resume

sys_arm:
        mv    a0, s0
        call  rk_sys_arm
        j     resume
        .nocompress
