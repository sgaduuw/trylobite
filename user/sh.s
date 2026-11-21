# Program 0 of shell.s: a shell. It reads a line, runs the program its
# first word names, waits for it, and says how it ended if not with code
# 0. Some words are built in: exit, and ls, cat, write and rm, which use
# the filesystem on the disk (docs/filesystem.md) through the block
# window. A word that is neither built in nor a program in the kernel
# image is looked up on the disk, and a program file of that name is
# run. It stops at the end of input. Programs take no arguments yet.

        .compress
        .section prog0, P_PROG0 * PAGE, V_USER
        .gp   USER_GP                  # set by spawn

        .equ  LINE_MAX, 60             # characters kept from a line
        .equ  BS, 8                    # backspace, and delete, both erase
        .equ  DEL, 127
        .equ  NOT_FS, -4               # fs_load: block 0 holds no filesystem
                                       # (bread's own failures are -1 to -3)
        .equ  NO_ENTRY, -1             # find: no such file; entries are at
                                       # positive addresses
        .equ  W_DIR, V_BLOCK + FS_DIR  # block 0's directory, in the window
        .equ  W_DIR_END, W_DIR + FS_FILES * FS_DIRENT
        .equ  W_FAT, V_BLOCK + FS_FAT  # ... and its FAT
        .equ  W_TEXT, V_BLOCK + BLOCK_T0   # a data block's text

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
        li    a0, SYS_PUTC
        sys
        j     read
erase:  beq   s1, s0, read             # nothing to erase
        addi  s1, s1, -1
        la    a1, sh_rubout
        li    a0, SYS_PUTS
        sys
        j     read

cancel: la    a1, sh_cancel
        li    a0, SYS_PUTS
        sys
        j     prompt

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

# from_disk: run the program file named s0, if the disk has one. Its
# first block holds the whole program; spawnw starts it from the window.
from_disk:
        call  fs_load
        bnez  a0, unknown              # no filesystem, so no programs on it
        mv    a0, s0
        call  find
        bltz  a0, unknown
        lw    a1, DE_FIRST(a0)
        bltz  a1, not_prog             # FAT_END: an empty file
        li    a0, SYS_BREAD
        sys
        bnez  a0, cant_read
        li    a0, SYS_SPAWNW
        sys
        li    t0, E_NOPROG
        bne   a0, t0, started
not_prog:
        la    a1, sh_notprog
        li    a0, SYS_PUTS
        sys
        mv    a1, s0
        j     say

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
started:                               # a0: the child, or why it did not start
        bgez  a0, 1f
        mv    s3, a0                   # it could not start: say why
        la    a1, sh_nostart
        li    a0, SYS_PUTS
        sys
        mv    a0, s3
        call  putn
        j     newline
1:      mv    s3, a0                   # s3: the child
        mv    a1, a0                   # Ctrl-C kills it while it runs; the
        li    a0, SYS_FOREGROUND       # kernel takes the console back after
        sys
        mv    a1, s3
        li    a0, SYS_WAIT
        sys
        mv    s3, a1                   # s3: its exit code or trap cause
        li    t0, WAIT_KILLED
        beq   a0, t0, killed
        br3   a0, prompt, faulted      # negative cannot happen: it is ours
        beqz  s3, prompt               # exited with 0: nothing to say
        la    a1, sh_exited
        j     2f
killed: la    a1, sh_killed
        li    a0, SYS_PUTS
        sys
        j     newline
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

# --- built-ins ----------------------------------------------------------------
# Each is jumped to with s4 at the rest of its line, and ends at prompt.

do_exit:
        li    a0, SYS_EXIT
        li    a1, 0
        sys

# ls: each file's size and name.
do_ls:  call  fs_load
        bnez  a0, cant_read
        li    s5, W_DIR                # s5: the entry
1:      li    t0, W_DIR_END
        bge   s5, t0, prompt
        lt    t0, DE_NAME(s5)
        beqz  t0, 2f                   # unused
        lw    a0, DE_SIZE(s5)
        call  putn
        li    a0, SYS_PUTC
        li    a1, ' '
        sys
        li    a0, SYS_PUTS
        addi  a1, s5, DE_NAME
        sys
        li    a0, SYS_PUTC
        li    a1, '\n'
        sys
2:      addi  s5, s5, FS_DIRENT
        j     1b

