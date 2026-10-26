import Foundation
import llama

/// The on-device code model through llama.cpp's Apple framework (MIT), with Metal. One context of
/// 512 tokens (the prompt is about 82 tokens, the answer about 13), greedy decoding, the model's own
/// chat template. llama.cpp's log is switched off, so message text can never reach a log.
final class LlamaRunner: LocalModelRunner {
    private static let contextTokens: UInt32 = 512
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var vocab: OpaquePointer?
    private var template: String?

    deinit { unload() }

    func load(path: String) throws {
        _ = Self.backend
        unload()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let loaded = llama_model_load_from_file(path, modelParams) else { throw LocalModelError.loadFailed }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Self.contextTokens
        contextParams.n_batch = Self.contextTokens
        contextParams.n_ubatch = Self.contextTokens
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.no_perf = true
        guard let created = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            throw LocalModelError.contextFailed
        }
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        model = loaded
        context = created
        sampler = chain
        vocab = llama_model_get_vocab(loaded)
        template = llama_model_chat_template(loaded, nil).map { String(cString: $0) }
    }

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
        model = nil
        vocab = nil
        template = nil
    }

    func complete(user: String, maxTokens: Int) throws -> String {
        guard let context, let sampler, let vocab else { throw LocalModelError.loadFailed }
        let prompt = formatted(user)
        // A template that already starts with the BOS marker must not get a second one.
        var tokens = try tokenize(prompt, addSpecial: !prompt.hasPrefix("<bos>"), vocab: vocab)
        guard !tokens.isEmpty, tokens.count + maxTokens < Int(Self.contextTokens) else { throw LocalModelError.promptTooLong }
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)
        let prefill = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard prefill == 0 else { throw LocalModelError.decodeFailed }
        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 64)
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if count > 0 { bytes += piece[0..<Int(count)].map { UInt8(bitPattern: $0) } }
            if CodeModelPrompt.isComplete(String(decoding: bytes, as: UTF8.self)) { break }
            let step = llama_decode(context, llama_batch_get_one(&token, 1))
            guard step == 0 else { throw LocalModelError.decodeFailed }
        }
        tokens.removeAll()
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The user message in the model's chat template (Gemma's turn markers).
    private func formatted(_ user: String) -> String {
        let fallback = "<start_of_turn>user\n\(user)<end_of_turn>\n<start_of_turn>model\n"
        guard let template else { return fallback }
        return template.withCString { templatePointer in
            "user".withCString { role in
                user.withCString { content in
                    var message = llama_chat_message(role: role, content: content)
                    var buffer = [CChar](repeating: 0, count: user.utf8.count * 2 + 256)
                    var length = llama_chat_apply_template(templatePointer, &message, 1, true, &buffer, Int32(buffer.count))
                    if length > Int32(buffer.count) {
                        buffer = [CChar](repeating: 0, count: Int(length) + 1)
                        length = llama_chat_apply_template(templatePointer, &message, 1, true, &buffer, Int32(buffer.count))
                    }
                    guard length > 0 else { return fallback }
                    return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
        }
    }

    private func tokenize(_ text: String, addSpecial: Bool, vocab: OpaquePointer) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, true)
        }
        guard count >= 0 else { throw LocalModelError.promptTooLong }
        return Array(tokens.prefix(Int(count)))
    }
}
