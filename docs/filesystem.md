# The filesystem

A filesystem on detrytus' block device, shaped like a Unix one: files
and directories are inodes with permissions, an owner and four times,
directories hold names with `.` and `..`, and programs reach files by
path through descriptors, with `open`, `read`, `write`, `lseek`,
`readdir`, `stat` and `close`, and `unlink`, `rename`, `mkdir`,
`rmdir`, `utimes`, `chmod` and `chown`. Every record lives in one
copy-on-write B-tree, after bcachefs: a change never writes over what
the disk's tree points to, so the disk always holds the tree as the last
call left it.

One Rust crate, `lib/rust/tryfs`, is the format: the file server
(`user/rust/fsd`, a process answering other processes' calls) and the
host's disk tool (`tools/rust/tryfs`, which `tools/fs.py` runs) are both
built on it. Every number below is named in `include/layout.s`, which
the crate reads too.

## Blocks

A block is one page, 19,683 trytes or 6,561 words. Memory is centred
(detrytus isa.md 5.2), so offsets are given from a block's centre, as
a program's block window sees them: trytes run
from −9,841 to 9,841 and words sit at −9,840, −9,837, ..., 9,840. A
word's low tryte comes first. The superblock's words after the boot
record, and a node's, are numbered from the block's first word instead:
word `k` is at `BLOCK_W0 + 3k`.

Block 0 is the superblock. Every other block is free, a node of the
tree, a file's data, or one of the kernel's (the boot record's). Which
blocks are free is not on the disk: mounting walks the tree and marks
every block it reaches, so there is no map to keep in step with it, and
no way for the two to disagree. A filesystem has 2 to `FS_MAX_BLOCKS`
(19,683) blocks; the disk may have more.

## The superblock

| Word | Name | Contents |
|------|------|----------|
| 0 | `FS_HEAD_MAGIC` | `FS_MAGIC`: a blank disk, all zeros, is not a filesystem |
| 1 | `FS_HEAD_VERSION` | `FS_VERSION`, 3 (1 was a flat directory and a FAT, 2 an inode table) |
| 2 | `FS_HEAD_BLOCKS` | how many blocks the filesystem has |
| 3 | `FS_HEAD_BOOT` | `BOOT_MAGIC` (20,261,128) on a disk the kernel boots from, else 0 |
| 4 | `BOOT_FIRST` | the kernel's first block |
| 5 | `BOOT_COUNT` | how many blocks it has |
| 6 | `BOOT_PAGE` | the RAM page its first block loads into: 1 |
| 7 | `BOOT_ENTRY` | where it starts: `FW_BOOT`, the firmware |
| 9 | `SB_ROOT` | the tree's root node |
| 10 | `SB_SEQ` | how many commits there have been: the one that wrote this |
| 11 | `SB_NEXT_INO` | the next inode number to hand out; numbers are not used again |
| 12 | `SB_INODES` | inodes in use |
| 13 | `SB_SUM` | the sum of words 0 to 12 |

A sum runs over words from 0, `s = 2s + w` for each, kept within a
word (`FS_SUM_RADIX`). A superblock or node whose sum is wrong is
damaged, and the filesystem does not mount (`E_IO`).

Words 3 to 8 are detrytus' **boot record** (detrytus
docs/platform.md, Booting from a disk): with no program, `detrytus run
--disk` loads blocks `BOOT_FIRST` to `BOOT_FIRST + BOOT_COUNT − 1` into
RAM pages from `BOOT_PAGE` and jumps to `BOOT_ENTRY`. `tools/fs.py new
--boot shell.s` and `tools/fs.py boot` put a build's pages 1 and up
(the kernel, the firmware and the built-in programs) in the first run
of free blocks long enough, and fill the record in; the file server
leaves both alone, and never allocates the kernel's blocks. Word 8
stays 0.

## The tree

A node is a block: a header, then items packed one after another in key
order.

| Word | Name | Contents |
|------|------|----------|
| 0 | | `NODE_MAGIC` |
| 1 | `N_LEVEL` | 0 for a leaf, one more than its children's above |
| 2 | `N_COUNT` | how many items it holds |
| 3 | `N_USED` | the words its items take |
| 4 | `N_SEQ` | the commit that wrote it |
| 5 | `N_SUM` | the sum of the header and items, this word counted as 0 |
| 9 (`N_ITEMS`) | | the first item |

An item is its key's length and its value's, in words (`IT_KLEN`,
`IT_VLEN`), then its key, then its value. A leaf's items are the
filesystem's records. An inner node's values are each one block, the
child holding keys from that item's key up to the next item's; the
first covers every key below the second. A leaf that would overflow
splits in two by words, and the split goes up the way to it; a root that
splits gets a new root above it. A node left empty is taken out of its
parent, and a root with one child gives way to it. There are no links
between siblings, which copy-on-write would have to keep up: the next
leaf is found from the parent's next key. A tree has at most 8 levels,
far more than `FS_MAX_BLOCKS` blocks need.

Keys compare word by word, a shorter key first when one is the start of
the other. Every key starts with an inode number and a kind, so each
inode's records sit together, its own record first:

| Key | Value |
|-----|-------|
| `[ino, K_INODE]` (−1) | the inode, `INODE_WORDS` (15) words, below |
| `[dir, K_DIRENT, name...]` (0) | an entry of directory `dir`: the inode it names (`DE_INO`) and that inode's type (`DE_TYPE`) |
| `[ino, K_EXTENT, end]` (1) | a run of the file's data: its first disk block (`EX_START`) and how many (`EX_LEN`), for the file's blocks `end − EX_LEN` to `end − 1` |

An extent is keyed by its end so that the extent holding file block `b`
is the first whose key is after `[ino, K_EXTENT, b]`. A block of a file
no extent covers is a hole, and reads as zeros (`NO_BLOCK`, 0, is never
data). A file of `n` trytes has `⌈n / 19,683⌉` blocks at most, and the
rest of its last block is zero. Writing the block after an extent's
last grows the extent when the next disk block is free, so a file
written from the start usually has one extent.

## Inodes

| Word | Name | Contents |
|------|------|----------|
| 0 | `IN_TYPE` | `T_FILE` (1) or `T_DIR` (2) |
| 1 | `IN_MODE` | its permissions, Unix's bits up to 0o7777 (`MODE_MAX`): a new file's are 0o644 (`MODE_FILE`), a directory's 0o755 (`MODE_DIR`) |
| 2 | `IN_UID` | its owner: 0 until there are users |
| 3 | `IN_GID` | its group: 0 too |
| 4 | `IN_LINKS` | a file's names; a directory's 2 (its name and its `.`) and one for each subdirectory's `..` |
| 5 | `IN_SIZE` | a file's size in trytes; a directory's entries, `.` and `..` counted |
| 6 | `IN_ATIME` | when it was last read |
| 8 | `IN_MTIME` | when its contents last changed |
| 10 | `IN_CTIME` | when anything about it last changed |
| 12 | `IN_BTIME` | when it was made |
| 14 | `IN_PARENT` | a directory's parent (the root's is itself); 0 for a file |

