# Program 0 of shell.s: init, the one program the kernel starts. It
# starts the servers, in the order of init_rows, waiting for each to
# register its name before the next, then the shell, and looks after
# them: receive tells it of each of its children that ends.
#
# - When the shell exits, so does init, with the shell's exit code; the
#   servers left asleep in receive then let the machine power off. A
#   shell that faults or is killed is started again.
# - When a server ends, init ends whatever needs it (the rows below it
#   that need it, and the shell), since they hold its old process number
#   or its handles, and starts them all again, the server first.
# - Each server and the shell may be started again INIT_RETRIES times.
#   After that init gives up on it: a server stays down, and so does
#   every row that needs it, and the shell runs without them; when init
#   gives up on the shell, it exits with INIT_LOST.
#
# A server that cannot start, or does not register the protocol version
# init expects, is said on the kernel's log and left down, and so is
# every row that needs it. When all is well init prints nothing.

        .compress
        .gp   USER_GP                  # set by spawn

        .equ  INIT_NONE, -1            # a row's need: no other row
        .equ  INIT_DOWN, -1            # in init_pids and init_sh: no process,
                                       # which no process number is
        .equ  INIT_RETRIES, 3          # starts again each may have
        .equ  INIT_LOST, 1             # init's exit code once it gives up on
                                       # the shell
        .equ  ROW, 12                  # trytes in a row of init_rows: the
        .equ  ROW_PROG, 0              # program, by number,
        .equ  ROW_VERSION, 3           # the protocol version it must register,
        .equ  ROW_NAME, 6              # the name it registers,
        .equ  ROW_NEED, 9              # and the row it needs up, or INIT_NONE

init:   li    a0, 0                    # every row, from the first
        call  init_start
        call  init_startsh

# Wait for something to end. Nobody has a reason to call init: a call
# gets E_INVAL.
init_watch:
        li    a0, SYS_RECEIVE
        sys
        bltz  a0, 1f                   # FROM_KERNEL: a notice
        mv    a1, a0
        li    a0, SYS_REPLY
        li    a2, E_INVAL
        sys
        j     init_watch
1:      li    t0, NOTE_ENDED
        bne   a1, t0, init_watch
        lw    t0, init_sh
        beq   a2, t0, init_shend
        la    s0, init_rows            # one of the servers?
        la    s1, init_pids
        la    s2, init_tries
        li    s3, 0                    # s3: the row's index
2:      lw    t0, ROW_PROG(s0)
        beqz  t0, init_watch                # nobody init looks after: one it
                                       # ended itself, or the shell's child
        lw    t0, 0(s1)
        beq   t0, a2, init_srvend
        addi  s0, s0, ROW
        addi  s1, s1, 3
        addi  s2, s2, 3
        addi  s3, s3, 1
        j     2b

# The server of row s3 (s0, s1, s2 its entries) has ended.
init_srvend:
        mv    a1, a2                   # it is a zombie now: reap it
        li    a0, SYS_WAIT
        sys
        li    t0, INIT_DOWN
        sw    t0, 0(s1)
        lw    t0, 0(s2)                # one more start for it
        addi  t0, t0, 1
        sw    t0, 0(s2)
        la    a2, init_again
        li    t1, INIT_RETRIES
        ble   t0, t1, 1f
        la    a2, init_giveup
1:      lw    a1, ROW_NAME(s0)
        call  init_say
        mv    a0, s3                   # what needs it goes too
        call  init_stopneed
        call  init_stopsh
        mv    a0, s3                   # and starts again, from it
        call  init_start
        call  init_startsh
        j     init_watch

# The shell has ended: on its own, init too; else start it again.
init_shend:
        mv    a1, a2
        li    a0, SYS_WAIT
        sys
        bnez  a0, 1f                   # not WAIT_EXITED
        li    a0, SYS_EXIT             # a1: its exit code
        sys
1:      li    t0, INIT_DOWN
        sw    t0, init_sh
        lw    t0, init_shtries
        addi  t0, t0, 1
        sw    t0, init_shtries
        la    a1, init_shname
        li    t1, INIT_RETRIES
        bgt   t0, t1, 2f
        la    a2, init_again
        call  init_say
        call  init_startsh
        j     init_watch
2:      la    a2, init_giveup
        call  init_say
        li    a0, SYS_EXIT
        li    a1, INIT_LOST
        sys

# init_start: start each row from row a0 on that is down, not given up
# on, and has what it needs up, waiting for it to register. A row that
# cannot be started is said and given up on. Clobbers s0..s5.
init_start:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    t0, ROW
        mul   t0, a0, t0
        la    s0, init_rows
        add   s0, s0, t0               # s0: a row
        li    t0, 3
        mul   t0, a0, t0
        la    s1, init_pids
        add   s1, s1, t0               # s1: its process
        la    s2, init_tries
        add   s2, s2, t0               # s2: how often it has been started
1:      lw    t0, ROW_PROG(s0)
        beqz  t0, 9f                   # program 0, init itself, ends them
        lw    t0, 0(s1)
        bgez  t0, 4f                   # up
        lw    t0, 0(s2)
        li    t1, INIT_RETRIES
        bgt   t0, t1, 4f               # given up on
        lw    t0, ROW_NEED(s0)
        bltz  t0, 2f
        li    t1, 3
        mul   t0, t0, t1
        la    t1, init_pids
        add   t0, t0, t1
        lw    t0, 0(t0)
        bltz  t0, 5f                   # what it needs is down: so is it
