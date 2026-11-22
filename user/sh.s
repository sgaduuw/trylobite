# Program 0 of shell.s: a shell. It reads a line, runs the program its
# first word names, waits for it, and says how it ended if not with code
# 0. Some words are built in: exit, and ls, cat, write, rm, mkdir, rmdir,
# cd and pwd, which use the filesystem on the disk (docs/filesystem.md)
# through the file server. The console is the console server's: the
# shell points its standard input, output and error at it, which the
# programs it starts inherit, reads and prints through them, and gives
# the server each program it runs as the foreground, for Ctrl-C. The kernel starts the shell as init; it
# starts the console server, then the disk server and the file server
# that needs it, and finds the servers by their names. A word that is neither
# built in nor a program in the kernel image names a program file: a
# path if it has a slash, else a file in /bin. It stops at the end of input. Programs take no arguments yet.

        .compress
        .section prog0, P_PROG0 * PAGE, V_USER
        .gp   USER_GP                  # set by spawn

        .equ  LINE_MAX, 60             # characters kept from a line
        .equ  BS, 8                    # backspace, and delete, both erase
        .equ  DEL, 127
        .equ  BUF_MAX, 243             # trytes cat reads at a time
        .equ  SH_NOFS, -1              # sh_fs with no file server: no process
                                       # has the number, so a call is E_NOPROC
        .equ  SH_NOCON, -1             # sh_con with no console server, alike

sh:     li    a0, SYS_SPAWN            # the console server
        li    a1, SH_CONSD
        sys
        bltz  a0, 1f                   # none: sh_con stays SH_NOCON
        li    a0, SYS_LOOKUP           # wait until it is ready
        la    a1, sh_conname
        li    a2, LOOKUP_WAIT
        sys
        bltz  a0, 1f
        li    t0, CONSOLE_PROTOCOL     # calls it would misread: none at all
        bne   a1, t0, 1f
        sw    a0, sh_con
        li    s0, STDERR               # standard input, output and error,
2:      li    a0, SYS_DESC             # which every program it starts
        mv    a1, s0                   # inherits
        lw    a2, sh_con
        li    a3, CONSOLE_HANDLE
        sys
        addi  s0, s0, -1
        bgez  s0, 2b
1:      li    a0, SYS_SPAWN            # the disk server, which the
        li    a1, SH_DISKD             # file server waits for
        sys
        bltz  a0, prompt               # none: no file server either
        li    a0, SYS_SPAWN            # the file server
        li    a1, SH_FSD
        sys
        bltz  a0, prompt               # none: sh_fs stays SH_NOFS
        li    a0, SYS_LOOKUP           # wait until it is ready
        la    a1, sh_fsname
        li    a2, LOOKUP_WAIT
        sys
        bltz  a0, prompt
        li    t0, FS_PROTOCOL          # calls it would misread: none at all
        bne   a1, t0, prompt
        sw    a0, sh_fs
prompt: la    a1, sh_prompt
        call  puts
        la    s0, sh_line              # s0: the line
        mv    s1, s0                   # s1: just past what was typed

read:   li    a0, SYS_READ
        li    a1, STDIN
        la    a2, sh_ch
        li    a3, 1
        sys
        blez  a0, eof                  # the end, or no standard input
        lt    a0, sh_ch
        bnez  a0, got                  # zero, NUL, is ignored
        j     read
        j     read
got:    li    t0, '\n'
        beq   a0, t0, enter
        li    t0, CTRL_C               # nothing runs: drop the line instead
        beq   a0, t0, cancel
        li    t0, BS
        beq   a0, t0, erase
        li    t0, DEL
        beq   a0, t0, erase
        addi  t0, s0, LINE_MAX
        bge   s1, t0, read             # the line is full: drop it
        st    a0, 0(s1)
        addi  s1, s1, 1
        mv    a1, a0                   # echo it, as a terminal would
        call  putc
        j     read
erase:  beq   s1, s0, read             # nothing to erase
        addi  s1, s1, -1
        la    a1, sh_rubout
        call  puts
        j     read

cancel: la    a1, sh_cancel
        call  puts
        j     prompt

