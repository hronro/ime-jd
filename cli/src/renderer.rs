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
    output_string: String,
    output: Output,
    input: String,
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
        }
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
                            return Ok(false);
                        }

                        'n' if modifiers == event::KeyModifiers::CONTROL => {
                            if self.input.is_empty() {
                                self.output.scroll_down(w)?;
                            } else {
                                let query_result = core::next_page();
                                if let Some(options) = query_result.options {
                                    self.draw_options(w, &options)?;
                                } else {
                                    self.draw_options(w, &[])?;
                                }
                            }
                        }

                        'p' if modifiers == event::KeyModifiers::CONTROL => {
                            if self.input.is_empty() {
                                self.output.scroll_up(w)?;
                            } else {
                                let query_result = core::prev_page();
                                if let Some(options) = query_result.options {
                                    self.draw_options(w, &options)?;
                                } else {
                                    self.draw_options(w, &[])?;
                                }
                            }
                        }

                        _ => {
                            let query_result = core::press_key(c as u8);

                            if let Some(commit) = query_result.commit {
                                self.output_string = format!("{}{}", self.output_string, commit);
                                self.output.push_unicode_char(commit.to_string(), w)?;

                                if let Some(options) = query_result.options {
                                    self.input = String::from(c);
                                    self.draw_options(w, &options)?;
                                } else {
                                    self.input = String::from("");
                                    self.draw_options(w, &[])?;
                                }
                            } else {
                                self.input = format!("{}{}", self.input, c);
                                if let Some(options) = query_result.options {
                                    self.draw_options(w, &options)?;
                                } else {
                                    self.draw_options(w, &[])?;
                                }
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
                            if let Some(options) = query_result.options {
                                self.draw_options(w, &options)?;
                            } else {
                                self.draw_options(w, &[])?;
                            }
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
            };
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

    pub fn push_unicode_char<W>(&mut self, uc: String, w: &mut W) -> Result<()>
    where
        W: Write,
    {
        let last_line = if let Some(line) = self.lines.last_mut() {
            line
        } else {
            self.lines.push(OutputLine::new(self.width));
            self.lines.last_mut().unwrap()
        };

        if let Some(new_line) = last_line.push_unicode_string(uc) {
            self.lines.push(new_line);
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
    width_remained: u16,
}
impl OutputLine {
    pub fn new(width: u16) -> Self {
        Self {
            content: String::new(),
            width,
            width_remained: width,
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn is_empty(&self) -> bool {
        self.content.is_empty()
    }

    pub fn push_unicode_string(&mut self, mut us: String) -> Option<Self> {
        let us_width = us.width();

        if us_width > self.width_remained as usize {
            loop {
                let uc = us.remove(0);

                let uc_width = uc.width().unwrap();

                if uc_width <= self.width_remained as usize {
                    self.content.push(uc);
                    self.width_remained -= uc_width as u16;
                } else {
                    let mut new_line_content = String::from(uc);
                    new_line_content.push_str(&us);
                    return Some(Self {
                        content: new_line_content,
                        width: self.width,
                        width_remained: self.width - us_width as u16,
                    });
                }
            }
        } else {
            self.content.push_str(&us);
            self.width_remained -= us_width as u16;
            None
        }
    }

    pub fn backspace(&mut self) {
        _ = self.content.pop();
    }
}
