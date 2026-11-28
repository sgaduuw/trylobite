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
# The line is edited as typed, as in a Unix shell: the cursor keys,
# Ctrl-A/E/U/K/W/L, a history on up and down, and Tab completion (the
# line editor, below).
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
        .equ  BEL, 7                   # the bell: Tab found nothing to add
        .equ  CTRL_A, 1                # the editing keys (the line editor)
        .equ  CTRL_B, 2
        .equ  CTRL_E, 5
        .equ  CTRL_F, 6
        .equ  CTRL_K, 11
        .equ  CTRL_L, 12
        .equ  CTRL_N, 14
        .equ  CTRL_P, 16
        .equ  CTRL_U, 21
        .equ  CTRL_W, 23
        .equ  HIST_N, 16               # lines up and down go through
        .equ  SH_COLS, 80              # columns Tab's list fills
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
        li    a0, SYS_SIGACTION        # a built-in writing to a pipe whose
        li    a1, SIGPIPE              # reader has gone gets E_PIPE, and
        li    a2, SIG_CATCH            # the shell lives on. Caught, not
        la    a3, sh_sigpipe           # ignored, so the programs it starts
        sys                            # have SIGPIPE's default
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
        mv    s2, s0                   # s2: the cursor, s0 to s1
        lw    t0, sh_nhist             # Up starts from the newest line
        sw    t0, sh_hpos

# --- the line editor ----------------------------------------------------------
# Keys edit the line at the cursor, as in a Unix shell's: left and right
# (or Ctrl-B, Ctrl-F), Home and End (Ctrl-A, Ctrl-E), Backspace, Delete
# (Ctrl-D is the live console's end of input), Ctrl-U and Ctrl-K (erase before and after the cursor),
# Ctrl-W (the word before it), Ctrl-L (clear the screen), up and down
# (Ctrl-P, Ctrl-N) through the lines typed before, and Tab, which
# completes a command or a path. The terminal follows with what any
# terminal understands: a backspace moves left, a character prints over
# what is there, so the line's tail is printed again after a change.
# During the edit s0 to s1 hold the line, unended, and s2 is the cursor.
read:   li    a0, SYS_READ
        li    a1, STDIN
        la    a2, sh_ch
        li    a3, 1
        sys
        blez  a0, eof                  # the end, or no standard input
        lt    a0, sh_ch
        bnez  a0, got                  # zero, NUL, is ignored
        j     read
got:    lw    t3, sh_tabbed            # t3: 1 if the last key was a Tab
                                       # that found several names
        sw    zero, sh_tabbed
        lw    t1, sh_state             # t1: what came before (SH_ values)
        sw    zero, sh_state
        li    t0, SH_ESC
        blt   t1, t0, 4f
        bne   t1, t0, 5f
        li    t0, '['                  # after an escape: ESC [ and ESC O
        beq   a0, t0, 6f               # start a sequence, as the arrow
        li    t0, 'O'                  # keys send; any other character
        bne   a0, t0, read             # after it (Alt+key) is dropped
6:      sw    zero, sh_param
        li    t0, SH_SEQ
        sw    t0, sh_state
        j     read
5:      li    t0, '@'                  # in a sequence: its final character,
        bge   a0, t0, key_seq          # @ to ~, says the key
        li    t0, SH_SEQ               # and before it a number, as in
        sw    t0, sh_state             # ESC [ 3 ~; of several, separated
        li    t0, '0'                  # by ;, the last counts
        blt   a0, t0, 7f
        li    t0, '9'
        bgt   a0, t0, 7f
        lw    t0, sh_param
        li    t1, 10
        mul   t0, t0, t1
        add   t0, t0, a0
        li    t1, '0'
        sub   t0, t0, t1
        sw    t0, sh_param
        j     read
