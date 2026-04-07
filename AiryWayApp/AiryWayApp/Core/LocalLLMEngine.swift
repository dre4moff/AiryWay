import Foundation

#if canImport(llama)
import llama
#endif

struct LocalModelResponse {
    let text: String
    let tokensGenerated: Int
    let elapsed: TimeInterval
}

enum LocalComputePreference: String, CaseIterable, Identifiable {
    case auto
    case cpuOnly
    case gpuMetal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .cpuOnly: return "CPU"
        case .gpuMetal: return "GPU (Metal)"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "Best default for this device"
        case .cpuOnly: return "Maximum stability, lower speed"
        case .gpuMetal: return "Higher speed and throughput"
        }
    }
}

enum LocalComputeBackend: Equatable {
    case unknown
    case cpu
    case gpuMetal

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .cpu: return "CPU"
        case .gpuMetal: return "GPU (Metal)"
        }
    }
}

enum LocalModelState: Equatable {
    case unloaded
    case loading
    case ready
    case generating
    case error(String)

    var label: String {
        switch self {
        case .unloaded: return "unloaded"
        case .loading: return "loading"
        case .ready: return "ready"
        case .generating: return "generating"
        case let .error(message): return "error: \(message)"
        }
    }
}

enum LocalLLMError: LocalizedError {
    case invalidModelPath
    case unsupportedModelExtension
    case modelNotLoaded
    case frameworkMissing
    case generationCancelled
    case busy
    case invalidResponse
    case downloadInProgress
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelPath:
            return "The model path is invalid or unreadable."
        case .unsupportedModelExtension:
            return "Only .gguf files are supported."
        case .modelNotLoaded:
            return "No local model is loaded yet. Import or download a GGUF model first."
        case .frameworkMissing:
            return "llama.xcframework is not linked to the target yet. Add it in Xcode and rebuild."
        case .generationCancelled:
            return "Generation stopped."
        case .busy:
            return "The model is already generating."
        case .invalidResponse:
            return "The model produced an empty response."
        case .downloadInProgress:
            return "A model download is already in progress."
        case let .backend(message):
            return message
        }
    }
}

protocol LocalLLMEngine: AnyObject {
    var displayName: String { get }
    var supportsStreaming: Bool { get }
    var loadedModelURL: URL? { get }
    var computePreference: LocalComputePreference { get }
    var activeComputeBackend: LocalComputeBackend { get }
    var supportsGPUOffload: Bool { get }
    var supportsNativeImageInput: Bool { get }

    func loadModel(at modelURL: URL) async throws
    func unloadModel() async
    func setComputePreference(_ preference: LocalComputePreference)
    func generate(
        prompt: String,
        context: String,
        conversation: [ChatMessage],
        maxOutputTokens: Int?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> LocalModelResponse
    func stopGeneration()
}

final class LlamaCppEngine: LocalLLMEngine {
    let displayName = "llama.cpp"
    let supportsStreaming = true

    private(set) var loadedModelURL: URL?
    private(set) var computePreference: LocalComputePreference = .auto
    private(set) var activeComputeBackend: LocalComputeBackend = .unknown
    private var isGenerating = false
    private var stopRequested = false
    private var backendWarmSessionID = UUID().uuidString

#if canImport(llama)
    private var llamaModelHandle: OpaquePointer?
    private var llamaContextHandle: OpaquePointer?
    private var llamaSamplerHandle: UnsafeMutablePointer<llama_sampler>?
    private static var isBackendInitialized = false
#endif

    var supportsGPUOffload: Bool {
#if canImport(llama)
    #if targetEnvironment(simulator)
        // ggml-metal on iOS Simulator can abort in native code for some model/config combinations.
        // Keep simulator stable by forcing CPU execution.
        return false
    #else
        return llama_supports_gpu_offload()
    #endif
#else
        return false
#endif
    }

    var supportsNativeImageInput: Bool {
        // Current framework bundle does not include multimodal helpers (llava/mtmd).
        false
    }

