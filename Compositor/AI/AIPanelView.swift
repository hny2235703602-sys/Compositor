import SwiftUI

struct AIPanelView: View {
    @Bindable var session: EditorSession
    var width: CGFloat = 320
    /// Saves and opens go through the window's controller so a write is not reloaded as someone else's change.
    var controller: ProjectController? = nil
    /// Collapses the drawer. The model stays on the window, so closing this view does not stop a request.
    var onClose: () -> Void = {}
    static let widths: ClosedRange<Double> = 260...480

    @AppStorage("aiEndpoint") private var endpoint = "https://api.openai.com/v1"
    @AppStorage("aiModel") private var modelName = "gpt-4o"
    @Bindable var model: AIPanelModel
    @State private var keyDraft = ""
    @State private var keySuffix: String?
    @State private var keyError: String?
    @State private var showsConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sessionChanges
            Divider()
            transcript
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.status {
                HStack(spacing: 8) {
                    if model.isSending { ProgressView().controlSize(.small) }
                    Text(status).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(model.isSending ? 0.16 : 0.08))
                .accessibilityIdentifier("aiStatus")
            }
            Divider()
            composer
            connection
        }
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aiPanel")
        .onAppear {
            keySuffix = AICredentials.suffix()
            if keySuffix == nil { showsConnection = true }
        }
    }

    private var header: some View {
        HStack {
            Text("Assistant").font(.system(size: 12, weight: .semibold))
            Spacer()
            if model.isSending {
                Button("Stop", action: model.cancel).controlSize(.small)
                ProgressView().controlSize(.small)
            }
            Button(action: onClose) {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .help("Hide Assistant")
            .accessibilityIdentifier("hideAssistant")
        }
        .padding(18)
    }

    private var sessionChanges: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changes this session").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            if model.changes.isEmpty {
                Text("None yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.changes) { change in
                            Text(change.summary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 88)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aiSessionChanges")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        Text("Ask what is selected, where the selection is, or what the zoom is. The document is read when you send.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(messageLabel(message.role))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(message.role == .error ? Color.red : Color.secondary)
                            Text(message.text).font(.system(size: 12)).textSelection(.enabled)
                                .foregroundStyle(message.role == .error ? Color.red : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(message.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func messageLabel(_ role: AIChatMessage.Role) -> String {
        switch role {
        case .user: uiName("You")
        case .assistant: uiName("Assistant")
        case .error: uiName("Error")
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this document", text: $model.draft)
                .textFieldStyle(.plain)
                .onSubmit(send)
                .releasesFocusOnCommit(session)
                .accessibilityIdentifier("aiPrompt")
            Button("Send", action: send)
                .disabled(model.isSending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("aiSend")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var connection: some View {
        DisclosureGroup("Connection", isExpanded: $showsConnection) {
            VStack(alignment: .leading, spacing: 8) {
                Text(keySuffix.map { "Key ending \($0)" } ?? "No API key")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("aiKeySuffix")
                AIKeyField(text: $keyDraft)
                    .accessibilityIdentifier("aiKey")
                HStack {
                    Button("Save Key", action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove Key", action: removeKey).disabled(keySuffix == nil)
                }
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
                TextField("Endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(nil)
                HStack(spacing: 6) {
                    if model.availableModels.isEmpty {
                        TextField("Model", text: $modelName).textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $modelName) {
                            ForEach(model.availableModels, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("aiModelPicker")
                    }
                    Button(action: fetchModels) {
                        if model.fetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.fetchingModels)
                    .help("Fetch models")
                    .accessibilityIdentifier("aiFetchModels")
                    .accessibilityLabel("Fetch Models")
                }
                if let modelsError = model.modelsError {
                    Text(modelsError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.connectionChecking ? "Checking…" : "Check Connection") {
                    Task { await model.checkConnection(endpoint: endpoint) }
                }
                .disabled(model.connectionChecking)
                .accessibilityIdentifier("aiCheckConnection")
                if let report = model.connectionReport {
                    Text(report.detail).font(.caption).foregroundStyle(report.reachable ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("aiConnectionReport")
                }
            }
            .padding(.top, 8)
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private func send() { model.send(session: session, endpoint: endpoint, modelName: modelName, controller: controller) }

    private func fetchModels() {
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (AICredentials.load() ?? "") : typed
        let chosen = modelName
        Task {
            await model.fetchModels(endpoint: endpoint, apiKey: key)
            guard model.modelsError == nil, let first = model.availableModels.first else { return }
            if !model.availableModels.contains(chosen) { modelName = first }
        }
    }

    private func saveKey() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        keyError = nil
        do {
            try AICredentials.save(keyDraft)
            keyDraft = ""
            keySuffix = AICredentials.suffix()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        AICredentials.delete()
        keyDraft = ""
        keySuffix = nil
        keyError = nil
    }
}