eof:    li    a1, '\n'                # end the last prompt's line
        call  putc
        li    a0, SYS_EXIT
        li    a1, 0
        sys

enter:  li    a1, '\n'
        call  putc
        st    zero, 0(s1)
        mv    a0, s0
        call  word
        mv    s0, a0                   # s0: the command
        mv    s4, a1                   # s4: the rest of the line
        lt    t0, 0(s0)
        beqz  t0, prompt               # an empty line

        la    s2, sh_builtins          # s2: the table entry tried
1:      lw    a0, 0(s2)
        beqz  a0, 6f                   # the end of the table
        mv    a1, s0
        call  streq
        bnez  a0, 2f
        addi  s2, s2, 6
        j     1b
2:      lw    t0, 3(s2)
        jalr  zero, 0(t0)

6:      la    s2, sh_programs          # s2: the table entry tried
7:      lw    a0, 0(s2)
        beqz  a0, from_disk            # the end of the table
        mv    a1, s0
        call  streq
        bnez  a0, found
        addi  s2, s2, 6
        j     7b

# from_disk: run the program file s0 names: a path, if it has a slash;
# else the file of that name in /bin, as a Unix shell searches its PATH.
from_disk:
        mv    t0, s0
        li    t2, '/'
1:      lt    t1, 0(t0)
        beqz  t1, 2f
        beq   t1, t2, 4f               # a path
        addi  t0, t0, 1
        j     1b
2:      la    t0, sh_path              # /bin/ and the name
        la    t1, sh_bin
        call  strcpy
        mv    t1, s0
        call  strcpy
        la    s5, sh_path
        j     5f
4:      mv    s5, s0
5:      li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_SPAWN
        mv    a3, s5
        sys
        bgez  a0, started
        li    t0, E_NOEXEC
        beq   a0, t0, not_prog
        li    t0, E_NOENT              # nothing there, or nothing to look in
        beq   a0, t0, unknown
        li    t0, E_NOTDIR
        beq   a0, t0, unknown
        li    t0, E_NOFS
        beq   a0, t0, unknown
        li    t0, E_NOPROC             # no file server
        beq   a0, t0, unknown
        li    t0, E_NAMETOOLONG        # no file has a name that long
        beq   a0, t0, unknown
        j     started                  # cannot start it, for another reason
not_prog:
        la    a1, sh_notprog
        call  puts
        mv    a1, s0
        j     say

unknown:
        la    a1, sh_unknown
        call  puts
        mv    a1, s0
        call  puts
        li    a1, '\n'
        call  putc
        j     prompt

found:  li    a0, SYS_SPAWN
        lw    a1, 3(s2)
        sys
started:                               # a0: the child, or why it did not start
        bgez  a0, 1f
        mv    s3, a0                   # it could not start: say why
        la    a1, sh_nostart
        call  puts
        mv    a0, s3
        call  putn
        j     newline
1:      mv    s3, a0                   # s3: the child
        mv    a3, a0                   # Ctrl-C kills it while it runs
        call  fground
        mv    a1, s3
        li    a0, SYS_WAIT
        sys
        mv    s3, a1                   # s3: its exit code or trap cause
        mv    s2, a0                   # s2: how it ended
        li    a3, NO_FOREGROUND        # the console is the shell's again,
        call  fground                  # before the next program's number
        mv    a0, s2                   # can be this one's
        li    t0, WAIT_KILLED
        beq   a0, t0, killed
        br3   a0, prompt, faulted      # negative cannot happen: it is ours
        beqz  s3, prompt               # exited with 0: nothing to say
        la    a1, sh_exited
        j     2f
killed: la    a1, sh_killed
        call  puts
        j     newline
faulted:
        la    a1, sh_faulted
2:
        call  puts
        mv    a0, s3
        call  putn
newline:
        li    a1, '\n'
        call  putc
        j     prompt

# --- built-ins ----------------------------------------------------------------
# Each is jumped to with s4 at the rest of its line, and ends at prompt.

do_exit:
        li    a0, SYS_EXIT
        li    a1, 0
        sys