7:      sw    zero, sh_param
        j     read
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
        beq   a0, t0, k_bs
        li    t0, DEL
        beq   a0, t0, k_bs
        li    t0, '\t'
        beq   a0, t0, k_tab
        li    t0, CTRL_A
        beq   a0, t0, k_home
        li    t0, CTRL_E
        beq   a0, t0, k_end
        li    t0, CTRL_B
        beq   a0, t0, k_left
        li    t0, CTRL_F
        beq   a0, t0, k_right
        li    t0, CTRL_U
        beq   a0, t0, k_kill
        li    t0, CTRL_K
        beq   a0, t0, k_killend
        li    t0, CTRL_W
        beq   a0, t0, k_word
        li    t0, CTRL_L
        beq   a0, t0, k_clear
        li    t0, CTRL_P
        beq   a0, t0, k_up
        li    t0, CTRL_N
        beq   a0, t0, k_down
        li    t0, ' '                  # other control characters are
        blt   a0, t0, read             # dropped
        addi  t0, s0, LINE_MAX
        bge   s1, t0, read             # the line is full: drop it
        call  ins_ch
        j     read

# key_seq: the escape sequence ending in a0, with the number sh_param.
key_seq:
        li    t0, 'A'
        beq   a0, t0, k_up
        li    t0, 'B'
        beq   a0, t0, k_down
        li    t0, 'C'
        beq   a0, t0, k_right
        li    t0, 'D'
        beq   a0, t0, k_left
        li    t0, 'H'
        beq   a0, t0, k_home
        li    t0, 'F'
        beq   a0, t0, k_end
        li    t0, '~'                  # ESC [ N ~: Home is 1 or 7, End
        bne   a0, t0, read             # 4 or 8, Delete 3; the rest, and
        lw    t0, sh_param             # every other sequence, do nothing
        li    t1, 1
        beq   t0, t1, k_home
        li    t1, 7
        beq   t0, t1, k_home
        li    t1, 4
        beq   t0, t1, k_end
        li    t1, 8
        beq   t0, t1, k_end
        li    t1, 3
        beq   t0, t1, k_del
        j     read

k_bs:   beq   s2, s0, read             # nothing before the cursor
        li    a0, 1
        call  del_back
        j     read
k_del:  beq   s2, s1, read             # nothing after it
        li    a0, 1
        call  del_fwd
        j     read
k_kill: sub   a0, s2, s0
        beqz  a0, read
        call  del_back
        j     read
k_killend:
        sub   a0, s1, s2
        beqz  a0, read
        call  del_fwd
        j     read
k_word: mv    t0, s2                   # the spaces before the cursor,
        li    t1, ' '                  # then the word before them
1:      beq   t0, s0, 2f
        lt    t2, -1(t0)
        bne   t2, t1, 2f
        addi  t0, t0, -1
        j     1b
2:      beq   t0, s0, 3f
        lt    t2, -1(t0)
        beq   t2, t1, 3f
        addi  t0, t0, -1
        j     2b
3:      sub   a0, s2, t0
        beqz  a0, read
        call  del_back
        j     read
k_left: beq   s2, s0, read
        addi  s2, s2, -1
        li    a1, BS
        call  putc
        j     read
k_right:
        beq   s2, s1, read
        lt    a1, 0(s2)                # printing it moves past it
        addi  s2, s2, 1
        call  putc
        j     read
k_home: sub   a0, s2, s0
        mv    s2, s0
        li    a1, BS
        call  rep
        j     read
k_end:  mv    a0, s2
        mv    s2, s1
        call  show
        j     read
k_clear:
        la    a1, sh_clear
        call  puts
        call  redraw
        j     read

# History: up and down go through the last HIST_N lines typed, oldest
# first in sh_hist; sh_hpos is the one shown, sh_nhist past the newest,
# where the line being typed waits in sh_draft.
k_up:   lw    t0, sh_hpos
        beqz  t0, read                 # nothing older
        lw    t1, sh_nhist
        bne   t0, t1, 1f
        la    t2, sh_draft             # leaving the line being typed
        mv    t1, s0
2:      beq   t1, s1, 3f
        lt    a0, 0(t1)
        st    a0, 0(t2)
        addi  t1, t1, 1
        addi  t2, t2, 1
        j     2b
3:      st    zero, 0(t2)
1:      addi  t0, t0, -1
        sw    t0, sh_hpos
        mv    a0, t0
        call  slot
        call  set_line
        j     read
k_down: lw    t0, sh_hpos
        lw    t1, sh_nhist
        bge   t0, t1, read             # nothing newer
        addi  t0, t0, 1
        sw    t0, sh_hpos
        la    a0, sh_draft
        beq   t0, t1, 1f
        mv    a0, t0
        call  slot
1:      call  set_line
        j     read