# cat NAME: print a file. The window holds one block, so block 0 is read
# again for the FAT before each next block of the file.
do_cat: call  name_arg
        call  fs_load
        bnez  a0, cant_read
        mv    a0, s5
        call  find
        bltz  a0, no_file
        lw    s6, DE_SIZE(a0)          # s6: trytes still to print
        lw    s7, DE_FIRST(a0)         # s7: the block they start in
1:      blez  s6, prompt
        li    a0, SYS_BREAD
        mv    a1, s7
        sys
        bnez  a0, cant_read
        li    t0, PAGE
        bge   s6, t0, 2f               # it fills the block: puts stops at its end
        li    t0, W_TEXT
        add   t0, t0, s6
        st    zero, 0(t0)              # end the text where the file does
2:      li    a0, SYS_PUTS
        li    a1, W_TEXT
        sys
        li    t0, PAGE
        sub   s6, s6, t0
        blez  s6, prompt
        call  fs_load
        bnez  a0, cant_read
        shi   t0, s7, 1                # x3: one word per block
        li    t1, W_FAT
        add   t0, t0, t1
        lw    s7, 0(t0)
        j     1b

# write NAME TEXT: make file NAME hold TEXT and a newline, replacing it if
# it is there. The text goes to a free block first and block 0 last, so a
# write cut short leaves the old file whole (docs/filesystem.md); that
# means it needs a free block even to replace a file.
do_write:
        call  name_arg
        mv    s6, a1                   # s6: the text
        mv    t0, s5                   # a name fits in an entry
1:      lt    t1, 0(t0)
        beqz  t1, 2f
        addi  t0, t0, 1
        j     1b
2:      sub   t0, t0, s5
        li    t1, FS_NAME_MAX
        bgt   t0, t1, bad_name
        call  fs_load
        bnez  a0, cant_read
        mv    a0, s5
        call  find
        mv    s7, a0                   # s7: its entry: the old one, or
        bgez  s7, 4f
        li    s7, W_DIR                # the first unused one
3:      li    t0, W_DIR_END
        bge   s7, t0, dir_full
        lt    t0, DE_NAME(s7)
        beqz  t0, 4f
        addi  s7, s7, FS_DIRENT
        j     3b
4:      li    s8, 1                    # s8: the first free block
        li    t0, V_BLOCK
        lw    t2, FS_HEAD_BLOCKS(t0)
5:      bge   s8, t2, disk_full
        shi   t0, s8, 1
        li    t1, W_FAT
        add   t0, t0, t1
        lw    t0, 0(t0)
        li    t1, FAT_FREE
        beq   t0, t1, 6f
        addi  s8, s8, 1
        j     5b
6:      li    t0, V_BLOCK + BLOCK_W0   # clear the window: the rest of the
        li    t1, V_BLOCK - BLOCK_W0   # block stays zero
7:      sw    zero, 0(t0)
        addi  t0, t0, 3
        ble   t0, t1, 7b
        li    t0, W_TEXT
        mv    t1, s6
8:      lt    t2, 0(t1)
        beqz  t2, 9f
        st    t2, 0(t0)
        addi  t0, t0, 1
        addi  t1, t1, 1
        j     8b
9:      li    t2, '\n'
        st    t2, 0(t0)
        li    t1, W_TEXT - 1
        sub   s6, t0, t1               # s6: the size, newline and all
        li    a0, SYS_BWRITE
        mv    a1, s8
        sys
        bnez  a0, cant_write
        call  fs_load                  # now block 0
        bnez  a0, cant_read
        lt    t0, DE_NAME(s7)
        beqz  t0, 1f                   # a new file
        mv    a0, s7
        call  unchain                  # the old text's blocks
1:      mv    t0, s5
        addi  t1, s7, DE_NAME
2:      lt    t2, 0(t0)
        st    t2, 0(t1)
        addi  t0, t0, 1
        addi  t1, t1, 1
        bnez  t2, 2b
        sw    s6, DE_SIZE(s7)
        sw    s8, DE_FIRST(s7)
        shi   t0, s8, 1
        li    t1, W_FAT
        add   t0, t0, t1
        li    t1, FAT_END
        sw    t1, 0(t0)
        j     save

# rm NAME: remove a file.
do_rm:  call  name_arg
        call  fs_load
        bnez  a0, cant_read
        mv    a0, s5
        call  find
        bltz  a0, no_file
        mv    s7, a0
        call  unchain
        addi  t0, s7, -3 + FS_DIRENT   # the entry's last word
