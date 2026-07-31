use std::io::{Result, Write};
use std::time::Instant;

use crossterm::{event, terminal};

/// How many candidates the debug REPL prints per keystroke.
const WINDOW: u32 = 4;

pub fn debug_mode<W>(w: &mut W) -> Result<()>
where
    W: Write,
{
    terminal::enable_raw_mode()?;
    let init_start = Instant::now();
    let mut jd = jd::JdContext::new().expect("failed to initialize the jd engine");
    let init_elapsed = init_start.elapsed();
    write!(w, "Initialized in {:?}\n\r", init_elapsed)?;
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

    Ok(())
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
