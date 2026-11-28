# Build a disk for the shell and boot it.
#
#   make           disk.img: a bootable filesystem with the kernel (shell.s)
#                  in its boot blocks, every program of bin/ in /bin and
#                  etc/init, what init starts, in /etc; and kernel/trykern.s
#                  and user/fsd-rust.s, the Rust parts of the kernel and of
#                  the file server
#   make kernel    kernel/trykern.s and user/fsd-rust.s alone (tools/kernel.py,
#                  tools/server.py)
#   make run       boot disk.img: detrytus' boot ROM loads the kernel from
#                  it (NET=user by default)
#   make benchmark time the emulator sorting 10,000 lines on disk.img
#   make clean     remove disk.img, kernel/trykern.s and user/fsd-rust.s
#
# The kernel is on the disk: tools/fs.py new --boot puts shell.s's RAM
# pages in blocks that block 0's boot record names, and detrytus run
# --disk with no program boots them. The shell runs the programs it finds
# in /bin. Loading the kernel as a file still works, and runs this
# disk's programs the same way:
#
#   detrytus run shell.s --disk disk.img
#
# disk.img is rebuilt from
# scratch when a program or library changes, losing what sessions wrote
# to it; copy it first to keep that.
#
# BENCH passes options to the benchmark's detrytus run (BENCH=--no-jit).
# BLOCKS sets the disk's size in blocks, DISK its file name, and NET the
# network (user, loop, udp:LOCAL,PEER, or empty for none). RAM_PAGES
# gives make run that many pages of RAM instead of detrytus' default
# (59,049). Building the
# Rust programs needs rustup, which installs the Rust that
# rust-toolchain.toml pins (tools/toolchain.py), and so does the
# kernel: build kernel/trykern.s and user/fsd-rust.s before assembling
# shell.s or demo.s. tools/fs.py builds tools/rust/tryfs, the host's disk
# tool, with cargo.

BLOCKS ?= 100
DISK ?= disk.img
NET ?= user
RAM_PAGES ?=

KERNEL_RUST := kernel/trykern.s
KERNEL_SOURCES := $(shell find kernel/rust -type f -not -path '*/target/*') lib/rust/trystd/build.rs include/layout.s
FSD_RUST := user/fsd-rust.s
FSD_SOURCES := $(shell find user/rust lib/rust/tryfs -type f -not -path '*/target/*') lib/rust/trystd/build.rs include/layout.s

PROGRAMS := $(sort $(wildcard bin/*.s bin/*.tc bin/*.rs))
# The modules of a program too big for one file, such as bin/sh/.
MODULES := $(shell find bin -mindepth 2 -type f -name "*.rs")
# What a program can include, import or link against.
SOURCES := $(shell find lib include -type f -not -path '*/target/*')
# What the kernel on the disk is built from.
BOOT_SOURCES := shell.s $(wildcard firmware/*.s kernel/*.s user/*.s) $(KERNEL_RUST) $(FSD_RUST)

.PHONY: all disk kernel run benchmark clean

all: disk kernel

disk: $(DISK)

kernel: $(KERNEL_RUST) $(FSD_RUST)

$(KERNEL_RUST): $(KERNEL_SOURCES) tools/kernel.py
	tools/kernel.py -o $@

$(FSD_RUST): $(FSD_SOURCES) tools/server.py
	tools/server.py -o $@

$(DISK): $(PROGRAMS) $(MODULES) $(SOURCES) $(BOOT_SOURCES) etc/init tools/fs.py $(shell find tools/rust -type f -not -path '*/target/*')
	tools/fs.py new $@.tmp $(BLOCKS) $(PROGRAMS) --boot shell.s
	tools/fs.py mkdir $@.tmp etc
	tools/fs.py put $@.tmp etc/init etc/init
	mv $@.tmp $@

run: $(DISK)
	detrytus run $(if $(RAM_PAGES),--ram-pages $(RAM_PAGES)) --disk $(DISK) $(if $(NET),--net $(NET))

benchmark: $(DISK) $(KERNEL_RUST)
	tools/benchmark.py $(DISK) $(BENCH)

clean:
	rm -f $(DISK) $(DISK).tmp $(KERNEL_RUST) $(FSD_RUST)
