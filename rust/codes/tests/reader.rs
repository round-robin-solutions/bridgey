//! The reader and the engine with a fake model: budget, guard, the email second pass, lazy load and idle unload.

use bridgey_codes::engine::{LocalEngine, ModelError, ModelRunner};
use bridgey_codes::reader::{Answer, AnswerSource, Failure, Outcome, Reader};
use bridgey_codes::Channel;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Scripted {
    answers: Mutex<Vec<Answer>>,
    seen: Mutex<Vec<String>>,
}

impl AnswerSource for Scripted {
    fn answer(&self, text: &str, _sender: Option<&str>, _budget: Duration) -> Answer {
        self.seen.lock().unwrap().push(text.to_string());
        let mut answers = self.answers.lock().unwrap();
        if answers.is_empty() {
            Answer::NoCode
        } else {
            answers.remove(0)
        }
    }
}

fn scripted(answers: Vec<Answer>) -> Scripted {
    Scripted { answers: Mutex::new(answers), seen: Mutex::new(vec![]) }
}

#[test]
fn a_code_the_guard_accepts_is_shown() {
    let source = scripted(vec![Answer::Candidate("482913".into())]);
    assert_eq!(Reader::new(&source).read("OTP is 482913", Some("HDFCBK"), Channel::Sms), Outcome::Code("482913".into()));
}

#[test]
fn a_code_not_in_the_message_is_refused() {
    let source = scripted(vec![Answer::Candidate("111111".into())]);
    assert_eq!(Reader::new(&source).read("OTP is 482913", None, Channel::Sms), Outcome::NoCode);
}

#[test]
fn a_code_only_in_a_link_is_refused() {
    let source = scripted(vec![Answer::Candidate("482913".into())]);
    assert_eq!(Reader::new(&source).read("Open https://x.io/v/482913 to verify", None, Channel::Sms), Outcome::NoCode);
}

#[test]
fn sms_is_read_once_and_mail_gets_snippets() {
    let sms = scripted(vec![]);
    assert_eq!(Reader::new(&sms).read("Your verification code is 330912.", None, Channel::Sms), Outcome::NoCode);
    assert_eq!(sms.seen.lock().unwrap().len(), 1);
    let mail = scripted(vec![Answer::NoCode, Answer::Candidate("330912".into())]);
    let text = format!("{} Your verification code is 330912. {}", "Welcome to Acme. ".repeat(10), "Thanks. ".repeat(10));
    assert_eq!(Reader::new(&mail).read(&text, None, Channel::Email), Outcome::Code("330912".into()));
    assert_eq!(mail.seen.lock().unwrap().len(), 2, "first read, then one snippet");
}

#[test]
fn a_failure_falls_back() {
    let source = scripted(vec![Answer::Failed(Failure::ModelMissing)]);
    assert_eq!(Reader::new(&source).read("OTP 482913", None, Channel::Sms), Outcome::Fallback(Failure::ModelMissing));
}

struct Fake {
    log: Arc<Mutex<Vec<String>>>,
    delay: Duration,
}

impl ModelRunner for Fake {
    fn load(&mut self, path: &Path) -> Result<(), ModelError> {
        self.log.lock().unwrap().push(format!("load {}", path.display()));
        Ok(())
    }
    fn complete(&mut self, user: &str, _max: usize) -> Result<String, ModelError> {
        std::thread::sleep(self.delay);
        let code = user.split_whitespace().find(|w| w.len() == 6 && w.chars().all(|c| c.is_ascii_digit()));
        Ok(match code {
            Some(c) => format!("{{\"kind\":\"otp\",\"code\":\"{c}\"}}"),
            None => "{\"kind\":\"none\",\"code\":null}".into(),
        })
    }
    fn unload(&mut self) {
        self.log.lock().unwrap().push("unload".into());
    }
}

fn engine(log: Arc<Mutex<Vec<String>>>, path: Option<PathBuf>, delay: Duration, idle: Duration) -> LocalEngine {
    let l = log.clone();
    LocalEngine::new(idle, Box::new(move || path.clone()), Box::new(move || Box::new(Fake { log: l.clone(), delay })))
}

#[test]
fn the_engine_loads_once_and_unloads_when_idle() {
    let log = Arc::new(Mutex::new(vec![]));
    let e = engine(log.clone(), Some("/m.gguf".into()), Duration::ZERO, Duration::from_millis(300));
    let reader = Reader::new(&e);
    assert_eq!(reader.read("OTP is 482913", None, Channel::Sms), Outcome::Code("482913".into()));
    assert_eq!(reader.read("OTP is 551204", None, Channel::Sms), Outcome::Code("551204".into()));
    assert_eq!(e.status(), (true, 1));
    std::thread::sleep(Duration::from_millis(700));
    assert_eq!(e.status(), (false, 1));
    assert_eq!(*log.lock().unwrap(), vec!["load /m.gguf".to_string(), "unload".to_string()]);
}

#[test]
fn no_model_file_is_model_missing() {
    let e = engine(Arc::new(Mutex::new(vec![])), None, Duration::ZERO, Duration::from_secs(60));
    assert_eq!(Reader::new(&e).read("OTP is 482913", None, Channel::Sms), Outcome::Fallback(Failure::ModelMissing));
}

