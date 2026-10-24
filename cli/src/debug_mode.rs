use std::io::{Result, Write};
use std::process::ExitCode;
use std::time::Instant;

use crossterm::{event, terminal};

use crate::user_dict;

/// How many candidates the debug REPL prints per keystroke.
const WINDOW: u32 = 4;

/// `user_dict` is the path of a `value<TAB>keys` text file whose phrases are
/// merged into every candidate list. The REPL is the one place the engine's
/// notes — skipped lines, dropped lines, and phrases on shared codes — are
/// listed. A dictionary that cannot be loaded ends the run with exit status 2.
pub fn debug_mode<W>(w: &mut W, user_dict: Option<&str>) -> Result<ExitCode>
where
    W: Write,
{
    // Loaded before raw mode, so its lines print as ordinary text.
    let loaded = match user_dict {
        Some(path) => match user_dict::load(path) {
            Ok(loaded) => Some(loaded),
            Err(message) => {
                eprintln!("jd-cli: user dict: {message}");
                return Ok(ExitCode::from(2));
            }
        },
        None => None,
    };
    if let Some(loaded) = &loaded {
        writeln!(w, "User dict: {}", loaded.summary())?;
        for (note, text) in &loaded.notes {
            writeln!(w, "  {note}: {text}")?;
        }
    }

    terminal::enable_raw_mode()?;
    // jd_init validates the user dictionary blob in one linear pass, so
    // this timing includes it when one is loaded.
    let init_start = Instant::now();
    let mut jd = match &loaded {
        Some(loaded) => jd::JdContext::with_user_dict(loaded.dict),
        None => jd::JdContext::new(),
    }
    .expect("failed to initialize the jd engine");
    let init_elapsed = init_start.elapsed();
    let dict_note = if loaded.is_some() {
        " (with user dict)"
    } else {
        ""
    };
    write!(w, "Initialized in {:?}{}\n\r", init_elapsed, dict_note)?;
    w.flush()?;

    loop {
        if let event::Event::Key(event::KeyEvent {
            code: key_code,
            kind: event::KeyEventKind::Press,
            modifiers,
            state: _,
        }) = event::read()?
        {
            match key_code {
                event::KeyCode::Char(c) => match c {
                    'c' | 'q' if modifiers == event::KeyModifiers::CONTROL => {
                        break;
                    }
                    _ => {
                        // Time the engine call alone; reading the state and the
                        // candidate window is timed separately, since a real
                        // frontend only reads what it draws.
                        let press_start = Instant::now();
                        jd.press_key(c as u8);
                        let press_elapsed = press_start.elapsed();

                        let read_start = Instant::now();
                        let window = jd.candidates(0, WINDOW);
                        let read_elapsed = read_start.elapsed();

                        write!(
                            w,
                            "Pressed `{}` (key {:?}, read {:?}):\n{}\n\n\r",
                            c,
                            press_elapsed,
                            read_elapsed,
                            describe(&jd, &window)
                        )?;
                    }
                },
                event::KeyCode::Backspace => {
                    jd.backspace();
                    let window = jd.candidates(0, WINDOW);
                    write!(w, "Pressed backspace:\n{}\n\n\r", describe(&jd, &window))?;
                }
                event::KeyCode::Esc => break,
                event::KeyCode::Enter => break,
                _ => {}
            }
            w.flush()?;
        };
    }

    terminal::disable_raw_mode()?;

    Ok(ExitCode::SUCCESS)
}

fn describe(jd: &jd::JdContext, window: &[jd::Candidate]) -> String {
    let state = jd.state();
    let mut out = String::new();
    out.push_str(&format!(
        "  commit: {}\n\r  options_count: {}, anchor_index: {}\n\r",
        match jd.commit() {
            Some(c) => format!("{c:?} = {c}"),
            None => "none".to_string(),
        },
        state.options_count,
        state.anchor_index,
    ));
    for (i, cand) in window.iter().enumerate() {
        out.push_str(&format!(
            "  [{}] {}{}\n\r",
            i,
            cand.value(),
            match cand.hint() {
                Some(h) => format!(" 〔{h}〕"),
                None => String::new(),
            }
        ));
    }
    if window.is_empty() {
        out.push_str("  (no candidates)\n\r");
    }
    out
}
