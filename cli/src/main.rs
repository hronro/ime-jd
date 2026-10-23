#![warn(clippy::all)]

use std::env;
use std::io;
use std::process::ExitCode;

pub use crossterm::terminal::size;

mod debug_mode;
mod renderer;
mod user_dict;

#[derive(Debug, Default, PartialEq, Eq)]
struct CliOptions {
    no_newline: bool,
    debug_mode: bool,
    help: bool,
    /// Path of a `value<TAB>keys` text file to load as the user dictionary.
    user_dict: Option<String>,
}

impl CliOptions {
    /// Parse the arguments after the program name. Anything unrecognised is
    /// an error: a mistyped flag must not silently run the CLI without it.
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut options = Self::default();
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--no-newline" => options.no_newline = true,
                "--debug" => options.debug_mode = true,
                "--help" | "-h" => options.help = true,
                "--user-dict" => match args.next() {
                    Some(path) => options.user_dict = Some(path),
                    None => return Err("--user-dict needs a file path".to_string()),
                },
                other => return Err(format!("unknown argument `{other}` (see --help)")),
            }
        }
        Ok(options)
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
        --user-dict <TXT_FILE_PATH>
                      Load a user dictionary: a UTF-8 text file of
                      `value<TAB>keys` lines, the format of core/tables/*.txt
                      (`#` comments and blank lines are ignored). Its phrases
                      are merged into every candidate list, ahead of built-in
                      words on the same code; exact duplicates of built-in
                      words are dropped. The compiled dictionary is cached in
                      the OS temp directory, keyed by the file's absolute path
                      and stamped with its modification time, and rebuilt when
                      the file changes or after a libjd update. A bad line is
                      reported with its number and the program exits with
                      status 2. Normal mode prints nothing else about it;
                      --debug prints a summary and, whenever the dictionary
                      is rebuilt, the dropped lines.

Tips:
    Pipe the output into your clipboard tool to copy the committed text
    directly:
        macOS:    jd-cli --no-newline | pbcopy
        Linux:    jd-cli --no-newline | wl-copy
        Windows:  chcp 65001 && jd-cli --no-newline | clip
                  (chcp 65001 forces the console to UTF-8 so non-ASCII
                  characters survive the pipe)
";

fn main() -> io::Result<ExitCode> {
    let cli_options = match CliOptions::parse(env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("jd-cli: {message}");
            return Ok(ExitCode::from(2));
        }
    };

    if cli_options.help {
        print!("{}", HELP);
        return Ok(ExitCode::SUCCESS);
    }

    let user_dict = cli_options.user_dict.as_deref();

    if cli_options.debug_mode {
        let mut stdout = io::stdout();
        return debug_mode::debug_mode(&mut stdout, user_dict);
    }

    let mut stderr = io::stderr();
    let (width, height) = size()?;
    let r = match renderer::Renderer::new((width, height), user_dict) {
        Ok(r) => r,
        Err(message) => {
            eprintln!("jd-cli: {message}");
            return Ok(ExitCode::from(2));
        }
    };
    if let Some(output) = r.render(&mut stderr)? {
        if cli_options.no_newline {
            print!("{output}");
        } else {
            println!("{output}");
        }
    }

    Ok(ExitCode::SUCCESS)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_known_flags() {
        let options =
            CliOptions::parse(args(&["--debug", "--user-dict", "x.txt", "--no-newline"])).unwrap();
        assert_eq!(
            options,
            CliOptions {
                no_newline: true,
                debug_mode: true,
                help: false,
                user_dict: Some("x.txt".to_string()),
            }
        );
        assert!(CliOptions::parse(args(&["-h"])).unwrap().help);
        assert_eq!(CliOptions::parse(args(&[])).unwrap(), CliOptions::default());
    }

    #[test]
    fn rejects_unknown_and_incomplete_flags() {
        assert!(CliOptions::parse(args(&["--user-dict"])).is_err());
        assert!(CliOptions::parse(args(&["--user-dict=x.txt"])).is_err());
        assert!(CliOptions::parse(args(&["--nope"])).is_err());
        assert!(CliOptions::parse(args(&["stray"])).is_err());
    }
}