# ls [DIR]: each entry of DIR, or of the current directory, but those whose names start with
# a dot: a file's size and name, a directory's name and a slash.
do_ls:  mv    a0, s4
        call  word
        mv    s5, a0                   # s5: the directory
        lt    t0, 0(s5)
        bnez  t0, 1f
        la    s5, sh_dot
1:      call  open_s5
        bltz  a0, fail
        mv    s6, a0                   # s6: its descriptor
        la    t0, sh_path              # the directory and a slash, for stat
        mv    t1, s5
        call  strcpy
        li    t2, '/'
        st    t2, 0(t0)
        addi  s7, t0, 1                # s7: where each name goes after them
2:      li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_READDIR
        mv    a3, s6
        la    a4, sh_name
        sys
        bltz  a0, failc
        beqz  a0, 6f                   # no more
        lt    t1, sh_name
        li    t2, '.'
        beq   t1, t2, 2b               # hidden, as ls hides them
        mv    t0, s7
        la    t1, sh_name
        call  strcpy
        li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_STAT
        la    a3, sh_path
        la    a4, sh_stat
        sys
        la    s5, sh_path
        bltz  a0, failc
        lw    t1, sh_stat + ST_TYPE
        li    t2, T_DIR
        beq   t1, t2, 3f
        lw    a0, sh_stat + ST_SIZE
        call  putn
        li    a1, ' '
        call  putc
3:
        la    a1, sh_name
        call  puts
        lw    t1, sh_stat + ST_TYPE
        li    t2, T_DIR
        bne   t1, t2, 4f
        li    a1, '/'
        call  putc
4:
        li    a1, '\n'
        call  putc
        j     2b
6:      call  close_s6
        j     prompt

# cat PATH: print a file, a block's worth or less at a time.
do_cat: call  name_arg
        call  open_s5
        bltz  a0, fail
        mv    s6, a0                   # s6: its descriptor
1:      li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_READ
        mv    a3, s6
        la    a4, sh_buf
        li    a5, BUF_MAX
        sys
        bltz  a0, failc
        beqz  a0, 2f                   # the end
        la    t0, sh_buf
        add   t0, t0, a0
        st    zero, 0(t0)
        la    a1, sh_buf
        call  puts
        j     1b
2:      call  close_s6
        j     prompt

# write PATH TEXT: make PATH hold the rest of the line and a newline,
# replacing what it held.
do_write:
        call  name_arg
        mv    s7, a1                   # s7: the text
        li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_OPEN
        mv    a3, s5
        li    a4, O_WRONLY + O_CREAT + O_TRUNC
        sys
        bltz  a0, fail
        mv    s6, a0                   # s6: its descriptor
        mv    t0, s7                   # the newline goes where the line ends
1:      lt    t1, 0(t0)
        beqz  t1, 2f
        addi  t0, t0, 1
        j     1b
2:      li    t1, '\n'
        st    t1, 0(t0)
        addi  t0, t0, 1
        sub   s8, t0, s7               # s8: trytes still to write
3:      beqz  s8, 4f
        li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_WRITE
        mv    a3, s6
        mv    a4, s7
        mv    a5, s8
        sys
        bltz  a0, failc
        add   s7, s7, a0
        sub   s8, s8, a0
        j     3b
4:      call  close_s6
        j     prompt

# cd [DIR]: make DIR the current directory, or / with none; programs
# the shell starts from the disk start in it.
do_cd:  mv    a0, s4
        call  word
        mv    s5, a0                   # s5: the directory
        lt    t0, 0(s5)
        bnez  t0, 1f
        la    s5, sh_root
1:      li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_CHDIR
        mv    a3, s5
        sys
        bltz  a0, fail
        j     prompt

# pwd: print the current directory's path.
do_pwd: li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_GETCWD
        la    a3, sh_buf
        li    a4, BUF_MAX + 1
        sys
        la    s5, sh_dot
        bltz  a0, fail
        la    a1, sh_buf
        call  puts
        j     newline

# rm PATH, mkdir PATH, rmdir PATH: one call each, on the path.
do_rm:  li    s8, FS_UNLINK
        j     1f
do_mkdir:
        li    s8, FS_MKDIR
        j     1f
