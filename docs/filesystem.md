# The filesystem

A filesystem on detrytus' block device, shaped like a Unix one: files
and directories are inodes, directories are files of names and inode
numbers with `.` and `..`, and programs reach files by path through
descriptors, with `open`, `read`, `write`, `lseek`, `readdir`, `stat`
and `close`, and `unlink`, `rename`, `mkdir` and `rmdir`. A process, the file
server (`user/fsd.s`), reads and changes it, answering other processes'
calls; `tools/fs.py` builds and changes images
on the host. Every number below is named in `include/layout.s`, which the
tool reads too.

## Blocks

A block is one page, 19,683 trytes or 6,561 words. Memory is centred
(detrytus isa.md 5.2), so offsets are given from a block's centre, as
a program's block window sees them: trytes run
from −9,841 to 9,841 and words sit at −9,840, −9,837, ..., 9,840. A
word's low tryte comes first.

| Block | Holds |
|-------|-------|
| 0 | the header and the map of free blocks |
| 1 (`FS_INODE_BLOCK`) | the inode table |
| 2 and on | the data of files and directories, and indirect blocks |

## Block 0

| Offset | Name | Contents |
|--------|------|----------|
| −9,840 (word 0) | `FS_HEAD_MAGIC` | `FS_MAGIC`: a blank disk, all zeros, is not a filesystem |
| −9,837 (word 1) | `FS_HEAD_VERSION` | `FS_VERSION`, 2 (version 1 was a flat directory and a FAT) |
| −9,834 (word 2) | `FS_HEAD_BLOCKS` | how many blocks the filesystem has, 3 to `FS_MAX_BLOCKS` (19,656); the disk may have more |
| −9,814 (`FS_MAP`) | the map | one tryte per block, from block 0: `MAP_USED` (1) or `MAP_FREE` (0) |

The map runs to the block's last tryte. Blocks 0 and 1 are always used,
as is every block an inode holds, and no other.

## Inodes

Block 1 holds `FS_INODES` (729) inodes of `INODE` (27) trytes, inode `i`
from `BLOCK_W0 + 27 × i`. Inode 0 is never used, so `NO_INO` (0) means
none; inode 1 (`ROOT_INO`) is the root directory, `/`. Each is nine
words, at these offsets from its first:

| Offset | Name | Contents |
|--------|------|----------|
| 0 | `I_TYPE` | `T_FREE` (0) unused, `T_FILE` (1) a file, `T_DIR` (2) a directory |
| 3 | `I_LINKS` | how many directory entries name it: a file's names; a directory's own name, its `.`, and each subdirectory's `..` |
| 6 | `I_SIZE` | its size in trytes |
| 9 | `I_DIRECT` | its first `NDIRECT` (5) data blocks, a word each |
| 24 | `I_INDIRECT` | a block holding the numbers of the rest, a word each, or `NO_BLOCK` |

Block `k` of a file, counting from 0, is direct block `k` while `k` is
below 5, and word `k − 5` of the indirect block after that, so a file
holds at most 6,566 blocks. A block number of `NO_BLOCK` (0) is a hole,
which reads as zeros; block 0 is never data. A file of `n` trytes has
`⌈n / 19,683⌉` blocks, and the rest of its last block is zero. Fields
of an unused inode are zero.

## Directories

A directory's data is entries of `DIRENT` (21) trytes, `DIRENTS` (937)
to a block, entry `k` from `BLOCK_W0 + 21 × k` of its block; its size is
21 trytes per entry. For now a directory has one block, so it holds at
most 937 entries. Offsets are from an entry's first word:

| Offset | Name | Contents |
|--------|------|----------|
| −1 | `D_NAME` | the name: 18 trytes, one code point each, ended and padded with 0 |
| 18 | `D_INO` | the inode it names, or `NO_INO` when the entry is unused |

