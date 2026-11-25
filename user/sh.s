# The shell of shell.s, which init (user/init.s) starts once the servers
# are up. It reads a line, runs the program its
# first word names, waits for it, and says how it ended if not with code
# 0. Some words are built in: exit, and ls, cat, write, rm, mkdir, rmdir,
# cd and pwd, which use the filesystem on the disk (docs/filesystem.md)
# through the file server. The console is the console server's: the
# shell points its standard input, output and error at it, which the
# programs it starts inherit, reads and prints through them, and gives
# the server each program it runs as the foreground, for Ctrl-C. It finds
# the console, pipe and file servers by their names, and does without
# one that is missing. A word that is neither
# built in nor a program in the kernel image names a program file: a
# path if it has a slash, else a file in /bin, and gets the line's words
# as its arguments, the command first. It stops at the end of input.
#
# A word after the command that starts with < or > redirects: < PATH makes
# the file standard input, > PATH standard output, made empty or new, and
# >> PATH standard output at the file's end. The path may follow at once
# (>out) or as the next word. The shell opens the file, points descriptor
# 0 or 1 at it for the command, built-in or program, which a program
# inherits, and points it back at the next prompt. Its own complaints go
# to standard error, so they reach the console whatever is redirected.
#
# Quotes make characters themselves, as in a Unix shell: 'a b' and "a b"
# are one word holding a space, \ makes the next character itself, and a
# quoted |, < or > neither pipes nor redirects. Inside "...", \ quotes
# only " and \. "" or '' alone is an empty word.
#
# A | between commands makes a pipeline: each command's standard output
# goes into a pipe (the pipe server's) that is the next one's standard
# input. The shell starts every program of the line before it waits for
# any, so they run side by side, and it keeps its own end of each pipe out
# of the children (FD_NOINHERIT), so that a reader sees the end once its
# writer has gone. A built-in in a pipeline runs in the shell itself, once
# every program of the line has started; one is allowed per line, since
# two would wait for each other.

        .compress
        .gp   USER_GP                  # set by spawn

        .equ  LINE_MAX, 60             # characters kept from a line
        .equ  CR, 13                   # carriage return: the assembler has no \r
        .equ  ESC, 27                  # escape, which starts the arrow keys' sequences
        .equ  SH_CR, 1                 # sh_state: a carriage return came last
        .equ  SH_ESC, 2                # an escape came last
        .equ  SH_SEQ, 3                # inside ESC [ or ESC O, before its final character
        .equ  BS, 8                    # backspace, and delete, both erase
        .equ  DEL, 127
        .equ  BUF_MAX, 243             # trytes cat reads at a time
        .equ  SH_NOFS, -1              # sh_fs with no file server: no process
                                       # has the number, so a call is E_NOPROC
        .equ  SH_NOCON, -1             # sh_con with no console server, alike
        .equ  SH_SAVEIN, NDESC - 2     # where standard input and output wait
        .equ  SH_SAVEOUT, NDESC - 1    # while a command has them redirected
        .equ  SH_PARKIN, NDESC - 4     # where a built-in's standard input and
        .equ  SH_PARKOUT, NDESC - 3    # output wait while the line starts
        .equ  SH_STAGES, 4             # commands a pipeline may have
        .equ  SH_NOPIPE, -1            # sh_pipe with no pipe server, alike
        .equ  SH_EMPTY, -1             # in the line, a word of quotes alone:
                                       # no character is negative

sh:     li    a0, SYS_NAME             # for ps: a program of the image
        la    a1, sh_myname            # has no argv[0] to name it
        sys
        li    a0, SYS_LOOKUP           # the console server, which init
        la    a1, sh_conname           # has started (user/init.s)
        li    a2, LOOKUP_NOW
        sys
        bltz  a0, 1f                   # none: sh_con stays SH_NOCON
        li    t0, CONSOLE_PROTOCOL     # calls it would misread: none at all
        bne   a1, t0, 1f
        sw    a0, sh_con
        li    a0, SYS_CALL             # standard input, output and error,
        lw    a1, sh_con               # which every program it starts
        li    a2, CN_OPEN              # inherits: its first descriptor, 0,
        sys                            # and two copies
        bltz  a0, 1f
        li    a0, SYS_DUP2
        li    a1, STDIN
        li    a2, STDOUT
        sys
        li    a0, SYS_DUP2
        li    a1, STDIN
        li    a2, STDERR
        sys