# Tab completes the word before the cursor. The first word of a command
# (at the start or after |) names a built-in or a program in the image
# or in /bin; any other word, or one with a slash, names a path, whose
# directory is read for the names that start with what follows its last
# slash. One name: the rest of it is typed, then a space, or a slash for
# a directory. Several: as much as they share; when that adds nothing, a
# bell, and a second Tab lists them in columns and prints the line again.
# Names starting with a dot are left out unless the word starts so too.
k_tab:  mv    s8, t3                   # s8: 1 if a Tab just rang the bell
        mv    s3, s2                   # s3: where the word starts
1:      beq   s3, s0, 2f
        lt    t0, -1(s3)
        li    t1, ' '
        beq   t0, t1, 2f
        li    t1, '|'
        beq   t0, t1, 2f
        li    t1, '<'
        beq   t0, t1, 2f
        li    t1, '>'
        beq   t0, t1, 2f
        addi  s3, s3, -1
        j     1b
2:      li    s7, 0                    # s7: 1 if it names a command
        mv    t0, s3
3:      beq   t0, s0, 4f
        lt    t1, -1(t0)
        li    t2, ' '
        bne   t1, t2, 5f
        addi  t0, t0, -1
        j     3b
5:      li    t2, '|'
        bne   t1, t2, 6f
4:      li    s7, 1
6:      mv    s4, s3                   # s4: past the word's last slash
        mv    t0, s3
        li    t2, '/'
7:      beq   t0, s2, 8f
        lt    t1, 0(t0)
        addi  t0, t0, 1
        bne   t1, t2, 7b
        mv    s4, t0
        li    s7, 0                    # a path, even first
        j     7b
8:      sub   s5, s2, s4               # s5: how much of the name is typed
        la    t0, sh_cdir              # the directory, as typed, slash and
        mv    t1, s3                   # all, or nothing for the current one
1:      beq   t1, s4, 2f
        lt    t2, 0(t1)
        st    t2, 0(t0)
        addi  t0, t0, 1
        addi  t1, t1, 1
        j     1b
2:      st    zero, 0(t0)
        sw    zero, sh_nmatch
        sw    zero, sh_mlen
        sw    zero, sh_mwide
        sw    zero, sh_tmode
        call  cands
        lw    t0, sh_nmatch
        beqz  t0, t_bell
        mv    s6, s5                   # what the names share, past what is
t_ins:  lw    t0, sh_mlen              # typed, is typed
        bge   s6, t0, t_after
        addi  t0, s0, LINE_MAX
        bge   s1, t0, read             # the line is full
        la    t0, sh_match
        add   t0, t0, s6
        lt    a0, 0(t0)
        call  ins_ch
        addi  s6, s6, 1
        j     t_ins
t_after:
        lw    t0, sh_nmatch
        li    t1, 1
        bne   t0, t1, t_many
        li    s6, ' '                  # one name: a space after it, or a
        bnez  s7, 1f                   # slash after a directory's
        la    a0, sh_match
        call  isdir
        beqz  a0, 1f
        li    s6, '/'
1:      addi  t0, s0, LINE_MAX
        bge   s1, t0, read
        mv    a0, s6
        call  ins_ch
        j     read
t_many: lw    t0, sh_mlen
        bgt   t0, s5, read             # it went further: that will do
        li    t0, 1                    # else a Tab after this one lists them
        sw    t0, sh_tabbed
        bnez  s8, t_list
t_bell: li    a1, BEL
        call  putc
        j     read
t_list: li    a1, '\n'
        call  putc
        li    t0, 1
        sw    t0, sh_tmode
        sw    zero, sh_col
        sw    zero, sh_pad
        lw    t0, sh_mwide             # a column: the longest name, a
        addi  t0, t0, 2                # slash after a directory's, and
        bnez  s7, 1f                   # two spaces
        addi  t0, t0, 1
1:      sw    t0, sh_width
        li    t1, SH_COLS
        div   t1, t1, t0
        bgtz  t1, 2f
        li    t1, 1
2:      sw    t1, sh_cols
        call  cands
        lw    t0, sh_col
        beqz  t0, 3f
        li    a1, '\n'
        call  putc
3:      call  redraw
        j     read

