#![warn(clippy::all)]

use std::env;
use std::io;

pub use crossterm::terminal::size;

mod core;
mod debug_mode;
mod renderer;

#[derive(Default)]
struct CliOptions {
    no_newline: bool,
    debug_mode: bool,
}
impl CliOptions {
    pub fn from_args(args: env::Args) -> Self {
        let mut options = Self::default();
        // skip self
        for arg in args.skip(1) {
            match arg.as_str() {
                "--no-newline" => options.no_newline = true,
                "--debug" => options.debug_mode = true,
                _ => {}
            }
        }
        options
    }
}

fn main() -> std::io::Result<()> {
    let cli_options = CliOptions::from_args(env::args());

    if cli_options.debug_mode {
        let mut stdout = io::stdout();
        debug_mode::debug_mode(&mut stdout)?;
    } else {
        let mut stderr = io::stderr();

        let (width, height) = size()?;

        let r = renderer::Renderer::new((width, height));

        if let Some(output) = r.render(&mut stderr)? {
            if cli_options.no_newline {
                print!("{output}");
            } else {
                println!("{output}");
            }
        }
    }

    Ok(())
}