1:      sw    zero, 0(t0)
        addi  t0, t0, -3
        bge   t0, s7, 1b
save:   li    a0, SYS_BWRITE           # block 0 back to the disk
        li    a1, 0
        sys
        bnez  a0, cant_write
        j     prompt

# What the built-ins say when they cannot go on.
cant_read:
        la    a1, sh_cantread
        j     1f
cant_write:
        la    a1, sh_cantwrite
1:      mv    s3, a0
        li    a0, SYS_PUTS
        sys
        mv    a0, s3
        call  putn
        j     newline
no_file:
        la    a1, sh_nofile
        li    a0, SYS_PUTS
        sys
        mv    a1, s5
        j     say
no_name:
        la    a1, sh_noname
        j     say
bad_name:
        la    a1, sh_badname
        j     say
dir_full:
        la    a1, sh_dirfull
        j     say
disk_full:
        la    a1, sh_diskfull
say:    li    a0, SYS_PUTS
        sys
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

# fs_load: read block 0 into the window and check it holds a filesystem.
# a0 = 0, bread's failure, or NOT_FS. Clobbers a1, t0..t2.
fs_load:
        li    a0, SYS_BREAD
        li    a1, 0
        sys
        bnez  a0, 9f
        li    t1, V_BLOCK
        li    a0, NOT_FS
        lw    t0, FS_HEAD_MAGIC(t1)
        li    t2, FS_MAGIC
        bne   t0, t2, 9f
        lw    t0, FS_HEAD_VERSION(t1)
        li    t2, FS_VERSION
        bne   t0, t2, 9f
        li    a0, 0
9:      ret

# find: the entry, in the window's block 0, of the file named at a0, or
# NO_ENTRY. Clobbers a1, t0..t4.
find:   mv    t2, a0                   # t2: the name
        li    t3, W_DIR                # t3: the entry tried
        mv    t4, ra                   # streq is a leaf: ra lasts in t4
1:      li    t0, W_DIR_END
        bge   t3, t0, 8f
        addi  a0, t3, DE_NAME
        mv    a1, t2
        call  streq                    # an unused entry's name is empty
        bnez  a0, 9f
        addi  t3, t3, FS_DIRENT
        j     1b
8:      li    t3, NO_ENTRY
9:      mv    a0, t3
        jalr  zero, 0(t4)

# unchain: mark the blocks of the file whose entry is at a0 free, in the
# window's FAT. Clobbers t0..t2.
unchain:
        lw    t0, DE_FIRST(a0)
1:      bltz  t0, 9f                   # FAT_END: no more
        shi   t1, t0, 1
        li    t2, W_FAT
        add   t1, t1, t2
        lw    t0, 0(t1)
        li    t2, FAT_FREE
        sw    t2, 0(t1)
        j     1b
9:      ret

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

# Each entry: the name, and where the built-in starts; 0 ends it.
sh_builtins:
        .word sh_exit, do_exit
        .word sh_ls, do_ls
        .word sh_cat, do_cat
        .word sh_write, do_write
        .word sh_rm, do_rm
        .word 0

# Each entry: the name, and the program number to spawn; 0 ends it.
# Everything else is on the disk.
sh_programs:
        .word sh_pingpong, 3
        .word 0

sh_pingpong: .string "pingpong"
sh_exit:     .string "exit"
sh_ls:       .string "ls"
sh_cat:      .string "cat"
sh_write:    .string "write"
sh_rm:       .string "rm"
sh_prompt:   .string "$ "
sh_rubout:   .tryte BS, ' ', BS, 0     # back, blank, back: the assembler has no \b
sh_unknown:  .string "sh: no such program: "
sh_notprog:  .string "sh: not a program: "
sh_nostart:  .string "sh: cannot start it: "
sh_exited:   .string "sh: exit "
sh_faulted:  .string "sh: fault "
sh_killed:   .string "sh: killed"
sh_cancel:   .string "^C\n"
sh_cantread: .string "sh: cannot read the filesystem: "
sh_cantwrite: .string "sh: cannot write the disk: "
sh_nofile:   .string "sh: no such file: "
sh_noname:   .string "sh: which file?"
sh_badname:  .string "sh: a name has at most 17 characters"
sh_dirfull:  .string "sh: the directory is full"
sh_diskfull: .string "sh: the disk is full"
sh_digits:   .zero 12
sh_digits_end: .zero 1
sh_line:     .zero LINE_MAX + 1
        .nocompress
