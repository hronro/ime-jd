#![warn(clippy::all)]

use std::env;
use std::io;

pub use crossterm::terminal::size;

mod debug_mode;
mod renderer;

#[derive(Default)]
struct CliOptions {
    no_newline: bool,
    debug_mode: bool,
    help: bool,
}
impl CliOptions {
    pub fn from_args(args: env::Args) -> Self {
        let mut options = Self::default();
        // skip self
        for arg in args.skip(1) {
            match arg.as_str() {
                "--no-newline" => options.no_newline = true,
                "--debug" => options.debug_mode = true,
                "--help" | "-h" => options.help = true,
                _ => {}
            }
        }
        options
    }
}

const HELP: &str = "\
jd-cli — terminal front-end for the jd input method

Launches an interactive prompt: type to query, navigate the candidate list,
and press Enter to commit. The committed text is written to stdout; the
interactive UI is drawn on stderr so the output can be piped or captured.

Usage:
    jd-cli [OPTIONS]

Options:
    -h, --help        Print this help message and exit
        --debug       Run an interactive REPL that prints raw core query
                      results and per-keypress timing. Useful for inspecting
                      the IME core's behavior
        --no-newline  Do not append a trailing newline to the committed
                      output on stdout

Tips:
    Pipe the output into your clipboard tool to copy the committed text
    directly:
        macOS:    jd-cli --no-newline | pbcopy
        Linux:    jd-cli --no-newline | wl-copy
        Windows:  chcp 65001 && jd-cli --no-newline | clip
                  (chcp 65001 forces the console to UTF-8 so non-ASCII
                  characters survive the pipe)
";

fn main() -> std::io::Result<()> {
    let cli_options = CliOptions::from_args(env::args());

    if cli_options.help {
        print!("{}", HELP);
        return Ok(());
    }

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
