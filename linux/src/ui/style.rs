//! The Round Robin "Stream" look on libadwaita: the Midnight Aurora palette of macos BrandTheme.swift and the Windows
//! theme (windows/src/Bridgey.App/Theme/Brand.xaml), as libadwaita's named colours, so every standard widget follows
//! it. Light and dark follow the system unless Settings > App > Appearance says otherwise. Headings use Space Grotesk
//! (OFL), shipped with the app.

use gtk::gdk;

const LIGHT: &str = r#"
@define-color accent_color #006685;
@define-color accent_bg_color #006685;
@define-color accent_fg_color #ffffff;
@define-color window_bg_color #f4f7fa;
@define-color window_fg_color #050b18;
@define-color view_bg_color #ffffff;
@define-color view_fg_color #050b18;
@define-color headerbar_bg_color #f4f7fa;
@define-color headerbar_fg_color #050b18;
@define-color card_bg_color #ffffff;
@define-color card_fg_color #050b18;
@define-color dialog_bg_color #f4f7fa;
@define-color popover_bg_color #ffffff;
@define-color success_color #006c49;
@define-color destructive_color #b3261e;
@define-color brand_on2 #4c5262;
@define-color brand_outline #dde3eb;
@define-color brand_tint_blue #daf1ff;
@define-color brand_tint_blue_ink #005a74;
@define-color brand_tint_green #cdffe2;
@define-color brand_tint_green_ink #005236;
@define-color brand_tint_purple #ede4ff;
@define-color brand_tint_purple_ink #5a38ba;
@define-color brand_ring_off #dce3ec;
@define-color brand_ring_gap #ffffff;
"#;

const DARK: &str = r#"
@define-color accent_color #54c7f5;
@define-color accent_bg_color #54c7f5;
@define-color accent_fg_color #050b18;
@define-color window_bg_color #050b18;
@define-color window_fg_color #f4f7fa;
@define-color view_bg_color #0d1321;
@define-color view_fg_color #f4f7fa;
@define-color headerbar_bg_color #050b18;
@define-color headerbar_fg_color #f4f7fa;
@define-color card_bg_color #151c29;
@define-color card_fg_color #f4f7fa;
@define-color dialog_bg_color #0d1321;
@define-color popover_bg_color #151c29;
@define-color success_color #5ef2b2;
@define-color destructive_color #ffb4a8;
@define-color brand_on2 #9aa8b8;
@define-color brand_outline #2a303f;
@define-color brand_tint_blue alpha(#54c7f5, 0.15);
@define-color brand_tint_blue_ink #6ad3ff;
@define-color brand_tint_green alpha(#5ef2b2, 0.13);
@define-color brand_tint_green_ink #5ef2b2;
@define-color brand_tint_purple alpha(#9b7cff, 0.16);
@define-color brand_tint_purple_ink #cdbdff;
@define-color brand_ring_off #232a38;
@define-color brand_ring_gap #050b18;
"#;

/// Shared rules; colours come from the palette above.
const COMMON: &str = r#"
.brand-title { font-family: "Space Grotesk", "Cantarell", sans-serif; font-weight: 600; font-size: 22pt; }
.brand-heading { font-family: "Space Grotesk", "Cantarell", sans-serif; font-weight: 600; font-size: 13pt; }
.brand-dim { color: @brand_on2; }
.card { border: 1px solid @brand_outline; border-radius: 12px; box-shadow: none; }
.device-card { padding: 16px; }
.ring { border-radius: 9999px; min-width: 38px; min-height: 38px; padding: 3px; background: @brand_ring_off; }
.ring.connected { background-image: linear-gradient(135deg, #9b7cff 0%, #54c7f5 55%, #5ef2b2 100%); }
.ring > .ring-inner { border-radius: 9999px; background: @brand_ring_gap; min-width: 38px; min-height: 38px; }
.chip { border-radius: 9999px; padding: 2px 10px; font-size: 9pt; font-weight: 600; }
.chip.blue { background: @brand_tint_blue; color: @brand_tint_blue_ink; }
.chip.green { background: @brand_tint_green; color: @brand_tint_green_ink; }
.chip.purple { background: @brand_tint_purple; color: @brand_tint_purple_ink; }
.code { font-family: "Space Grotesk", monospace; font-size: 30pt; font-weight: 600; letter-spacing: 4px; }
.code-chip { font-family: monospace; font-weight: 700; }
.notice-card { padding: 12px 14px; }
.banner-card { padding: 10px 14px; background: @brand_tint_blue; color: @brand_tint_blue_ink; border: none; }
.banner-card.warn { background: alpha(@destructive_color, 0.12); color: @window_fg_color; }
.activity-row { padding: 8px 12px; }
.send-box { padding: 6px; }
"#;

pub fn load_fonts() {
    // Fontconfig's application fonts: Space Grotesk for headings, from the app's own files.
    #[link(name = "fontconfig")]
    extern "C" {
        fn FcConfigAppFontAddFile(config: *mut std::ffi::c_void, file: *const std::ffi::c_char) -> i32;
    }
    let font = crate::paths::resources().join("fonts/SpaceGrotesk-SemiBold.ttf");
    if let Ok(c) = std::ffi::CString::new(font.to_string_lossy().as_bytes()) {
        if font.is_file() {
            unsafe {
                FcConfigAppFontAddFile(std::ptr::null_mut(), c.as_ptr());
            }
        }
    }
}

pub struct Style {
    palette: gtk::CssProvider,
}

impl Style {
    pub fn install() -> Style {
        let display = gdk::Display::default().expect("display");
        let common = gtk::CssProvider::new();
        common.load_from_string(COMMON);
        gtk::style_context_add_provider_for_display(&display, &common, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
        let palette = gtk::CssProvider::new();
        gtk::style_context_add_provider_for_display(&display, &palette, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
        // The app's own icons (the AppImage's, or linux/data in a source checkout).
        gtk::IconTheme::for_display(&display).add_search_path(crate::paths::resources().join("icons"));
        let style = Style { palette };
        style.follow(adw::StyleManager::default().is_dark());
        style
    }

    pub fn follow(&self, dark: bool) {
        self.palette.load_from_string(if dark { DARK } else { LIGHT });
    }
}
