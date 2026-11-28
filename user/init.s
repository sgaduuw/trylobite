# Program 0 of shell.s: init, the one program the kernel starts. It
# starts the servers, in the order of init_rows, waiting for each to
# register its name before the next, then the programs /etc/init names,
# then the shell, and looks after them: receive tells it of each of its
# children that ends.
#
# Which servers start, and which programs, is /etc/init's to say. The
# console, disk and file servers always start, first, since init needs
# them to read it (the bootstrap rows, the first INIT_BOOT of
# init_rows). Each line of /etc/init then names one of the other
# servers of init_rows by the name it registers, which starts it, and
# what it needs, in init_rows' order whatever the file's; or a program
# file, by a path that starts with a slash, and its arguments, words
# split at spaces, which init starts through the file server, with the
# console as its standard output and error, in the file's order, after
# the servers. Empty lines and lines that start with # say nothing.
# Without /etc/init, or with no file server to read it, every server of
# init_rows starts and no program.
#
# - When the shell exits, so does init, with the shell's exit code,
#   once it has ended the programs; the servers left asleep in receive
#   then let the machine power off. A shell that faults or is killed is
#   started again.
# - When a server ends, init ends whatever needs it (the rows below it
#   that need it, the programs and the shell), since they hold its old
#   process number or its handles, and starts them all again, the
#   server first.
# - A program that exits is done and is not started again; one that
#   faults or is killed is.
# - Each server, program and the shell may be started again
#   INIT_RETRIES times. After that init gives up on it: a server stays
#   down, and so does every row that needs it, and the shell runs
#   without them; when init gives up on the shell, it exits with
#   INIT_LOST.
#
# A server that cannot start, or does not register the protocol version
# init expects, is said on the kernel's log and left down, and so is
# every row that needs it; so is a program that cannot start. A server
# that ends before it registers is started again, as one that ends later
# is. Each server init starts is said with its process number once it
# has registered, each program once it has started, and the shell before
# it starts, since the shell prints at once: the end of the boot report.

        .compress
        .gp   USER_GP                  # set by spawn

        .equ  INIT_NONE, -1            # a row's need: no other row
        .equ  INIT_DOWN, -1            # in init_pids, init_ppids and init_sh:
                                       # no process, which no process number is
        .equ  INIT_FINISHED, -2        # in init_ppids: a program that exited,
                                       # not to be started again
        .equ  INIT_BOOT, 3             # the bootstrap rows, which /etc/init
                                       # needs: console, disk and file servers
        .equ  INIT_TAB, 729            # the most of /etc/init init reads
        .equ  INIT_PROGS, 9            # the most programs it may name
        .equ  INIT_RETRIES, 3          # starts again each may have
        .equ  INIT_LOST, 1             # init's exit code once it gives up on
                                       # the shell
        .equ  ROW, 12                  # trytes in a row of init_rows: the
        .equ  ROW_PROG, 0              # program, by number,
        .equ  ROW_VERSION, 3           # the protocol version it must register,
        .equ  ROW_NAME, 6              # the name it registers,
        .equ  ROW_NEED, 9              # and the row it needs up, or INIT_NONE

init:   li    a0, SYS_NAME             # for ps: a program of the image
        la    a1, init_myname          # has no argv[0] to name it
        sys
        li    a0, 0                    # the bootstrap rows, from the first
        call  init_start
        call  init_readtab             # which others /etc/init wants
        li    a0, INIT_BOOT
        call  init_start
        call  init_startprogs
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
        beqz  t0, init_whichprog       # not a server
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
        li    a3, 0
        call  init_say
        mv    a0, s3                   # what needs it goes too
        call  init_stopneed
        call  init_stopprogs
        call  init_stopsh
        mv    a0, s3                   # and starts again, from it
        call  init_start
        call  init_startprogs
        call  init_startsh
        j     init_watch

# One of the programs, perhaps: else nobody init looks after, such as one
# it ended itself.
init_whichprog:
        la    s0, init_pargs
        la    s1, init_ppids
        la    s2, init_ptries
        lw    s5, init_nprogs          # s5: rows left
1:      beqz  s5, init_watch
        lw    t0, 0(s1)
        beq   t0, a2, init_progend
        addi  s0, s0, 3
        addi  s1, s1, 3
        addi  s2, s2, 3
        addi  s5, s5, -1
        j     1b

