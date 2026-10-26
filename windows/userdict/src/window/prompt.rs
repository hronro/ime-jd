//! The window's questions and notices, as task dialogs: the system's own
//! message box, with a main instruction, a body, and buttons named for what
//! they do.

use windows::Win32::Foundation::HWND;
use windows::Win32::UI::Controls::{
    TASKDIALOG_BUTTON, TASKDIALOGCONFIG, TASKDIALOGCONFIG_0, TD_ERROR_ICON, TD_INFORMATION_ICON,
    TD_WARNING_ICON, TDF_ALLOW_DIALOG_CANCELLATION, TDF_POSITION_RELATIVE_TO_WINDOW,
    TaskDialogIndirect,
};
use windows::Win32::UI::WindowsAndMessaging::{IDCANCEL, IDOK};
use windows::core::{HSTRING, PCWSTR};

use super::TITLE;

/// The answer Escape, Alt+F4 and the close box give.
pub const CANCEL: i32 = IDCANCEL.0;
/// The single 好 of a notice.
pub const OK: i32 = IDOK.0;

#[derive(Clone, Copy)]
pub enum Icon {
    Information,
    Warning,
    Error,
}

/// Ask, with `buttons` as `(id, label)` pairs, the first one the default.
/// Returns the id chosen — [`CANCEL`] when the dialog is dismissed, or
/// could not be shown at all.
pub fn ask(owner: HWND, icon: Icon, instruction: &str, content: &str, buttons: &[(i32, &str)]) -> i32 {
    let labels: Vec<HSTRING> = buttons.iter().map(|&(_, label)| HSTRING::from(label)).collect();
    let buttons: Vec<TASKDIALOG_BUTTON> = buttons
        .iter()
        .zip(&labels)
        .map(|(&(id, _), label)| TASKDIALOG_BUTTON {
            nButtonID: id,
            pszButtonText: PCWSTR(label.as_ptr()),
        })
        .collect();
    let title = HSTRING::from(TITLE);
    let instruction = HSTRING::from(instruction);
    let content = HSTRING::from(content);
    let config = TASKDIALOGCONFIG {
        cbSize: size_of::<TASKDIALOGCONFIG>() as u32,
        hwndParent: owner,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW,
        pszWindowTitle: PCWSTR(title.as_ptr()),
        Anonymous1: TASKDIALOGCONFIG_0 {
            pszMainIcon: match icon {
                Icon::Information => TD_INFORMATION_ICON,
                Icon::Warning => TD_WARNING_ICON,
                Icon::Error => TD_ERROR_ICON,
            },
        },
        pszMainInstruction: PCWSTR(instruction.as_ptr()),
        pszContent: PCWSTR(content.as_ptr()),
        cButtons: buttons.len() as u32,
        pButtons: buttons.as_ptr(),
        nDefaultButton: buttons.first().map_or(0, |button| button.nButtonID),
        ..Default::default()
    };
    let mut chosen = CANCEL;
    // SAFETY: every string and the button array outlive the modal call.
    if unsafe { TaskDialogIndirect(&config, Some(&mut chosen), None, None) }.is_err() {
        return CANCEL;
    }
    chosen
}

/// A notice with a single 好.
pub fn tell(owner: HWND, icon: Icon, instruction: &str, content: &str) {
    ask(owner, icon, instruction, content, &[(OK, "好")]);
}
