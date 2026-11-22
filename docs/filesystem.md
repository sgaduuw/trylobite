# The filesystem

A filesystem on detrytus' block device, shaped like a Unix one: files
and directories are inodes, directories are files of names and inode
numbers with `.` and `..`, and programs reach files by path through
descriptors, with `open`, `read`, `lseek`, `readdir`, `stat` and
`close`. The kernel reads it (`kernel/fs.s`) through a cache of blocks
(`kernel/cache.s`); `tools/fs.py` builds and changes images on the
host. Every number below is named in `include/layout.s`, which the
tool reads too.

For now the kernel only reads: files are made, changed and removed
with the tool.

## Blocks

A block is one page, 19,683 trytes or 6,561 words. Memory is centred
(detrytus isa.md 5.2), so offsets are given from a block's centre, as
the kernel's cache and a program's block window see them: trytes run
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

A path is names separated by slashes. It starts at the root whether or
not it starts with one, since nothing has a current directory yet;
slashes before, between and after names do not count, and `.` and `..`
are ordinary entries, so `/a/./b/../b` is `/a/b`. A path has at most
`PATH_DEPTH` (6) names (see the cache, below).

## Files and programs

A file is trytes. Two kinds use this:

- **Text**: one code point per tryte, 1 to 9,841.
- **Programs**: `EXEC_MAGIC` as the first word, then the program's
  image, at most `EXEC_MAX` (9,843) trytes, so only the first block
  matters. The magic word's first tryte is negative, which no text
  file's is.

## System calls

A path is a 0-terminated string in the caller's memory, and a buffer a
range of it: its page, or its block window 0 once it has one (otherwise
`E_FAULT`). Each call fails with `E_NOFS` when there is no disk or no
filesystem on it, `E_IO` when the disk refuses a block or names one
past its end, and `E_NOMEM` when the cache has no room (below). The
others are `E_NOENT` (no such name), `E_NOTDIR` (a name on the way is a
file), `E_NAMETOOLONG`, `E_BADF` (no such open descriptor), `E_ISDIR`,
`E_MFILE`, `E_INVAL` and `E_NOEXEC`.

| Number | Call | Does |
|--------|------|------|
| 16 | `open(path, flags)` | gives the lowest free descriptor (of `NFD`, 8), at position 0 of the file or directory. `flags` is `O_RDONLY` (0), the only one yet |
| 17 | `close(fd)` | frees the descriptor |
| 18 | `read(fd, buffer, n)` | copies up to `n` trytes from the position, and moves it past them: how many, never past the end of the file or of the block the position is in, so a caller loops until it gets 0. A directory is `E_ISDIR` |
| 19 | `lseek(fd, offset, whence)` | sets the position to `offset` from the start, where it is or the end (`SEEK_SET`, `SEEK_CUR`, `SEEK_END`): the new position. It may pass the end, but not the start |
| 20 | `readdir(fd, buffer)` | the next entry in use of a directory: its name to the buffer, `NAME_MAX + 1` trytes, ended with 0, and its inode as the result; 0 at the end. The position counts 21 trytes per entry, used or not. A file is `E_NOTDIR` |
| 21 | `stat(path, buffer)` | four words at the word-aligned buffer: `ST_INO`, `ST_TYPE`, `ST_LINKS` and `ST_SIZE` |
| 22 | `spawnf(path)` | starts the program file at the path, as `spawnw` does from the window; anything but a program file is `E_NOEXEC` |

Descriptors belong to a process and go with it; a new process has none.
They are numbered from 0 like Unix ones, but nothing opens 0, 1 and 2
for the console yet.

## The kernel's cache

The kernel reads blocks into a cache of up to `NBUF` (8) pages, taken
from the free pages as it needs them and kept, least recently used
first to go. A file call that needs a block not there starts reading
it, sleeps, and runs again from the start once it is in, finding it and
the blocks it found before; one already on its way is waited for. A
call changes nothing before it has every block it needs, so a call that
runs again does no harm, and one that fails halfway leaves nothing
half done.

So a call needs room in the cache for every block it touches at once:
block 0, the inode table, and one block per directory on its path, plus
a file's indirect and data block. That is why a path has at most 6
names. A call never evicts a block it has used itself; with too few
free pages for the blocks it needs, it fails with `E_NOMEM` rather than
evict and read the same blocks for ever.

`bread` and `bwrite` reach blocks past the cache. A `bwrite` drops the
cache's copy of its block, so the filesystem reads it again.

## The shell

`sh` (`user/sh.s`) has two file built-ins: `ls [DIR]` lists a directory,
`/` when none is given, leaving out names that start with a dot: a
file's size and name, a directory's name and a slash. `cat PATH` prints
a file. They say what went wrong as Unix tools do, `sh: PATH: no such
file or directory`, and carry on.

A command that is neither built in nor one of the programs in the
kernel image (only `pingpong`) is a program file, which `spawnf`
starts: the path given, if it holds a slash, or else the file of that
name in `/bin`, as a Unix shell searches its `PATH`. Nothing there, or
no filesystem, is `sh: no such program: NAME`; a text file or a
directory is `sh: not a program: NAME`. The programs in `bin/` are
meant for `/bin`.

## Program files

Every process runs from `V_USER`, so a program is assembled to run
there and needs no relocating: its image is what it holds from
`V_USER − 1` (the low tryte of its first word, at `V_USER`) upward.
`spawnf` (or `spawnw`, given the file's first block in the caller's
window) checks the magic word, copies the image to `V_USER` in a fresh
page, clears the rest of the page, and starts the new process at
`V_USER` with `gp` at `USER_GP`, as `spawn` starts a built-in program.
The image includes the program's stack space: the stack starts at the
top of the page and grows down towards the image.

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

## The host tool

```bash
tools/fs.py new disk.img 100 notes.txt bin/*.s   # programs go in /bin
tools/fs.py ls disk.img
tools/fs.py ls disk.img bin
tools/fs.py mkdir disk.img docs
tools/fs.py put disk.img README.md docs          # into a directory
tools/fs.py put disk.img notes.txt docs/old      # or at a path
tools/fs.py cat disk.img docs/old
tools/fs.py rm disk.img docs/old
detrytus asm bin/hello.s -o hello.dti
tools/fs.py put disk.img hello.dti               # a program: /bin/hello
detrytus run shell.s --ram-pages 40 --disk disk.img
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
and the top of the page. `cat` refuses a program file, and `rm` a
directory with anything in it.

## Later

Writing: `open` with flags to create and truncate, `write`, `unlink`,
`mkdir` and `rmdir`, with the cache writing changed blocks back.
Then a current directory and relative paths, and descriptors 0, 1 and 2
for the console.