    func loadModel(at modelURL: URL) async throws {
        guard modelURL.isFileURL else { throw LocalLLMError.invalidModelPath }
        guard modelURL.pathExtension.lowercased() == "gguf" else { throw LocalLLMError.unsupportedModelExtension }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw LocalLLMError.invalidModelPath }

#if canImport(llama)
        await unloadModel()
        initializeBackendIfNeeded()

        let primaryGPULayers = resolvedGPULayersForLoad()
        let model: OpaquePointer
        if let loaded = loadModelHandle(at: modelURL, gpuLayers: primaryGPULayers) {
            model = loaded
        } else if primaryGPULayers != 0 {
            // If GPU loading fails, retry on CPU to keep Auto robust across devices/models.
            activeComputeBackend = .cpu
            guard let cpuLoaded = loadModelHandle(at: modelURL, gpuLayers: 0) else {
                throw LocalLLMError.backend("llama.cpp failed to load model file.")
            }
            model = cpuLoaded
        } else {
            throw LocalLLMError.backend("llama.cpp failed to load model file.")
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 8192
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = Int32(max(2, ProcessInfo.processInfo.processorCount - 1))
        contextParams.n_threads_batch = Int32(max(2, ProcessInfo.processInfo.processorCount - 1))

        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LocalLLMError.backend("llama.cpp failed to initialize context.")
        }

        guard let sampler = makeSampler(seed: UInt32.random(in: 1...UInt32.max)) else {
            llama_free(context)
            llama_model_free(model)
            throw LocalLLMError.backend("llama.cpp failed to initialize sampler.")
        }

        llamaModelHandle = model
        llamaContextHandle = context
        llamaSamplerHandle = sampler
#else
        activeComputeBackend = .cpu
        try await Task.sleep(nanoseconds: 180_000_000)
#endif
        loadedModelURL = modelURL
        backendWarmSessionID = UUID().uuidString
    }

    func unloadModel() async {
        stopRequested = true
        isGenerating = false
#if canImport(llama)
        if let sampler = llamaSamplerHandle {
            llama_sampler_free(sampler)
        }
        if let context = llamaContextHandle {
            llama_free(context)
        }
        if let model = llamaModelHandle {
            llama_model_free(model)
        }
        llamaSamplerHandle = nil
        llamaContextHandle = nil
        llamaModelHandle = nil
#endif
        activeComputeBackend = .unknown
        loadedModelURL = nil
    }

    func setComputePreference(_ preference: LocalComputePreference) {
        computePreference = preference
    }

    func stopGeneration() {
        stopRequested = true
    }

    func generate(
        prompt: String,
        context: String,
        conversation: [ChatMessage],
        maxOutputTokens: Int?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> LocalModelResponse {
        guard loadedModelURL != nil else { throw LocalLLMError.modelNotLoaded }
        guard !isGenerating else { throw LocalLLMError.busy }

        isGenerating = true
        stopRequested = false
        let start = Date()

        defer {
            isGenerating = false
            stopRequested = false
        }

        let fullText = try await generateWithBackend(
            prompt: prompt,
            context: context,
            conversation: conversation,
            maxOutputTokens: maxOutputTokens
        )
        let sanitizedText = sanitizeAssistantOutput(fullText)
        guard !sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalLLMError.invalidResponse
        }

        var streamed = ""
        var emittedChunks = 0

        for chunk in chunkForStreaming(sanitizedText) {
            if Task.isCancelled || stopRequested {
                throw LocalLLMError.generationCancelled
            }
            streamed += chunk
            emittedChunks += 1
            onToken(chunk)
        }

        let elapsed = Date().timeIntervalSince(start)
        return LocalModelResponse(
            text: streamed,
            tokensGenerated: max(estimateTokenCount(in: streamed), emittedChunks),
            elapsed: elapsed
        )
    }

