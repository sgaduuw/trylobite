# fs_server(): the file server's process number, or E_NOPROC when there
# is no file server or it speaks another protocol than FS_PROTOCOL, so
# that every call to it fails. In assembly because the lookup answers
# in two registers. For Trice programs, through lib/io.tc.

fs_server:
        li    a0, SYS_LOOKUP
        la    a1, fs$name
        li    a2, LOOKUP_NOW
        sys
        bltz  a0, 1f
        li    t0, FS_PROTOCOL
        beq   a1, t0, 2f
1:      li    a0, E_NOPROC
2:      ret
fs$name: .string "fs"
        .align 1
