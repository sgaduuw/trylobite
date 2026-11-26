//! rmandel: the Mandelbrot set in characters, worked out in Rust's f32,
//! which detrytus does in software (compiler_builtins' floating point).
#![no_std]

use trystd::prelude::*;

trystd::main!(run);

const COLS: i32 = 40;
const ROWS: i32 = 13;
const STEPS: u32 = 24;

/// How many steps z = z² + c takes to leave the circle of radius 2,
/// up to STEPS.
fn escape(cr: f32, ci: f32) -> u32 {
    let (mut zr, mut zi) = (0.0f32, 0.0f32);
    for n in 0..STEPS {
        let (rr, ii) = (zr * zr, zi * zi);
        if rr + ii > 4.0 {
            return n;
        }
        zi = 2.0 * zr * zi + ci;
        zr = rr - ii + cr;
    }
    STEPS
}

fn run() -> io::Result<()> {
    let shades = b" .:-=+*%#@";
    let mut line = [0u8; COLS as usize + 1];
    for row in 0..ROWS {
        let ci = 1.2 - 2.4 * row as f32 / (ROWS - 1) as f32;
        for col in 0..COLS {
            let cr = -2.1 + 2.8 * col as f32 / (COLS - 1) as f32;
            let n = escape(cr, ci);
            line[col as usize] = if n == STEPS {
                b'@'
            } else {
                shades[(n as usize * (shades.len() - 1) / STEPS as usize).min(shades.len() - 2)]
            };
        }
        line[COLS as usize] = b'\n';
        io::stdout().write_all(&line)?;
    }
    Ok(())
}