do_rmdir:
        li    s8, FS_RMDIR
1:      call  name_arg
        li    a0, SYS_CALL
        lw    a1, sh_fs
        mv    a2, s8
        mv    a3, s5
        sys
        bltz  a0, fail
        j     prompt

# failc: close descriptor s6, then fail. fail: say why a call about path
# s5 failed with a0, as Unix tools do, and go back to the prompt.
failc:  mv    s3, a0
        call  close_s6
        mv    a0, s3
fail:   mv    s3, a0                   # s3: why
        la    a1, sh_sh
        call  puts
        mv    a1, s5
        call  puts
        la    a1, sh_colon
        call  puts
        la    s2, sh_errors            # s2: the table entry tried
1:      lw    t0, 0(s2)
        beqz  t0, 2f                   # not in the table
        beq   t0, s3, 3f
        addi  s2, s2, 6
        j     1b
2:      la    a1, sh_error
        call  puts
        mv    a0, s3
        call  putn
        j     newline
3:      lw    a1, 3(s2)
        j     say
no_name:
        la    a1, sh_noname
say:
        call  puts
        j     newline

# --- helpers --------------------------------------------------------------------

# name_arg: s5 = the first word of s4, the file a built-in is about, and
# a1 = what follows it; to no_name, not returning, if there is none.
# Clobbers a0, t0, t1.
name_arg:
        mv    a0, s4
        mv    t2, ra                   # word is a leaf: ra lasts in t2
        call  word
        mv    ra, t2
        mv    s5, a0
        lt    t0, 0(s5)
        beqz  t0, no_name
        ret

# close_s6: close descriptor s6. Clobbers a0, a1.
close_s6:
        li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_CLOSE
        mv    a3, s6
        sys
        ret

# open_s5: a0 = a descriptor for path s5, open for reading, or why not.
open_s5:
        li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_OPEN
        mv    a3, s5
        li    a4, O_RDONLY
        sys
        ret

# strcpy: copy the string at t1 to t0, and leave t0 at its ending 0.
# Clobbers t1, t2.
strcpy: lt    t2, 0(t1)
        st    t2, 0(t0)
        beqz  t2, 1f
        addi  t0, t0, 1
        addi  t1, t1, 1
        j     strcpy
1:      ret

# word: split the first word off the string at a0. a0 = the word, ended
# with 0; a1 = what follows, past its spaces. Clobbers t0, t1.
word:   li    t1, ' '
1:      lt    t0, 0(a0)                # skip leading spaces
        bne   t0, t1, 2f
        addi  a0, a0, 1
        j     1b
2:      mv    a1, a0
3:      lt    t0, 0(a1)                # find the word's end
        beqz  t0, 9f
        beq   t0, t1, 4f
        addi  a1, a1, 1
        j     3b
4:      st    zero, 0(a1)
5:      addi  a1, a1, 1                # and the next one's start
        lt    t0, 0(a1)
        beq   t0, t1, 5b
9:      ret

# streq: a0 = 1 if the strings at a0 and a1 are the same, else 0.
# Clobbers t0, t1.
streq:  lt    t0, 0(a0)
        lt    t1, 0(a1)
        bne   t0, t1, 1f
        beqz  t0, 2f
        addi  a0, a0, 1
        addi  a1, a1, 1
        j     streq
1:      li    a0, 0
        ret
2:      li    a0, 1
        ret

# puts: print the 0-terminated string at a1. putc: print code point a1,
# which fits in a tryte. Both to standard output. Clobber a0..a5 and t0.
puts:   mv    a4, a1
1:      lt    t0, 0(a4)
        beqz  t0, 2f
        addi  a4, a4, 1
        j     1b
2:      sub   a3, a4, a1               # a3: its length
        mv    a2, a1
        j     3f
putc:   st    a1, sh_ch
        la    a2, sh_ch
        li    a3, 1
3:      li    a0, SYS_WRITE
        li    a1, STDOUT
        sys
        ret

# fground: give the console to process a3, or to nobody with
# NO_FOREGROUND. Clobbers a0..a2.
fground:
        li    a0, SYS_CALL
        lw    a1, sh_con
        li    a2, CN_FOREGROUND
        sys
        ret

