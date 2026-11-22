# Program 0 of shell.s: init, the one program the kernel starts. It
# starts the servers, in the order of init_rows, waiting for each to
# register its name before the next, then the shell, and waits for the
# shell. When the shell exits, so does init, with the shell's exit
# code; the servers left asleep in receive then let the machine power
# off.
#
# A row whose server cannot start, or does not register the protocol
# version init expects, is said on the kernel's log and left down, and so
# is every row that needs it: no file server without the disk server.
# The shell does without whatever is missing. Init prints nothing when
# all is well.

        .compress
        .gp   USER_GP                  # set by spawn

        .equ  INIT_NONE, -1            # a row's need: no other row
        .equ  INIT_DOWN, -1            # in init_pids: no process, which no
                                       # process number is
        .equ  INIT_LOST, 1             # init's exit code if the shell faulted
                                       # or was killed
        .equ  ROW, 12                  # trytes in a row of init_rows: the
        .equ  ROW_PROG, 0              # program, by number,
        .equ  ROW_VERSION, 3           # the protocol version it must register,
        .equ  ROW_NAME, 6              # the name it registers,
        .equ  ROW_NEED, 9              # and the row it needs up, or INIT_NONE

init:   la    s0, init_rows            # s0: a row
        la    s1, init_pids            # s1: its process
1:      lw    t0, ROW_PROG(s0)
        beqz  t0, 5f                   # program 0, init itself, ends them
        li    t0, INIT_DOWN
        sw    t0, 0(s1)
        lw    t0, ROW_NEED(s0)
        bltz  t0, 2f
        li    t1, 3
        mul   t0, t0, t1
        la    t1, init_pids
        add   t0, t0, t1
        lw    t0, 0(t0)
        bltz  t0, 3f                   # what it needs is down: so is it
2:      li    a0, SYS_SPAWN
        lw    a1, ROW_PROG(s0)
        sys
        bltz  a0, 3f
        mv    s2, a0                   # s2: its process
        li    a0, SYS_LOOKUP           # wait until it is ready
        lw    a1, ROW_NAME(s0)
        li    a2, LOOKUP_WAIT
        sys
        bltz  a0, 3f
        lw    t0, ROW_VERSION(s0)
        bne   a1, t0, 3f               # calls to it would be misread
        sw    s2, 0(s1)
        j     4f
3:      li    a0, SYS_PUTS
        la    a1, init_down
        sys
        li    a0, SYS_PUTS
        lw    a1, ROW_NAME(s0)
        sys
        li    a0, SYS_PUTC
        li    a1, '\n'
        sys
4:      addi  s0, s0, ROW
        addi  s1, s1, 3
        j     1b

5:      li    a0, SYS_SPAWN            # then the shell
        li    a1, INIT_SH
        sys
        bltz  a0, 7f
        mv    a1, a0
        li    a0, SYS_WAIT
        sys
        bnez  a0, 7f                   # not WAIT_EXITED
6:      li    a0, SYS_EXIT             # a1: its exit code
        sys
7:      li    a1, INIT_LOST
        j     6b

# The servers, in the order they start: a row needs one above it.
init_rows:
        .word INIT_CONSD, CONSOLE_PROTOCOL, init_con, INIT_NONE   # row 0
        .word INIT_PIPED, PIPE_PROTOCOL, init_pipe, INIT_NONE     # row 1
        .word INIT_DISKD, DISK_PROTOCOL, init_disk, INIT_NONE     # row 2
        .word INIT_FSD, FS_PROTOCOL, init_fs, 2                   # row 3
        .word 0
init_pids: .words 4                    # each row's process, or INIT_DOWN

init_down: .string "init: no server named "
init_con:  .string "console"
init_pipe: .string "pipe"
init_disk: .string "disk"
init_fs:   .string "fs"
        .nocompress