# The program of s0, s1, s2 has ended: if it exited, it is done; else it
# starts again.
init_progend:
        mv    a1, a2
        li    a0, SYS_WAIT
        sys
        bnez  a0, 1f                   # not WAIT_EXITED
        li    t0, INIT_FINISHED
        sw    t0, 0(s1)
        j     init_watch
1:      li    t0, INIT_DOWN
        sw    t0, 0(s1)
        lw    t0, 0(s2)                # one more start for it
        addi  t0, t0, 1
        sw    t0, 0(s2)
        la    a2, init_again
        li    t1, INIT_RETRIES
        ble   t0, t1, 2f
        la    a2, init_giveup
2:      lw    a1, 0(s0)
        li    a3, 0
        call  init_say
        call  init_startprogs
        j     init_watch

# The shell has ended: on its own, init too; else start it again.
init_shend:
        mv    a1, a2
        li    a0, SYS_WAIT
        sys
        bnez  a0, 1f                   # not WAIT_EXITED
        j     init_exit                # a1: its exit code
1:      li    t0, INIT_DOWN
        sw    t0, init_sh
        lw    t0, init_shtries
        addi  t0, t0, 1
        sw    t0, init_shtries
        la    a1, init_shname
        li    t1, INIT_RETRIES
        bgt   t0, t1, 2f
        la    a2, init_again
        li    a3, 0
        call  init_say
        call  init_startsh
        j     init_watch
2:      la    a2, init_giveup
        li    a3, 0
        call  init_say
        li    a1, INIT_LOST
        j     init_exit

# init_exit: end the programs, then init, with exit code a1.
init_exit:
        mv    s4, a1
        call  init_stopprogs
        li    a0, SYS_EXIT
        mv    a1, s4
        sys

# init_start: start each row from row a0 on that is down, not given up
# on, and has what it needs up, waiting for it to register. A row that
# cannot be started is said and given up on; one that ends before it
# registers counts a start, as if it had ended later, and is started
# again until init gives up on it. Clobbers s0..s5.
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
        la    s4, init_want
        add   s4, s4, t0               # s4: whether it is to run at all
1:      lw    t0, ROW_PROG(s0)
        beqz  t0, 9f                   # program 0, init itself, ends them
        lw    t0, 0(s4)
        beqz  t0, 4f                   # not wanted
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
        li    a0, SYS_LOOKUP           # wait until it is ready, or ends
        lw    a1, ROW_NAME(s0)
        li    a2, LOOKUP_WHILE
        mv    a3, s3
        sys
        li    t0, E_NOPROC
        beq   a0, t0, 6f
        bltz  a0, 3f
        lw    t0, ROW_VERSION(s0)
        bne   a1, t0, 3f               # calls to it would be misread
        sw    s3, 0(s1)
        la    a1, init_started         # "started fs, process 4"
        lw    a2, ROW_NAME(s0)
        la    a3, init_process
        mv    a0, s3
        call  init_number
        mv    a4, a0
        call  init_say
        j     4f
6:      li    a0, SYS_WAIT           # it ended before it registered:
        mv    a1, s3                   # reap it, and start it again as
        sys                            # if it had ended later
        lw    t0, 0(s2)
        addi  t0, t0, 1
        sw    t0, 0(s2)
        la    a2, init_again
        li    t1, INIT_RETRIES
        ble   t0, t1, 7f
        la    a2, init_giveup
7:      lw    a1, ROW_NAME(s0)
        li    a3, 0
        call  init_say
        j     1b                       # the same row again
3:      li    t0, INIT_RETRIES + 1     # no use trying again
        sw    t0, 0(s2)
5:      la    a1, init_noserver
        lw    a2, ROW_NAME(s0)
        li    a3, 0
        call  init_say
4:      addi  s0, s0, ROW
        addi  s1, s1, 3
        addi  s2, s2, 3
        addi  s4, s4, 3
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
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    a1, init_starting
        la    a2, init_shname
        li    a3, 0
        call  init_say
        lw    ra, 0(sp)
        addi  sp, sp, 3
        li    a0, SYS_SPAWN
        li    a1, INIT_SH
        sys
        bltz  a0, 1f
        sw    a0, init_sh
        ret
1:      li    a1, INIT_LOST
        j     init_exit

