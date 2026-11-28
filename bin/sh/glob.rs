//! Patterns, as a Unix shell has them for file names and case: * any
//! characters, ? one, [abc] one of those, [a-z] one in that range, [!x]
//! one not in it; a quoted character only itself.
//!
//! For file names the pattern is split at its slashes, and each part
//! that is a pattern is matched against the names in the directory the
//! parts before it reached; a name starting with a dot only matches a
//! part that starts with one. The paths found come in order.

use trystd::fs::File;
use trystd::prelude::*;
use trystd::sys;

/// Whether `name` matches the pattern `pat`, `quoted` saying which of its
/// characters are themselves.
pub fn matches(pat: &[u8], quoted: &[bool], name: &[u8]) -> bool {
    let (mut p, mut n) = (0, 0);
    // Where the last * was, and where in the name it took up from.
    let mut star: Option<(usize, usize)> = None;
    loop {
        if p < pat.len() {
            let special = !quoted[p];
            match pat[p] {
                b'*' if special => {
                    star = Some((p, n));
                    p += 1;
                    continue;
                }
                b'?' if special && n < name.len() => {
                    p += 1;
                    n += 1;
                    continue;
                }
                b'[' if special && n < name.len() => {
                    if let Some((hit, next)) = class(pat, quoted, p, name[n]) {
                        if hit {
                            p = next;
                            n += 1;
                            continue;
                        }
                    } else if name[n] == b'[' {
                        // No closing ]: an ordinary [.
                        p += 1;
                        n += 1;
                        continue;
                    }
                }
                c if n < name.len() && name[n] == c && !(special && matches!(c, b'?' | b'[')) => {
                    p += 1;
                    n += 1;
                    continue;
                }
                _ => {}
            }
        } else if n == name.len() {
            return true;
        }
        // A mismatch: let the last * take one more character.
        match star {
            Some((sp, sn)) if sn < name.len() => {
                star = Some((sp, sn + 1));
                p = sp + 1;
                n = sn + 1;
            }
            _ => return false,
        }
    }
}

/// The bracket expression at `pat[at]`: whether `c` is in it, and where
/// the pattern goes on after it; None if it has no closing ].
fn class(pat: &[u8], quoted: &[bool], at: usize, c: u8) -> Option<(bool, usize)> {
    let mut i = at + 1;
    let negate = matches!(pat.get(i), Some(b'!' | b'^')) && !quoted[i];
    if negate {
        i += 1;
    }
    let mut hit = false;
    let mut first = true;
    while i < pat.len() {
        if pat[i] == b']' && !quoted[i] && !first {
            return Some((hit != negate, i + 1));
        }
        first = false;
        let lo = pat[i];
        if pat.get(i + 1) == Some(&b'-') && pat.get(i + 2).is_some_and(|&h| h != b']') {
            let hi = pat[i + 2];
            hit |= lo <= c && c <= hi;
            i += 3;
        } else {
            hit |= lo == c;
            i += 1;
        }
    }
    None
}

/// Whether part `p` of a pattern has an unquoted pattern character.
fn is_pattern(pat: &[u8], quoted: &[bool]) -> bool {
    pat.iter().zip(quoted).any(|(&c, &q)| !q && matches!(c, b'*' | b'?' | b'['))
}

/// The paths pattern `pat` matches, in order; none if it matches none.
pub fn expand(pat: &[u8], quoted: &[bool]) -> Vec<Vec<u8>> {
    let absolute = pat.first() == Some(&b'/');
    let mut found: Vec<Vec<u8>> = vec![if absolute { b"/".to_vec() } else { Vec::new() }];
    let mut start = if absolute { 1 } else { 0 };
    while start <= pat.len() {
        let end = pat[start..].iter().position(|&c| c == b'/').map_or(pat.len(), |k| start + k);
        let (part, q) = (&pat[start..end], &quoted[start..end]);
        let last = end == pat.len();
        let mut next = Vec::new();
        for base in &found {
            if part.is_empty() {
                // A doubled or trailing slash.
                next.push(base.clone());
                continue;
            }
            if !is_pattern(part, q) {
                let mut path = base.clone();
                path.extend_from_slice(part);
                if last || trystd::fs::metadata(&path).is_ok_and(|m| m.is_dir()) {
                    next.push(path);
                }
                continue;
            }
            let dir: &[u8] = if base.is_empty() { b"." } else { base };
            let Ok(d) = File::open(dir) else { continue };
            let mut buf = [0u8; sys::NAME_MAX as usize + 1];
            let mut names = Vec::new();
            while let Ok(Some(name)) = d.read_name(&mut buf) {
                if name == b"." || name == b".." {
                    continue;
                }
                if name.first() == Some(&b'.') && part.first() != Some(&b'.') {
                    continue; // hidden, unless asked for
                }
                if matches(part, q, name) {
                    names.push(name.to_vec());
                }
            }
            names.sort();
            for name in names {
                let mut path = base.clone();
                path.extend_from_slice(&name);
                if last || trystd::fs::metadata(&path).is_ok_and(|m| m.is_dir()) {
                    next.push(path);
                }
            }
        }
        found = next;
        if last {
            break;
        }
        for path in found.iter_mut() {
            path.push(b'/');
        }
        start = end + 1;
    }
    found
}
