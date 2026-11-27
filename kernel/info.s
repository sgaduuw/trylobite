# What the kernel tells about itself, for system tools: its log
# (bin/dmesg) and a summary of the machine and its use (bin/uname,
# bin/uptime, bin/free). Written in Rust (kernel/rust/trykern/src/info.rs):
# these hand it the caller's record, and it leaves the result in the
# record's a0 (and a1) for resume.

        .compress
sys_log:
        mv    a0, s0
        call  rk_sys_log
        j     resume

sys_info:
        mv    a0, s0
        call  rk_sys_info
        j     resume
        .nocompress
