import SwiftUI
import PhotosUI
import Security

// ============================================================
//  Claude Studio v0.2 · 单文件版
//  Claude 风格 iOS 客户端：双协议流式 / 多会话 / 多配置档案
// ============================================================

@main
struct ClaudeStudioApp: App {
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Color.claudeOrange)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var showSidebar = false

    var body: some View {
        ZStack {
            ChatView(showSidebar: $showSidebar)
            SidebarView(isPresented: $showSidebar)
        }
        .background(Color.paper.ignoresSafeArea())
    }
}

// MARK: - 主题

extension Color {
    static let claudeOrange = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)

    static var paper: Color { dyn((0.149, 0.145, 0.137), (0.969, 0.961, 0.937)) }
    static var sidebarBackground: Color { dyn((0.110, 0.107, 0.101), (0.937, 0.925, 0.894)) }
    static var bubbleUser: Color { dyn((0.216, 0.212, 0.204), (0.941, 0.929, 0.898)) }
    static var fieldBackground: Color { dyn((0.235, 0.231, 0.223), (1, 1, 1)) }
    static var fieldBorder: Color { dyn((0.32, 0.31, 0.30), (0.85, 0.84, 0.81)) }
    static var codeBackground: Color { dyn((0.110, 0.107, 0.101), (0.988, 0.984, 0.965)) }
    static var primaryText: Color { dyn((0.93, 0.92, 0.90), (0.13, 0.125, 0.12)) }

    static var separator: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.10)
                : UIColor(red: 0.87, green: 0.86, blue: 0.83, alpha: 1)
        })
    }

    private static func dyn(_ dark: (CGFloat, CGFloat, CGFloat),
                            _ light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

struct ClaudeStar: View {
    var color: Color = .claudeOrange

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2
            let inner = outer * 0.66
            var path = Path()
            for i in 0..<24 {
                let angle = CGFloat(i) * .pi / 12 - .pi / 2
                let radius = i.isMultiple(of: 2) ? outer : inner
                let point = CGPoint(x: center.x + cos(angle) * radius,
                                    y: center.y + sin(angle) * radius)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
    }
}

struct TypingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.claudeOrange)
            .frame(width: 9, height: 17)
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever()) { visible = false }
            }
    }
}

// MARK: - 数据模型

enum Provider: String, Codable, CaseIterable, Identifiable, Hashable {
    case anthropic
    case openaiCompatible

    var id: String { rawValue }
    var label: String { self == .anthropic ? "Anthropic" : "OpenAI 兼容" }
    var defaultBaseURL: String {
        self == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com"
    }
    var placeholderModel: String {
        self == .anthropic ? "claude-sonnet-4-5" : "gpt-4o"
    }
}

struct APIProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "新配置"
    var provider: Provider = .anthropic
    var baseURL = ""
    var model = ""
    var keychainID = "cs-" + UUID().uuidString
    var systemPrompt = ""
}

struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var text = ""
    var imageData: Data?
    var isStreaming = false
    var createdAt = Date()
}

struct ChatSession: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = "新对话"
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()
}