1:      li    a0, SYS_LOOKUP           # the pipe server
        la    a1, sh_pipename
        li    a2, LOOKUP_NOW
        sys
        bltz  a0, 1f                   # none: sh_pipe stays SH_NOPIPE
        li    t0, PIPE_PROTOCOL
        bne   a1, t0, 1f
        sw    a0, sh_pipe
1:      li    a0, SYS_LOOKUP           # the file server
        la    a1, sh_fsname
        li    a2, LOOKUP_NOW
        sys
        bltz  a0, prompt               # none: sh_fs stays SH_NOFS
        li    t0, FS_PROTOCOL          # calls it would misread: none at all
        bne   a1, t0, prompt
        sw    a0, sh_fs
prompt: lw    t0, sh_redir             # what the last command redirected
        beqz  t0, 1f                   # comes back
        sw    zero, sh_redir
        li    a1, STDIN
        li    a2, SH_SAVEIN
        call  unredir
        li    a1, STDOUT
        li    a2, SH_SAVEOUT
        call  unredir
        li    s0, 3                    # and whatever a pipeline that stopped
2:      li    a0, SYS_CLOSE            # partway left open, so that its
        mv    a1, s0                   # programs see their pipes end
        sys
        addi  s0, s0, 1
        li    t0, SH_SAVEIN
        blt   s0, t0, 2b
1:      sw    zero, sh_inpipe          # then wait for a pipeline's programs,
        la    s0, sh_pids              # in order
        lw    s1, sh_npids
        sw    zero, sh_npids
3:      beqz  s1, 4f
        lw    a0, 0(s0)
        call  reap
        addi  s0, s0, 3
        addi  s1, s1, -1
        j     3b
4:      li    t0, STDOUT
        sw    t0, sh_outfd
        la    a1, sh_prompt
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
got:    lw    t1, sh_state             # t1: what came before (SH_ values)
        sw    zero, sh_state
        li    t0, SH_ESC
        blt   t1, t0, 4f
        bne   t1, t0, 5f
        li    t0, '['                  # after an escape: ESC [ and ESC O
        beq   a0, t0, 6f               # start a sequence, as the arrow
        li    t0, 'O'                  # keys send; any other character
        bne   a0, t0, read             # after it (Alt+key) is dropped
6:      li    t0, SH_SEQ
        sw    t0, sh_state
        j     read
5:      li    t0, '@'                  # in a sequence: everything up to
        blt   a0, t0, 6b               # its final character, @ to ~, is
        j     read                     # dropped, so no key leaves a trace
4:      li    t0, ESC
        bne   a0, t0, 7f
        li    t0, SH_ESC
        sw    t0, sh_state
        j     read
7:      li    t0, CR                   # a carriage return ends the line,
        bne   a0, t0, 1f               # as a terminal's Enter may send it,
        li    t0, SH_CR
        sw    t0, sh_state
        j     enter
1:      li    t0, '\n'                 # and so does a newline, but not
        bne   a0, t0, 2f               # one right after it (CR LF)
        bnez  t1, read
        j     enter
2:      li    t0, CTRL_C               # nothing runs: drop the line instead
        beq   a0, t0, cancel
        li    t0, BS
        beq   a0, t0, erase
        li    t0, DEL
        beq   a0, t0, erase
        li    t0, '\t'                 # a tab is a space,
        bne   a0, t0, 3f
        li    a0, ' '
3:      li    t0, ' '                  # and other control characters
        blt   a0, t0, read             # are dropped
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