# cands: call cand with each name Tab may complete to: the built-ins,
# the image's programs and /bin's files for a command (s7), else the
# names in directory sh_cdir. Clobbers s6, and what cand does.
cands:  addi  sp, sp, -3
        sw    ra, 0(sp)
        beqz  s7, 3f
        la    s6, sh_builtins
1:      lw    a0, 0(s6)
        beqz  a0, 2f
        call  cand
        addi  s6, s6, 6
        j     1b
2:      la    s6, sh_programs
5:      lw    a0, 0(s6)
        beqz  a0, 6f
        call  cand
        addi  s6, s6, 6
        j     5b
6:      la    a0, sh_bindir
        j     4f
3:      la    t0, sh_path              # the directory to open: as typed,
        la    t1, sh_cdir              # but for its last slash, or . if
        call  strcpy                   # nothing was
        la    a0, sh_dot
        la    t1, sh_path
        beq   t0, t1, 4f
        la    a0, sh_path
        addi  t1, t1, 1
        beq   t0, t1, 4f               # /, which stays
        st    zero, -1(t0)
4:      mv    a3, a0
        li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_OPEN
        li    a4, O_RDONLY
        sys
        bltz  a0, 9f                   # nothing there: no names
        mv    s6, a0                   # s6: its descriptor
7:      li    a0, SYS_IOCALL
        mv    a1, s6
        li    a2, IO_READDIR
        la    a3, sh_name
        li    a4, 0
        sys
        blez  a0, 8f                   # the end, or it failed
        lt    t1, sh_name
        li    t2, '.'
        bne   t1, t2, 1f
        lt    t1, sh_name + 1          # . and .. never: they add nothing
        beqz  t1, 7b
        bne   t1, t2, 2f
        lt    t1, sh_name + 2
        beqz  t1, 7b
2:      beqz  s5, 7b                   # the rest hidden, unless asked for
        lt    t1, 0(s4)
        bne   t1, t2, 7b
1:      la    a0, sh_name
        call  cand
        j     7b
8:      li    a0, SYS_CLOSE
        mv    a1, s6
        sys
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# cand: if the name at a0 starts with the s5 trytes at s4, count it in
# sh_nmatch, keep in sh_match what all such share (sh_mlen long) and the
# longest one's length in sh_mwide; or with sh_tmode, print it in its
# column. Clobbers a0..a5, t0..t3.
cand:   mv    t0, s4
        mv    t1, a0
        mv    t2, s5
1:      beqz  t2, 2f
        lt    a1, 0(t0)
        lt    a2, 0(t1)
        bne   a1, a2, 9f               # not one
        addi  t0, t0, 1
        addi  t1, t1, 1
        addi  t2, t2, -1
        j     1b
2:      mv    t1, a0                   # t1: its length
3:      lt    t2, 0(t1)
        beqz  t2, 4f
        addi  t1, t1, 1
        j     3b
4:      sub   t1, t1, a0
        lw    t0, sh_tmode
        bnez  t0, c_print
        lw    t0, sh_mwide
        bge   t0, t1, 5f
        sw    t1, sh_mwide
5:      lw    t0, sh_nmatch
        addi  t0, t0, 1
        sw    t0, sh_nmatch
        li    t2, 1
        bne   t0, t2, 6f
        sw    t1, sh_mlen              # the first: all of it
        la    t0, sh_match
        mv    t1, a0
        j     strcpy
6:      la    t0, sh_match             # another: as much as it shares
        mv    t1, a0
        li    t2, 0
        lw    a3, sh_mlen
7:      beq   t2, a3, 8f
        lt    a1, 0(t0)
        lt    a2, 0(t1)
        bne   a1, a2, 8f
        addi  t0, t0, 1
        addi  t1, t1, 1
        addi  t2, t2, 1
        j     7b
8:      sw    t2, sh_mlen
9:      ret
c_print:
        addi  sp, sp, -9
        sw    ra, 0(sp)
        sw    a0, 3(sp)                # the name
        sw    t1, 6(sp)                # and its length
        lw    a0, sh_pad               # the spaces after the last one in
        li    a1, ' '                  # its row
        call  rep
        lw    a1, 3(sp)
        call  puts
        bnez  s7, 1f
        lw    a0, 3(sp)
        call  isdir
        beqz  a0, 1f
        li    a1, '/'
        call  putc
        lw    t1, 6(sp)
        addi  t1, t1, 1
        sw    t1, 6(sp)
