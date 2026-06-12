use std::io::{Result, Write};

use crossterm::{
    cursor, event, execute, queue,
    style::{Print, PrintStyledContent, StyledContent, Stylize},
    terminal,
};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::core;

/// The layout is like below:
/// ```
/// +--------------------------+
/// |                          |
/// |                          |
/// | output                   |
/// |                          |
/// |                          |
/// |                          |
/// +--------------------------+
/// |                          |
/// | options                  |
/// |                          |
/// |                          |
/// +--------------------------+
/// | input                    |
/// +--------------------------+
/// ```
pub struct Renderer {
    width: u16,
    height: u16,
    output_rows: u16,
    /// Height of the options/page area. Fixed for the session because the
    /// core's page size is set once at init and can't change, so on resize we
    /// keep this constant and let the output area absorb the height change.
    option_rows: u16,
    output_string: String,
    output: Output,
    input: String,
    /// The options currently displayed, retained so they can be redrawn after
    /// a resize without re-querying (and thus mutating) the core.
    current_options: Vec<core::QueryOption>,
}
impl Renderer {
    /// Please note that you can not initialize more than one instance of `Renderer`.
    pub fn new(size: (u16, u16)) -> Self {
        let (width, height) = size;
        let option_rows = ((height - 3) / 2 - 2).min(4);
        let output_rows = height - 4 - option_rows - 1;

        core::init(core::InitOptions {
            page_size: option_rows as u8,
        });

        Self {
            width,
            height,
            output_rows,
            option_rows,
            output_string: String::from(""),
            output: Output::new(
                width - 2,
                output_rows,
                1,
                "│".green(),
                width - 1,
                "│".green(),
            ),
            input: String::from(""),
            current_options: Vec::new(),
        }
    }

    /// Store the latest options and draw them. Used by every key handler so
    /// `current_options` always mirrors what's on screen (for resize redraws).
    fn update_options<W>(
        &mut self,
        w: &mut W,
        options: Option<Vec<core::QueryOption>>,
    ) -> Result<()>
    where
        W: Write,
    {
        self.current_options = options.unwrap_or_default();
        self.draw_options(w, &self.current_options)
    }

    /// Re-layout and redraw everything for a new terminal size.
    fn resize<W>(&mut self, w: &mut W, new_width: u16, new_height: u16) -> Result<()>
    where
        W: Write,
    {
        self.width = new_width;
        self.height = new_height;
        // Fixed 5 rows of chrome (top border, two separators, input, bottom
        // border) plus the options area; the rest is the output area.
        // saturating_sub keeps us panic-free on a transient tiny size.
        self.output_rows = new_height.saturating_sub(self.option_rows + 5);

        self.output.width = new_width.saturating_sub(2);
        self.output.height = self.output_rows;
        self.output.right_padding_x = new_width.saturating_sub(1);
        self.output.reflow(&self.output_string);

        execute!(w, terminal::Clear(terminal::ClearType::All))?;
        self.draw_borders(w)?;
        self.output.draw(w)?;
        self.draw_options(w, &self.current_options)?;
        self.draw_input(w)?;
        w.flush()?;

        Ok(())
    }

    /// Only draw horizontal borders and corners.
    /// Vertical borders are drawn in `Output`, `draw_options()` and `draw_input()`.
    fn draw_borders<W>(&self, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        let last_column_x = self.width - 1;
        let last_row_y = self.height - 1;
        for y in [0, self.output_rows + 1, self.height - 3, last_row_y] {
            if y == 0 {
                queue!(w, cursor::MoveTo(0, y), PrintStyledContent("╭".green()))?;
            } else if y == last_row_y {
                queue!(w, cursor::MoveTo(0, y), PrintStyledContent("╰".green()))?;
            } else {
                queue!(w, cursor::MoveTo(0, y), PrintStyledContent("├".green()))?;
            }
            for x in 1..(self.width - 1) {
                queue!(w, cursor::MoveTo(x, y), PrintStyledContent("─".green()))?;
            }
            if y == 0 {
                queue!(
                    w,
                    cursor::MoveTo(last_column_x, y),
                    PrintStyledContent("╮".green())
                )?;
            } else if y == last_row_y {
                queue!(
                    w,
                    cursor::MoveTo(last_column_x, y),
                    PrintStyledContent("╯".green())
                )?;
            } else {
                queue!(
                    w,
                    cursor::MoveTo(last_column_x, y),
                    PrintStyledContent("┤".green())
                )?;
            }
        }

        Ok(())
    }