#[test]
fn a_slow_model_times_out_within_the_budget() {
    let e = engine(Arc::new(Mutex::new(vec![])), Some("/m.gguf".into()), Duration::from_millis(800), Duration::from_secs(60));
    let mut reader = Reader::new(&e);
    reader.budget = Duration::from_millis(200);
    let started = std::time::Instant::now();
    assert_eq!(reader.read("OTP is 482913", None, Channel::Sms), Outcome::Fallback(Failure::Timeout));
    assert!(started.elapsed() < Duration::from_millis(500));
}

#[test]
fn ffi_calls_answer_json() {
    let out: serde_json::Value = serde_json::from_str(&bridgey_codes::ffi::call(r#"{"op":"guard","answer":"482913","text":"OTP 4 8 2 9 1 3"}"#)).unwrap();
    assert_eq!(out["code"], serde_json::Value::Null, "the guard reads the text as given; the join is the caller's");
    let out: serde_json::Value = serde_json::from_str(&bridgey_codes::ffi::call(r#"{"op":"guard","answer":"482913","text":"OTP 482913"}"#)).unwrap();
    assert_eq!(out["code"], "482913");
    let out: serde_json::Value = serde_json::from_str(&bridgey_codes::ffi::call(r#"{"op":"candidate","packageName":"com.android.mms","text":"OTP 4 8 2 9 1 3"}"#)).unwrap();
    assert_eq!(out["candidate"]["text"], "OTP 482913");
    let out: serde_json::Value = serde_json::from_str(&bridgey_codes::ffi::call("nope")).unwrap();
    assert_eq!(out["ok"], false);
}

/// A runner whose context holds only short prompts, counting completions.
struct Small {
    completions: Arc<Mutex<u32>>,
    log: Arc<Mutex<Vec<String>>>,
}

impl ModelRunner for Small {
    fn load(&mut self, _path: &Path) -> Result<(), ModelError> {
        self.log.lock().unwrap().push("load".into());
        Ok(())
    }
    fn complete(&mut self, user: &str, _max: usize) -> Result<String, ModelError> {
        *self.completions.lock().unwrap() += 1;
        if user.len() > 200 {
            return Err(ModelError::PromptTooLong);
        }
        let code = user.split_whitespace().find(|w| w.len() == 6 && w.chars().all(|c| c.is_ascii_digit()));
        Ok(code.map(|c| format!("{{\"kind\":\"otp\",\"code\":\"{c}\"}}")).unwrap_or_else(|| "{\"kind\":\"none\"}".into()))
    }
    fn unload(&mut self) {
        self.log.lock().unwrap().push("unload".into());
    }
}

#[test]
fn a_prompt_too_long_is_read_on_a_window_and_the_model_stays_loaded() {
    let log = Arc::new(Mutex::new(vec![]));
    let completions = Arc::new(Mutex::new(0));
    let (l, c) = (log.clone(), completions.clone());
    let e = LocalEngine::new(Duration::from_secs(60), Box::new(|| Some(PathBuf::from("/m.gguf"))),
        Box::new(move || Box::new(Small { completions: c.clone(), log: l.clone() })));
    let text = format!("OTP is 482913 for login. {}", "word ".repeat(40));
    assert_eq!(Reader::new(&e).read(&text, None, Channel::Sms), Outcome::Code("482913".into()));
    assert_eq!(e.status(), (true, 1), "loaded once, never unloaded");
    assert_eq!(*log.lock().unwrap(), vec!["load".to_string()]);
    assert_eq!(*completions.lock().unwrap(), 2, "the whole text, then its first half");
}

#[test]
fn jobs_whose_caller_gave_up_are_dropped() {
    let log = Arc::new(Mutex::new(vec![]));
    let completions = Arc::new(Mutex::new(0u32));
    let (l, c) = (log.clone(), completions.clone());
    struct Slow(Arc<Mutex<u32>>, Arc<Mutex<Vec<String>>>);
    impl ModelRunner for Slow {
        fn load(&mut self, _: &Path) -> Result<(), ModelError> { Ok(()) }
        fn complete(&mut self, _: &str, _: usize) -> Result<String, ModelError> {
            *self.0.lock().unwrap() += 1;
            std::thread::sleep(Duration::from_millis(300));
            Ok("{\"kind\":\"none\"}".into())
        }
        fn unload(&mut self) { self.1.lock().unwrap().push("unload".into()); }
    }
    let e = Arc::new(LocalEngine::new(Duration::from_secs(60), Box::new(|| Some(PathBuf::from("/m.gguf"))),
        Box::new(move || Box::new(Slow(c.clone(), l.clone())))));
    // Five callers that wait 50 ms each, at once: the first job runs, the four queued behind it are skipped.
    let handles: Vec<_> = (0..5).map(|_| { let e = e.clone(); std::thread::spawn(move || e.answer("OTP 482913", None, Duration::from_millis(50))) }).collect();
    for h in handles { assert_eq!(h.join().unwrap(), Answer::Failed(Failure::Timeout)); }
    std::thread::sleep(Duration::from_millis(700));
    assert_eq!(e.status(), (true, 1));
    assert_eq!(*completions.lock().unwrap(), 1, "only the job already running when its caller gave up");
}
