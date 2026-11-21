# Program 0 of shell.s: a shell. It reads a line, runs the program it
# names, waits for it, and says how it ended if not with code 0. It stops
# at the end of input. Only the first word of a line counts: programs
# take no arguments yet.

        .compress
        .section prog0, P_PROG0 * PAGE, V_USER
        .gp   USER_GP                  # set by spawn

        .equ  LINE_MAX, 60             # characters kept from a line
        .equ  BS, 8                    # backspace, and delete, both erase
        .equ  DEL, 127

sh:
prompt: la    a1, sh_prompt
        li    a0, SYS_PUTS
        sys
        la    s0, sh_line              # s0: the line
        mv    s1, s0                   # s1: just past what was typed

read:   li    a0, SYS_GETC
        sys
        br3   a0, eof, got             # zero, NUL, is ignored
        j     read
got:    li    t0, '\n'
        beq   a0, t0, enter
        li    t0, BS
        beq   a0, t0, erase
        li    t0, DEL
        beq   a0, t0, erase
        addi  t0, s0, LINE_MAX
        bge   s1, t0, read             # the line is full: drop it
        st    a0, 0(s1)
        addi  s1, s1, 1
        mv    a1, a0                   # echo it, as a terminal would
        li    a0, SYS_PUTC
        sys
        j     read
erase:  beq   s1, s0, read             # nothing to erase
        addi  s1, s1, -1
        la    a1, sh_rubout
        li    a0, SYS_PUTS
        sys
        j     read

eof:    li    a0, SYS_PUTC             # end the last prompt's line
        li    a1, '\n'
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys

enter:  li    a0, SYS_PUTC
        li    a1, '\n'
        sys
        st    zero, 0(s1)
        li    t1, ' '
1:      lt    t0, 0(s0)                # skip leading spaces
        bne   t0, t1, 2f
        addi  s0, s0, 1
        j     1b
2:      beqz  t0, prompt               # an empty line
        mv    t2, s0                   # end the word at the first space
3:      lt    t0, 0(t2)
        beqz  t0, 4f
        beq   t0, t1, 5f
        addi  t2, t2, 1
        j     3b
5:      st    zero, 0(t2)

4:      la    a0, sh_exit              # the one built-in
        mv    a1, s0
        call  streq
        beqz  a0, 6f
        li    a0, SYS_EXIT
        li    a1, 0
        sys

6:      la    s2, sh_programs          # s2: the table entry tried
7:      lw    a0, 0(s2)
        beqz  a0, unknown              # the end of the table
        mv    a1, s0
        call  streq
        bnez  a0, found
        addi  s2, s2, 6
        j     7b

unknown:
        la    a1, sh_unknown
        li    a0, SYS_PUTS
        sys
        mv    a1, s0
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_PUTC
        li    a1, '\n'
        sys
        j     prompt

found:  li    a0, SYS_SPAWN
        lw    a1, 3(s2)
        sys
        bgez  a0, 1f
        mv    s3, a0                   # it could not start: say why
        la    a1, sh_nostart
        li    a0, SYS_PUTS
        sys
        mv    a0, s3
        call  putn
        j     newline
1:      mv    a1, a0
        li    a0, SYS_WAIT
        sys
        mv    s3, a1                   # s3: its exit code or trap cause
        br3   a0, prompt, faulted      # negative cannot happen: it is ours
        beqz  s3, prompt               # exited with 0: nothing to say
        la    a1, sh_exited
        j     2f
faulted:
        la    a1, sh_faulted
2:      li    a0, SYS_PUTS
        sys
        mv    a0, s3
        call  putn
newline:
        li    a0, SYS_PUTC
        li    a1, '\n'
        sys
        j     prompt

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

# putn: print a0 in decimal. Clobbers a0, a1, t0..t3.
putn:   mv    t3, a0
        bgez  t3, 1f
        li    a0, SYS_PUTC
        li    a1, '-'
        sys
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
        li    a0, SYS_PUTS
        sys
        ret

# Each entry: the name, and the program number to spawn; 0 ends it.
sh_programs:
        .word sh_hello, 3
        .word sh_fail, 4
        .word sh_pingpong, 5
        .word 0

sh_hello:    .string "hello"
sh_fail:     .string "fail"
sh_pingpong: .string "pingpong"
sh_exit:     .string "exit"
sh_prompt:   .string "$ "
sh_rubout:   .tryte BS, ' ', BS, 0     # back, blank, back: the assembler has no \b
sh_unknown:  .string "sh: no such program: "
sh_nostart:  .string "sh: cannot start it: "
sh_exited:   .string "sh: exit "
sh_faulted:  .string "sh: fault "
sh_digits:   .zero 12
sh_digits_end: .zero 1
sh_line:     .zero LINE_MAX + 1
        .nocompress