A name has 1 to `NAME_MAX` (17) code points, none of them a space, a
slash or a control character, and is unique in its directory. Every
directory starts with `.`, naming itself, and `..`, naming its parent;
the root's `..` is the root. An unused entry's name is zero too.

## Paths

A path is names separated by slashes. One that starts with a slash
starts at the root; any other starts at the calling process's current
directory (below), and an empty path names nothing (`E_NOENT`). More
slashes between and after names do not count, and `.` and `..` are
ordinary entries, so `/a/./b/../b` is `/a/b`; the root's `..` is the
root. `tools/fs.py` has no current directory: its paths all start at
the root. A path has at most
`PATH_MAX` (243) trytes.

## Files and programs

A file is trytes. Two kinds use this:

- **Text**: one code point per tryte, 1 to 9,841.
- **Programs**: `EXEC_MAGIC` as the first word, the image's size in
  trytes as the second (`EXEC_SIZE`), then the program's image, at most
  `EXEC_MAX` (177,141) trytes: as many blocks as the file server's nine
  windows hold, less the two words. The magic word's first tryte is
  negative, which no text file's is.

## The file server's calls

The file server registers the name `fs` with protocol `FS_PROTOCOL`
(kernel.md, Names) before it takes a call. A client looks it up once,
waiting for it if need be, and treats a missing server or another
version as no filesystem:

```asm
        li    a0, SYS_LOOKUP
        la    a1, fs_name              # fs_name: .string "fs"
        li    a2, LOOKUP_WAIT
        sys                            # a0: the server, a1: its version
        li    t0, FS_PROTOCOL
        bne   a1, t0, no_files
        sw    a0, fs_pid
```

A file call is then a `call` to it (kernel.md, Messages for servers) with the
operation in `a2` and its arguments in `a3`, `a4` and `a5`; the reply's
first word, in `a0`, is the result:

```asm
        li    a0, SYS_CALL
        lw    a1, fs_pid
        li    a2, FS_OPEN
        la    a3, path
        li    a4, O_RDONLY
        sys                            # a0: a descriptor, or why not
```

The descriptor `open` gives is the kernel's (kernel.md, Descriptors): the
caller reads, writes, seeks and lists through it with the descriptor
calls, which reach the server as `IO_` operations with the file's
handle, and closes it with `close`:

```asm
        li    a0, SYS_READ
        mv    a1, s0                   # the descriptor
        la    a2, buffer
        li    a3, 243
        sys                            # a0: how many, 0 at the end, or why not
```