1:      lw    t0, sh_width
        lw    t1, 6(sp)
        sub   t0, t0, t1
        sw    t0, sh_pad
        lw    t0, sh_col
        addi  t0, t0, 1
        lw    t1, sh_cols
        blt   t0, t1, 2f
        li    a1, '\n'                 # the row is full
        call  putc
        li    t0, 0
        sw    zero, sh_pad
2:      sw    t0, sh_col
        lw    ra, 0(sp)
        addi  sp, sp, 9
        ret

# isdir: a0 = 1 if the name at a0, in directory sh_cdir, is a directory,
# else 0. Clobbers a0..a5, t0..t2, sh_path.
isdir:  mv    a5, ra
        mv    t1, a0
        la    t0, sh_path
        mv    a4, t1
        la    t1, sh_cdir
        call  strcpy
        mv    t1, a4
        call  strcpy
        mv    ra, a5
        li    a0, SYS_CALL
        lw    a1, sh_fs
        li    a2, FS_STAT
        la    a3, sh_path
        la    a4, sh_stat
        sys
        bltz  a0, 1f
        lw    t1, sh_stat + ST_TYPE
        li    t2, T_DIR
        bne   t1, t2, 1f
        li    a0, 1
        ret
1:      li    a0, 0
        ret

# --- line editing helpers -------------------------------------------------------

# ins_ch: put a0 in the line at the cursor, which moves past it. The
# caller sees that there is room. Clobbers a0..a5, t0..t3.
ins_ch: addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    t1, s1                   # what follows moves up one
1:      beq   t1, s2, 2f
        lt    t0, -1(t1)
        st    t0, 0(t1)
        addi  t1, t1, -1
        j     1b
2:      st    a0, 0(s2)
        addi  s1, s1, 1
        mv    a0, s2                   # print it and what follows, and
        call  show                     # come back to just past it
        addi  s2, s2, 1
        sub   a0, s1, s2
        li    a1, BS
        call  rep
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# del_back: erase the a0 trytes before the cursor. del_fwd: the a0 after
# it. tail: print from the cursor to the end, then a0 spaces over what
# was there, and come back. All clobber a0..a5, t0..t3.
del_back:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        li    a1, BS
        call  rep
        lw    a0, 3(sp)
        sub   s2, s2, a0
        lw    ra, 0(sp)
        addi  sp, sp, 6
del_fwd:
        add   t0, s2, a0               # what follows closes up
        mv    t1, s2
1:      beq   t0, s1, 2f
        lt    t2, 0(t0)
        st    t2, 0(t1)
        addi  t0, t0, 1
        addi  t1, t1, 1
        j     1b
2:      sub   s1, s1, a0
tail:   addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        mv    a0, s2
        call  show
        lw    a0, 3(sp)
        li    a1, ' '
        call  rep
        lw    a0, 3(sp)
        add   a0, a0, s1
        sub   a0, a0, s2
        li    a1, BS
        call  rep
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# set_line: make the line the string at a0, shown in place of the old
# one, with the cursor at its end. Clobbers a0..a5, t0..t3.
set_line:
        addi  sp, sp, -9
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        sub   t0, s1, s0               # the old length
        sw    t0, 6(sp)
        sub   a0, s2, s0               # back to the start
        li    a1, BS
        call  rep
        lw    t1, 3(sp)
        mv    s1, s0
1:      lt    t0, 0(t1)
        beqz  t0, 2f
        st    t0, 0(s1)
        addi  s1, s1, 1
        addi  t1, t1, 1
        j     1b
2:      mv    a0, s0
        call  show
        mv    s2, s1
        lw    a0, 6(sp)                # blank what is left of the old one
        sub   t0, s1, s0
        sub   a0, a0, t0
        sw    a0, 6(sp)
        li    a1, ' '
        call  rep
        lw    a0, 6(sp)
        li    a1, BS
        call  rep
        lw    ra, 0(sp)
        addi  sp, sp, 9
        ret

