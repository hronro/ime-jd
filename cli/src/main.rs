#![warn(clippy::all)]

use std::env;
use std::io;
use std::process::ExitCode;

pub use crossterm::terminal::size;

mod debug_mode;
mod dicts;
mod lookup;
mod renderer;

#[derive(Debug, Default, PartialEq, Eq)]
struct CliOptions {
    no_newline: bool,
    debug_mode: bool,
    help: bool,
    /// Path of a `value<TAB>keys` text file to type from in place of the
    /// built-in dictionary.
    dict: Option<String>,
    /// Path of a `value<TAB>keys` text file to load as the user dictionary.
    user_dict: Option<String>,
    /// A candidate whose codes to print, instead of running the prompt.
    lookup: Option<String>,
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
                "--dict" => match args.next() {
                    Some(path) => options.dict = Some(path),
                    None => return Err("--dict needs a file path".to_string()),
                },
                "--user-dict" => match args.next() {
                    Some(path) => options.user_dict = Some(path),
                    None => return Err("--user-dict needs a file path".to_string()),
                },
                "--lookup" => match args.next() {
                    _ if options.lookup.is_some() => {
                        return Err("--lookup takes one candidate".to_string());
                    }
                    Some(candidate) if !candidate.is_empty() => options.lookup = Some(candidate),
                    _ => return Err("--lookup needs a candidate".to_string()),
                },
                other => return Err(format!("unknown argument `{other}` (see --help)")),
            }
        }
        if options.lookup.is_some() && options.debug_mode {
            return Err("--lookup and --debug cannot be used together".to_string());
        }
        Ok(options)
    }
}

const HELP: &str = "\
jd-cli — terminal front-end for the jd input method

Launches an interactive prompt: type to query, navigate the candidate list,
and press Enter to commit. The committed text is written to stdout; the
interactive UI is drawn on stderr so the output can be piped or captured.
With --lookup it prints the codes of a candidate instead, and exits.

Usage:
    jd-cli [OPTIONS]
    jd-cli --lookup <CANDIDATE> [--dict <TXT_FILE_PATH>]
                                [--user-dict <TXT_FILE_PATH>] [--no-newline]

Options:
    -h, --help        Print this help message and exit
        --debug       Run an interactive REPL that prints raw core query
                      results and per-keypress timing. Useful for inspecting
                      the IME core's behavior
        --dict <TXT_FILE_PATH>
                      Type from this dictionary instead of the built-in one:
                      a UTF-8 text file of `value<TAB>keys` lines, the format
                      of core/tables/*.txt (`cat core/tables/*.txt` is the
                      built-in dictionary itself), up to 16 777 215 entries.
                      The words on a code are its candidates in the order of
                      their lines. A line that does not parse is skipped and
                      an exact repeat of an earlier line dropped. It is
                      cached as --user-dict is, and is reported and ends the
                      program with status 2 the same way when it cannot be
                      loaded. An empty file means no dictionary at all, so
                      with --user-dict only its phrases are typed
        --lookup <CANDIDATE>
                      Print every code that types CANDIDATE, one per line,
                      shortest first, and exit. A code on which CANDIDATE
                      is the first candidate stands alone; any other is
                      followed by a TAB and which candidate it is there,
                      e.g. `o<TAB>candidate 2`. With --dict, the codes are
                      that dictionary's. With --user-dict, its codes are
                      included and marked `user dict`, and its phrases
                      count toward the candidate numbers. When nothing types
                      CANDIDATE it prints `CANDIDATE: not found`. Exits with
                      status 0 when found, 1 when not found, 2 on an error
        --no-newline  Do not append a trailing newline to the committed
                      output on stdout (with --lookup, to its last line)
        --user-dict <TXT_FILE_PATH>
                      Load a user dictionary: a UTF-8 text file of
                      `value<TAB>keys` lines, the format of core/tables/*.txt
                      (`#` comments and blank lines are ignored). Its phrases
                      are merged into every candidate list, ahead of the
                      dictionary's words on the same code (the built-in
                      dictionary's, or --dict's); exact duplicates of the
                      dictionary's words are dropped, and a line that does
                      not parse is skipped. The compiled dictionary is cached
                      in the OS temp directory, keyed by the file's absolute
                      path (and --dict's) and stamped with its modification
                      time, and rebuilt when the file or --dict changes or
                      after a libjd update. A file that
                      cannot be loaded at all is reported and the program
                      exits with status 2. Normal mode prints nothing else
                      about either file; --debug prints a summary of each
                      and, whenever one is rebuilt, its skipped and dropped
                      lines.

Tips:
    `cut -f1` keeps just the codes of --lookup, and `head -1` the shortest:
        jd-cli --lookup 键道 | head -1 | cut -f1
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

    let dicts = match dicts::Dicts::load(
        cli_options.dict.as_deref(),
        cli_options.user_dict.as_deref(),
    ) {
        Ok(dicts) => dicts,
        Err(message) => {
            eprintln!("jd-cli: {message}");
            return Ok(ExitCode::from(2));
        }
    };

    if let Some(candidate) = &cli_options.lookup {
        let jd = dicts.context().expect("failed to initialize the jd engine");
        let mut stdout = io::stdout();
        return lookup::run(&mut stdout, &jd, candidate, cli_options.no_newline);
    }

    if cli_options.debug_mode {
        let mut stdout = io::stdout();
        return debug_mode::debug_mode(&mut stdout, &dicts);
    }

    let mut stderr = io::stderr();
    let (width, height) = size()?;
    let jd = dicts.context().expect("failed to initialize the jd engine");
    let r = renderer::Renderer::new((width, height), jd);
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
                dict: None,
                user_dict: Some("x.txt".to_string()),
                lookup: None,
            }
        );
        let options =
            CliOptions::parse(args(&["--dict", "d.txt", "--user-dict", "x.txt"])).unwrap();
        assert_eq!(options.dict.as_deref(), Some("d.txt"));
        assert_eq!(options.user_dict.as_deref(), Some("x.txt"));
        let options =
            CliOptions::parse(args(&["--lookup", "键道", "--user-dict", "x.txt"])).unwrap();
        assert_eq!(options.lookup.as_deref(), Some("键道"));
        assert_eq!(options.user_dict.as_deref(), Some("x.txt"));
        assert!(CliOptions::parse(args(&["-h"])).unwrap().help);
        assert_eq!(CliOptions::parse(args(&[])).unwrap(), CliOptions::default());
    }

    #[test]
    fn rejects_unknown_and_incomplete_flags() {
        assert!(CliOptions::parse(args(&["--user-dict"])).is_err());
        assert!(CliOptions::parse(args(&["--dict"])).is_err());
        assert!(CliOptions::parse(args(&["--user-dict=x.txt"])).is_err());
        assert!(CliOptions::parse(args(&["--nope"])).is_err());
        assert!(CliOptions::parse(args(&["stray"])).is_err());
        assert!(CliOptions::parse(args(&["--lookup"])).is_err());
        assert!(CliOptions::parse(args(&["--lookup", ""])).is_err());
        assert!(CliOptions::parse(args(&["--lookup", "甲", "--lookup", "乙"])).is_err());
        assert!(CliOptions::parse(args(&["--lookup", "甲", "--debug"])).is_err());
    }
}
