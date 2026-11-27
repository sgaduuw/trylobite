# Messages: send and recv, and for servers call, receive, reply, copyin,
# copyout and notify (kernel/rust/trykern/src/ipc.rs). The system calls hand the Rust the
# caller's record; it leaves the result there, and says 1 when the
# caller sleeps.

        .compress
sys_send:
        mv    a0, s0
        call  rk_sys_send
        j     1f
sys_recv:
        mv    a0, s0
        call  rk_sys_recv
        j     1f
sys_call_user:
        mv    a0, s0
        call  rk_sys_call
        j     1f
sys_receive:
        mv    a0, s0
        call  rk_sys_receive
        j     1f
sys_reply:
        mv    a0, s0
        call  rk_sys_reply
        j     1f
sys_copyin:
        mv    a0, s0
        call  rk_sys_copyin
        j     1f
sys_copyout:
        mv    a0, s0
        call  rk_sys_copyout
        j     1f
sys_notify:
        mv    a0, s0
        call  rk_sys_notify
1:      bnez  a0, schedule
        j     resume
        .nocompress