# redraw: print the prompt and the line, and put the cursor back.
# Clobbers a0..a5, t0..t3.
redraw: addi  sp, sp, -3
        sw    ra, 0(sp)
        la    a1, sh_prompt
        call  puts
        mv    a0, s0
        call  show
        sub   a0, s1, s2
        li    a1, BS
        call  rep
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# show: print the line from a0 to its end, s1. Clobbers a0..a3.
show:   sub   a3, s1, a0
        blez  a3, 1f
        mv    a2, a0
        li    a0, SYS_WRITE
        lw    a1, sh_outfd
        sys
1:      ret

# rep: print a0 copies of a1, none if a0 is not positive. Clobbers
# a0..a5, t0, t2, t3.
rep:    addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    t3, a0
        mv    t2, a1
1:      blez  t3, 2f
        mv    a1, t2
        call  putc
        addi  t3, t3, -1
        j     1b
2:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# slot: a0 = the address of history line a0. Clobbers t0.
slot:   li    t0, LINE_MAX + 1
        mul   a0, a0, t0
        la    t0, sh_hist
        add   a0, a0, t0
        ret

# hist_add: keep the line, now ended, as the newest in the history,
# unless it is empty or the same as the newest; the oldest goes when
# HIST_N are kept. Clobbers a0..a2, t0..t3.
hist_add:
        mv    a2, ra
        beq   s1, s0, 9f
        lw    t3, sh_nhist
        beqz  t3, 2f
        addi  a0, t3, -1
        call  slot
        mv    a1, a0
        mv    a0, s0
        call  streq
        bnez  a0, 9f
2:      li    t0, HIST_N
        blt   t3, t0, 3f
        la    t0, sh_hist              # full: each moves down one
        addi  t1, t0, LINE_MAX + 1
        li    t2, (HIST_N - 1) * (LINE_MAX + 1)
4:      lt    a0, 0(t1)
        st    a0, 0(t0)
        addi  t0, t0, 1
        addi  t1, t1, 1
        addi  t2, t2, -1
        bnez  t2, 4b
        addi  t3, t3, -1
3:      mv    a0, t3
        call  slot
        mv    t0, a0
        mv    t1, s0
        call  strcpy
        addi  t3, t3, 1
        sw    t3, sh_nhist
9:      mv    ra, a2
        ret

cancel: la    a1, sh_cancel
        call  puts
        j     prompt

eof:    li    a1, '\n'                # end the last prompt's line
        call  putc
        li    a0, SYS_EXIT
        li    a1, 0
        sys

enter:  mv    a0, s2                   # the cursor to the end first
        call  show
        li    a1, '\n'
        call  putc
        st    zero, 0(s1)
        call  hist_add

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
1:      li    t0, SIGPIPE              # a writer whose reader left: as
        beq   s3, t0, 9f               # Unix shells, nothing to say
        la    a1, sh_killed
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

# sh_sigpipe: the shell's signal entry, for SIGPIPE: nothing to do but go
# back (a1 is the frame). It only comes while the shell waits in a write
# the pipe server holds, which a signal never cuts short, so no call of
# the shell's gets E_INTR.
sh_sigpipe:
        li    a0, SYS_SIGRETURN
        sys

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
sh_param:    .word 0                   # an escape sequence's number
sh_tabbed:   .word 0                   # 1 if the last key was Tab, with several names
sh_nhist:    .word 0                   # history lines kept,
sh_hpos:     .word 0                   # and the one up and down are at
sh_nmatch:   .word 0                   # names Tab found,
sh_mlen:     .word 0                   # how much they share,
sh_mwide:    .word 0                   # the longest one's length,
sh_tmode:    .word 0                   # 1 while it lists them,
sh_width:    .word 0                   # in columns this wide,
sh_cols:     .word 0                   # this many to a row,
sh_col:      .word 0                   # the one it is at,
sh_pad:      .word 0                   # and the spaces before it
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
sh_clear:    .tryte ESC, '[', 'H', ESC, '[', '2', 'J', 0   # home, clear the screen
sh_bindir:   .string "/bin"
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
sh_hist:     .zero HIST_N * (LINE_MAX + 1)   # the lines typed, oldest first
sh_draft:    .zero LINE_MAX + 1        # the line being typed, while up shows others
sh_match:    .zero NAME_MAX + 1        # what Tab's names share
sh_cdir:     .zero LINE_MAX + 1        # the directory Tab looks in, as typed
sh_buf:      .zero BUF_MAX + 1         # what cat reads, and a 0 to end it
sh_myname: .string "sh"
        .nocompress
