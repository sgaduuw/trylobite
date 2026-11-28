//! Variables: the shell's own, and those it exports, which are the
//! environment its programs start with.
//!
//! The shell starts with its environment's variables, all exported, and
//! gives PATH and HOME a value if they came without one. A variable set
//! with NAME=value is the shell's alone until `export` exports it; an
//! exported one's every change goes to the environment at once
//! (trystd::env::set_var), so a program the shell starts later sees it.

use trystd::env;
use trystd::prelude::*;

/// Where commands are looked for, and home, when the environment does
/// not say.
pub const PATH: &[u8] = b"/bin";
pub const HOME: &[u8] = b"/";

pub struct Var {
    pub name: Vec<u8>,
    pub value: Vec<u8>,
    pub exported: bool,
}

pub struct Vars {
    pub list: Vec<Var>,
}

/// Whether `name` can name a variable: a letter or _, then letters,
/// digits and _.
pub fn is_name(name: &[u8]) -> bool {
    match name.split_first() {
        Some((&c, rest)) => {
            (c.is_ascii_alphabetic() || c == b'_')
                && rest.iter().all(|&c| c.is_ascii_alphanumeric() || c == b'_')
        }
        None => false,
    }
}

impl Vars {
    /// The environment's variables, and PATH and HOME.
    pub fn import() -> Vars {
        let mut vars = Vars { list: Vec::new() };
        for (name, value) in env::vars_bytes() {
            vars.list.push(Var { name, value, exported: true });
        }
        for (name, value) in [(&b"PATH"[..], PATH), (b"HOME", HOME)] {
            if vars.get(name).is_none() {
                vars.set(name, value);
                vars.export(name);
            }
        }
        vars
    }

    fn find(&self, name: &[u8]) -> Option<usize> {
        self.list.iter().position(|v| v.name == name)
    }

    pub fn get(&self, name: &[u8]) -> Option<&[u8]> {
        self.find(name).map(|k| &self.list[k].value[..])
    }

    /// Give `name` the value `value`; an exported one changes in the
    /// environment too. False, having said why, if it would not fit there.
    pub fn set(&mut self, name: &[u8], value: &[u8]) -> bool {
        match self.find(name) {
            Some(k) => {
                if self.list[k].exported && !to_env(name, value) {
                    return false;
                }
                self.list[k].value = value.to_vec();
            }
            None => self.list.push(Var { name: name.to_vec(), value: value.to_vec(), exported: false }),
        }
        true
    }

    /// Export `name`, set or not: from now on it is in the environment
    /// whenever it has a value.
    pub fn export(&mut self, name: &[u8]) -> bool {
        match self.find(name) {
            Some(k) => {
                if !self.list[k].exported {
                    if !to_env(name, &self.list[k].value) {
                        return false;
                    }
                    self.list[k].exported = true;
                }
            }
            None => {
                // Exported with no value: it reaches the environment once
                // it gets one. An empty value stands in, as POSIX's shells
                // keep it apart only for `export` with no arguments.
                if !to_env(name, b"") {
                    return false;
                }
                self.list.push(Var { name: name.to_vec(), value: Vec::new(), exported: true });
            }
        }
        true
    }

    /// Forget `name`, and take it out of the environment.
    pub fn unset(&mut self, name: &[u8]) {
        if let Some(k) = self.find(name) {
            if self.list.remove(k).exported {
                let _ = env::remove_var(name);
            }
        }
    }
}

/// Put `name` in the environment, or say why it would not go.
fn to_env(name: &[u8], value: &[u8]) -> bool {
    match env::set_var(name, value) {
        Ok(()) => true,
        Err(e) => {
            crate::fail(name, &e);
            false
        }
    }
}
