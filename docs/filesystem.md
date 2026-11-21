# The filesystem

A first, simple filesystem on detrytus' block device, to bootstrap
with: one flat directory, and a file allocation table (FAT) chaining
each file's blocks. Programs reach it through `bread` and `bwrite`, so
it needs nothing from the kernel; `tools/fs.py` builds and reads images
on the host. Every number below is named in `include/layout.s`, which
the tool reads too.

## Blocks

A block is one page, 19,683 trytes or 6,561 words. Memory is centred
(detrytus isa.md 5.2), so offsets are given from a block's centre, as a
program sees them through its block window at `V_BLOCK`: trytes run
from −9,841 to 9,841 and words sit at −9,840, −9,837, ..., 9,840. A
word's low tryte comes first.

Block 0 holds the header, the directory and the FAT. Every other block
belongs to at most one file.

## Block 0

| Offset | Name | Contents |
|--------|------|----------|
| −9,840 (word 0) | `FS_HEAD_MAGIC` | `FS_MAGIC`: a blank disk, all zeros, is not a filesystem |
| −9,837 (word 1) | `FS_HEAD_VERSION` | `FS_VERSION`, 1 |
| −9,834 (word 2) | `FS_HEAD_BLOCKS` | how many blocks the filesystem has, 2 to `FS_MAX_BLOCKS` (5,832); the disk may have more |
| −9,813 (word 9) | `FS_DIR` | the directory: `FS_FILES` (64) entries of `FS_DIRENT` (24) trytes |
| −7,653 (word 729) | `FS_FAT` | the FAT: one word per block, to the end of block 0 |

The rest is zero.

### Directory entries

Each entry is eight words, at `FS_DIR + 24 × i`. Offsets are from its
first word:

| Offset | Name | Contents |
|--------|------|----------|
| −1 | `DE_NAME` | the name: 18 trytes, one code point each, ended and padded with 0. At most `FS_NAME_MAX` (17) code points, none of them a space or a control character |
| 18 | `DE_SIZE` | the file's size in trytes |
| 21 | `DE_FIRST` | its first block, or `FAT_END` when it is empty |

An entry whose name starts with 0 is unused; its other fields are 0
too. Names are unique. The order of entries means nothing.

### The FAT

Word `FS_FAT + 3 × b` describes block `b`:

| Value | Meaning |
|-------|---------|
| `FAT_FREE` (0) | in no file |
| `FAT_END` (−1) | the last block of its file: there is no next one |
| 1 or more | the next block of the same file |

Block 0 is marked `FAT_END`, so it is never free, and since no block
links to 0, a next block of 0 cannot be mistaken for `FAT_FREE`. A file
of `n` trytes has `⌈n / 19,683⌉` blocks.

## Data blocks

A file is trytes, from the block's first tryte (`BLOCK_T0`, −9,841)
upward, continuing in the next block of its chain. Its size says where
it ends; the rest of its last block is zero. Two kinds of file use this:

- **Text**: one code point per tryte, 1 to 9,841. Since the rest of the
  last block is zero, a program can `puts` a block that the file does
  not fill.
- **Programs**: `EXEC_MAGIC` as the first word, then the program's
  image, at most `EXEC_MAX` (9,843) trytes, so a program file is always
  one block. The magic word's first tryte is negative, which no text
  file's is.

## Program files

Every process runs from `V_USER`, so a program is assembled to run
there and needs no relocating: its image is what it holds from
`V_USER − 1` (the low tryte of its first word, at `V_USER`) upward. To
start one, a program reads the file's first block into its block window
and calls `spawnw` (15). The kernel checks the magic word, copies the
image to `V_USER` in a fresh page, clears the rest of the page, and
starts the new process at `V_USER` with `gp` at `USER_GP`, as `spawn`
starts a built-in program. A block without the magic word gives
`E_NOPROG`. The image includes the program's stack space: the stack
starts at the top of the page and grows down towards the image.

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

## Changing it

The disk keeps whole commands, never half of one, but a change that
writes block 0 and a data block can be cut between the two. Write the
data first and block 0 last, so an interrupted change loses only the
change. Nothing guards against two processes changing the filesystem at
once; for now only the shell does.

## The shell

`sh` (`user/sh.s`) has four built-ins: `ls` lists each file's size and
name, `cat NAME` prints a file, `write NAME TEXT` makes `NAME` hold the
rest of the line and a newline, replacing it if it is there, and `rm
NAME` removes it. Its window holds one block, so `cat` reads block 0
again for the FAT before each further block of a file. `write` puts the
text in a free block first and block 0 last, so it needs a free block
even to replace a file. Failures are said, not fatal: `sh: no such file:
NAME`, `sh: the disk is full`, `sh: cannot read the filesystem: N` (a
`bread` failure, or −4 when block 0 holds no filesystem).

A command that is neither built in nor one of the programs in the
kernel image (only `pingpong`) is a file: the shell finds it, reads its
first block and calls `spawnw`. No such file, or no filesystem, is `sh:
no such program: NAME`; a text or empty file is `sh: not a program:
NAME`. The programs in `bin/` are meant for the disk.

## The host tool

```bash
tools/fs.py new disk.img 100 README.md   # 100 blocks, holding one file
tools/fs.py ls disk.img
tools/fs.py put disk.img notes.txt notes
tools/fs.py cat disk.img notes
tools/fs.py rm disk.img notes
detrytus asm bin/hello.s -o hello.dti
tools/fs.py put disk.img hello.dti       # a program file, named hello
tools/fs.py put disk.img bin/fail.s      # assembled first, named fail
detrytus run shell.s --ram-pages 40 --disk disk.img
```

Images are detrytus disk files, two bytes per tryte, as long as the
filesystem. The tool checks the header and every chain when it opens
one, and refuses a name or text that does not fit. Given an image
assembled by `detrytus asm`, or a `.s` file, which they assemble with
`detrytus` first, `put` and `new` store it as a program file, named
after the file without `.dti` or `.s`, and refuse one that does
not lie between `V_USER − 1` and the top of the page. `cat` refuses a
program file.

## Later

This is a bootstrap. Nested directories, inodes, permissions and a
POSIX-shaped interface (descriptors, `open`, `read`, `write`) are
expected to replace it once the filesystem moves out of single
programs, into the kernel or a file server.
