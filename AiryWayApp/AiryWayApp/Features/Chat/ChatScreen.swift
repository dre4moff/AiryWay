import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatScreen: View {
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var isDebugPresented = false
    @State private var isSidebarPresented = false
    @State private var isFileImporterPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isAudioRecorderPresented = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                backgroundGradient
                .ignoresSafeArea()

                chatContent
                    .disabled(isSidebarPresented)

                if isSidebarPresented {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.26, extraBounce: 0.02)) {
                                isSidebarPresented = false
                            }
                        }

                    ConversationDrawer(
                        conversations: chatViewModel.conversationList,
                        selectedConversationID: chatViewModel.selectedConversationID,
                        isGenerating: chatViewModel.isGenerating,
                        onNewConversation: {
                            chatViewModel.createNewConversation()
                        },
                        onSelectConversation: { id in
                            chatViewModel.selectConversation(id)
                            withAnimation(.snappy(duration: 0.26, extraBounce: 0.02)) {
                                isSidebarPresented = false
                            }
                        },
                        onDeleteConversation: { id in
                            chatViewModel.deleteConversation(id)
                        }
                    )
                    .frame(width: min(UIScreen.main.bounds.width * 0.84, 340))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.snappy(duration: 0.26, extraBounce: 0.02)) {
                            isSidebarPresented.toggle()
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isDebugPresented = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .disabled(chatViewModel.debugItems.isEmpty)
                }
            }
            .sheet(isPresented: $isDebugPresented) {
                DebugSheet(items: chatViewModel.debugItems)
            }
            .sheet(isPresented: $isAudioRecorderPresented) {
                AudioRecorderSheet { url, duration in
                    chatViewModel.addAudioAttachment(fileURL: url, duration: duration)
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let first = urls.first else { return }
                Task { await chatViewModel.addFileAttachment(from: first) }
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await chatViewModel.addImageAttachment(from: data)
                    }
                    selectedPhotoItem = nil
                }
            }
            .onTapGesture {
                dismissKeyboard()
            }
            .simultaneousGesture(sidebarGesture)
        }
    }

    private var backgroundGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.14),
                    Color(red: 0.10, green: 0.13, blue: 0.19),
                    Color(red: 0.06, green: 0.07, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.97, blue: 1.0),
                Color(red: 0.92, green: 0.95, blue: 0.99),
                Color.white
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var chatContent: some View {
        VStack(spacing: 12) {
            statusBanner

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chatViewModel.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 2)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chatViewModel.messages.count) {
                    if let last = chatViewModel.messages.last?.id {
                        withAnimation(.smooth(duration: 0.22)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            composerBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(modelStateColor)
                .frame(width: 10, height: 10)
                .scaleEffect(chatViewModel.isGenerating ? 1.16 : 1.0)
                .animation(
                    chatViewModel.isGenerating
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.2),
                    value: chatViewModel.isGenerating
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("\(settingsStore.selectedModelName)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("State: \(settingsStore.modelState.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if chatViewModel.isGenerating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating...")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))

                Button("Stop") {
                    chatViewModel.stopGeneration()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.36))
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .animation(.smooth(duration: 0.22), value: chatViewModel.isGenerating)
    }

    private var composerBar: some View {
        let rawCapabilities = settingsStore.selectedModelCapabilities
        let capabilities = settingsStore.effectiveSelectedModelCapabilities
        let canUseImageInput = capabilities.supportsImageInput
        let hasText = !chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !chatViewModel.pendingAttachments.isEmpty
        let actionButtonSize: CGFloat = 40
        let isSendDisabled = chatViewModel.isGenerating || (!hasText && !hasAttachments)

        return VStack(alignment: .leading, spacing: 10) {
            if hasAttachments {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chatViewModel.pendingAttachments) { attachment in
                            AttachmentChip(
                                attachment: attachment,
                                onRemove: { chatViewModel.removePendingAttachment(attachment.id) }
                            )
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Menu {
                    if capabilities.supportsFileInput {
                        Button {
                            dismissKeyboard()
                            isFileImporterPresented = true
                        } label: {
                            Label("Carica file", systemImage: "doc.badge.plus")
                        }
                    } else {
                        Button {
                        } label: {
                            Label("Carica file (Non supportato)", systemImage: "doc")
                        }
                        .disabled(true)
                    }

                    if canUseImageInput {
                        Button {
                            dismissKeyboard()
                            isPhotoPickerPresented = true
                        } label: {
                            Label("Carica immagine", systemImage: "photo.on.rectangle")
                        }
                    } else if rawCapabilities.supportsImageInput {
                        Button {
                        } label: {
                            Label("Carica immagine (Runtime non supportato)", systemImage: "photo")
                        }
                        .disabled(true)
                    } else {
                        Button {
                        } label: {
                            Label("Carica immagine (Non supportato)", systemImage: "photo")
                        }
                        .disabled(true)
                    }

                    if capabilities.supportsAudioInput {
                        Button {
                            dismissKeyboard()
                            isAudioRecorderPresented = true
                        } label: {
                            Label("Registra audio", systemImage: "waveform.badge.plus")
                        }
                    } else {
                        Button {
                        } label: {
                            Label("Registra audio (Non supportato)", systemImage: "waveform")
                        }
                        .disabled(true)
                    }
                } label: {
                    Circle()
                        .fill(Color(uiColor: .secondarySystemBackground).opacity(0.95))
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: actionButtonSize, height: actionButtonSize)
                }
                .buttonStyle(.plain)
                .disabled(chatViewModel.isGenerating)

                TextField("Ask AiryWay", text: $chatViewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .focused($isComposerFocused)
                    .onSubmit {
                        if !isSendDisabled {
                            dismissKeyboard()
                            chatViewModel.send()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(minHeight: actionButtonSize, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: actionButtonSize / 2, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground).opacity(0.95))
                    )

                Button {
                    dismissKeyboard()
                    chatViewModel.send()
                } label: {
                    Circle()
                        .fill(isSendDisabled ? Color(uiColor: .tertiarySystemFill) : Color.accentColor)
                        .overlay {
                            if chatViewModel.isGenerating {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(isSendDisabled ? Color.secondary : .white)
                            }
                        }
                        .frame(width: actionButtonSize, height: actionButtonSize)
                        .animation(.easeInOut(duration: 0.15), value: isSendDisabled)
                        .animation(.easeInOut(duration: 0.15), value: chatViewModel.isGenerating)
                }
                .buttonStyle(.plain)
                .disabled(isSendDisabled)
                .accessibilityLabel(chatViewModel.isGenerating ? "Generating" : "Send")
            }
            .frame(minHeight: actionButtonSize, alignment: .center)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.32))
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var sidebarGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onEnded { value in
                if !isSidebarPresented {
                    let startsFromEdge = value.startLocation.x <= 24
                    let opensDrawer = value.translation.width >= 80
                    if startsFromEdge && opensDrawer {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSidebarPresented = true
                        }
                    }
                } else {
                    let closesDrawer = value.translation.width <= -80
                    if closesDrawer {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSidebarPresented = false
                        }
                    }
                }
            }
    }

    private var modelStateColor: Color {
        switch settingsStore.modelState {
        case .unloaded: return .gray
        case .loading: return .orange
        case .ready: return .green
        case .generating: return .blue
        case .error: return .red
        }
    }

    private func dismissKeyboard() {
        isComposerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachmentPayload
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(attachment.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.92))
        )
    }

    private var icon: String {
        switch attachment.kind {
        case .file: return "doc"
        case .image: return "photo"
        case .audio: return "waveform"
        }
    }
}