# init_readtab: read /etc/init, if the file server is up and the file
# is there: want each server it names, and what that needs, and note
# each program file it names, in init_pargs and init_plen. Without it,
# want every server. Clobbers s0..s4.
init_readtab:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        lw    a1, init_fspid
        bltz  a1, 30f                  # no file server: every server
        li    a0, SYS_CALL
        li    a2, FS_OPEN
        la    a3, init_tabname
        li    a4, O_RDONLY
        sys
        bltz  a0, 30f                  # no /etc/init: every server
        mv    s0, a0                   # s0: its descriptor
        la    s1, init_tab             # s1: where the next read goes, up to
1:      la    a3, init_tab_full        # one tryte past INIT_TAB, so as to
        sub   a3, a3, s1               # tell a file that is too long
        beqz  a3, 2f
        li    a0, SYS_READ
        mv    a1, s0
        mv    a2, s1
        sys
        blez  a0, 3f                   # the end, or it cannot be read
        add   s1, s1, a0
        j     1b
2:      la    a1, init_tabname         # "/etc/init: too long, ..."
        la    a2, init_toolong
        li    a3, 0
        call  init_say
        la    s1, init_tab_full
        addi  s1, s1, -1               # INIT_TAB trytes of it
3:      st    zero, 0(s1)
        li    a0, SYS_CLOSE
        mv    a1, s0
        sys

# Each line in turn. Its words are written back over it, each ended by a
# 0, as the arguments of a program are (FS_SPAWN), from s1, which never
# passes s0.
        la    s0, init_tab             # s0: the next tryte of the text
        mv    s1, s0                   # s1: where the next word tryte goes
4:      lt    t0, 0(s0)
        beqz  t0, 29f                  # the end
        li    t1, ' '                  # spaces before it
        bne   t0, t1, 5f
        addi  s0, s0, 1
        j     4b
5:      li    t1, '\n'                 # an empty line
        bne   t0, t1, 6f
        addi  s0, s0, 1
        j     4b
6:      li    t1, '#'                  # a comment, to the end of the line
        bne   t0, t1, 8f
7:      lt    t0, 0(s0)
        beqz  t0, 4b
        addi  s0, s0, 1
        li    t1, '\n'
        bne   t0, t1, 7b
        j     4b
8:      mv    s2, s1                   # s2: the line's words
9:      lt    t0, 0(s0)
        beqz  t0, 11f                  # the end of the text: of the line too
        addi  s0, s0, 1
        li    t1, '\n'
        beq   t0, t1, 11f
        li    t1, ' '
        bne   t0, t1, 10f
        lt    t2, -1(s1)               # one space ends a word; more say
        beqz  t2, 9b                   # nothing
        li    t0, 0
10:     st    t0, 0(s1)
        addi  s1, s1, 1
        j     9b
11:     lt    t2, -1(s1)               # the last word's end, unless a space
        beqz  t2, 12f                  # ended it
        st    zero, 0(s1)
        addi  s1, s1, 1
12:     lt    t0, 0(s2)
        li    t1, '/'
        beq   t0, t1, 20f              # a program file

        la    s3, init_rows            # else a server: which row?
        la    s4, init_want
13:     lw    t0, ROW_PROG(s3)
        beqz  t0, 15f                  # none
        lw    a0, ROW_NAME(s3)
        mv    a1, s2
        call  init_streq
        bnez  a0, 14f
        addi  s3, s3, ROW
        addi  s4, s4, 3
        j     13b
14:     li    t0, 1                    # want it, and what it needs
        sw    t0, 0(s4)
        lw    t0, ROW_NEED(s3)
        bltz  t0, 4b
        li    t1, ROW
        mul   t1, t0, t1
        la    s3, init_rows
        add   s3, s3, t1
        li    t1, 3
        mul   t1, t0, t1
        la    s4, init_want
        add   s4, s4, t1
        j     14b
15:     la    a1, init_tabname         # "/etc/init: no server named X"
        la    a2, init_colon
        la    a3, init_noserver
        mv    a4, s2
        call  init_say
        j     4b

20:     lw    t0, init_nprogs          # a program file: one more row
        li    t1, INIT_PROGS
        blt   t0, t1, 21f
        la    a1, init_tabname         # "/etc/init: too many programs, ..."
        la    a2, init_toomany
        mv    a3, s2
        call  init_say
        j     4b