A path is a 0-terminated string in the caller's memory, and a buffer a
range of it: its page, or a block window it has (otherwise `E_FAULT`);
the server copies them with `copyin` and `copyout`. Each call fails
with `E_NOFS` when there is no disk or no filesystem on it (or
`E_NOPROC`, from the kernel, when no file server runs), `E_IO` when the
disk refuses a block or names one past its end, and `E_NOMEM` when the
kernel has no page for one of the server's windows (below). The
others are `E_NOENT` (no such name), `E_NOTDIR` (a name on the way is a
file), `E_NAMETOOLONG`, `E_BADF` (no such open descriptor, or not open
for this), `E_ISDIR`, `E_MFILE`, `E_INVAL`, `E_NOEXEC`, `E_EXIST`,
`E_NOSPC` (no free block or inode), `E_NOTEMPTY`, `E_FBIG` (past a
file's last block) and `E_BUSY`.

| Operation | Call | Does |
|-----------|------|------|
| `FS_OPEN` (0) | `open(path, flags)` | gives the caller's lowest free descriptor (of `NDESC`, 9), at position 0 of the file or directory. `flags` is below. `E_MFILE` when the caller has no descriptor free, or the server has `NFILE` (27) files open; with `O_CREAT` the file may have been made by then |
| `FS_STAT` (5) | `stat(path, buffer)` | four words at the word-aligned buffer: `ST_INO`, `ST_TYPE`, `ST_LINKS` and `ST_SIZE` |
| `FS_SPAWN` (6) | `spawnf(path, args, n)` | starts the program file at the path as the caller's child, with the `n` trytes of arguments at `args` in the caller's memory (Program arguments): the server reads its blocks into consecutive windows (the first stays where its cache read it if the rest fit after it), and gives them to `spawnw` with the caller as the parent. Anything but a program file is `E_NOEXEC` |
| `FS_UNLINK` (8) | `unlink(path)` | removes a file's name from its directory, and frees the file when no name is left. A directory is `E_ISDIR`, a name `.` or `..` `E_INVAL` |
| `FS_MKDIR` (9) | `mkdir(path)` | makes an empty directory, holding `.` and `..`: `E_EXIST` if the name is taken |
| `FS_RMDIR` (10) | `rmdir(path)` | removes an empty directory (`E_NOTEMPTY` otherwise); the root is `E_BUSY`, a name `.` or `..` `E_INVAL` |
| `FS_CHDIR` (11) | `chdir(path)` | makes the directory the caller's current one; a file is `E_NOTDIR` |
| `FS_GETCWD` (12) | `getcwd(buffer, n)` | the current directory's path from the root, ended with 0, to the buffer: its length. `E_NOROOM` (Unix's `ERANGE`) when it and its 0 need more than `n` trytes, `E_NAMETOOLONG` when it is longer than `PATH_MAX` |
| `FS_STATFS` (13) | `statfs(buffer)` | how full the disk is, four words at the word-aligned buffer: `SF_BLOCKS` (in the filesystem) and `SF_BFREE` (free in the map), `SF_INODES` (728, inodes 1 to 728) and `SF_IFREE` (free ones). `bin/df` says them. Adding it did not move `FS_PROTOCOL`: an older client never sends it |
| `FS_RENAME` (14) | `rename(from, to)` | gives what `from` names the name `to`, in the same directory or another; a directory moved to another parent gets that as its `..`. A file already named `to` is replaced, and freed if that was its last name; the same file under both names is left alone. Below, what it refuses |

Numbers 1 to 4 and 7 were `close`, `read`, `lseek`, `readdir` and
`write` before `FS_PROTOCOL` 2; they are descriptor calls on what
`open` gave now:

| Descriptor call | Does |
|-----------------|------|
| `close(fd)` | empties the descriptor; the file closes when no descriptor names it |
| `read(fd, buffer, n)` | copies up to `n` trytes from the position, and moves it past them: how many, never past the end of the file or of the block the position is in, so a caller loops until it gets 0. A directory is `E_ISDIR` |
| `write(fd, buffer, n)` | copies up to `n` trytes to the position, or the end with `O_APPEND`, and moves it past them: how many, never past the end of the block the position is in, so a caller loops. A write past the end grows the file, leaving holes; one past its last block is `E_FBIG` |
| `iocall(fd, IO_LSEEK, offset, whence)` | sets the position to `offset` from the start, where it is or the end (`SEEK_SET`, `SEEK_CUR`, `SEEK_END`): the new position. It may pass the end, but not the start |
| `iocall(fd, IO_READDIR, buffer, 0)` | the next entry in use of a directory: its name to the buffer, `NAME_MAX + 1` trytes, ended with 0, and its inode as the result; 0 at the end. The position counts 21 trytes per entry, used or not. A file is `E_NOTDIR` |

`flags` is the access mode, `O_RDONLY` (0), `O_WRONLY` (1) or `O_RDWR`
(2), plus any of `O_CREAT` (3: make a file that is not there),
`O_TRUNC` (9: empty a file opened for writing) and `O_APPEND` (27:
write at the end each time). Being ternary digits that are 0 or 1, they
add as Unix flags OR together; any other value is `E_INVAL`. A
directory opens for reading only (`E_ISDIR`), and `read` or `write` on
a descriptor not open for it is `E_BADF`.