enum APIError: LocalizedError {
    case noKey
    case badURL
    case plain(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "尚未填写 API Key，请到设置中配置"
        case .badURL: return "Base URL 无效，请检查设置"
        case .plain(let message): return message
        case .server(let code, let message): return "请求失败（HTTP \(code)）：\(message)"
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.claudestudio.keys"

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - API 服务（Anthropic + OpenAI 兼容，SSE 流式）

struct APIService {
    let profile: APIProfile
    let apiKey: String

    func streamReply(history: [ChatMessage], system: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    let request = try makeRequest(history: history, system: system)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        var body = ""
                        var count = 0
                        for try await line in bytes.lines {
                            body += line
                            count += 1
                            if count > 40 { break }
                        }
                        throw APIError.server(http.statusCode, Self.readableMessage(body))
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let message = Self.errorIn(payload) {
                            throw APIError.plain(message)
                        }
                        if let delta = Self.deltaIn(payload, provider: profile.provider) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    private func makeRequest(history: [ChatMessage], system: String?) throws -> URLRequest {
        var base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        switch profile.provider {
        case .anthropic:
            let path = base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
            guard let url = URL(string: base + path) else { throw APIError.badURL }
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            var body: [String: Any] = [
                "model": profile.model,
                "max_tokens": 4096,
                "stream": true,
                "messages": anthropicMessages(history),
            ]
            if let system, !system.isEmpty { body["system"] = system }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request

        case .openaiCompatible:
            let path = base.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions"
            guard let url = URL(string: base + path) else { throw APIError.badURL }
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": profile.model,
                "stream": true,
                "messages": openAIMessages(history, system: system),
            ])
            return request
        }
    }

    private func anthropicMessages(_ history: [ChatMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in history {
            var blocks: [[String: Any]] = []
            if let data = message.imageData {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": data.base64EncodedString(),
                    ],
                ])
            }
            if !message.text.isEmpty {
                blocks.append(["type": "text", "text": message.text])
            }
            guard !blocks.isEmpty else { continue }
            let role = message.role == .user ? "user" : "assistant"
            if let last = result.last, last["role"] as? String == role,
               let lastBlocks = last["content"] as? [[String: Any]] {
                result[result.count - 1]["content"] = lastBlocks + blocks
            } else {
                result.append(["role": role, "content": blocks])
            }
        }
        while result.first?["role"] as? String == "assistant" { result.removeFirst() }
        return result
    }

    private func openAIMessages(_ history: [ChatMessage], system: String?) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let system, !system.isEmpty {
            result.append(["role": "system", "content": system])
        }
        for message in history {
            if let data = message.imageData, message.role == .user {
                result.append([
                    "role": "user",
                    "content": [
                        ["type": "text", "text": message.text],
                        ["type": "image_url",
                         "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]],
                    ],
                ])
            } else {
                result.append([
                    "role": message.role == .user ? "user" : "assistant",
                    "content": message.text,
                ])
            }
        }
        return result
    }

    private static func deltaIn(_ payload: String, provider: Provider) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        switch provider {
        case .anthropic:
            guard let delta = object["delta"] as? [String: Any] else { return nil }
            return delta["text"] as? String
        case .openaiCompatible:
            guard let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { return nil }
            return delta["content"] as? String
        }
    }

    private static func errorIn(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }

    private static func readableMessage(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return body.isEmpty ? "服务端返回未知错误" : body
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = object["message"] as? String { return message }
        return body
    }
}

// MARK: - 状态中枢

@MainActor
final class ChatStore: ObservableObject {

    @Published private(set) var sessions: [ChatSession] = [] { didSet { schedulePersist() } }
    @Published var currentSessionID: UUID?
    @Published private(set) var profiles: [APIProfile] = [] { didSet { persistProfiles() } }
    @Published var activeProfileID: UUID?
    @Published private(set) var isGenerating = false
    @Published var lastError: String?

    private var generationTask: Task<Void, Never>?
    private var streamingSessionID: UUID?
    private var persistTask: Task<Void, Never>?

    var currentSession: ChatSession? { sessions.first { $0.id == currentSessionID } }
    var activeProfile: APIProfile? { profiles.first { $0.id == activeProfileID } }