# Quoting: undo it in place, before anything looks for words, | or
# redirections. In '...' every character is itself; in "..." too, but
# that \" and \\ stand for " and \; elsewhere \ makes the character after
# it itself. A space, |, < or > made itself this way is stored negated,
# which no typed character is, so nothing splits or redirects at it, and
# word (or unquote) turns it back. A word made of quotes alone ("" or '')
# is SH_EMPTY, so that it is still there, as an empty argument. Nothing
# grows, so the line is rewritten as it is read.
        mv    t0, s0                   # t0: what is read next
        mv    t1, s0                   # t1: where what is kept goes
        mv    t3, s0                   # t3: where the word being read starts
        li    a2, 0                    # a2: the quote it is in, or 0
        li    a3, 0                    # a3: 1 once the word has had quotes
q_next: lt    t2, 0(t0)
        addi  t0, t0, 1
        bnez  a2, q_in
        beqz  t2, q_brk
        li    a0, '\''
        beq   t2, a0, q_open
        li    a0, '"'
        beq   t2, a0, q_open
        li    a0, '\\'
        beq   t2, a0, q_esc
        li    a0, ' '                  # what ends a word: kept, as typed
        beq   t2, a0, q_brk
        li    a0, '|'
        beq   t2, a0, q_brk
        li    a0, '<'
        beq   t2, a0, q_brk
        li    a0, '>'
        beq   t2, a0, q_brk
        j     q_keep
q_open: mv    a2, t2
        li    a3, 1
        j     q_next
q_esc:  lt    t2, 0(t0)
        beqz  t2, q_bs                 # nothing after it: the \ itself
        addi  t0, t0, 1
        j     q_lit
q_bs:   li    t2, '\\'
        j     q_keep
q_in:   beqz  t2, q_unmatched
        beq   t2, a2, q_close
        li    a0, '"'                  # in '...', nothing is special
        bne   a2, a0, q_lit
        li    a0, '\\'
        bne   t2, a0, q_lit
        lt    a0, 0(t0)                # in "...", \ makes " and \ themselves
        li    a1, '"'
        beq   a0, a1, 1f
        li    a1, '\\'
        bne   a0, a1, q_lit            # and is itself before anything else
1:      mv    t2, a0
        addi  t0, t0, 1
        j     q_lit
q_close:
        li    a2, 0
        j     q_next
q_lit:  li    a0, ' '                  # t2 is itself: if it would split or
        beq   t2, a0, 1f               # redirect, negated
        li    a0, '|'
        beq   t2, a0, 1f
        li    a0, '<'
        beq   t2, a0, 1f
        li    a0, '>'
        bne   t2, a0, q_keep
1:      neg   t2, t2
q_keep: st    t2, 0(t1)
        addi  t1, t1, 1
        j     q_next
q_brk:  beqz  a3, 1f                   # t2 ends a word: a space, |, < or >,
        bne   t1, t3, 1f               # or the line's end. Quotes and
        li    a0, SH_EMPTY             # nothing else are an empty word
        st    a0, 0(t1)
        addi  t1, t1, 1
1:      li    a3, 0
        st    t2, 0(t1)
        addi  t1, t1, 1
        mv    t3, t1
        bnez  t2, q_next
        j     q_done
q_unmatched:
        call  to_err
        la    a1, sh_unmatched
        j     say

q_done: la    t0, sh_segs              # cut the line at each |, a command
        sw    s0, 0(t0)                # after each
        li    t1, 1                    # t1: how many
        li    t3, '|'
1:      lt    t2, 0(s0)
        beqz  t2, 2f
        addi  s0, s0, 1
        bne   t2, t3, 1b
        st    zero, -1(s0)
        li    t2, SH_STAGES
        beq   t1, t2, p_many
        addi  t0, t0, 3
        sw    s0, 0(t0)
        addi  t1, t1, 1
        j     1b
2:      sw    t1, sh_nseg
        lw    a0, sh_segs
        li    t2, 1
        bne   t1, t2, pipeline