21:     li    t1, 3
        mul   t1, t0, t1
        la    t2, init_pargs
        add   t2, t2, t1
        sw    s2, 0(t2)                # its arguments, the path first,
        la    t2, init_plen
        add   t2, t2, t1
        sub   t3, s1, s2
        sw    t3, 0(t2)                # and how many trytes they take
        addi  t0, t0, 1
        sw    t0, init_nprogs
        j     4b

30:     la    t0, init_want            # every server
        la    t1, init_pids
        li    t2, 1
31:     beq   t0, t1, 29f              # init_want ends where init_pids starts
        sw    t2, 0(t0)
        addi  t0, t0, 3
        j     31b
29:     lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# init_startprogs: start each program that is down and neither done nor
# given up on, through the file server, with the console as standard
# output and error, which init holds only meanwhile. One that cannot
# start is said and given up on. Clobbers s0..s5.
init_startprogs:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    s0, init_pargs           # s0: its arguments,
        la    s1, init_plen            # s1: how many trytes they take,
        la    s2, init_ppids           # s2: its process,
        la    s3, init_ptries          # s3: how often it has been started
        li    s4, 0                    # s4: 1 once the console is open
        lw    s5, init_nprogs          # s5: rows left
1:      beqz  s5, 8f
        lw    t0, 0(s2)
        li    t1, INIT_DOWN
        bne   t0, t1, 4f               # up, or done
        lw    t0, 0(s3)
        li    t1, INIT_RETRIES
        bgt   t0, t1, 4f               # given up on
        bnez  s4, 2f
        li    s4, 1
        call  init_opencon
2:      li    a0, E_NOPROC
        lw    a1, init_fspid
        bltz  a1, 3f                   # no file server to start it
        li    a0, SYS_CALL
        li    a2, FS_SPAWN
        lw    a3, 0(s0)
        mv    a4, a3
        lw    a5, 0(s1)
        sys
        bltz  a0, 3f
        sw    a0, 0(s2)
        la    a1, init_started         # "started /bin/x, process 8"
        lw    a2, 0(s0)
        la    a3, init_process
        call  init_number
        mv    a4, a0
        call  init_say
        j     4f
3:      li    t0, INIT_RETRIES + 1     # no use trying again
        sw    t0, 0(s3)
        la    a1, init_nostart
        lw    a2, 0(s0)
        li    a3, 0
        call  init_say
4:      addi  s0, s0, 3
        addi  s1, s1, 3
        addi  s2, s2, 3
        addi  s3, s3, 3
        addi  s5, s5, -1
        j     1b
8:      beqz  s4, 9f                   # the programs have their copies
        li    a0, SYS_CLOSE
        li    a1, STDOUT
        sys
        li    a0, SYS_CLOSE
        li    a1, STDERR
        sys
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# init_opencon: make init's standard output and error the console, if
# the console server is up, for the programs to inherit. Init has no
# descriptors open otherwise, so the console's comes as descriptor 0
# (STDIN), which is closed again: what a program reads is the shell's.
init_opencon:
        lw    a1, init_pids            # the console server, row 0
        bltz  a1, 9f
        li    a0, SYS_CALL
        li    a2, CN_OPEN
        sys
        bltz  a0, 9f
        li    a0, SYS_DUP2
        li    a1, STDIN
        li    a2, STDOUT
        sys
        li    a0, SYS_DUP2
        li    a1, STDIN
        li    a2, STDERR
        sys
        li    a0, SYS_CLOSE
        li    a1, STDIN
        sys
9:      ret

# init_stopprogs: end each program that runs, and wait for it. Clobbers
# s0, s5.
init_stopprogs:
        la    s0, init_ppids
        lw    s5, init_nprogs
1:      beqz  s5, 9f
        lw    a1, 0(s0)
        bltz  a1, 2f                   # down, or done
        li    a0, SYS_KILL
        li    a2, FOR_SELF
        sys
        li    a0, SYS_WAIT
        lw    a1, 0(s0)
        sys
        li    t0, INIT_DOWN
        sw    t0, 0(s0)
2:      addi  s0, s0, 3
        addi  s5, s5, -1
        j     1b
9:      ret

# init_streq: a0 = 1 if the strings at a0 and a1 are the same, else 0.
# Clobbers t0, t1.
init_streq:
1:      lt    t0, 0(a0)
        lt    t1, 0(a1)
        bne   t0, t1, 2f
        beqz  t0, 3f
        addi  a0, a0, 1
        addi  a1, a1, 1
        j     1b