    fn draw_options<W>(&self, w: &mut W, options: &[core::QueryOption]) -> Result<()>
    where
        W: Write,
    {
        let option_first_row_y = self.output_rows + 2;
        let option_last_row_y = self.height - 4;

        for (index, y) in (option_first_row_y..=option_last_row_y).enumerate() {
            queue!(
                w,
                cursor::MoveTo(0, y),
                terminal::Clear(terminal::ClearType::CurrentLine),
                PrintStyledContent("│".green())
            )?;
            if let Some(option) = options.get(index) {
                let option_string = format!(
                    "[{}] {}{}",
                    index + 1,
                    option.value,
                    if let Some(hint) = option.hint {
                        format!(" 〔{hint}〕")
                    } else {
                        String::from("")
                    }
                );
                queue!(w, Print(option_string))?;
            }
            queue!(
                w,
                cursor::MoveTo(self.width - 1, y),
                PrintStyledContent("│".green())
            )?;
        }
        Ok(())
    }

    fn draw_input<W>(&self, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        queue!(
            w,
            cursor::MoveTo(0, self.height - 2),
            terminal::Clear(terminal::ClearType::CurrentLine),
            PrintStyledContent("│".green()),
            Print(&self.input),
            cursor::MoveTo(self.width - 1, self.height - 2),
            PrintStyledContent("│".green()),
        )?;
        Ok(())
    }

    pub fn render<W>(mut self, w: &mut W) -> Result<Option<String>>
    where
        W: Write,
    {
        execute!(
            w,
            terminal::EnterAlternateScreen,
            cursor::Hide,
            terminal::Clear(terminal::ClearType::All)
        )?;
        terminal::enable_raw_mode()?;
        self.draw_borders(w)?;
        self.output.draw(w)?;
        self.draw_options(w, &[])?;
        self.draw_input(w)?;
        w.flush()?;

        let should_commit_output = self.handle_input(w)?;

        execute!(w, cursor::Show, terminal::LeaveAlternateScreen)?;
        terminal::disable_raw_mode()?;

        if should_commit_output {
            Ok(Some(self.output_string.clone()))
        } else {
            Ok(None)
        }
    }

    /// Return whether to commit the output.
    fn handle_input<W>(&mut self, w: &mut W) -> Result<bool>
    where
        W: Write,
    {
        loop {
            match event::read()? {
                event::Event::Key(event::KeyEvent {
                    code: key_code,
                    kind: event::KeyEventKind::Press,
                    modifiers,
                    state: _,
                }) => {
                    match key_code {
                        event::KeyCode::Char(c) => match c {
                            'c' | 'q' if modifiers == event::KeyModifiers::CONTROL => {
                                return Ok(false);
                            }

                            'n' if modifiers == event::KeyModifiers::CONTROL => {
                                if self.input.is_empty() {
                                    self.output.scroll_down(w)?;
                                } else {
                                    let query_result = core::next_page();
                                    self.update_options(w, query_result.options)?;
                                }
                            }

                            'p' if modifiers == event::KeyModifiers::CONTROL => {
                                if self.input.is_empty() {
                                    self.output.scroll_up(w)?;
                                } else {
                                    let query_result = core::prev_page();
                                    self.update_options(w, query_result.options)?;
                                }
                            }

                            _ => {
                                let query_result = core::press_key(c as u8);

                                if let Some(commit) = query_result.commit {
                                    self.output_string.push_str(commit);
                                    self.output.push_unicode_char(commit, w)?;

                                    self.input = if query_result.options.is_some() {
                                        String::from(c)
                                    } else {
                                        String::new()
                                    };
                                    self.update_options(w, query_result.options)?;
                                } else {
                                    self.input = format!("{}{}", self.input, c);
                                    self.update_options(w, query_result.options)?;
                                }
                                self.draw_input(w)?;
                            }
                        },
                        event::KeyCode::Backspace => {
                            if self.input.is_empty() {
                                _ = self.output_string.pop();
                                self.output.backspace(w)?;
                            } else {
                                _ = self.input.pop();
                                self.draw_input(w)?;
                                let query_result = core::backspace();
                                self.update_options(w, query_result.options)?;
                            }
                        }
                        event::KeyCode::Esc => {
                            return Ok(false);
                        }
                        event::KeyCode::Enter => {
                            return Ok(true);
                        }
                        _ => {}
                    }
                    w.flush()?;
                }
                event::Event::Resize(new_width, new_height) => {
                    self.resize(w, new_width, new_height)?;
                }
                _ => {}
            }
        }
    }
}
impl Drop for Renderer {
    fn drop(&mut self) {
        core::deinit();
    }
}

