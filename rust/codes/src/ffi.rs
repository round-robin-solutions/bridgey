//! The apps' way in: one JSON call (docs/mesh-and-codes.md, "One reader"). The Mac calls the C function, Android
//! the JNI one; the CLI links the crate directly. Panics never cross the boundary. Message text and codes are never
//! logged.
//!
//! | `op` | Request fields | Result |
//! | --- | --- | --- |
//! | `candidate` | the notification's `packageName`, `smsDefaultApp`, `redacted`, `text`, `emailApp`, `preview`, `emailCodes` | `candidate`: `{channel, text}` or null |
//! | `gate` | `text` | `gate`: whether the phone may send it as a preview or a code candidate |
//! | `guard` | `answer`, `text` (the joined message) | `code` or null |
//! | `serviceKey` | `sender` | `serviceKey`, `brokerKey` |
//! | `sender` | `title`, `applicationName` | `sender` |
//! | `read` (feature `llama`) | `modelPath`, `text` (the candidate's), `sender`, `channel`, optional `budgetMs` | `outcome` (`found`, `none` or a failure word) and `code` |
//! | `unload` (feature `llama`) | | |

use crate::candidate::{code_candidate, NotificationFields};
use serde_json::{json, Value};

fn error(message: &str) -> String {
    json!({"ok": false, "error": message}).to_string()
}

/// One call. Returns `{"ok":true,...}` or `{"ok":false,"error":...}`.
pub fn call(request: &str) -> String {
    std::panic::catch_unwind(|| call_inner(request)).unwrap_or_else(|_| error("internal error"))
}

fn call_inner(request: &str) -> String {
    let Ok(request) = serde_json::from_str::<Value>(request) else { return error("request is not JSON") };
    let text = |key: &str| request.get(key).and_then(Value::as_str).unwrap_or("").to_string();
    match request.get("op").and_then(Value::as_str).unwrap_or("") {
        "candidate" => match serde_json::from_value::<NotificationFields>(request.clone()) {
            Ok(fields) => json!({"ok": true, "candidate": code_candidate(&fields)}).to_string(),
            Err(_) => error("candidate needs packageName and text"),
        },
        "gate" => json!({"ok": true, "gate": crate::text::phone_gate(&text("text"))}).to_string(),
        "guard" => {
            let answer = request.get("answer").and_then(Value::as_str);
            json!({"ok": true, "code": crate::guard::accept(answer, &crate::text::code_guard_text(&text("text")))}).to_string()
        }
        "serviceKey" => {
            let sender = text("sender");
            json!({"ok": true, "serviceKey": crate::service::code_service_key(&sender), "brokerKey": crate::service::broker_service_key(&sender)}).to_string()
        }
        "sender" => json!({"ok": true, "sender": crate::service::code_sender(&text("title"), &text("applicationName"))}).to_string(),
        #[cfg(feature = "llama")]
        "read" => model::read(&request),
        #[cfg(feature = "llama")]
        "unload" => {
            model::engine().unload();
            json!({"ok": true}).to_string()
        }
        _ => error("unknown op"),
    }
}

#[cfg(feature = "llama")]
mod model {
    use crate::candidate::Channel;
    use crate::engine::{LocalEngine, DEFAULT_IDLE};
    use crate::reader::{Outcome, Reader};
    use serde_json::{json, Value};
    use std::path::PathBuf;
    use std::sync::{Mutex, OnceLock};
    use std::time::Duration;

    fn path() -> &'static Mutex<Option<PathBuf>> {
        static PATH: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();
        PATH.get_or_init(|| Mutex::new(None))
    }

    pub fn engine() -> &'static LocalEngine {
        static ENGINE: OnceLock<LocalEngine> = OnceLock::new();
        ENGINE.get_or_init(|| {
            LocalEngine::new(
                DEFAULT_IDLE,
                Box::new(|| path().lock().unwrap().clone().filter(|p| p.is_file())),
                Box::new(|| Box::new(crate::llama::LlamaRunner::default())),
            )
        })
    }

    pub fn read(request: &Value) -> String {
        let Some(model) = request.get("modelPath").and_then(Value::as_str) else { return super::error("read needs modelPath") };
        let Some(channel) = request.get("channel").and_then(Value::as_str).and_then(Channel::of) else { return super::error("read needs channel") };
        let text = request.get("text").and_then(Value::as_str).unwrap_or("");
        *path().lock().unwrap() = Some(PathBuf::from(model));
        let mut reader = Reader::new(engine());
        if let Some(ms) = request.get("budgetMs").and_then(Value::as_u64) {
            reader.budget = Duration::from_millis(ms.clamp(100, 10_000));
        }
        let outcome = reader.read(text, request.get("sender").and_then(Value::as_str), channel);
        let code = match &outcome {
            Outcome::Code(code) => Some(code.clone()),
            _ => None,
        };
        json!({"ok": true, "outcome": outcome.word(), "code": code}).to_string()
    }
}

mod c_abi {
    use std::ffi::{c_char, CStr, CString};

    /// One JSON request, one JSON result; free the result with `bridgey_codes_free`.
    #[no_mangle]
    pub extern "C" fn bridgey_codes_call(request: *const c_char) -> *mut c_char {
        let request = if request.is_null() {
            String::new()
        } else {
            // SAFETY: the caller passes a NUL-terminated UTF-8 string that outlives the call.
            unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned()
        };
        CString::new(super::call(&request)).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
    }

    /// Frees a string returned by this library.
    #[no_mangle]
    pub extern "C" fn bridgey_codes_free(text: *mut c_char) {
        if !text.is_null() {
            // SAFETY: `text` came from CString::into_raw in this library and is freed once.
            drop(unsafe { CString::from_raw(text) });
        }
    }
}

#[cfg(target_os = "android")]
mod jni_abi {
    use jni::objects::{JClass, JString};
    use jni::sys::jstring;
    use jni::JNIEnv;

    #[no_mangle]
    pub extern "system" fn Java_dev_bridgey_android_codes_RustCodes_nativeCall(mut env: JNIEnv, _: JClass, request: JString) -> jstring {
        let request: String = env.get_string(&request).map(|s| s.into()).unwrap_or_default();
        let result = super::call(&request);
        env.new_string(result).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
    }
}
