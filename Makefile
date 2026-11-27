# Build a disk for the shell and boot it.
#
#   make           disk.img: a filesystem with every program of bin/ in /bin,
#                  and kernel/trykern.s, the kernel's Rust part
#   make kernel    kernel/trykern.s alone (tools/kernel.py)
#   make run       boot shell.s with disk.img (NET=user by default)
#   make benchmark time the emulator sorting 10,000 lines on disk.img
#   make clean     remove disk.img and kernel/trykern.s
#
# The kernel itself is not on the disk: detrytus loads shell.s, and the
# shell runs the programs it finds in /bin. disk.img is rebuilt from
# scratch when a program or library changes, losing what sessions wrote
# to it; copy it first to keep that.
#
# BENCH passes options to the benchmark's detrytus run (BENCH=--no-jit).
# BLOCKS sets the disk's size in blocks, DISK its file name, and NET the
# network (user, loop, udp:LOCAL,PEER, or empty for none). Building the
# Rust programs needs a Rust toolchain with rust-src and the
# riscv32imac-unknown-none-elf target (docs/rust.md), and so does the
# kernel: build kernel/trykern.s before assembling shell.s or demo.s.

BLOCKS ?= 100
DISK ?= disk.img
NET ?= user
RAM_PAGES ?= 6561

KERNEL_RUST := kernel/trykern.s
KERNEL_SOURCES := $(shell find kernel/rust -type f -not -path '*/target/*') lib/rust/trystd/build.rs include/layout.s

PROGRAMS := $(sort $(wildcard bin/*.s bin/*.tc bin/*.rs))
# What a program can include, import or link against.
SOURCES := $(shell find lib include -type f -not -path '*/target/*')

.PHONY: all disk kernel run benchmark clean

all: disk kernel

disk: $(DISK)

kernel: $(KERNEL_RUST)

$(KERNEL_RUST): $(KERNEL_SOURCES) tools/kernel.py
	tools/kernel.py -o $@

$(DISK): $(PROGRAMS) $(SOURCES) tools/fs.py
	tools/fs.py new $@.tmp $(BLOCKS) $(PROGRAMS)
	mv $@.tmp $@

run: $(DISK) $(KERNEL_RUST)
	detrytus run shell.s --ram-pages $(RAM_PAGES) --disk $(DISK) $(if $(NET),--net $(NET))

benchmark: $(DISK) $(KERNEL_RUST)
	tools/benchmark.py $(DISK) $(BENCH)

clean:
	rm -f $(DISK) $(DISK).tmp $(KERNEL_RUST)