#[derive(Debug)]
struct Output {
    width: u16,
    height: u16,
    top_padding: u16,
    left_padding_content: StyledContent<&'static str>,
    right_padding_x: u16,
    right_padding_content: StyledContent<&'static str>,
    scrolled_up_lines: u16,
    lines: Vec<OutputLine>,
}
impl Output {
    pub fn new(
        width: u16,
        height: u16,
        top_padding: u16,
        left_padding_content: StyledContent<&'static str>,
        right_padding_x: u16,
        right_padding_content: StyledContent<&'static str>,
    ) -> Self {
        Self {
            width,
            height,
            top_padding,
            left_padding_content,
            right_padding_x,
            right_padding_content,
            scrolled_up_lines: 0,
            lines: Vec::new(),
        }
    }

    fn displayed_lines(&self) -> &[OutputLine] {
        if self.lines.len() <= self.height as usize {
            &self.lines
        } else {
            let start = self.lines.len() - self.height as usize - self.scrolled_up_lines as usize;
            let end = self.lines.len() - 1 - self.scrolled_up_lines as usize;
            &self.lines[start..=end]
        }
    }

    pub fn draw<W>(&self, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        let lines = self.displayed_lines();

        for i in 0..(self.height as usize) {
            if let Some(line) = lines.get(i) {
                queue!(
                    w,
                    cursor::MoveTo(0, self.top_padding + i as u16),
                    terminal::Clear(terminal::ClearType::CurrentLine),
                    PrintStyledContent(self.left_padding_content),
                    Print(line.content()),
                    cursor::MoveTo(self.right_padding_x, self.top_padding + i as u16),
                    PrintStyledContent(self.right_padding_content),
                )?;
            } else {
                queue!(
                    w,
                    cursor::MoveTo(0, self.top_padding + i as u16),
                    terminal::Clear(terminal::ClearType::CurrentLine),
                    PrintStyledContent(self.left_padding_content),
                    cursor::MoveTo(self.right_padding_x, self.top_padding + i as u16),
                    PrintStyledContent(self.right_padding_content),
                )?;
            }
        }

        Ok(())
    }

    fn draw_last_line<W>(&self, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        let lines = self.displayed_lines();
        let last_line = lines.last().unwrap();

        queue!(
            w,
            cursor::MoveTo(0, self.top_padding + lines.len() as u16 - 1),
            terminal::Clear(terminal::ClearType::CurrentLine),
            PrintStyledContent(self.left_padding_content),
            Print(last_line.content()),
            cursor::MoveTo(
                self.right_padding_x,
                self.top_padding + lines.len() as u16 - 1
            ),
            PrintStyledContent(self.right_padding_content),
        )
    }

    /// Append a unicode string to the output, wrapping across as many lines
    /// as needed. Returns `true` if at least one new line was created.
    /// Assumes `self.lines` is non-empty.
    fn append_unicode_string(&mut self, s: &str) -> bool {
        let mut created_new_line = false;
        let mut rest = s.to_string();

        loop {
            let last_line = self.lines.last_mut().unwrap();
            match last_line.push_unicode_string(&rest) {
                None => break,
                Some(overflow) => {
                    if overflow.is_empty() {
                        break;
                    }
                    self.lines.push(OutputLine::new(self.width));
                    created_new_line = true;
                    rest = overflow;
                }
            }
        }

        created_new_line
    }

    /// Rebuild the wrapped lines from the full committed text using the
    /// current width. Used when the terminal is resized and existing lines
    /// have to be re-flowed.
    fn reflow(&mut self, source: &str) {
        self.lines.clear();
        self.scrolled_up_lines = 0;
        if !source.is_empty() {
            self.lines.push(OutputLine::new(self.width));
            self.append_unicode_string(source);
        }
    }

    pub fn push_unicode_char<W>(&mut self, uc: &str, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        if self.lines.is_empty() {
            self.lines.push(OutputLine::new(self.width));
        }

        let created_new_line = self.append_unicode_string(uc);

        if created_new_line {
            self.scrolled_up_lines = 0;
            self.draw(w)?;
        } else if self.scrolled_up_lines == 0 {
            self.draw_last_line(w)?;
        } else {
            self.scrolled_up_lines = 0;
            self.draw(w)?;
        }

        Ok(())
    }

    pub fn backspace<W>(&mut self, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        if let Some(last_line) = self.lines.last_mut() {
            last_line.backspace();

            if last_line.is_empty() {
                _ = self.lines.pop();
                self.scrolled_up_lines = 0;
                self.draw(w)?;
            } else if self.scrolled_up_lines == 0 {
                self.draw_last_line(w)?;
            } else {
                self.scrolled_up_lines = 0;
                self.draw(w)?;
            }
        }

        Ok(())
    }