    init() {
        loadProfiles()
        loadSessions()
        if profiles.isEmpty {
            profiles = [APIProfile(
                name: "Anthropic",
                provider: .anthropic,
                baseURL: Provider.anthropic.defaultBaseURL,
                model: "claude-sonnet-4-5"
            )]
        }
        if activeProfileID == nil || !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles.first?.id
        }
    }

    func newSession() {
        if isGenerating { stop() }
        sessions.insert(ChatSession(title: "新对话"), at: 0)
        currentSessionID = sessions.first?.id
    }

    func selectSession(_ id: UUID) {
        currentSessionID = id
        UserDefaults.standard.set(id.uuidString, forKey: "cs.lastSession")
    }

    func deleteSession(_ id: UUID) {
        if isGenerating { stop() }
        sessions.removeAll { $0.id == id }
        if currentSessionID == id { currentSessionID = sessions.first?.id }
    }

    func sessions(matching query: String) -> [ChatSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    func send(_ text: String, image: Data?) {
        guard generationTask == nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else { return }
        if currentSession == nil { newSession() }
        guard let index = sessions.firstIndex(where: { $0.id == currentSessionID }) else { return }

        var message = ChatMessage(role: .user, text: trimmed)
        message.imageData = image
        sessions[index].messages.append(message)

        if sessions[index].title == "新对话" {
            sessions[index].title = trimmed.isEmpty ? "图片对话" : String(trimmed.prefix(24))
        }
        sessions[index].updatedAt = Date()
        generate()
    }

    func generate() {
        guard generationTask == nil else { return }
        guard let profile = activeProfile else {
            lastError = "尚未配置 API，请点击顶部模型菜单进入设置"
            return
        }
        guard let key = Keychain.load(account: profile.keychainID), !key.isEmpty else {
            lastError = "配置「\(profile.name)」还没有填写 API Key"
            return
        }
        guard let index = sessions.firstIndex(where: { $0.id == currentSessionID }) else { return }

        let sessionID = sessions[index].id
        let history = sessions[index].messages.filter { !$0.isStreaming }

        var placeholder = ChatMessage(role: .assistant, text: "")
        placeholder.isStreaming = true
        let placeholderID = placeholder.id
        sessions[index].messages.append(placeholder)
        streamingSessionID = sessionID
        isGenerating = true

        let service = APIService(profile: profile, apiKey: key)
        let systemPrompt = profile.systemPrompt

        generationTask = Task {
            do {
                let stream = service.streamReply(history: history, system: systemPrompt)
                for try await delta in stream {
                    appendDelta(delta, to: placeholderID, in: sessionID)
                }
                finish(placeholderID, in: sessionID, error: nil)
            } catch is CancellationError {
                finish(placeholderID, in: sessionID, error: nil)
            } catch {
                finish(placeholderID, in: sessionID, error: error.localizedDescription)
            }
        }
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        if let id = streamingSessionID,
           let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].messages.removeAll { $0.isStreaming && $0.text.isEmpty }
            for i in sessions[index].messages.indices where sessions[index].messages[i].isStreaming {
                sessions[index].messages[i].isStreaming = false
            }
        }
        streamingSessionID = nil
    }

    func regenerate() {
        guard generationTask == nil,
              let index = sessions.firstIndex(where: { $0.id == currentSessionID }) else { return }
        while sessions[index].messages.last?.role == .assistant {
            sessions[index].messages.removeLast()
        }
        guard !sessions[index].messages.isEmpty else { return }
        generate()
    }

    func editMessage(_ messageID: UUID, newText: String) {
        guard let s = sessions.firstIndex(where: { $0.id == currentSessionID }),
              let m = sessions[s].messages.firstIndex(where: { $0.id == messageID }),
              sessions[s].messages[m].role == .user else { return }
        if isGenerating { stop() }
        sessions[s].messages[m].text = newText
        if m < sessions[s].messages.count - 1 {
            sessions[s].messages.removeSubrange((m + 1)...)
        }
        sessions[s].updatedAt = Date()
        generate()
    }

    private func appendDelta(_ delta: String, to messageID: UUID, in sessionID: UUID) {
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }),
              let m = sessions[s].messages.firstIndex(where: { $0.id == messageID }) else { return }
        sessions[s].messages[m].text += delta
    }

    private func finish(_ messageID: UUID, in sessionID: UUID, error: String?) {
        generationTask = nil
        streamingSessionID = nil
        isGenerating = false
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }),
              let m = sessions[s].messages.firstIndex(where: { $0.id == messageID }) else { return }
        sessions[s].messages[m].isStreaming = false
        if sessions[s].messages[m].text.isEmpty {
            sessions[s].messages.remove(at: m)
            if let error { lastError = error }
        } else if let error {
            lastError = error
        }
        sessions[s].updatedAt = Date()
        persistSessions()
    }

    func setActiveProfile(_ id: UUID) {
        activeProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: "cs.activeProfile")
    }

    func saveProfile(_ profile: APIProfile, apiKey: String) {
        if !apiKey.isEmpty { Keychain.save(apiKey, account: profile.keychainID) }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persistProfiles()
    }

    func deleteProfiles(at offsets: IndexSet) {
        for index in offsets { Keychain.delete(account: profiles[index].keychainID) }
        profiles.remove(atOffsets: offsets)
        persistProfiles()
        if let active = activeProfileID, !profiles.contains(where: { $0.id == active }) {
            if let first = profiles.first {
                setActiveProfile(first.id)
            } else {
                activeProfileID = nil
                UserDefaults.standard.removeObject(forKey: "cs.activeProfile")
            }
        }
    }

    private static var sessionsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "cs.profiles"),
           let decoded = try? JSONDecoder().decode([APIProfile].self, from: data) {
            profiles = decoded
        }
        if let id = UserDefaults.standard.string(forKey: "cs.activeProfile"),
           let uuid = UUID(uuidString: id) {
            activeProfileID = uuid
        }
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "cs.profiles")
        }
    }

    private func loadSessions() {
        if let data = try? Data(contentsOf: Self.sessionsURL),
           let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            sessions = decoded
        }
        if let saved = UserDefaults.standard.string(forKey: "cs.lastSession"),
           let id = UUID(uuidString: saved),
           sessions.contains(where: { $0.id == id }) {
            currentSessionID = id
        } else {
            currentSessionID = sessions.first?.id
        }
    }

    private func persistSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: Self.sessionsURL, options: .atomic)
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            persistSessions()
        }
    }
}

