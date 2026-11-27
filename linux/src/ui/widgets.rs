//! Small builders that keep keyboard and screen reader access the same everywhere: an icon-only button always has a
//! label for Orca (AT-SPI) and a tooltip; motion is opacity only and follows the desktop's and Bridgey's reduce motion.

use adw::prelude::*;
use gtk::glib;

/// An icon button; `label` is what a screen reader says and the tooltip shows.
pub fn icon_button(icon: &str, label: &str) -> gtk::Button {
    let b = gtk::Button::builder().icon_name(icon).tooltip_text(label).valign(gtk::Align::Center).build();
    b.update_property(&[gtk::accessible::Property::Label(label)]);
    b.add_css_class("flat");
    b
}

/// A button with an icon and a visible label.
pub fn labelled_button(icon: &str, label: &str) -> gtk::Button {
    let content = adw::ButtonContent::builder().icon_name(icon).label(label).use_underline(true).build();
    let b = gtk::Button::builder().child(&content).build();
    b.update_property(&[gtk::accessible::Property::Label(label)]);
    b
}

pub fn text_button(label: &str) -> gtk::Button {
    gtk::Button::builder().label(label).use_underline(true).valign(gtk::Align::Center).build()
}

pub fn label(text: &str, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::builder().label(text).xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).build();
    for c in classes {
        l.add_css_class(c);
    }
    l
}

pub fn clear(b: &gtk::Box) {
    while let Some(c) = b.first_child() {
        b.remove(&c);
    }
}

pub fn clear_list(l: &gtk::ListBox) {
    l.remove_all();
}

/// A new card fades in (opacity only); with animations off it simply appears.
pub fn arrive(w: &impl IsA<gtk::Widget>) {
    let w = w.as_ref().clone();
    let target = adw::PropertyAnimationTarget::new(&w, "opacity");
    let anim = adw::TimedAnimation::new(&w, 0.0, 1.0, 220, target);
    anim.set_easing(adw::Easing::EaseOutCubic);
    w.set_opacity(0.0);
    anim.play();
    // Keep the animation alive until it ends.
    let held = std::rc::Rc::new(std::cell::RefCell::new(Some(anim.clone())));
    anim.connect_done(move |_| {
        held.borrow_mut().take();
    });
}

thread_local! {
    static KEPT: std::cell::RefCell<Vec<adw::Dialog>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Keeps a closed dialog alive. libadwaita 1.5.0 (Ubuntu 24.04, the AppImage's floor) keeps a pointer to a closed
/// dialog's breakpoints in the window, and a later resize could then crash; holding the dialog avoids that. Only the
/// last few are kept.
pub fn keep_after_close(dialog: &impl IsA<adw::Dialog>) {
    let d = dialog.as_ref().clone();
    KEPT.with(|k| {
        let mut k = k.borrow_mut();
        k.push(d);
        let len = k.len();
        if len > 8 {
            k.drain(..len - 8);
        }
    });
}

/// Formats a byte count the British way: 1.2 MB, 340 KB.
pub fn size(bytes: u64) -> String {
    let b = bytes as f64;
    if b >= 1e9 {
        format!("{:.1} GB", b / 1e9)
    } else if b >= 1e6 {
        format!("{:.1} MB", b / 1e6)
    } else if b >= 1e3 {
        format!("{:.0} KB", b / 1e3)
    } else {
        format!("{bytes} B")
    }
}

/// "14:05" today, else "27 Nov".
pub fn time(ms: u64) -> String {
    let Ok(dt) = glib::DateTime::from_unix_local((ms / 1000) as i64) else { return String::new() };
    let today = glib::DateTime::now_local().ok().map(|n| n.ymd()) == Some(dt.ymd());
    let fmt = if today { "%H:%M" } else { "%e %b" };
    dt.format(fmt).map(|s| s.trim().to_string()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    #[test]
    fn sizes_read_plainly() {
        assert_eq!(super::size(999), "999 B");
        assert_eq!(super::size(340_000), "340 KB");
        assert_eq!(super::size(1_260_000), "1.3 MB");
    }
}