private struct ConversationDrawer: View {
    let conversations: [ChatConversation]
    let selectedConversationID: UUID?
    let isGenerating: Bool
    let onNewConversation: () -> Void
    let onSelectConversation: (UUID) -> Void
    let onDeleteConversation: (UUID) -> Void

    private let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved chats")
                    .font(.headline)
                Spacer()
                Button {
                    onNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(conversations) { conversation in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                onSelectConversation(conversation.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    let preview = conversation.previewText
                                    Text(preview.isEmpty ? "No messages yet." : preview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)

                                    Text(dateFormatter.localizedString(for: conversation.updatedAt, relativeTo: Date()))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(selectedConversationID == conversation.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isGenerating)

                            if conversations.count > 1 {
                                Button(role: .destructive) {
                                    onDeleteConversation(conversation.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .padding(.top, 8)
                                .disabled(isGenerating)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(formattedText)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: min(UIScreen.main.bounds.width * 0.78, 560), alignment: .leading)
            .background(bubbleStyle)
            if message.role != .user { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var label: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "AiryWay"
        case .system: return "System"
        }
    }

    private var bubbleStyle: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(bubbleColor)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06))
            )
    }

    private var formattedText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: message.text, options: options) {
            return parsed
        }
        return AttributedString(message.text)
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return Color.accentColor.opacity(0.18)
        case .assistant:
            return Color(uiColor: .secondarySystemBackground).opacity(0.95)
        case .system:
            return Color.orange.opacity(0.14)
        }
    }
}

private struct DebugSheet: View {
    let items: [AgentDebugItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.stage)
                        .font(.headline)
                    Text(item.detail)
                        .font(.caption)
                        .textSelection(.enabled)
                    Text("\(item.durationMS) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Debug")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AudioRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = AudioRecorderController()

    let onRecorded: (URL, TimeInterval) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 58))
                    .foregroundStyle(recorder.isRecording ? .red : .accentColor)

                Text(recorder.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(timeLabel(recorder.elapsed))
                    .font(.title3.monospacedDigit())

                HStack(spacing: 12) {
                    Button(recorder.isRecording ? "Stop" : "Start") {
                        Task {
                            if recorder.isRecording {
                                if let result = recorder.stop() {
                                    onRecorded(result.url, result.duration)
                                    dismiss()
                                }
                            } else {
                                await recorder.start()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Cancel", role: .cancel) {
                        recorder.cancel()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Record audio")
        }
    }

    private func timeLabel(_ value: TimeInterval) -> String {
        let total = Int(max(0, value))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private final class AudioRecorderController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var statusText = "Tap Start to record."
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var startDate: Date?
    private var timer: Timer?

    override init() {
        super.init()
    }

    func start() async {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let granted = await requestPermission()
            guard granted else {
                statusText = "Microphone permission denied."
                return
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("airway-audio-\(UUID().uuidString)")
                .appendingPathExtension("m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.record()

            self.recorder = recorder
            startDate = Date()
            isRecording = true
            statusText = "Recording..."
            startTimer()
        } catch {
            statusText = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder else { return nil }
        recorder.stop()
        timer?.invalidate()
        timer = nil

        let duration = elapsed
        let url = recorder.url

        self.recorder = nil
        isRecording = false
        statusText = "Audio saved"

        return (url: url, duration: duration)
    }

    func cancel() {
        recorder?.stop()
        if let recorder {
            try? FileManager.default.removeItem(at: recorder.url)
        }
        recorder = nil
        timer?.invalidate()
        timer = nil
        startDate = nil
        isRecording = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let startDate {
                elapsed = Date().timeIntervalSince(startDate)
            }
        }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