A time is two words, seconds since 1970 and nanoseconds, from the
kernel's clock (`SYS_CLOCK`, kernel.md): the server reads it once per
call that may change something, so every time one call sets is the same.
Inode 0 is never used, so `NO_INO` (0) means none; inode 1 (`ROOT_INO`)
is the root directory, `/`.

Reading moves the access time only while it is no later than the
modification or change time, as Linux's `relatime` has it: so `ls -lu`
says whether a file was read since it last changed, and reading does
not write the disk every time.

## Directories

A directory's entries are its `K_DIRENT` items. A name of 1 to
`NAME_MAX` (60) code points packs into `NAME_WORDS` (20) words, three
code points to a word with the first the most significant, so names
sort as their code points do and a directory lists in that order. A
name holds no space, slash or control character, and is unique in its
directory. `.` and `..` are not stored: the server answers them from
the directory itself and its `IN_PARENT`, and they cannot be made,
removed or renamed. A directory takes no block of its own; its entries
share leaves with every other record, so a directory may hold as many
names as the disk has room for.

## Transactions

Every call that changes the filesystem is one transaction:

1. A node about to change is first copied to a free block, and its
   parent to point to the copy, and so up to the root; a node this call
   has already copied changes in place. Blocks the call allocates are
   *fresh*: nothing on the disk points to them.