# segment: run the command at a0, with its redirections: a line's only
# one, or one of a pipeline's (sh_inpipe).
segment:
        call  word
        mv    s0, a0                   # s0: the command
        mv    s4, a1                   # s4: the rest of the line
        lt    t0, 0(s0)
        bnez  t0, 1f
        lw    t0, sh_inpipe            # an empty line; in a pipeline, a
        beqz  t0, prompt               # command missing
        call  to_err
        la    a1, sh_nocmd
        j     say
1:

# Redirections: take each word starting with < or > out of the rest of
# the line, with the spaces before it, opening its file and pointing
# standard input or output at it. The rest closes up behind, as typed.
        mv    s6, s4                   # s6: where the next word is read
        mv    s7, s4                   # s7: where what is kept goes
r_next: mv    t2, s6                   # t2: the spaces before the word
        li    t1, ' '
1:      lt    t0, 0(s6)
        bne   t0, t1, 2f
        addi  s6, s6, 1
        j     1b
2:      beqz  t0, r_done               # spaces at the end go too
        li    t1, '<'
        beq   t0, t1, r_in
        li    t1, '>'
        beq   t0, t1, r_out
        li    t1, ' '
3:      lt    t0, 0(t2)                # a word to keep, and its spaces:
        st    t0, 0(s7)                # s7 is never past t2
        addi  t2, t2, 1
        addi  s7, s7, 1
        lt    t0, 0(t2)
        beqz  t0, 4f
        blt   t2, s6, 3b
        bne   t0, t1, 3b
4:      mv    s6, t2
        j     r_next
r_in:   li    s8, STDIN                # s8: the descriptor it replaces
        li    s3, O_RDONLY             # s3: how it opens the file
        addi  s6, s6, 1
        j     r_path
r_out:  li    s8, STDOUT
        li    s3, O_WRONLY + O_CREAT + O_TRUNC
        addi  s6, s6, 1
        lt    t0, 0(s6)
        li    t1, '>'
        bne   t0, t1, r_path
        li    s3, O_WRONLY + O_CREAT + O_APPEND
        addi  s6, s6, 1
r_path: lt    t0, 0(s6)                # the rest of the word, or the next
        li    t1, ' '
        bne   t0, t1, 1f
        addi  s6, s6, 1
        j     r_path
1:      mv    s5, s6                   # s5: the path
        beqz  t0, no_name
2:      addi  s6, s6, 1
        lt    s2, 0(s6)                # s2: what ends it, 0 or a space,
        beqz  s2, 3f                   # which comes back once it is open
        bne   s2, t1, 2b
        st    zero, 0(s6)
3:      mv    a0, s5                   # it leaves the line, so is undone
        call  unquote                  # in place
        li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_OPEN
        mv    a3, s5
        mv    a4, s3
        sys
        bltz  a0, fail
        st    s2, 0(s6)
        mv    s3, a0                   # s3: the file's descriptor
        lw    t0, sh_redir             # keep the shell's own, the first time
        bnez  t0, 4f
        li    t0, 1
        sw    t0, sh_redir
        call  save_fds
4:      beq   s3, s8, r_next           # with no console, it may be there already
        li    a0, SYS_DUP2
        mv    a1, s3
        mv    a2, s8
        sys
        li    a0, SYS_CLOSE
        mv    a1, s3
        sys
        j     r_next
r_done: st    zero, 0(s7)

        la    s2, sh_builtins          # s2: the table entry tried
1:      lw    a0, 0(s2)
        beqz  a0, 6f                   # the end of the table
        mv    a1, s0
        call  streq
        bnez  a0, 2f
        addi  s2, s2, 6
        j     1b
2:      lw    t0, sh_inpipe
        bnez  t0, p_builtin
        lw    t0, 3(s2)
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
5:      la    t0, sh_args              # its arguments: the command as typed,
        mv    t1, s0
        call  strcpy
        addi  s3, t0, 1                # s3: where the next one goes
        mv    a0, s4
