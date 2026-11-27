//! The window and its pages, on GTK4 and libadwaita. Pages are drawn from the state again after each change
//! (`App::queue_render`); lists are short, so this stays cheap and simple.

pub mod home;
pub mod notices;
pub mod pair;
pub mod prefs;
pub mod style;
pub mod widgets;
pub mod window;
