use std::io::{Result, Write};
use std::time::Instant;

use crossterm::{event, terminal};

pub fn debug_mode<W>(w: &mut W) -> Result<()>
where
    W: Write,
{
    terminal::enable_raw_mode()?;
    let init_start = Instant::now();
    let mut jd = jd::JdContext::new(4).expect("failed to initialize the jd engine");
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
                        let press_start = Instant::now();
                        let query_result = jd.press_key(c as u8);
                        let press_elapsed = press_start.elapsed();

                        write!(
                            w,
                            "Pressed `{}` (handled in {:?}):\n{:?}\n\n\n\r",
                            c, press_elapsed, query_result
                        )?;
                    }
                },
                event::KeyCode::Backspace => {
                    let query_result = jd.backspace();
                    write!(w, "Pressed backspace:\n{:?}\n\n\n\r", query_result)?;
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
