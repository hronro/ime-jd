use windows::core::GUID;

pub const CLSID_JD_IME: GUID = GUID::from_u128(0x820f6a70_6057_480c_898d_031fb7b1f79b);
pub const GUID_JD_PROFILE: GUID = GUID::from_u128(0x1df29577_b990_4579_897b_fe6e4b15ea83);

#[allow(dead_code)]
pub const GUID_JD_DISPLAY_ATTRIBUTE: GUID =
    GUID::from_u128(0x59775ca8_b5ab_4b07_a8d8_bac8d4f67074);

// Simplified Chinese (PRC) — matches the simplified-character tables under core/src/tables/.
pub const LANGID_ZH_CN: u16 = 0x0804;
pub const IME_DESCRIPTION: &str = "键道";