// MARK: - 消息视图

struct MessageView: View {
    @EnvironmentObject private var store: ChatStore
    let message: ChatMessage
    var isLastAssistant: Bool = false
    var onEdit: () -> Void = {}

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                ClaudeStar()
                    .frame(width: 20, height: 20)
                    .padding(.top, 4)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                content
                if !message.isStreaming, !(message.role == .assistant && message.text.isEmpty) {
                    actions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 8) {
                if let data = message.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 190, maxHeight: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.primaryText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.bubbleUser))
                }
            }
        case .assistant:
            HStack(alignment: .bottom, spacing: 2) {
                MarkdownView(text: message.text)
                if message.isStreaming {
                    TypingCursor().padding(.bottom, 3)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 18) {
            if message.role == .assistant {
                actionIcon(copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = message.text
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                if isLastAssistant {
                    actionIcon("arrow.clockwise") { store.regenerate() }
                }
            } else {
                actionIcon("pencil") { onEdit() }
            }
        }
    }

    private func actionIcon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Markdown 渲染

struct MarkdownView: View {
    let text: String

    var body: some View {
        if text.isEmpty {
            Text("…")
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(Color.primaryText.opacity(0.35))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                    block.view
                }
            }
            .font(.system(size: 16, design: .serif))
            .foregroundStyle(Color.primaryText)
            .textSelection(.enabled)
        }
    }
}

enum MarkdownParser {

    enum MDBlock {
        case paragraph(AttributedString)
        case heading(Int, AttributedString)
        case bullets([AttributedString])
        case numbered([AttributedString])
        case quote([AttributedString])
        case divider
        case code(String?, String)
    }

    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        for (isCode, content) in splitCodeFences(text) {
            if isCode {
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let language = lines.first ?? ""
                let code = lines.dropFirst().joined(separator: "\n")
                blocks.append(.code(language.isEmpty ? nil : language, code))
            } else {
                blocks.append(contentsOf: parseText(content))
            }
        }
        return blocks
    }

    private static func splitCodeFences(_ text: String) -> [(isCode: Bool, content: String)] {
        var result: [(isCode: Bool, content: String)] = []
        var current = ""
        var inCode = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("```") {
                if inCode {
                    result.append((true, current))
                    current = ""
                    inCode = false
                } else {
                    if !current.isEmpty { result.append((false, current)); current = "" }
                    inCode = true
                    current = line.dropFirst(3).trimmingCharacters(in: .whitespaces) + "\n"
                }
            } else {
                current += line + "\n"
            }
        }
        if !current.isEmpty { result.append((inCode, current)) }
        return result
    }

    private static func parseText(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quotes: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
                paragraph = []
            }
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets.map(inline))); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered.map(inline))); numbered = [] }
            if !quotes.isEmpty { blocks.append(.quote(quotes.map(inline))); quotes = [] }
        }
        func flushAll() { flushParagraph(); flushLists() }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushAll(); continue }
            if trimmed.hasPrefix("```") { continue }

            if let level = headingLevel(trimmed) {
                flushAll()
                blocks.append(.heading(level, inline(String(trimmed.dropFirst(level + 1)))))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.divider)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quotes.append(trimmed == ">" ? "" : String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }
            if let item = numberedItem(trimmed) {
                flushParagraph()
                numbered.append(item)
                continue
            }
            flushLists()
            paragraph.append(line)
        }
        flushAll()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        for level in 1...6 where line.hasPrefix(String(repeating: "#", count: level) + " ") {
            return level
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let digits = line[..<dot]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    private static func inline(_ s: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(s)
        for run in attributed.runs {
            if run.presentationIntent?.components.first?.kind == .code {
                attributed[run.range].font = .system(size: 15, design: .monospaced)
                attributed[run.range].foregroundColor = .claudeOrange
            } else if run.link != nil {
                attributed[run.range].foregroundColor = .claudeOrange
            }
        }
        return attributed
    }
}

