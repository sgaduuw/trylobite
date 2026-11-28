//! The trylobite filesystem (docs/filesystem.md): one copy-on-write
//! B-tree holding every inode, directory entry and extent, after
//! bcachefs, on a disk of ternary blocks.
//!
//! The file server (user/rust/fsd) and the host's disk tool
//! (tools/rust/tryfs) both build on this crate, so there is one
//! implementation of the format. Each brings a [`Store`]: the file
//! server's is its block windows, read and written through the disk
//! server; the host's ([`mem::MemStore`], with the `std` feature) is a
//! whole disk image in memory.
//!
//! A word is an `i64` here, as in the kernel: every number on the disk is
//! a word, and include/layout.s names them all ([`layout`]).
//!
//! Changes are transactions. Nothing reachable from the superblock's root
//! is ever written over: a node about to change is first copied to a
//! free block ([`Fs::cow`]), and so up to the root, and the blocks the
//! old version used become free only once the superblock naming the new
//! root is on the disk ([`Fs::commit`]). A call that fails part way
//! leaves the disk as it was ([`Fs::abort`]). Only file data is written
//! in place.

#![no_std]
#![allow(clippy::new_without_default)]

#[cfg(any(test, feature = "std"))]
extern crate std;

pub mod layout {
    //! include/layout.s's numbers, every one an i64.
    #![allow(dead_code)]
    include!(concat!(env!("OUT_DIR"), "/layout.rs"));
}

pub mod bits;
pub mod fs;
pub mod key;
pub mod node;
pub mod ops;
pub mod store;
pub mod sum;
pub mod tree;

#[cfg(feature = "std")]
pub mod check;
#[cfg(feature = "std")]
pub mod mem;

pub use fs::{Fs, Inode, Time};
pub use key::Key;
pub use store::{Slot, Store};

/// A failure: one of include/layout.s's E_ numbers.
pub type Error = i64;
pub type Result<T> = core::result::Result<T, Error>;

#[cfg(all(test, feature = "std"))]
mod tests;
