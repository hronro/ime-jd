#![warn(clippy::all)]

use std::env;
use std::io;

pub use crossterm::terminal::size;

mod core;
mod debug_mode;
mod renderer;

fn main() -> std::io::Result<()> {
    let args: Vec<String> = env::args().collect();
    // skip self
    let args = &args[1..];

    if args.iter().any(|arg| arg == "--debug") {
        let mut stdout = io::stdout();
        debug_mode::debug_mode(&mut stdout)?;
    } else {
        let mut stdout = io::stdout();

        let (width, height) = size()?;

        let r = renderer::Renderer::new((width, height));

        if let Some(output) = r.render(&mut stdout)? {
            println!("{output}");
        }
    }

    Ok(())
}