6:      call  word                     # then each word of the rest, which
        beq   a0, a1, 7f               # may be empty (""): none if nothing
                                       # was taken
        mv    s6, a1
        mv    t0, s3
        mv    t1, a0
        call  strcpy
        addi  s3, t0, 1
        mv    a0, s6
        j     6b
7:      li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_SPAWN
        mv    a3, s5
        la    a4, sh_args
        la    t0, sh_args
        sub   a5, s3, t0
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
        call  to_err
        la    a1, sh_notprog
        call  puts
        mv    a1, s0
        j     say

unknown:
        call  to_err
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
        call  to_err
        la    a1, sh_nostart
        call  puts
        mv    a0, s3
        call  putn
        j     newline
1:      lw    t0, sh_inpipe
        bnez  t0, p_started
        call  reap
        j     prompt
newline:
        li    a1, '\n'
        call  putc
        j     prompt

# --- pipelines ------------------------------------------------------------------
# pipeline: run the sh_nseg commands of sh_segs, a pipe between each and
# the next. Each command in turn gets its standard input (the last pipe's
# read end, or the shell's) and output (a new pipe's write end, or the
# shell's) in 0 and 1, and is started (a program) or put aside until all
# are (a built-in). prompt then puts the shell's back, which closes its
# ends of the pipes, and waits for the programs.
pipeline:
        li    t0, 1
        sw    t0, sh_inpipe
        sw    zero, sh_stage
        sw    zero, sh_bi
        li    t0, -1                   # no pipe yet
        sw    t0, sh_prevr
        lw    t0, sh_redir
        bnez  t0, p_next
        li    t0, 1
        sw    t0, sh_redir
        call  save_fds
p_next: lw    a1, sh_prevr             # standard input: the last pipe,
        bgez  a1, 1f
        li    a1, SH_SAVEIN            # or the shell's
1:      li    a0, SYS_DUP2
        li    a2, STDIN
        sys
        lw    a1, sh_prevr
        bltz  a1, 2f
        li    a0, SYS_CLOSE
        sys
2:      lw    t0, sh_stage             # standard output: a new pipe,
        addi  t0, t0, 1
        lw    t1, sh_nseg
        blt   t0, t1, 3f
        li    a0, SYS_DUP2             # or the shell's, for the last
        li    a1, SH_SAVEOUT
        li    a2, STDOUT
        sys
        li    t0, -1
        sw    t0, sh_prevr
        j     4f
3:      li    a0, SYS_CALL
        lw    a1, sh_pipe
        li    a2, PP_PIPE
        sys
        bltz  a0, p_nopipe
        sw    a0, sh_prevr             # the read end, for the next one,
        mv    s0, a1                   # s0: the write end
        call  noinherit                # which this one must not hold
        li    a0, SYS_DUP2
        mv    a1, s0
        li    a2, STDOUT
        sys
        li    a0, SYS_CLOSE
        mv    a1, s0
        sys
4:      lw    t0, sh_stage
        li    t1, 3
        mul   t0, t0, t1
        la    t1, sh_segs
        add   t0, t0, t1
        lw    a0, 0(t0)
        j     segment

# p_started: program a0 of the line has started. p_builtin: built-in s2,
# with the rest of its line at s4, waits with its 0 and 1 put aside.
p_started:
        lw    t0, sh_npids
        li    t1, 3
        mul   t1, t0, t1
        la    t2, sh_pids
        add   t1, t1, t2
        sw    a0, 0(t1)
        addi  t0, t0, 1
        sw    t0, sh_npids
        j     p_step
p_builtin:
        lw    t0, sh_bi
        bnez  t0, p_twobi
        sw    s2, sh_bi
        sw    s4, sh_birest
        li    a0, SYS_DUP2
        li    a1, STDIN
        li    a2, SH_PARKIN
        sys
        li    a0, SH_PARKIN            # put aside, and not inherited
        call  noinherit
        li    a0, SYS_DUP2
        li    a1, STDOUT
        li    a2, SH_PARKOUT
        sys
        li    a0, SH_PARKOUT
        call  noinherit
