//! The code model through llama.cpp (MIT), a line-for-line port of the Mac's LlamaRunner.swift: one context of
//! 512 tokens (the prompt is about 82 tokens, the answer about 13), greedy decoding, the model's own chat template,
//! and the answer stops as soon as its JSON object closes. llama.cpp's log is switched off, so message text can
//! never reach a log. GPU layers are asked for (Metal on a Mac); a build without a GPU backend runs on the CPU.

use crate::engine::{ModelError, ModelRunner};
use crate::prompt;
use llama_cpp_sys_2 as sys;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;
use std::sync::Once;

const CONTEXT_TOKENS: u32 = 512;

unsafe extern "C" fn silent(_level: sys::ggml_log_level, _text: *const c_char, _data: *mut c_void) {}

fn backend() {
    static INIT: Once = Once::new();
    INIT.call_once(|| unsafe {
        sys::llama_log_set(Some(silent), std::ptr::null_mut());
        sys::llama_backend_init();
    });
}

pub struct LlamaRunner {
    model: *mut sys::llama_model,
    context: *mut sys::llama_context,
    sampler: *mut sys::llama_sampler,
    vocab: *const sys::llama_vocab,
    template: Option<CString>,
    threads: i32,
}

// The runner lives on the engine's thread; it is only moved there once.
unsafe impl Send for LlamaRunner {}

impl Default for LlamaRunner {
    fn default() -> Self {
        Self::new(None)
    }
}

impl LlamaRunner {
    /// `threads` defaults to the Mac's rule: between 1 and 4, two fewer than the cores.
    pub fn new(threads: Option<i32>) -> LlamaRunner {
        let cores = std::thread::available_parallelism().map(|n| n.get() as i32).unwrap_or(2);
        LlamaRunner {
            model: std::ptr::null_mut(),
            context: std::ptr::null_mut(),
            sampler: std::ptr::null_mut(),
            vocab: std::ptr::null(),
            template: None,
            threads: threads.unwrap_or((cores - 2).clamp(1, 4)),
        }
    }

    fn formatted(&self, user: &str) -> String {
        let fallback = format!("<start_of_turn>user\n{user}<end_of_turn>\n<start_of_turn>model\n");
        let (Some(template), Ok(role), Ok(content)) = (self.template.as_ref(), CString::new("user"), CString::new(user)) else { return fallback };
        let message = sys::llama_chat_message { role: role.as_ptr(), content: content.as_ptr() };
        let mut buffer = vec![0u8; user.len() * 2 + 256];
        unsafe {
            let mut length = sys::llama_chat_apply_template(template.as_ptr(), &message, 1, true, buffer.as_mut_ptr().cast(), buffer.len() as i32);
            if length > buffer.len() as i32 {
                buffer = vec![0u8; length as usize + 1];
                length = sys::llama_chat_apply_template(template.as_ptr(), &message, 1, true, buffer.as_mut_ptr().cast(), buffer.len() as i32);
            }
            if length <= 0 {
                return fallback;
            }
            String::from_utf8_lossy(&buffer[..length as usize]).into_owned()
        }
    }

    /// The prompt's tokens: the chat template's own parts with special tokens parsed, the user turn (which holds the
    /// message text) without, so a message that contains `<end_of_turn>` or `<start_of_turn>` stays plain text and
    /// cannot steer the model. A template that already starts with the BOS marker gets no second one.
    pub fn prompt_tokens(&self, user: &str) -> Result<Vec<sys::llama_token>, ModelError> {
        let text = self.formatted(user);
        let Some(at) = text.find(user) else { return Err(ModelError::PromptTooLong) };
        let (prefix, suffix) = (&text[..at], &text[at + user.len()..]);
        let mut tokens = self.tokenize(prefix, !text.starts_with("<bos>"), true)?;
        tokens.extend(self.tokenize(user, false, false)?);
        tokens.extend(self.tokenize(suffix, false, true)?);
        Ok(tokens)
    }

    /// The Mac's way (the whole formatted prompt with special tokens parsed), kept for the token equality check.
    pub fn whole_prompt_tokens(&self, user: &str) -> Result<Vec<sys::llama_token>, ModelError> {
        let text = self.formatted(user);
        self.tokenize(&text, !text.starts_with("<bos>"), true)
    }