extension MarkdownParser.MDBlock {
    @ViewBuilder
    var view: some View {
        switch self {
        case .paragraph(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: level == 1 ? 24 : (level == 2 ? 20 : 17),
                              weight: .semibold, design: .serif))
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(Color.claudeOrange.opacity(0.75))
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(index + 1).")
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let items):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.claudeOrange.opacity(0.5))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(Color.secondary)
            }
            .padding(.vertical, 2)
        case .divider:
            Divider()
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Rectangle().fill(Color.separator).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 13, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.fieldBorder))
    }
}

// MARK: - 主界面

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore
    @Binding var showSidebar: Bool

    @State private var input = ""
    @State private var pendingImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var editTarget: ChatMessage?
    @State private var showSettings = false

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.separator).frame(height: 0.5)

            if let session = store.currentSession, !session.messages.isEmpty {
                messageList(session)
            } else {
                emptyState
            }

            if let error = store.lastError {
                errorBanner(error)
            }

            inputBar
        }
        .background(Color.paper)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .sheet(item: $editTarget) { message in
            EditMessageSheet(message: message) { newText in
                store.editMessage(message.id, newText: newText)
                editTarget = nil
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) { showSidebar = true }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(store.currentSession?.title ?? "Claude Studio")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Menu {
                    ForEach(store.profiles) { profile in
                        Button {
                            store.setActiveProfile(profile.id)
                        } label: {
                            if profile.id == store.activeProfileID {
                                Label("\(profile.name) · \(profile.model)", systemImage: "checkmark")
                            } else {
                                Text("\(profile.name) · \(profile.model)")
                            }
                        }
                    }
                    Divider()
                    Button {
                        showSettings = true
                    } label: {
                        Label("管理 API 配置", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(store.activeProfile?.name ?? "未配置模型")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
            }

            Spacer(minLength: 0)

            Button {
                store.newSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func messageList(_ session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    let lastAssistantID = session.messages.last(where: { $0.role == .assistant })?.id
                    ForEach(session.messages) { message in
                        MessageView(message: message, isLastAssistant: message.id == lastAssistantID) {
                            editTarget = message
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: session.messages.count)
            }
            .scrollDismissesKeyboard(.immediately)
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: session.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: session.messages.last?.text) { _ in
                if store.isGenerating { scrollToBottom(proxy) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = store.currentSession?.messages.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ClaudeStar().frame(width: 34, height: 34)
            Text("有什么可以帮您？")
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(Color.primaryText)
            if let profile = store.activeProfile {
                Text("\(profile.name) · \(profile.model)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }
            if needsKeySetup {
                Button {
                    showSettings = true
                } label: {
                    Label("去填写 API Key", systemImage: "key.horizontal")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.claudeOrange)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    private var needsKeySetup: Bool {
        guard let profile = store.activeProfile,
              let key = Keychain.load(account: profile.keychainID), !key.isEmpty else { return true }
        return false
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.primaryText)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                store.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let image = pendingImage {
                HStack(spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { pendingImage = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                TextField("发送消息…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color.fieldBackground))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.fieldBorder))

                Button {
                    if store.isGenerating {
                        store.stop()
                    } else {
                        let text = input
                        let imageData = compressImage(pendingImage)
                        store.send(text, image: imageData)
                        input = ""
                        withAnimation(.easeOut(duration: 0.18)) {
                            pendingImage = nil
                            pickerItem = nil
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill((canSend || store.isGenerating)
                                  ? Color.claudeOrange
                                  : Color.secondary.opacity(0.3))
                        Image(systemName: store.isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !store.isGenerating)
                .padding(.bottom, 1)
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            Color.paper
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.separator).frame(height: 0.5)
                }
        )
        .animation(.easeOut(duration: 0.18), value: pendingImage != nil)
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    withAnimation(.easeOut(duration: 0.18)) { pendingImage = image }
                }
                pickerItem = nil
            }
        }
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @EnvironmentObject private var store: ChatStore
    @Binding var isPresented: Bool
    @State private var search = ""
    @State private var showSettings = false

    private var filtered: [ChatSession] {
        store.sessions(matching: search).sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if isPresented {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) {
                                isPresented = false
                            }
                        }
                    panel
                        .frame(width: min(300, geo.size.width * 0.82))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.92), value: isPresented)
        .allowsHitTesting(isPresented)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ClaudeStar().frame(width: 20, height: 20)
                Text("Claude Studio")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.primaryText)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Button {
                store.newSession()
                withAnimation { isPresented = false }
            } label: {
                Label("新对话", systemImage: "plus.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.claudeOrange.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.claudeOrange)
            .padding(.horizontal, 14)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                TextField("搜索对话", text: $search)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.fieldBackground))
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { session in
                        sessionRow(session)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()
            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background { Color.sidebarBackground.ignoresSafeArea() }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        Button {
            store.selectSession(session.id)
            withAnimation { isPresented = false }
        } label: {
            HStack(spacing: 10) {
                if session.id == store.currentSessionID {
                    ClaudeStar().frame(width: 14, height: 14)
                } else {
                    Image(systemName: "message")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(1)
                    Text(session.updatedAt, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(session.id == store.currentSessionID
                        ? Color.claudeOrange.opacity(0.1)
                        : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                store.deleteSession(session.id)
            } label: {
                Label("删除对话", systemImage: "trash")
            }
        }
    }
}

// MARK: - 编辑消息弹层

struct EditMessageSheet: View {
    let message: ChatMessage
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(size: 16))
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color.paper)
                .navigationTitle("编辑消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存并重发") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .onAppear { text = message.text }
    }
}

// MARK: - 附件压缩

func compressImage(_ image: UIImage?) -> Data? {
    guard let image else { return nil }
    let maxDimension: CGFloat = 1024
    let ratio = min(1, maxDimension / max(image.size.width, image.size.height))
    let size = CGSize(width: round(image.size.width * ratio),
                      height: round(image.size.height * ratio))
    let renderer = UIGraphicsImageRenderer(size: size)
    let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    return resized.jpegData(compressionQuality: 0.7)
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: APIProfile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.profiles) { profile in
                        Button {
                            store.setActiveProfile(profile.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text("\(profile.provider.label) · \(profile.model)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    if Keychain.load(account: profile.keychainID) == nil {
                                        Label("未设置 Key", systemImage: "exclamationmark.circle")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if profile.id == store.activeProfileID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.claudeOrange)
                                }
                            }
                        }
                    }
                    .onDelete { store.deleteProfiles(at: $0) }

                    Button {
                        editing = APIProfile(
                            name: "新配置",
                            provider: .anthropic,
                            baseURL: Provider.anthropic.defaultBaseURL,
                            model: Provider.anthropic.placeholderModel
                        )
                    } label: {
                        Label("添加配置", systemImage: "plus.circle")
                    }
                } header: {
                    Text("API 配置（点击切换当前使用的模型）")
                }

                Section("偏好") {
                    Label("深浅色跟随系统设置", systemImage: "circle.lefthalf.filled")
                        .font(.system(size: 14))
                    Label("API Key 使用 Keychain 加密存储", systemImage: "lock.shield")
                        .font(.system(size: 14))
                    Label("对话记录仅保存在本机", systemImage: "internaldrive")
                        .font(.system(size: 14))
                }

                Section("关于") {
                    LabeledContent("版本", value: "0.2")
                    LabeledContent("支持协议", value: "Anthropic Messages / OpenAI 兼容（SSE 流式）")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { profile in
                ProfileEditor(profile: profile).environmentObject(store)
            }
        }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State var profile: APIProfile
    @State private var apiKey = ""
    @State private var showKey = false

    private var hasSavedKey: Bool {
        guard let key = Keychain.load(account: profile.keychainID), !key.isEmpty else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称（如 Claude / GPT / 中转）", text: $profile.name)
                    Picker("接口类型", selection: $profile.provider) {
                        ForEach(Provider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    TextField("Base URL（可填中转地址）", text: $profile.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("模型名称", text: $profile.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                Section {
                    HStack {
                        Group {
                            if showKey {
                                TextField("sk-ant-…", text: $apiKey)
                            } else {
                                SecureField("sk-ant-…", text: $apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    if hasSavedKey {
                        Label(apiKey.isEmpty ? "已保存密钥，留空表示不修改" : "将覆盖已保存的密钥",
                              systemImage: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("密钥仅保存在本机 Keychain，不会上传到任何服务器。")
                }

                Section("系统提示词（可选）") {
                    TextEditor(text: $profile.systemPrompt)
                        .frame(minHeight: 90)
                }
            }
            .navigationTitle("编辑配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.saveProfile(profile, apiKey: apiKey)
                        dismiss()
                    }
                    .disabled(profile.name.isEmpty || profile.baseURL.isEmpty || profile.model.isEmpty)
                }
            }
            .onChange(of: profile.provider) { _ in
                profile.baseURL = profile.provider.defaultBaseURL
                profile.model = profile.provider.placeholderModel
            }
        }
    }
}
