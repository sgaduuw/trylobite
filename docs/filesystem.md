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

A file's text is one code point per tryte, 1 to 9,841, from the block's
first tryte (`BLOCK_T0`, −9,841) upward, continuing in the next block of
its chain. Its size says where it ends; the rest of its last block is
zero, so a program can `puts` a block that the file does not fill.

## Changing it

The disk keeps whole commands, never half of one, but a change that
writes block 0 and a data block can be cut between the two. Write the
data first and block 0 last, so an interrupted change loses only the
change. Nothing guards against two processes changing the filesystem at
once; for now only the shell does.

## The host tool

```bash
tools/fs.py new disk.img 100 README.md   # 100 blocks, holding one file
tools/fs.py ls disk.img
tools/fs.py put disk.img notes.txt notes
tools/fs.py cat disk.img notes
tools/fs.py rm disk.img notes
detrytus run shell.s --ram-pages 40 --disk disk.img
```

Images are detrytus disk files, two bytes per tryte, as long as the
filesystem. The tool checks the header and every chain when it opens
one, and refuses a name or text that does not fit.

## Later

This is a bootstrap. Nested directories, inodes, permissions and a
POSIX-shaped interface (descriptors, `open`, `read`, `write`) are
expected to replace it once the filesystem moves out of single
programs, into the kernel or a file server.
