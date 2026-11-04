//! The on-device engine (Swift `LocalCodeEngine`): loads the model on first use, answers one message at a time on
//! its own thread, and unloads the model after `idle` without messages (or when asked). The caller waits at most
//! its budget; an answer that comes later is dropped, because a model cannot be stopped mid-answer.

use crate::prompt;
use crate::reader::{Answer, AnswerSource, Failure};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub const DEFAULT_IDLE: Duration = Duration::from_secs(15 * 60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelError {
    LoadFailed,
    ContextFailed,
    PromptTooLong,
    DecodeFailed,
}

/// Runs one model in-process. `llama::LlamaRunner` is the real one; tests use a fake. Only ever used on the
/// engine's own thread.
pub trait ModelRunner: Send {
    fn load(&mut self, path: &std::path::Path) -> Result<(), ModelError>;
    /// One greedy completion for one user message.
    fn complete(&mut self, user: &str, max_tokens: usize) -> Result<String, ModelError>;
    fn unload(&mut self);
}

pub type RunnerFactory = Box<dyn Fn() -> Box<dyn ModelRunner> + Send>;
pub type ModelPath = Box<dyn Fn() -> Option<PathBuf> + Send>;

/// One answer, with how long it took and whether the model had to load first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Timed {
    pub answer: Answer,
    pub elapsed: Duration,
    pub loaded: bool,
}

enum Job {
    /// `gone` is set when the caller stopped waiting: the job is skipped if it has not started.
    Answer { text: String, sender: Option<String>, reply: Sender<Timed>, gone: Arc<AtomicBool> },
    Unload,
    Status(Sender<(bool, u32)>),
}

pub struct LocalEngine {
    jobs: Mutex<Sender<Job>>,
}

struct Worker {
    make_runner: RunnerFactory,
    model_path: ModelPath,
    runner: Option<Box<dyn ModelRunner>>,
    loaded_path: Option<PathBuf>,
    loads: u32,
}

impl LocalEngine {
    pub fn new(idle: Duration, model_path: ModelPath, make_runner: RunnerFactory) -> LocalEngine {
        let (tx, rx) = mpsc::channel::<Job>();
        let worker = Worker { make_runner, model_path, runner: None, loaded_path: None, loads: 0 };
        thread::Builder::new().name("bridgey-code-model".into()).spawn(move || worker.run(rx, idle)).expect("code model thread");
        LocalEngine { jobs: Mutex::new(tx) }
    }

    /// The answer within `budget`, timed. `Failed(Timeout)` when the model did not answer in time.
    pub fn timed_answer(&self, text: &str, sender: Option<&str>, budget: Duration) -> Timed {
        let started = Instant::now();
        let (reply, answer) = mpsc::channel();
        let gone = Arc::new(AtomicBool::new(false));
        let job = Job::Answer { text: text.to_string(), sender: sender.map(str::to_string), reply, gone: gone.clone() };
        if self.jobs.lock().unwrap().send(job).is_err() {
            return Timed { answer: Answer::Failed(Failure::Unavailable), elapsed: started.elapsed(), loaded: false };
        }
        match answer.recv_timeout(budget) {
            Ok(timed) => timed,
            Err(_) => {
                gone.store(true, Ordering::SeqCst);
                Timed { answer: Answer::Failed(Failure::Timeout), elapsed: started.elapsed(), loaded: false }
            }
        }
    }

    /// Unloads now, e.g. after the model was removed. The next message loads it again if a file is there.
    pub fn unload(&self) {
        let _ = self.jobs.lock().unwrap().send(Job::Unload);
    }

    /// Unloads now and waits until it is done. Call before the process exits: llama.cpp's Metal backend asserts at
    /// exit while a model is still loaded.
    pub fn shutdown(&self) {
        self.unload();
        let _ = self.status();
    }

    /// Whether a model is in memory and how many times one was loaded.
    pub fn status(&self) -> (bool, u32) {
        let (tx, rx) = mpsc::channel();
        if self.jobs.lock().unwrap().send(Job::Status(tx)).is_err() {
            return (false, 0);
        }
        rx.recv().unwrap_or((false, 0))
    }
}

impl AnswerSource for LocalEngine {
    fn answer(&self, text: &str, sender: Option<&str>, budget: Duration) -> Answer {
        self.timed_answer(text, sender, budget).answer
    }
}

impl Worker {
    fn run(mut self, jobs: Receiver<Job>, idle: Duration) {
        loop {
            let wait = if self.runner.is_some() { idle } else { Duration::from_secs(3600) };
            match jobs.recv_timeout(wait) {
                Ok(Job::Answer { text, sender, reply, gone }) => {
                    // A caller that gave up (its budget ended while earlier jobs ran) gets nothing: the queue drains.
                    if !gone.load(Ordering::SeqCst) {
                        let _ = reply.send(self.answer_now(&text, sender.as_deref()));
                    }
                }
                Ok(Job::Unload) => self.unload_now(),
                Ok(Job::Status(reply)) => {
                    let _ = reply.send((self.runner.is_some(), self.loads));
                }
                Err(RecvTimeoutError::Timeout) => self.unload_now(),
                Err(RecvTimeoutError::Disconnected) => {
                    self.unload_now();
                    return;
                }
            }
        }
    }

    fn answer_now(&mut self, text: &str, sender: Option<&str>) -> Timed {
        let started = Instant::now();
        let Some(path) = (self.model_path)() else {
            self.unload_now();
            return Timed { answer: Answer::Failed(Failure::ModelMissing), elapsed: Duration::ZERO, loaded: false };
        };
        let mut loaded = false;
        if self.runner.is_none() || self.loaded_path.as_ref() != Some(&path) {
            self.unload_now();
            let mut fresh = (self.make_runner)();
            if fresh.load(&path).is_err() {
                return Timed { answer: Answer::Failed(Failure::Unavailable), elapsed: started.elapsed(), loaded: false };
            }
            self.runner = Some(fresh);
            self.loaded_path = Some(path);
            self.loads += 1;
            loaded = true;
        }
        // A text that tokenizes past the context (600 characters of some scripts can) is read on a shorter window,
        // its first half each time, at most twice; the model stays loaded. The guard still checks the whole text.
        let mut window = text.to_string();
        for _ in 0..3 {
            match self.runner.as_mut().unwrap().complete(&prompt::user(sender, &window), prompt::MAXIMUM_ANSWER_TOKENS) {
                Ok(output) => return Timed { answer: prompt::parse(&output), elapsed: started.elapsed(), loaded },
                Err(ModelError::PromptTooLong) => window = first_half(&window),
                Err(_) => {
                    self.unload_now();
                    return Timed { answer: Answer::Failed(Failure::Unavailable), elapsed: started.elapsed(), loaded };
                }
            }
        }
        Timed { answer: Answer::Failed(Failure::Unavailable), elapsed: started.elapsed(), loaded }
    }

    fn unload_now(&mut self) {
        if let Some(mut runner) = self.runner.take() {
            runner.unload();
        }
        self.loaded_path = None;
    }
}

/// The first half of a text, cut at whitespace so no token (a code) is split.
fn first_half(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut end = chars.len() / 2;
    while end > 0 && !chars[end].is_whitespace() {
        end -= 1;
    }
    chars[..end].iter().collect::<String>().trim_end().to_string()
}