2:      li    a0, 0
        ret
3:      li    a0, 1
        ret

# init_say: "init: ", the strings at a1, a2, a3 and a4, as many as are
# not 0 (a2 onwards are read only when the one before is not 0), and a
# newline, on the kernel's log, in one puts so that no other line lands
# inside it. A line too long for init_line is cut short: names from
# /etc/init may be any length.
init_say:
        la    t0, init_line            # t0: where the next tryte goes
        la    t3, init_line_end        # t3: where it must stop
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
        bge   t0, t3, 4f               # no room
        st    t2, 0(t0)
        addi  t0, t0, 1
        addi  a1, a1, 1
        j     3b
4:      mv    a1, a2                   # the next string along
        mv    a2, a3
        mv    a3, a4
        li    a4, 0
        bnez  a1, 3b
        li    t2, '\n'
        st    t2, 0(t0)
        st    zero, 1(t0)
        li    a0, SYS_PUTS
        la    a1, init_line
        sys
        ret

# init_number: a0 = a string of a0's digits, for a0 >= 0, in
# init_digits. Clobbers t0, t1.
init_number:
        mv    t1, a0
        la    a0, init_digits_end
        st    zero, 0(a0)
1:      li    t0, 10
        rem   t0, t1, t0
        addi  t0, t0, '0'
        addi  a0, a0, -1
        st    t0, 0(a0)
        li    t0, 10
        div   t1, t1, t0
        bnez  t1, 1b
        ret

# The servers, in the order they start: a row needs one above it. The
# first INIT_BOOT always start; the rest when /etc/init names them.
init_rows:
        .word INIT_CONSD, CONSOLE_PROTOCOL, init_con, INIT_NONE   # row 0
        .word INIT_DISKD, DISK_PROTOCOL, init_disk, INIT_NONE     # row 1
        .word INIT_FSD, FS_PROTOCOL, init_fs, 1                   # row 2
        .word INIT_PIPED, PIPE_PROTOCOL, init_pipe, INIT_NONE     # row 3
        .word INIT_NETD, NET_PROTOCOL, init_net, INIT_NONE        # row 4
        .word INIT_IPD, IP_PROTOCOL, init_ip, 4                   # row 5
        .word 0
init_want:  .word 1, 1, 1, 0, 0, 0     # each row: 1 if it is to run
init_pids:  .word INIT_DOWN, INIT_DOWN # each row's process: the console's,
init_fspid: .word INIT_DOWN            # the file server's,
            .word INIT_DOWN, INIT_DOWN, INIT_DOWN
init_tries: .words 6                   # and how often it has started again
init_sh:    .word INIT_DOWN            # the shell's process
init_shtries: .word 0                  # and how often it has started again

# The programs /etc/init names, in its order.
init_nprogs:  .word 0                  # how many
init_pargs:   .words INIT_PROGS        # each one's arguments, in init_tab,
init_plen:    .words INIT_PROGS        # how many trytes they take,
init_ppids:   .word INIT_DOWN, INIT_DOWN, INIT_DOWN, INIT_DOWN, INIT_DOWN
              .word INIT_DOWN, INIT_DOWN, INIT_DOWN, INIT_DOWN
                                       # its process,
init_ptries:  .words INIT_PROGS        # and how often it has started again

init_said:     .string "init: "
init_line:     .zero 79                # what init_say prints: 79 trytes at
init_line_end: .zero 2                 # most, then a newline and a 0
init_digits:   .zero 9                 # init_number's digits, and its 0
init_digits_end: .zero 1
init_started:  .string "started "
init_process:  .string ", process "
init_starting: .string "starting "
init_noserver: .string "no server named "
init_again:    .string " ended, starting it again"
init_giveup:   .string " ended too often, giving up on it"
init_shname:   .string "sh"
init_con:      .string "console"
init_pipe:     .string "pipe"
init_disk:     .string "disk"
init_fs:       .string "fs"
init_net:      .string "net"
init_ip:       .string "ip"
init_myname:   .string "init"
init_tabname:  .string "/etc/init"
init_colon:    .string ": "
init_toolong:  .string ": too long, reading the start of it"
init_toomany:  .string ": too many programs, leaving out "
init_nostart:  .string "cannot start "
init_tab:      .zero INIT_TAB + 1      # /etc/init, then its words
init_tab_full: .zero 1                 # (a read reaching here: too long)
        .nocompress