p_step: lw    t0, sh_stage
        addi  t0, t0, 1
        sw    t0, sh_stage
        lw    t1, sh_nseg
        blt   t0, t1, p_next
        lw    s2, sh_bi                # all started: now the built-in
        beqz  s2, prompt
        li    a0, SYS_DUP2
        li    a1, SH_PARKIN
        li    a2, STDIN
        sys
        li    a0, SYS_DUP2
        li    a1, SH_PARKOUT
        li    a2, STDOUT
        sys
        li    a0, SYS_CLOSE
        li    a1, SH_PARKIN
        sys
        li    a0, SYS_CLOSE
        li    a1, SH_PARKOUT
        sys
        lw    s4, sh_birest
        lw    t0, 3(s2)
        jalr  zero, 0(t0)

p_twobi:
        call  to_err
        la    a1, sh_twobi
        j     say
p_many:
        call  to_err
        la    a1, sh_many
        j     say
p_nopipe:
        mv    s3, a0
        call  to_err
        la    a1, sh_nopipe
        call  puts
        mv    a0, s3
        call  putn
        j     newline

# reap: give the console to child a0, wait for it to end, take the
# console back, and say how it ended if not with 0. Clobbers a0..a5,
# t0..t3, s2, s3.
reap:   addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    s3, a0                   # s3: the child
        mv    a3, a0                   # Ctrl-C kills it while it runs
        call  fground
        mv    a1, s3
        li    a0, SYS_WAIT
        sys
        mv    s3, a1                   # s3: its exit code or trap cause
        mv    s2, a0                   # s2: how it ended
        li    a3, NO_FOREGROUND        # the console is the shell's again,
        call  fground                  # before the next program's number
        call  to_err                   # can be this one's. What follows is
        mv    a0, s2                   # about it, not output
        li    t0, WAIT_KILLED
        beq   a0, t0, 1f
        br3   a0, 9f, 2f               # negative cannot happen: it is ours
        beqz  s3, 9f                   # exited with 0: nothing to say
        la    a1, sh_exited
        j     3f
1:      la    a1, sh_killed
        call  puts
        j     4f
2:      la    a1, sh_faulted
3:      call  puts
        mv    a0, s3
        call  putn
4:      li    a1, '\n'
        call  putc
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

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
2:      li    a0, SYS_IOCALL
        mv    a1, s6
        li    a2, IO_READDIR
        la    a3, sh_name
        li    a4, 0
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

# cat [PATH]: print a file, or standard input to its end, a block's
# worth or less at a time.
do_cat: mv    a0, s4
        call  word
        mv    s5, a0                   # s5: the file
        li    s6, STDIN                # s6: what it reads
        lt    t0, 0(s5)
        bnez  t0, 3f
        la    s5, sh_stdin
        j     1f
3:      call  open_s5
        bltz  a0, fail
        mv    s6, a0
1:      li    a0, SYS_READ
        mv    a1, s6
        la    a2, sh_buf
        li    a3, BUF_MAX
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
        mv    s7, a1                   # s7: the text, as typed but for
        mv    a0, s7                   # its quoting
        call  unquote
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
        li    a0, SYS_WRITE
        mv    a1, s6
        mv    a2, s7
        mv    a3, s8
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
        call  to_err
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
        call  to_err
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

# close_s6: close descriptor s6, unless it is standard input, which cat
# reads without a path. Clobbers a0, a1.
close_s6:
        li    a0, STDIN
        beq   s6, a0, 1f
        li    a0, SYS_CLOSE
        mv    a1, s6
        sys
1:      ret

# unredir: point descriptor a1 back at what a2 kept for it, and close a2.
# With nothing kept (no console), a1 is closed. Clobbers a0..a3.
unredir:
        mv    a3, a1                   # a3: the descriptor
        li    a0, SYS_CLOSE
        sys
        li    a0, SYS_DUP2
        mv    a1, a2
        mv    a2, a3
        sys
        li    a0, SYS_CLOSE            # a1: what kept it
        sys
        ret