    private func generateWithBackend(
        prompt: String,
        context: String,
        conversation: [ChatMessage],
        maxOutputTokens: Int?
    ) async throws -> String {
#if canImport(llama)
        return try await generateWithLinkedLlama(
            prompt: prompt,
            context: context,
            conversation: conversation,
            maxOutputTokens: maxOutputTokens
        )
#else
        return try await generateFallbackText(prompt: prompt, context: context, maxOutputTokens: maxOutputTokens)
#endif
    }

#if canImport(llama)
    private func generateWithLinkedLlama(
        prompt: String,
        context: String,
        conversation: [ChatMessage],
        maxOutputTokens: Int?
    ) async throws -> String {
        guard let model = llamaModelHandle,
              let contextHandle = llamaContextHandle else {
            throw LocalLLMError.frameworkMissing
        }

        let promptText = buildModelPrompt(
            prompt: prompt,
            context: context,
            conversation: conversation,
            model: model
        )

        if let existing = llamaSamplerHandle {
            llama_sampler_free(existing)
            llamaSamplerHandle = nil
        }
        guard let sampler = makeSampler(seed: UInt32.random(in: 1...UInt32.max)) else {
            throw LocalLLMError.backend("llama.cpp failed to initialize sampler.")
        }
        llamaSamplerHandle = sampler

        let task: Task<String, Error> = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw LocalLLMError.backend("Model engine deallocated.") }

            let vocab = llama_model_get_vocab(model)
            guard let vocab else {
                throw LocalLLMError.backend("llama.cpp vocabulary is unavailable.")
            }

            llama_sampler_reset(sampler)
            llama_memory_clear(llama_get_memory(contextHandle), true)

            var promptTokens = try self.tokenize(text: promptText, vocab: vocab)
            let nCtx = Int(llama_n_ctx(contextHandle))
            if nCtx > 32 && promptTokens.count >= nCtx - 4 {
                promptTokens = Array(promptTokens.suffix(nCtx - 4))
            }

            if promptTokens.isEmpty {
                throw LocalLLMError.invalidResponse
            }

            let maxBatchSize = max(1, Int(llama_n_batch(contextHandle)))
            var cursor = 0
            while cursor < promptTokens.count {
                if Task.isCancelled || self.stopRequested {
                    throw LocalLLMError.generationCancelled
                }

                let end = min(cursor + maxBatchSize, promptTokens.count)
                var decodeChunk = Array(promptTokens[cursor..<end])
                let promptDecodeResult = decodeChunk.withUnsafeMutableBufferPointer { ptr in
                    let batch = llama_batch_get_one(ptr.baseAddress, Int32(ptr.count))
                    return llama_decode(contextHandle, batch)
                }
                if promptDecodeResult < 0 {
                    throw LocalLLMError.backend("llama.cpp prompt decode failed (\(promptDecodeResult)) at chunk \(cursor)-\(end).")
                }

                cursor = end
            }

            var output = ""
            let availableContext = max(1, nCtx - promptTokens.count - 8)
            let maxGeneration: Int
            if let requested = maxOutputTokens {
                maxGeneration = max(1, min(requested, availableContext))
            } else {
                maxGeneration = availableContext
            }

            for _ in 0..<maxGeneration {
                if Task.isCancelled || self.stopRequested {
                    throw LocalLLMError.generationCancelled
                }

                let token = llama_sampler_sample(sampler, contextHandle, -1)
                if llama_vocab_is_eog(vocab, token) {
                    break
                }

                let piece = self.tokenToPiece(token: token, vocab: vocab)
                if !piece.isEmpty {
                    output += piece
                    if output.count >= 24,
                       let cutIndex = self.firstDialogueLeakCutIndex(in: output) {
                        output = String(output[..<cutIndex])
                        break
                    }
                }

                llama_sampler_accept(sampler, token)

                var tokenCopy = token
                let tokenDecodeResult = withUnsafeMutablePointer(to: &tokenCopy) { ptr in
                    let batch = llama_batch_get_one(ptr, 1)
                    return llama_decode(contextHandle, batch)
                }
                if tokenDecodeResult < 0 {
                    throw LocalLLMError.backend("llama.cpp token decode failed (\(tokenDecodeResult)).")
                }
            }