    pub fn scroll_up<W>(&mut self, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        if self.lines.len() as u16 > self.height
            && self.scrolled_up_lines < (self.lines.len() as u16 - self.height)
        {
            self.scrolled_up_lines += 1;
            self.draw(w)?;
        }

        Ok(())
    }

    pub fn scroll_down<W>(&mut self, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        if self.scrolled_up_lines > 0 {
            self.scrolled_up_lines -= 1;
            self.draw(w)?;
        }

        Ok(())
    }
}

#[derive(Debug)]
struct OutputLine {
    content: String,
    width: u16,
}
impl OutputLine {
    pub fn new(width: u16) -> Self {
        Self {
            content: String::new(),
            width,
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn is_empty(&self) -> bool {
        self.content.is_empty()
    }

    /// Columns still available on this line. Derived from the actual content
    /// width so it can never drift out of sync with what was pushed.
    fn remaining_width(&self) -> usize {
        (self.width as usize).saturating_sub(self.content.width())
    }

    /// Append as many leading characters of `s` as fit in the remaining
    /// width. Returns `None` if the whole string fit, or `Some(rest)` with
    /// the characters that didn't fit so the caller can wrap them onto a new
    /// line.
    ///
    /// If this line is empty and even the first character is wider than a
    /// full line (a terminal narrower than a single wide glyph), that
    /// character is placed anyway so wrapping always makes progress.
    pub fn push_unicode_string(&mut self, s: &str) -> Option<String> {
        let mut remaining = self.remaining_width();
        let mut split_at: Option<usize> = None;

        for (idx, ch) in s.char_indices() {
            let char_width = ch.width().unwrap_or(0);
            if char_width <= remaining {
                remaining -= char_width;
            } else if idx == 0 && self.content.is_empty() {
                // Degenerate case: the first glyph is wider than an empty
                // line. Place just this glyph and wrap the rest.
                split_at = Some(idx + ch.len_utf8());
                break;
            } else {
                split_at = Some(idx);
                break;
            }
        }

        match split_at {
            None => {
                self.content.push_str(s);
                None
            }
            Some(at) => {
                self.content.push_str(&s[..at]);
                Some(s[at..].to_string())
            }
        }
    }

    pub fn backspace(&mut self) {
        _ = self.content.pop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_output(width: u16) -> Output {
        Output::new(width, 100, 1, "│".green(), width + 1, "│".green())
    }

    fn line_contents(out: &Output) -> Vec<&str> {
        out.lines.iter().map(|l| l.content()).collect()
    }

    /// The original bug: after a multi-glyph commit wrapped, the new line's
    /// remaining width was mis-computed from the *whole* commit, so later
    /// glyphs wrapped early even with space left.
    #[test]
    fn wide_char_does_not_wrap_when_it_fits() {
        // width 6 == three CJK glyphs per line.
        let mut out = make_output(6);
        out.reflow("中中中中"); // four glyphs: 3 on line 1, 1 on line 2
        assert_eq!(line_contents(&out), vec!["中中中", "中"]);
        assert_eq!(out.lines[1].remaining_width(), 4);

        // One more glyph has room on line 2 and must not start a new line.
        out.append_unicode_string("中");
        assert_eq!(line_contents(&out), vec!["中中中", "中中"]);
    }

    /// Re-flowing the full text (resize path) must match glyph-by-glyph
    /// incremental pushing (typing path).
    #[test]
    fn reflow_matches_incremental_push() {
        let text = "你好world世界abc中";
        for width in [4u16, 5, 6, 7, 10] {
            let mut incremental = make_output(width);
            incremental.lines.push(OutputLine::new(width));
            for ch in text.chars() {
                incremental.append_unicode_string(&ch.to_string());
            }
            let mut reflowed = make_output(width);
            reflowed.reflow(text);
            assert_eq!(
                line_contents(&incremental),
                line_contents(&reflowed),
                "mismatch at width {width}"
            );
        }
    }

    #[test]
    fn mixed_width_fills_line_exactly() {
        // width 5: "ab" (2) + "中" (2) + "c" (1) == 5, exactly full.
        let mut out = make_output(5);
        out.reflow("ab中c");
        assert_eq!(line_contents(&out), vec!["ab中c"]);
        assert_eq!(out.lines[0].remaining_width(), 0);
    }

    /// A glyph wider than the whole line is force-placed one per line so
    /// wrapping always terminates (no infinite loop, no trailing blank line).
    #[test]
    fn glyph_wider_than_line_still_progresses() {
        let mut out = make_output(1);
        out.reflow("中中");
        assert_eq!(line_contents(&out), vec!["中", "中"]);
    }
}
