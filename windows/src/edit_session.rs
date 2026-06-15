use std::cell::RefCell;

use windows::Win32::UI::TextServices::{ITfEditSession, ITfEditSession_Impl};
use windows::core::{Result, implement};

type EditCallback = Box<dyn FnOnce(u32) -> Result<()>>;

#[implement(ITfEditSession)]
pub struct EditSession {
    callback: RefCell<Option<EditCallback>>,
}

impl EditSession {
    pub fn new<F>(callback: F) -> Self
    where
        F: FnOnce(u32) -> Result<()> + 'static,
    {
        Self {
            callback: RefCell::new(Some(Box::new(callback))),
        }
    }
}

impl ITfEditSession_Impl for EditSession_Impl {
    fn DoEditSession(&self, ec: u32) -> Result<()> {
        let cb = self.callback.borrow_mut().take();
        match cb {
            Some(f) => f(ec),
            None => Ok(()),
        }
    }
}