            let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                throw LocalLLMError.invalidResponse
            }
            return cleaned
        }
        return try await task.value
    }

    private func initializeBackendIfNeeded() {
        if Self.isBackendInitialized { return }
        llama_backend_init()
        Self.isBackendInitialized = true
    }

    private func makeSampler(seed: UInt32) -> UnsafeMutablePointer<llama_sampler>? {
        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            return nil
        }

        // Stable but not locked: avoids repeated identical replies while keeping coherence.
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(128, 1.10, 0.0, 0.0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(64))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.65))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed))
        return sampler
    }

    private func loadModelHandle(at modelURL: URL, gpuLayers: Int32) -> OpaquePointer? {
        var modelParams = llama_model_default_params()
        modelParams.use_mmap = true
        modelParams.use_mlock = false
        modelParams.n_gpu_layers = gpuLayers
        return modelURL.path.withCString { cPath in
            llama_model_load_from_file(cPath, modelParams)
        }
    }

    private func resolvedGPULayersForLoad() -> Int32 {
        let gpuAvailable = supportsGPUOffload
        switch computePreference {
        case .cpuOnly:
            activeComputeBackend = .cpu
            return 0
        case .gpuMetal:
            if gpuAvailable {
                activeComputeBackend = .gpuMetal
                return -1
            } else {
                activeComputeBackend = .cpu
                return 0
            }
        case .auto:
            #if os(iOS)
            // Stability-first default on iOS. GPU (Metal) remains available via explicit user choice.
            activeComputeBackend = .cpu
            return 0
            #else
            if gpuAvailable {
                activeComputeBackend = .gpuMetal
                return -1
            } else {
                activeComputeBackend = .cpu
                return 0
            }
            #endif
        }
    }

    private struct TemplateTurn {
        let role: String
        let content: String
    }

    private func buildModelPrompt(
        prompt: String,
        context: String,
        conversation: [ChatMessage],
        model: OpaquePointer
    ) -> String {
        let userText: String = {
            let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let boundedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !boundedContext.isEmpty else { return request }
            return "\(request)\n\n\(String(boundedContext.prefix(8_000)))"
        }()

        var turns = conversation.compactMap { message -> TemplateTurn? in
            let baseText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseText.isEmpty else { return nil }

            let role: String
            let text: String
            switch message.role {
            case .user:
                role = "user"
                text = baseText
            case .assistant:
                role = "assistant"
                text = sanitizeAssistantOutput(baseText)
            case .system:
                role = "system"
                text = baseText
            }
            guard !text.isEmpty else { return nil }
            return TemplateTurn(role: role, content: text)
        }

        if turns.isEmpty, !userText.isEmpty {
            turns = [TemplateTurn(role: "user", content: userText)]
        }

        if let templated = applyNativeChatTemplateIfAvailable(model: model, turns: turns) {
            return templated
        }
        return buildPlainConversationPrompt(turns: turns, fallbackUserText: userText)
    }

    private func buildPlainConversationPrompt(turns: [TemplateTurn], fallbackUserText: String) -> String {
        let trimmedUser = fallbackUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        if turns.isEmpty {
            return trimmedUser
        }

        let rendered = turns.suffix(14).map { turn -> String in
            switch turn.role {
            case "assistant":
                return "Assistant: \(turn.content)"
            case "system":
                return "System: \(turn.content)"
            default:
                return "User: \(turn.content)"
            }
        }
        .joined(separator: "\n")

        return "\(rendered)\nAssistant:"
    }

    private func applyNativeChatTemplateIfAvailable(model: OpaquePointer, turns: [TemplateTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        guard let templatePtr = llama_model_chat_template(model, nil) else { return nil }

        var rolePointers: [UnsafeMutablePointer<CChar>?] = []
        var contentPointers: [UnsafeMutablePointer<CChar>?] = []
        var chatMessages: [llama_chat_message] = []
        rolePointers.reserveCapacity(turns.count)
        contentPointers.reserveCapacity(turns.count)
        chatMessages.reserveCapacity(turns.count)

        for turn in turns {
            let rolePtr = strdup(turn.role)
            let contentPtr = strdup(turn.content)
            guard let rolePtr, let contentPtr else { return nil }
            rolePointers.append(rolePtr)
            contentPointers.append(contentPtr)
            chatMessages.append(
                llama_chat_message(
                    role: UnsafePointer(rolePtr),
                    content: UnsafePointer(contentPtr)
                )
            )
        }

        defer {
            for pointer in rolePointers {
                free(pointer)
            }
            for pointer in contentPointers {
                free(pointer)
            }
        }

        var probe = [CChar](repeating: 0, count: 1)
        let needed = chatMessages.withUnsafeMutableBufferPointer { ptr in
            llama_chat_apply_template(
                templatePtr,
                ptr.baseAddress,
                ptr.count,
                true,
                &probe,
                Int32(probe.count)
            )
        }

        guard needed > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(needed) + 1)
        let written = buffer.withUnsafeMutableBufferPointer { outPtr in
            chatMessages.withUnsafeMutableBufferPointer { msgPtr in
                llama_chat_apply_template(
                    templatePtr,
                    msgPtr.baseAddress,
                    msgPtr.count,
                    true,
                    outPtr.baseAddress,
                    Int32(outPtr.count)
                )
            }
        }

        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    private func tokenize(text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let maxTokens = max(64, text.utf8.count + 16)
        var tokens = [llama_token](repeating: 0, count: maxTokens)

        let count: Int32 = text.withCString { cString in
            llama_tokenize(
                vocab,
                cString,
                Int32(strlen(cString)),
                &tokens,
                Int32(tokens.count),
                true,
                true
            )
        }

        if count == Int32.min {
            throw LocalLLMError.backend("Tokenization overflow.")
        }

        if count < 0 {
            let needed = Int(-count) + 8
            tokens = [llama_token](repeating: 0, count: needed)
            let secondCount: Int32 = text.withCString { cString in
                llama_tokenize(
                    vocab,
                    cString,
                    Int32(strlen(cString)),
                    &tokens,
                    Int32(tokens.count),
                    true,
                    true
                )
            }
            guard secondCount > 0 else {
                throw LocalLLMError.backend("Tokenization failed (\(secondCount)).")
            }
            return Array(tokens.prefix(Int(secondCount)))
        }

        guard count > 0 else {
            throw LocalLLMError.backend("Tokenization returned no tokens.")
        }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenToPiece(token: llama_token, vocab: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        var written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)

        if written < 0 {
            let required = Int(-written) + 8
            buffer = [CChar](repeating: 0, count: required)
            written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }

        guard written > 0 else { return "" }
        let bytes = buffer[..<Int(written)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
#endif

    private func generateFallbackText(prompt: String, context: String, maxOutputTokens: Int?) async throws -> String {
        let outputBudget = maxOutputTokens ?? 512
        if prompt.contains("[[AIRYWAY_TOOL_PLANNER]]") {
            return fallbackPlannerResponse(from: prompt)
        }

        if prompt.contains("[[AIRYWAY_SUMMARIZE_TOOL]]") {
            return summarize(text: context, sentenceTarget: 4)
        }

        let normalizedPrompt = prompt.lowercased()
        let boundedContext = String(context.prefix(8_000))

        if normalizedPrompt.contains("riass") || normalizedPrompt.contains("summar") {
            return summarize(text: boundedContext, sentenceTarget: 5)
        }

        if boundedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let synthesized = synthesizeAnswerFromToolTranscript(prompt: prompt), !synthesized.isEmpty {
                return String(synthesized.prefix(max(220, outputBudget * 8)))
            }
            if let userRequest = extractSection(from: prompt, after: "User request:", before: "Planner hint:")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !userRequest.isEmpty {
                return "Risposta offline (modello locale, session \(backendWarmSessionID.prefix(8))): \(userRequest)"
            }
            return "Risposta offline pronta (session \(backendWarmSessionID.prefix(8)))."
        }

        let intro = "AiryWay local answer (session \(backendWarmSessionID.prefix(8))):"
        let digest = summarize(text: boundedContext, sentenceTarget: 6)
        let answer = "\(intro)\n\nUser request: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(digest)"
        return String(answer.prefix(max(240, outputBudget * 7)))
    }

    private func fallbackPlannerResponse(from prompt: String) -> String {
        let userInput = extractValue(forKey: "USER_INPUT:", in: prompt).lowercased()
        let currentPageURL = extractValue(forKey: "CURRENT_PAGE_URL:", in: prompt)
        let hasToolResult = extractValue(forKey: "LATEST_TOOL_RESULT:", in: prompt).isEmpty == false

        if hasToolResult {
            return "{\"final_answer\":\"Done. I used the tool result and I can now answer the user clearly.\"}"
        }

        if userInput.contains("search ") || userInput.contains("cerca ") {
            let query = stripCommandPrefix(from: userInput, options: ["search ", "cerca "])
            return "{\"tool_call\":{\"name\":\"search_web\",\"arguments\":{\"query\":\"\(escapeJSON(query))\"}}}"
        }

        if userInput.contains("open ") || userInput.contains("vai su ") {
            let target = stripCommandPrefix(from: userInput, options: ["open ", "vai su "])
            return "{\"tool_call\":{\"name\":\"open_url\",\"arguments\":{\"url\":\"\(escapeJSON(target))\"}}}"
        }

        if userInput.contains("read") || userInput.contains("leggi") || userInput.contains("fetch") {
            let url = currentPageURL.isEmpty ? "" : currentPageURL
            return "{\"tool_call\":{\"name\":\"fetch_page_text\",\"arguments\":{\"url\":\"\(escapeJSON(url))\"}}}"
        }

        if userInput.contains("riass") || userInput.contains("summar") {
            return "{\"tool_call\":{\"name\":\"summarize_text\",\"arguments\":{\"text\":\"\"}}}"
        }

        if shouldPreferOnlineSearch(for: userInput) {
            let fallbackQuery = cleanSearchQuery(userInput)
            if !fallbackQuery.isEmpty {
                return "{\"tool_call\":{\"name\":\"search_web\",\"arguments\":{\"query\":\"\(escapeJSON(fallbackQuery))\"}}}"
            }
        }

        return "{\"final_answer\":\"Answer directly with local model knowledge.\"}"
    }

    private func summarize(text: String, sentenceTarget: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "No readable text available." }

        let separators = CharacterSet(charactersIn: ".!?")
        let roughSentences = cleaned
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let picked = Array(roughSentences.prefix(max(2, sentenceTarget)))
        if picked.isEmpty {
            return String(cleaned.prefix(600))
        }

        return picked.joined(separator: ". ") + "."
    }

    private func chunkForStreaming(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else { return [text] }

        var chunks: [String] = []
        var cursor: [Substring] = []

        for word in words {
            cursor.append(word)
            if cursor.count >= 3 {
                chunks.append(cursor.joined(separator: " ") + " ")
                cursor.removeAll(keepingCapacity: true)
            }
        }

        if !cursor.isEmpty {
            chunks.append(cursor.joined(separator: " "))
        }

        return chunks
    }

    private func estimateTokenCount(in text: String) -> Int {
        max(1, text.split(whereSeparator: \.isWhitespace).count)
    }

    private func sanitizeAssistantOutput(_ raw: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .replacingOccurrences(of: "<s>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*(?:\[\s*)?(?:assistant|airyway)(?:\s*\])?\s*:?\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        if let cutIndex = firstDialogueLeakCutIndex(in: cleaned) {
            cleaned = String(cleaned[..<cutIndex])
        }

        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstDialogueLeakCutIndex(in text: String) -> String.Index? {
        guard !text.isEmpty else { return nil }

        let patterns = [
            #"(?im)^[\t >|*\-]*(?:\[\s*)?(?:user|utente|human|system)(?:\s*\])?\s*:?.*$"#,
            #"(?im)^[\t >|*\-]*(?:\[\s*)?(?:assistant|airyway)(?:\s*\])?\s*:\s+.*$"#
        ]

        var earliest: String.Index?

        for pattern in patterns {
            guard let range = text.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                continue
            }

            // Ignore labels at absolute start (e.g. "Assistant: ..."), handled by sanitizer.
            if range.lowerBound == text.startIndex {
                continue
            }

            if let current = earliest {
                if range.lowerBound < current {
                    earliest = range.lowerBound
                }
            } else {
                earliest = range.lowerBound
            }
        }

        return earliest
    }

    private func synthesizeAnswerFromToolTranscript(prompt: String) -> String? {
        guard let transcript = extractSection(
            from: prompt,
            after: "Tool transcript:",
            before: "Current page:"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !transcript.isEmpty,
        transcript.lowercased() != "none" else {
            return nil
        }

        if transcript.localizedCaseInsensitiveContains("search_web: no results") {
            return "Ho provato una ricerca online ma non ho trovato risultati utili. Se vuoi, riformulo la query."
        }

        if let searchJSON = extractLikelyJSONArray(from: transcript),
           let data = searchJSON.data(using: .utf8),
           let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let lines = rawArray.prefix(3).compactMap { item -> String? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                let snippet = (item["snippet"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if snippet.isEmpty {
                    return "- \(title) (\(url))"
                }
                return "- \(title): \(snippet) (\(url))"
            }

            if !lines.isEmpty {
                return "Risultati online trovati:\n" + lines.joined(separator: "\n")
            }
        }

        if let fetchedLine = transcript
            .split(separator: "\n")
            .first(where: { $0.localizedCaseInsensitiveContains("fetched '") }) {
            return "Ho letto contenuto online con gli strumenti disponibili. Sintesi operativa: \(fetchedLine)"
        }

        return "Ho eseguito strumenti online ma non ho abbastanza testo utile per una risposta affidabile. Posso fare un fetch della pagina specifica se mi passi l'URL."
    }

    private func extractValue(forKey key: String, in text: String) -> String {
        guard let range = text.range(of: key) else { return "" }
        let tail = text[range.upperBound...]
        let line = tail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return String(line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractSection(from text: String, after start: String, before end: String) -> String? {
        guard let startRange = text.range(of: start) else { return nil }
        let tail = text[startRange.upperBound...]
        if let endRange = tail.range(of: end) {
            return String(tail[..<endRange.lowerBound])
        }
        return String(tail)
    }

    private func extractLikelyJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end else {
            return nil
        }
        return String(text[start...end])
    }

    private func shouldPreferOnlineSearch(for userInput: String) -> Bool {
        let text = userInput.lowercased()
        if text.isEmpty { return false }

        let explicitOnline = [
            "cerca", "search", "trova", "web", "internet", "online", "fonte", "fonti"
        ]
        if explicitOnline.contains(where: { text.contains($0) }) {
            return true
        }

        let freshnessSignals = [
            "oggi", "adesso", "attuale", "ultime", "ultima", "latest", "news",
            "notizie", "notizia", "headline", "breaking", "ultima ora", "ultim'ora",
            "quotazione", "prezzo", "meteo", "risultati", "risultato", "classifica"
        ]
        return freshnessSignals.contains(where: { text.contains($0) })
    }

    private func cleanSearchQuery(_ userInput: String) -> String {
        var query = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["cerca ", "search ", "trova "]
        for prefix in prefixes where query.lowercased().hasPrefix(prefix) {
            query = String(query.dropFirst(prefix.count))
            break
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripCommandPrefix(from text: String, options: [String]) -> String {
        for option in options where text.hasPrefix(option) {
            return String(text.dropFirst(option.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func escapeJSON(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