# putn: print a0 in decimal. Clobbers a0..a5, t0..t3.
putn:   addi  sp, sp, -3               # it calls puts and putc
        sw    ra, 0(sp)
        mv    t3, a0
        bgez  t3, 1f
        li    a1, '-'
        call  putc
        neg   t3, t3
1:      la    t2, sh_digits_end
        st    zero, 0(t2)
        li    t1, 10
2:      rem   t0, t3, t1
        addi  t0, t0, '0'
        addi  t2, t2, -1
        st    t0, 0(t2)
        div   t3, t3, t1
        bnez  t3, 2b
        mv    a1, t2
        call  puts
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# Each entry: the name, and where the built-in starts; 0 ends it.
sh_builtins:
        .word sh_exit, do_exit
        .word sh_ls, do_ls
        .word sh_cat, do_cat
        .word sh_write, do_write
        .word sh_rm, do_rm
        .word sh_mkdir, do_mkdir
        .word sh_rmdir, do_rmdir
        .word sh_cd, do_cd
        .word sh_pwd, do_pwd
        .word 0

# Each entry: a failure from a file call, and what to say about it.
sh_errors:
        .word E_NOENT, sh_noent
        .word E_NOTDIR, sh_notdir
        .word E_ISDIR, sh_isdir
        .word E_NOFS, sh_nofs
        .word E_NOPROC, sh_nofs          # no file server to ask
        .word E_NAMETOOLONG, sh_toolong
        .word E_EXIST, sh_exist
        .word E_NOSPC, sh_nospc
        .word E_NOTEMPTY, sh_notempty
        .word E_BUSY, sh_busy
        .word E_INVAL, sh_inval
        .word 0

# Each entry: the name, and the program number to spawn; 0 ends it.
# Everything else is on the disk.
sh_programs:
        .word sh_pingpong, 3
        .word 0

        .align 1
sh_fs:       .word SH_NOFS             # the file server's process number
sh_con:      .word SH_NOCON            # the console server's process number
sh_fsname:   .string "fs"
sh_conname:  .string "console"
sh_ch:       .zero 1                   # what putc prints, and read reads
sh_pingpong: .string "pingpong"
sh_exit:     .string "exit"
sh_ls:       .string "ls"
sh_cat:      .string "cat"
sh_write:    .string "write"
sh_rm:       .string "rm"
sh_mkdir:    .string "mkdir"
sh_rmdir:    .string "rmdir"
sh_cd:       .string "cd"
sh_pwd:      .string "pwd"
sh_prompt:   .string "$ "
sh_rubout:   .tryte BS, ' ', BS, 0     # back, blank, back: the assembler has no \b
sh_unknown:  .string "sh: no such program: "
sh_notprog:  .string "sh: not a program: "
sh_nostart:  .string "sh: cannot start it: "
sh_exited:   .string "sh: exit "
sh_faulted:  .string "sh: fault "
sh_killed:   .string "sh: killed"
sh_cancel:   .string "^C\n"
sh_noname:   .string "sh: which file?"
sh_sh:       .string "sh: "
sh_colon:    .string ": "
sh_noent:    .string "no such file or directory"
sh_notdir:   .string "not a directory"
sh_isdir:    .string "is a directory"
sh_nofs:     .string "no filesystem on the disk"
sh_toolong:  .string "name too long"
sh_exist:    .string "file exists"
sh_nospc:    .string "no space left"
sh_notempty: .string "directory not empty"
sh_busy:     .string "busy"
sh_inval:    .string "invalid argument"
sh_error:    .string "error "
sh_root:     .string "/"
sh_dot:      .string "."
sh_bin:      .string "/bin/"
sh_digits:   .zero 12
sh_digits_end: .zero 1
sh_line:     .zero LINE_MAX + 1
sh_path:     .zero LINE_MAX + NAME_MAX + 3   # a path the shell puts together
sh_name:     .zero NAME_MAX + 1        # a name readdir gives
sh_stat:     .words STAT / 3           # what stat says
sh_buf:      .zero BUF_MAX + 1         # what cat reads, and a 0 to end it
        .nocompress