# save_fds: keep the shell's standard input and output in SH_SAVEIN and
# SH_SAVEOUT, out of children, while a command has others. Clobbers
# a0..a3, t0.
save_fds:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    a0, SYS_DUP2
        li    a1, STDIN
        li    a2, SH_SAVEIN
        sys
        li    a0, SH_SAVEIN
        call  noinherit
        li    a0, SYS_DUP2
        li    a1, STDOUT
        li    a2, SH_SAVEOUT
        sys
        li    a0, SH_SAVEOUT
        call  noinherit
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# noinherit: keep descriptor a0 out of the children the shell starts.
# Clobbers a0..a2.
noinherit:
        mv    a1, a0
        li    a0, SYS_FDFLAGS
        li    a2, FD_NOINHERIT
        sys
        ret

# to_err: what puts and putc print goes to standard error, until the next
# prompt. Clobbers t0.
to_err: li    t0, STDERR
        sw    t0, sh_outfd
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
# with 0, its quoting undone (unquote); a1 = what follows, past its
# spaces, which is a0 if there was no word. Clobbers t0, t1, a2, a3.
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
9:                                     # then undo its quoting

# unquote: give the string at a0 back what quoting kept from it, in place:
# each negated character is itself again, and SH_EMPTY goes. Clobbers t0,
# t1, a2, a3.
unquote:
        mv    a2, a0                   # a2: what is read next
        mv    a3, a0                   # a3: where it goes
1:      lt    t0, 0(a2)
        addi  a2, a2, 1
        li    t1, SH_EMPTY
        beq   t0, t1, 1b
        bgez  t0, 2f
        neg   t0, t0
2:      st    t0, 0(a3)
        addi  a3, a3, 1
        bnez  t0, 1b
        ret

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
# which fits in a tryte. Both to standard output, or standard error after
# to_err. Clobber a0..a5 and t0.
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
        lw    a1, sh_outfd
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
sh_pipe:     .word SH_NOPIPE           # the pipe server's process number
sh_inpipe:   .word 0                   # 1 while a pipeline starts
sh_nseg:     .word 0                   # its commands,
sh_segs:     .words SH_STAGES          # where each starts,
sh_stage:    .word 0                   # the one being started,
sh_prevr:    .word 0                   # the last pipe's read end, or -1,
sh_bi:       .word 0                   # its built-in's table entry, or 0,
sh_birest:   .word 0                   # and the rest of the built-in's line
sh_npids:    .word 0                   # programs it has started,
sh_pids:     .words SH_STAGES          # in order
sh_outfd:    .word STDOUT              # where puts and putc print
sh_state:    .word 0                   # SH_CR after a CR, SH_ESC/SH_SEQ in an escape
sh_redir:    .word 0                   # 1 while a command has redirections
sh_fsname:   .string "fs"
sh_conname:  .string "console"
sh_pipename: .string "pipe"
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
sh_nocmd:    .string "sh: a command is missing around |"
sh_twobi:    .string "sh: one built-in to a pipeline"
sh_many:     .string "sh: too many commands in the pipeline"
sh_nopipe:   .string "sh: cannot make a pipe: "
sh_unmatched: .string "sh: a quote is not closed"
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
sh_stdin:    .string "standard input"
sh_bin:      .string "/bin/"
sh_digits:   .zero 12
sh_digits_end: .zero 1
sh_line:     .zero LINE_MAX + 1
sh_path:     .zero LINE_MAX + NAME_MAX + 3   # a path the shell puts together
sh_args:     .zero LINE_MAX + 1        # a program's arguments, each ended by 0
sh_name:     .zero NAME_MAX + 1        # a name readdir gives
sh_stat:     .words STAT / 3           # what stat says
sh_buf:      .zero BUF_MAX + 1         # what cat reads, and a 0 to end it
sh_myname: .string "sh"
        .nocompress
