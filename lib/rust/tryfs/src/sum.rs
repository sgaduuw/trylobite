//! The sums that tell a damaged block from a good one: the superblock and
//! every node carry one, worked out over their words as
//! `s = s * FS_SUM_RADIX + w` from 0, kept within a word's range as a
//! 27-trit register would keep it, by adding or taking away 3^27. Two
//! is a unit modulo 3^27, so every word counts, wherever it is.

/// The largest word, (3^27 - 1) / 2.
pub const WORD_MAX: i64 = 3_812_798_742_493;
/// 3^27: the range a word wraps in.
const WRAP: i64 = 2 * WORD_MAX + 1;

/// The sum so far, `s`, with one more word `w`.
#[inline]
pub fn step(s: i64, w: i64) -> i64 {
    let mut t = s + s + w; // within 3 * WORD_MAX: one wrap brings it back
    if t > WORD_MAX {
        t -= WRAP;
    } else if t < -WORD_MAX {
        t += WRAP;
    }
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stays_within_a_word() {
        let mut s = 0;
        for w in [WORD_MAX, WORD_MAX, -WORD_MAX, 7, WORD_MAX, WORD_MAX, WORD_MAX] {
            s = step(s, w);
            assert!((-WORD_MAX..=WORD_MAX).contains(&s));
        }
    }

    #[test]
    fn notices_one_changed_word_anywhere() {
        let words: std::vec::Vec<i64> = (0..6561).map(|i| i * 7919 % 1000 - 500).collect();
        let sum = |ws: &[i64]| ws.iter().fold(0, |s, &w| step(s, w));
        let good = sum(&words);
        for at in [0, 1, 3279, 6560] {
            let mut bad = words.clone();
            bad[at] += 1;
            assert_ne!(sum(&bad), good, "a change at word {at} went unnoticed");
        }
    }
}
