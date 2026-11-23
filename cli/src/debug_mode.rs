use std::io::{Result, Write};
use std::process::ExitCode;
use std::time::Instant;

use crossterm::{event, terminal};

use crate::dicts::Dicts;

/// How many candidates the debug REPL prints per keystroke.
const WINDOW: u32 = 4;

/// `dicts` are `--dict` and `--user-dict`, loaded. The REPL is the one place
/// the engine's notes on them — skipped lines, dropped lines, and phrases on
/// shared codes — are listed.
pub fn debug_mode<W>(w: &mut W, dicts: &Dicts) -> Result<ExitCode>
where
    W: Write,
{
    // Printed before raw mode, so the lines come out as ordinary text.
    if let Some(dict) = &dicts.dict {
        writeln!(w, "Dict: {}", dict.summary())?;
        for (note, text) in &dict.notes {
            writeln!(w, "  {note}: {text}")?;
        }
    }
    if let Some(user) = &dicts.user {
        writeln!(w, "User dict: {}", user.summary())?;
        for (note, text) in &user.notes {
            writeln!(w, "  {note}: {text}")?;
        }
    }

    terminal::enable_raw_mode()?;
    // jd_init validates each blob it is given in one linear pass, so this
    // timing includes that.
    let init_start = Instant::now();
    let mut jd = dicts.context().expect("failed to initialize the jd engine");
    let init_elapsed = init_start.elapsed();
    let dict_note = match (&dicts.dict, &dicts.user) {
        (Some(_), Some(_)) => " (with dict and user dict)",
        (Some(_), None) => " (with dict)",
        (None, Some(_)) => " (with user dict)",
        (None, None) => "",
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