`unlink` and `rmdir` refuse, with `E_BUSY`, a file or directory that a
process has open, or that is a process's current directory, where Unix
would keep it until the last descriptor closes or the process moves.
`rename` refuses to replace a file some process has open (`E_BUSY`)
for the same reason, and never replaces a directory: one named `to` is
`E_ISDIR` for a file and `E_EXIST` for a directory, where Unix lets a
directory replace an empty one. A directory may not move inside itself
(`E_INVAL`), the root may not move (`E_BUSY`) nor be replaced
(`E_EXIST`), and neither name may be `.` or `..` (`E_INVAL`). A new file or directory takes the lowest free inode and its
blocks the lowest free blocks.

Descriptors are the kernel's, so a child inherits its parent's open
files, and the shell can point a program's standard input or output at
one (`<`, `>`, `>>`). Copies share the open file and its position. The
server keeps one record per open file, its handle the record's index,
and frees it when the kernel says no descriptor names it any more
(`NOTE_CLOSED`), before it takes any later call: so a file closed, or
held only by a process that ended, can be removed at once.

Each process has a current directory, kept by the server as well and
forgotten when the process ends. It is the root until the process calls
`chdir`. A program started from a file with `spawnf` starts in its
parent's current directory; one the kernel starts from its image
(`spawn`) starts at the root. The server finds a directory's path for
`getcwd` by climbing: each directory's `..` is its parent, and the
parent's entry for it gives its name.

## The server's blocks

