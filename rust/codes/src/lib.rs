//! The one-time code reader every Bridgey device shares (docs/mesh-and-codes.md, "One reader").
//!
//! One message in, one outcome out, on any device that has the model: the same rules, model, prompt and guard
//! the Mac shipped in Swift (CodeReader.swift, CodeText.swift, EmailCodeRules.swift, CodeModel.swift,
//! LlamaRunner.swift), ported here so this crate is the single source of truth. Its answers are pinned in
//! `protocol/test-vectors/codes-reader-v1.json` (written by `examples/vectors.rs`), which the Swift and Kotlin
//! tests check their own copies against until they call this crate through `ffi`.
//!
//! - [`text`]: the digit-box join, the gate before the model, links and copyright years blanked for the guard.
//! - [`email`]: the email-only pre-check and the second-pass snippets.
//! - [`guard`]: accepts the model's code only if it is literally in the message and looks like a code.
//! - [`prompt`]: the prompt the model was trained on and its JSON answer.
//! - [`service`]: the service a code is from ("HDFC Bank"), and the key that folds the same service.
//! - [`candidate`]: which forwarded notifications the reader may look at, and which text it reads.
//! - [`reader`]: one message through the model and the guard within the 2 second budget.
//! - [`engine`]: loads the model on first use on its own thread and unloads it after 15 idle minutes.
//! - `llama` (feature `llama`): the model runner on llama.cpp.
//!
//! Message text and codes are never logged by anything in this crate.

pub mod candidate;
pub mod email;
pub mod engine;
pub mod ffi;
pub mod guard;
#[cfg(feature = "llama")]
pub mod llama;
pub mod prompt;
pub mod reader;
pub mod service;
pub mod text;
mod utf16;

pub use candidate::{code_candidate, Candidate, Channel, NotificationFields};
pub use guard::accept;
pub use reader::{Answer, Failure, Outcome, Reader};
