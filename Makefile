# Build a disk for the shell and boot it.
#
#   make           disk.img: a filesystem with every program of bin/ in /bin
#   make run       boot shell.s with disk.img (NET=user by default)
#   make clean     remove disk.img
#
# The kernel itself is not on the disk: detrytus loads shell.s, and the
# shell runs the programs it finds in /bin. disk.img is rebuilt from
# scratch when a program or library changes, losing what sessions wrote
# to it; copy it first to keep that.
#
# BLOCKS sets the disk's size in blocks, DISK its file name, and NET the
# network (user, loop, udp:LOCAL,PEER, or empty for none). Building the
# Rust programs needs a Rust toolchain with rust-src and the
# riscv32imac-unknown-none-elf target (docs/rust.md).

BLOCKS ?= 100
DISK ?= disk.img
NET ?= user
RAM_PAGES = 81

PROGRAMS := $(sort $(wildcard bin/*.s bin/*.tc bin/*.rs))
# What a program can include, import or link against.
SOURCES := $(shell find lib include -type f -not -path '*/target/*')

.PHONY: all disk run clean

all: disk

disk: $(DISK)

$(DISK): $(PROGRAMS) $(SOURCES) tools/fs.py
	tools/fs.py new $@.tmp $(BLOCKS) $(PROGRAMS)
	mv $@.tmp $@

run: $(DISK)
	detrytus run shell.s --ram-pages $(RAM_PAGES) --disk $(DISK) $(if $(NET),--net $(NET))

clean:
	rm -f $(DISK) $(DISK).tmp