The server keeps blocks in its `NWIN` (9) block windows, as a cache:
a block it needs and has not got is read into the window used least
recently, by a `DK_READ` call to the disk server (`user/diskd.s`),
while the server, and so every call waiting for it, sleeps. A call touches at most four blocks at once (block 0, the
inode table, and an indirect and a data block, or a directory's and a
new directory's), so none it is using goes. Each window is a page the kernel makes (`window`) the
first time the server reads into it; with no free page for one, the
call fails with `E_NOMEM`. The server finds the disk server by its name,
`disk`, when it starts, waiting for it; with none, or one of another
protocol, every call finds no filesystem.

A call that changes the filesystem first gathers the blocks it needs
and checks everything that can fail, then changes them in its windows,
marking them dirty, and writes each dirty one back with `DK_WRITE` before
it replies. So when a call returns its changes are on the disk, the
machine may power off at any time between calls, and a call that fails
has changed nothing. A dirty window is never the one reused.

The server takes for granted that nothing else writes the disk while it
runs: a block another process writes through the disk server is not
seen in its windows.

## The shell

`sh` (`user/sh.s`) starts the disk server and the file server first,
then has eight file
built-ins. `ls [DIR]` lists a directory,
the current one when none is given, leaving out names that start with a dot: a
file's size and name, a directory's name and a slash. `cat PATH` prints
a file. `write PATH TEXT` makes the file hold the rest of the line,
replacing what it held; `rm PATH`, `mkdir PATH` and `rmdir PATH` make
the calls of those names. `cd [DIR]` moves the shell to the directory,
or to `/` with none, and `pwd` prints where it is; programs it starts
from the disk start there. They say what went wrong as Unix tools do, `sh: PATH: no such
file or directory`, and carry on.

A command that is neither built in nor one of the programs in the
kernel image (only `pingpong`) is a program file, which `spawnf`
(`FS_SPAWN`) starts: the path given, if it holds a slash, or else the file of that
name in `/bin`, as a Unix shell searches its `PATH`, with the line's
words (redirections left out) as its arguments. Nothing there, or
no filesystem, is `sh: no such program: NAME`; a text file or a
directory is `sh: not a program: NAME`. The programs in `bin/` are
meant for `/bin`: besides `hello`, `fail` and `spin`, which tests run,
they are `echo`, `upper`, `wc`, `head` and `grep` for text, and `cp`,
`mv` and `touch` for files (docs/kernel.md, The shell).

## Program files

Every process runs from `V_USER`, so a program is assembled to run
there and needs no relocating: its image is what it holds from
`V_USER − 1` (the low tryte of its first word, at `V_USER`) upward.
`spawnw`, given the file's blocks in consecutive block windows, checks
the magic word and that the windows hold the whole image, copies the
image to `V_USER` in a fresh page, and on into as many pages above it
as it needs (`NXPAGE` at most), clears the rest, and starts the new
process at `V_USER` with `gp` at `USER_GP` and `sp` at `USER_SP`, as
`spawn` starts a built-in program. `USER_SP` is `V_USER`: the stack
grows down from just below the image, through the lower half of the
page, towards the arguments at its bottom (Program arguments), about
8,800 trytes of it. Since the file server has nine windows, a program
file has at most nine blocks.

A program for the disk is a file of its own, assembled where it loads
and runs:

```asm
        .include "../include/layout.s"
        .compress
        .section hello, V_USER, V_USER
        .gp   USER_GP
hello:  ...
        .nocompress
```

## Program arguments

A program started with `spawnw` (and so with `spawnf`) gets arguments,
as a C program gets `argc` and `argv`: it starts with `a0` the number
of them and `a1` the address `V_ARGV`, where a word per argument holds
the address of its string, ended by 0, and a 0 word follows the last.
The parent names a block of at most `ARG_MAX` (243) trytes in its own
memory, the strings one after another, each ended by 0 (the last may
end at the block's end instead); `spawnw` copies it into the bottom of
the lower half of the child's page, below its stack, from `V_ARGS`,
and builds the list at `V_ARGV`, the page's first word. The block is read in the
parent's memory whoever calls, so the file server passes its client's
`args` and `n` straight to `spawnw` without copying them. A count out of
range is `E_INVAL`, a block not all in the parent's memory `E_FAULT`,
and no program starts. A count of 0 starts the program with no
arguments: `a0` is 0 and the list is just its 0 word.

The shell gives a program the words of its command line, split at
spaces, the command first as typed (`wc`, or `/bin/wc`), without the
redirections. Quoting keeps a space, `|`, `<` or `>` in a word, as in a
Unix shell: `'...'` and `"..."` (where `\"` and `\\` are `"` and `\`),
or `\` before one character; `""` alone is an empty argument. `echo` says its arguments; `wc FILE...` counts each file
named, with a total for two or more, and standard input with none.

```text
$ wc notes more
1 2 12 notes
2 3 14 more
3 5 26 total
```

## The host tool

```bash
tools/fs.py new disk.img 100 notes.txt bin/*.s bin/*.tc   # programs go in /bin
tools/fs.py ls disk.img
tools/fs.py ls disk.img bin
tools/fs.py mkdir disk.img docs
tools/fs.py put disk.img README.md docs          # into a directory
tools/fs.py put disk.img notes.txt docs/old      # or at a path
tools/fs.py cat disk.img docs/old
tools/fs.py rm disk.img docs/old
detrytus asm bin/hello.s -o hello.dti
tools/fs.py put disk.img hello.dti               # a program: /bin/hello
detrytus run shell.s --ram-pages 81 --disk disk.img
```

Images are detrytus disk files, two bytes per tryte, as long as the
filesystem. The tool checks an image when it opens one: it walks the
tree from the root, and every inode in use must be reached, with as
many links as names, and every block must be in the map exactly when
one inode holds it. It refuses a name, text or path that does not fit.
Given an image assembled by `detrytus asm`, or a `.s` file, which it
assembles with `detrytus` first, `put` and `new` store it as a program
file, named after the file without `.dti` or `.s`, in `/bin` unless a
path is given, and refuse one that does not lie between `V_USER − 1`
and `EXEC_MAX` trytes above it. `cat` refuses a program file, and `rm` a
directory with anything in it.

## Later

Directories of more than one block.