    fn tokenize(&self, text: &str, add_special: bool, parse_special: bool) -> Result<Vec<sys::llama_token>, ModelError> {
        if text.is_empty() {
            return Ok(Vec::new());
        }
        let length = text.len() as i32;
        let mut tokens = vec![0 as sys::llama_token; text.len() + 8];
        unsafe {
            let mut count = sys::llama_tokenize(self.vocab, text.as_ptr().cast(), length, tokens.as_mut_ptr(), tokens.len() as i32, add_special, parse_special);
            if count < 0 {
                tokens = vec![0; (-count) as usize];
                count = sys::llama_tokenize(self.vocab, text.as_ptr().cast(), length, tokens.as_mut_ptr(), tokens.len() as i32, add_special, parse_special);
            }
            if count < 0 {
                return Err(ModelError::PromptTooLong);
            }
            tokens.truncate(count as usize);
        }
        Ok(tokens)
    }
}

impl ModelRunner for LlamaRunner {
    fn load(&mut self, path: &Path) -> Result<(), ModelError> {
        backend();
        self.unload();
        let path = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| ModelError::LoadFailed)?;
        unsafe {
            let mut model_params = sys::llama_model_default_params();
            model_params.n_gpu_layers = 99;
            let model = sys::llama_model_load_from_file(path.as_ptr(), model_params);
            if model.is_null() {
                return Err(ModelError::LoadFailed);
            }
            let mut context_params = sys::llama_context_default_params();
            context_params.n_ctx = CONTEXT_TOKENS;
            context_params.n_batch = CONTEXT_TOKENS;
            context_params.n_ubatch = CONTEXT_TOKENS;
            context_params.n_threads = self.threads;
            context_params.n_threads_batch = self.threads;
            context_params.no_perf = true;
            let context = sys::llama_init_from_model(model, context_params);
            if context.is_null() {
                sys::llama_model_free(model);
                return Err(ModelError::ContextFailed);
            }
            let chain = sys::llama_sampler_chain_init(sys::llama_sampler_chain_default_params());
            sys::llama_sampler_chain_add(chain, sys::llama_sampler_init_greedy());
            self.model = model;
            self.context = context;
            self.sampler = chain;
            self.vocab = sys::llama_model_get_vocab(model);
            let template = sys::llama_model_chat_template(model, std::ptr::null());
            self.template = (!template.is_null()).then(|| CStr::from_ptr(template).to_owned());
        }
        Ok(())
    }

    fn complete(&mut self, user: &str, max_tokens: usize) -> Result<String, ModelError> {
        if self.context.is_null() || self.sampler.is_null() || self.vocab.is_null() {
            return Err(ModelError::LoadFailed);
        }
        let mut tokens = self.prompt_tokens(user)?;
        if tokens.is_empty() || tokens.len() + max_tokens >= CONTEXT_TOKENS as usize {
            return Err(ModelError::PromptTooLong);
        }
        let mut bytes: Vec<u8> = Vec::new();
        unsafe {
            sys::llama_memory_clear(sys::llama_get_memory(self.context), true);
            sys::llama_sampler_reset(self.sampler);
            if sys::llama_decode(self.context, sys::llama_batch_get_one(tokens.as_mut_ptr(), tokens.len() as i32)) != 0 {
                return Err(ModelError::DecodeFailed);
            }
            let mut piece = [0 as c_char; 64];
            for _ in 0..max_tokens {
                let mut token = sys::llama_sampler_sample(self.sampler, self.context, -1);
                if sys::llama_vocab_is_eog(self.vocab, token) {
                    break;
                }
                let count = sys::llama_token_to_piece(self.vocab, token, piece.as_mut_ptr(), piece.len() as i32, 0, false);
                if count > 0 {
                    bytes.extend(piece[..count as usize].iter().map(|c| *c as u8));
                }
                if prompt::is_complete(&String::from_utf8_lossy(&bytes)) {
                    break;
                }
                if sys::llama_decode(self.context, sys::llama_batch_get_one(&mut token, 1)) != 0 {
                    return Err(ModelError::DecodeFailed);
                }
            }
        }
        tokens.clear();
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    fn unload(&mut self) {
        unsafe {
            if !self.sampler.is_null() {
                sys::llama_sampler_free(self.sampler);
            }
            if !self.context.is_null() {
                sys::llama_free(self.context);
            }
            if !self.model.is_null() {
                sys::llama_model_free(self.model);
            }
        }
        self.sampler = std::ptr::null_mut();
        self.context = std::ptr::null_mut();
        self.model = std::ptr::null_mut();
        self.vocab = std::ptr::null();
        self.template = None;
    }
}

impl Drop for LlamaRunner {
    fn drop(&mut self) {
        self.unload();
    }
}