2:      li    a0, SYS_SPAWN
        lw    a1, ROW_PROG(s0)
        sys
        bltz  a0, 3f
        mv    s3, a0                   # s3: its process
        li    a0, SYS_LOOKUP           # wait until it is ready
        lw    a1, ROW_NAME(s0)
        li    a2, LOOKUP_WAIT
        sys
        bltz  a0, 3f
        lw    t0, ROW_VERSION(s0)
        bne   a1, t0, 3f               # calls to it would be misread
        sw    s3, 0(s1)
        j     4f
3:      li    t0, INIT_RETRIES + 1     # no use trying again
        sw    t0, 0(s2)
5:      la    a1, init_noserver
        lw    a2, ROW_NAME(s0)
        call  init_say
4:      addi  s0, s0, ROW
        addi  s1, s1, 3
        addi  s2, s2, 3
        j     1b
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# init_stopneed: end each row below row a0 that needs a row that is down,
# such as a0 itself, and wait for it. Clobbers s0, s1.
init_stopneed:
        addi  a0, a0, 1
        li    t0, ROW
        mul   t0, a0, t0
        la    s0, init_rows
        add   s0, s0, t0               # s0: a row
        li    t0, 3
        mul   t0, a0, t0
        la    s1, init_pids
        add   s1, s1, t0               # s1: its process
1:      lw    t0, ROW_PROG(s0)
        beqz  t0, 9f
        lw    a1, 0(s1)
        bltz  a1, 2f                   # down already
        lw    t0, ROW_NEED(s0)
        bltz  t0, 2f
        li    t1, 3
        mul   t0, t0, t1
        la    t1, init_pids
        add   t0, t0, t1
        lw    t0, 0(t0)
        bgez  t0, 2f                   # what it needs is up
        li    a0, SYS_KILL
        li    a2, FOR_SELF
        sys
        li    a0, SYS_WAIT
        lw    a1, 0(s1)
        sys
        li    t0, INIT_DOWN
        sw    t0, 0(s1)
2:      addi  s0, s0, ROW
        addi  s1, s1, 3
        j     1b
9:      ret

# init_stopsh: end the shell, if it runs, and wait for it.
init_stopsh:
        lw    a1, init_sh
        bltz  a1, 9f
        li    a0, SYS_KILL
        li    a2, FOR_SELF
        sys
        li    a0, SYS_WAIT
        lw    a1, init_sh
        sys
        li    t0, INIT_DOWN
        sw    t0, init_sh
9:      ret

# init_startsh: start the shell. Init has nothing left to look after
# without one: if it cannot start, init exits.
init_startsh:
        li    a0, SYS_SPAWN
        li    a1, INIT_SH
        sys
        bltz  a0, 1f
        sw    a0, init_sh
        ret
1:      li    a0, SYS_EXIT
        li    a1, INIT_LOST
        sys

# init_say: "init: ", the strings at a1 and a2, and a newline, on the
# kernel's log, in one puts so that no other line lands inside it.
init_say:
        la    t0, init_line            # t0: where the next tryte goes
        la    t1, init_said
1:      lt    t2, 0(t1)
        beqz  t2, 2f
        st    t2, 0(t0)
        addi  t0, t0, 1
        addi  t1, t1, 1
        j     1b
2:      beqz  a1, 4f                   # then a1's string, then a2's
3:      lt    t2, 0(a1)
        beqz  t2, 4f
        st    t2, 0(t0)
        addi  t0, t0, 1
        addi  a1, a1, 1
        j     3b
4:      mv    a1, a2
        li    a2, 0
        bnez  a1, 3b
        li    t2, '\n'
        st    t2, 0(t0)
        st    zero, 1(t0)
        li    a0, SYS_PUTS
        la    a1, init_line
        sys
        ret

# The servers, in the order they start: a row needs one above it.
init_rows:
        .word INIT_CONSD, CONSOLE_PROTOCOL, init_con, INIT_NONE   # row 0
        .word INIT_PIPED, PIPE_PROTOCOL, init_pipe, INIT_NONE     # row 1
        .word INIT_DISKD, DISK_PROTOCOL, init_disk, INIT_NONE     # row 2
        .word INIT_FSD, FS_PROTOCOL, init_fs, 2                   # row 3
        .word 0
init_pids:  .word INIT_DOWN, INIT_DOWN, INIT_DOWN, INIT_DOWN   # each row's
                                       # process
init_tries: .words 4                   # and how often it has started again
init_sh:    .word INIT_DOWN            # the shell's process
init_shtries: .word 0                  # and how often it has started again

init_said:     .string "init: "
init_line:     .zero 60                # what init_say prints: 48 trytes at
                                       # most, its 0 included
init_noserver: .string "no server named "
init_again:    .string " ended, starting it again"
init_giveup:   .string " ended too often, giving up on it"
init_shname:   .string "sh"
init_con:      .string "console"
init_pipe:     .string "pipe"
init_disk:     .string "disk"
init_fs:       .string "fs"
        .nocompress