2. Blocks the call stops using (old nodes, a removed file's data) are
   *freed*, but stay in use until the commit, since the tree on the
   disk still points to them.
3. To commit, the server writes every block it changed, then the
   superblock naming the new root. Only then are the freed blocks free.
4. A call that fails part way aborts: it forgets its changed blocks and
   gives back its fresh ones, and the disk still holds the last commit.

So the machine may power off at any time and the disk holds a whole
filesystem: the old one until the superblock is written, the new one
after. The one exception is file data, which a write puts in the file's
block in place, as most Unix filesystems do; a new block is fresh like
any other. A new data block goes after the one before it in the file
if that is free, else the first free one from there on, else the first
from where the last search stopped (wrapping round), so files tend to
lie in runs. A node goes in the last free block instead: nodes gather
at the end of the disk and data at the start, so copying nodes at every
change does not leave free blocks scattered among a file's, and the free
space between stays in one run, where `tools/fs.py boot` can put a
kernel.

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
`E_NOSPC` (no free block), `E_NOTEMPTY`, `E_FBIG` (past a
file's last block) and `E_BUSY`.

| Operation | Call | Does |
|-----------|------|------|
| `FS_OPEN` (0) | `open(path, flags)` | gives the caller's lowest free descriptor (of `NDESC`, 9), at position 0 of the file or directory. `flags` is below. `E_MFILE` when the caller has no descriptor free, or the server has `NFILE` (27) files open; with `O_CREAT` the file may have been made by then |
| `FS_STAT` (5) | `stat(path, buffer)` | `STAT` (48) trytes at the word-aligned buffer, a word each but the times: `ST_INO`, `ST_TYPE`, `ST_LINKS`, `ST_SIZE`, `ST_MODE`, `ST_UID`, `ST_GID`, then `ST_ATIME`, `ST_MTIME`, `ST_CTIME` and `ST_BTIME`, two words each (seconds, nanoseconds), and `ST_BLOCKS`, the disk blocks its data takes |
| `FS_SPAWN` (6) | `spawnf(path, args, n)` | starts the program file at the path as the caller's child, with the `n` trytes of arguments at `args` in the caller's memory (Program arguments): the server reads its blocks into consecutive windows (the first stays where its cache read it if the rest fit after it), and gives them to `spawnw` with the caller as the parent. Anything but a program file is `E_NOEXEC` |
| `FS_UNLINK` (8) | `unlink(path)` | removes a file's name from its directory, and frees the file when no name is left. A directory is `E_ISDIR`, a name `.` or `..` `E_INVAL` |
| `FS_MKDIR` (9) | `mkdir(path)` | makes an empty directory, holding `.` and `..`: `E_EXIST` if the name is taken |
| `FS_RMDIR` (10) | `rmdir(path)` | removes an empty directory (`E_NOTEMPTY` otherwise); the root is `E_BUSY`, a name `.` or `..` `E_INVAL` |
| `FS_CHDIR` (11) | `chdir(path)` | makes the directory the caller's current one; a file is `E_NOTDIR` |
| `FS_GETCWD` (12) | `getcwd(buffer, n)` | the current directory's path from the root, ended with 0, to the buffer: its length. `E_NOROOM` (Unix's `ERANGE`) when it and its 0 need more than `n` trytes, `E_NAMETOOLONG` when it is longer than `PATH_MAX` |
| `FS_STATFS` (13) | `statfs(buffer)` | how full the disk is, four words at the word-aligned buffer: `SF_BLOCKS` (in the filesystem) and `SF_BFREE` (free), `SF_INODES` and `SF_IFREE`. Inodes take no fixed room, so `SF_IFREE` is as many as the free blocks would hold as leaves of inodes (`INODES_PER_BLOCK`, 344, each), and `SF_INODES` those and the ones in use. `bin/df` says them |
| `FS_RENAME` (14) | `rename(from, to)` | gives what `from` names the name `to`, in the same directory or another; a directory moved to another parent gets that as its `..`. A file already named `to` is replaced, and freed if that was its last name; the same file under both names is left alone. Below, what it refuses |
| `FS_UTIMES` (15) | `utimes(path, times)` | sets its access and modification times from four words at the word-aligned `times`: seconds and nanoseconds for each. Nanoseconds of `UTIME_NOW` (−1) set that time to now, `UTIME_OMIT` (−2) leave it, and any other outside 0 to 999,999,999 is `E_INVAL`. The change time becomes now |
| `FS_CHMOD` (16) | `chmod(path, mode)` | sets its permissions; a mode outside 0 to 0o7777 is `E_INVAL` |
| `FS_CHOWN` (17) | `chown(path, uid, gid)` | sets its owner and group, `KEEP_ID` (−1) leaving one as it is; any other negative is `E_INVAL` |

There are no users yet, so the server checks no permissions: anyone may
read, write, `chmod` or `chown` anything. The fields are there so that
tools can show and keep them, and a later kernel can enforce them.

Numbers 1 to 4 and 7 were `close`, `read`, `lseek`, `readdir` and
`write` before `FS_PROTOCOL` 2; they are descriptor calls on what
`open` gave now:

| Descriptor call | Does |
|-----------------|------|
| `close(fd)` | empties the descriptor; the file closes when no descriptor names it |
| `read(fd, buffer, n)` | copies up to `n` trytes from the position, and moves it past them: how many, never past the end of the file or of the block the position is in, so a caller loops until it gets 0. A directory is `E_ISDIR` |
| `write(fd, buffer, n)` | copies up to `n` trytes to the position, or the end with `O_APPEND`, and moves it past them: how many, never past the end of the block the position is in, so a caller loops. A write past the end grows the file, leaving holes; one past its last block is `E_FBIG` |
| `iocall(fd, IO_LSEEK, offset, whence)` | sets the position to `offset` from the start, where it is or the end (`SEEK_SET`, `SEEK_CUR`, `SEEK_END`): the new position. It may pass the end, but not the start |
| `iocall(fd, IO_READDIR, buffer, 0)` | the next entry of a directory: its name to the buffer, `NAME_MAX + 1` trytes, ended with 0, and its inode as the result; 0 at the end. `.` and `..` come first, then the rest in name order. The position counts one per entry, and seeking back to 0 starts again. A file is `E_NOTDIR` |

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
(`E_EXIST`), and neither name may be `.` or `..` (`E_INVAL`).

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

## The file server

The server (`user/rust/fsd`, with its system-call stubs and start in
`user/fsd.s`) is Rust built with `tools/server.py` into
`user/fsd-rust.s`, which `user/fsd.s` includes; `make kernel` builds it
with the kernel's Rust. Its image takes `FS_PAGES` (4) pages, the only
built-in program of more than one (its `IMAGE_PAGES` word, kernel.md,
Memory). `tools/server.py` also checks that its deepest chain of
calls fits its stack, about 9,800 trytes below `V_USER`, and fails the
build if it does not. Its state, about 14,000 trytes, most of it the
sets of which blocks are in use, is in its heap (`brk`), not its image,
where those zeros would take a page. Node sums are a loop in
`user/fsd.s`, where a register wraps as the sum does, rather than Rust's
64-bit arithmetic.

It keeps blocks in its `NWIN` (9) block windows, as a cache: a block
it needs and has not got is read into the window used least recently,
by a `DK_READ` call to the disk server (`user/diskd.s`), while the
server, and so every call waiting for it, sleeps. The tree never needs
more than four blocks at once, so none it is using goes. A window that
changed is dirty until the commit writes it; one may be written early
to make room only if it is fresh, since nothing on the disk points to
it yet. Each window is a page the kernel makes (`window`) the first
time the server reads into it; with no free page for one, the call
fails with `E_NOMEM`. The server also remembers the last few inodes and
extents it read, until the tree changes. It finds the disk server by
its name, `disk`, when it starts, waiting for it; with none, or one of
another protocol, every call finds no filesystem.

The server mounts the filesystem at its first call, and again after the
disk refused a block, walking the whole tree; so a disk it cannot read
is `E_NOFS` and a damaged one `E_IO`, for every call until one mounts.
It takes for granted that nothing else writes the disk while it runs: a
block another process writes through the disk server is not seen in its
windows.

## The shell

`sh` (`bin/sh.rs`), which init starts from `/bin/sh` once the disk
and file servers are up, has eight file
built-ins. `ls [DIR]` lists a directory,
the current one when none is given, leaving out names that start with a dot: a
file's size and name, a directory's name and a slash. Given an option
first (`ls -l`, `ls -la`), it runs `/bin/ls` instead, which says each
name's type and permissions, links, owner, group, size and modification
time as Unix's `ls -l` does (`-a` keeps the names starting with a dot,
`.` and `..` among them). `cat PATH` prints
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
`mv` and `touch` for files, and `ls`, `stat` (every field of an inode,
its times to the nanosecond) and `chmod MODE PATH...` (an octal mode)
for what the inodes hold; `touch` sets an existing file's times to now
(docs/kernel.md, The shell).

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
tools/fs.py new disk.img 100 notes.txt bin/*.rs   # programs go in /bin
tools/fs.py ls disk.img
tools/fs.py ls disk.img bin
tools/fs.py mkdir disk.img docs
tools/fs.py put disk.img README.md docs          # into a directory
tools/fs.py put disk.img notes.txt docs/old      # or at a path
tools/fs.py cat disk.img docs/old
tools/fs.py rm disk.img docs/old
tools/fs.py put disk.img bin/hello.rs            # built first: /bin/hello
tools/fs.py mkdir disk.img etc
tools/fs.py put disk.img etc/init etc/init       # what init starts (kernel.md)
tools/fs.py check disk.img                       # fsck: says what is wrong
detrytus run shell.s --disk disk.img
```

`tools/fs.py` is a Python front end over `tools/rust/tryfs`, a host
program built on the same `lib/rust/tryfs` crate as the file server,
which it builds with `cargo` the first time (or runs the one `$TRYFS`
names). That program takes the commands above and more (`mv`, `rmdir`,
`chmod`, `chown`, `utimes`, `stat`, `info`, `get`) on an image, and
answers in lines of JSON, which is how the tests read a disk:
`tools.fs.Filesystem` wraps it.

Images are detrytus disk files, two bytes per tryte, as long as the
filesystem. The tool checks an image when it opens one, as `check`
does: mounting walks the tree and checks each node's sum, level and
that no block is used twice, and then every key must be in order, every
entry must name an inode that is there, every inode must be reached
from the root with as many links as names, extents must stay within
their file's size, and the superblock's counts must be right. It refuses a name, text or path that does not fit.
Given an image assembled by `detrytus asm`, or a `.s` file, which it
assembles with `detrytus` first, `put` and `new` store it as a program
file, named after the file without `.dti` or `.s`, in `/bin` unless a
path is given, and refuse one that does not lie between `V_USER − 1`
and `EXEC_MAX` trytes above it. `cat` refuses a program file, and `rm` a
directory with anything in it.

## Later

- Users, and permission checks on the fields every inode already has.
- Checksums on file data, and more than one superblock, as bcachefs
  keeps, so that a damaged block is found and the last commit survives
  one.
- Snapshots: since nothing reachable from a superblock is written
  over, keeping an old root is most of one.
- Inline data: a small file's trytes as an item in the tree instead of
  a block of its own.
