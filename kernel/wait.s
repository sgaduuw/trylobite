# Processes ending and their parents waiting: wait, kill and bury
# (kernel/rust/trykern/src/wait.rs). The system calls hand the Rust the
# caller's record; it leaves the result there.

        .compress
# wait blocks when the Rust says 1: it has made the caller ST_WAIT.
sys_wait:
        mv    a0, s0
        call  rk_sys_wait
        bnez  a0, schedule
        j     resume

sys_kill:
        mv    a0, s0
        call  rk_sys_kill
        j     resume

# bury: the process in s0 has ended and its pages are free. Servers,
# devices, names and descriptors hear of it first (the assembly's
# wrappers want its number in t4); then the Rust orphans its children and tells its parent, or
# leaves it a zombie. Does not return.
bury:
        call  current_pid
        mv    a1, a0
        mv    a0, s0
        call  rk_ipc_ended             # servers learn of it (ipc.rs)
        mv    a0, s0
        call  rk_drv_ended             # its devices go (devices.rs)
        call  current_pid
        mv    t4, a0                   # t4: its number
        call  srv_ended                # its names go (names.s)
        call  desc_ended               # and its descriptors (desc.s)
        mv    a0, s0
        call  rk_bury
        j     schedule
        .nocompress
