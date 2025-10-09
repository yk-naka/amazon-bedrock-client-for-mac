//
//  ChatViewModel.swift
//  Amazon Bedrock Client for Mac
//
//  Created by Na, Sanghwa on 6/28/24.
//

import AWSBedrockRuntime
import Combine
import Logging
import Smithy
import SwiftUI

// MARK: - Required Type Definitions for Bedrock API integration

enum MessageRole: String, Codable {
    case user = "user"
    case assistant = "assistant"
}

enum MessageContent: Codable {
    case text(String)
    case image(ImageContent)
    case document(DocumentContent)
    case thinking(ThinkingContent)
    case toolresult(ToolResultContent)
    case tooluse(ToolUseContent)

    // For encoding/decoding
    private enum CodingKeys: String, CodingKey {
        case type, text, image, document, thinking, toolresult, tooluse
    }

    struct ImageContent: Codable {
        let format: ImageFormat
        let base64Data: String
    }

    struct DocumentContent: Codable {
        let format: DocumentFormat
        let base64Data: String
        let name: String
    }

    struct ThinkingContent: Codable {
        let text: String
        let signature: String
    }

    struct ToolResultContent: Codable {
        let toolUseId: String
        let result: String
        let status: String
    }

    struct ToolUseContent: Codable {
        let toolUseId: String
        let name: String
        let input: JSONValue
    }

    enum DocumentFormat: String, Codable {
        case pdf = "pdf"
        case csv = "csv"
        case doc = "doc"
        case docx = "docx"
        case xls = "xls"
        case xlsx = "xlsx"
        case html = "html"
        case txt = "txt"
        case md = "md"

        static func fromExtension(_ ext: String) -> DocumentFormat {
            let lowercased = ext.lowercased()
            switch lowercased {
            case "pdf": return .pdf
            case "csv": return .csv
            case "doc": return .doc
            case "docx": return .docx
            case "xls": return .xls
            case "xlsx": return .xlsx
            case "html": return .html
            case "txt": return .txt
            case "md": return .md
            default: return .pdf  // Default to PDF if unsupported
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let imageContent):
            try container.encode("image", forKey: .type)
            try container.encode(imageContent, forKey: .image)
        case .document(let documentContent):
            try container.encode("document", forKey: .type)
            try container.encode(documentContent, forKey: .document)
        case .thinking(let thinkingContent):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinkingContent, forKey: .thinking)
        case .toolresult(let toolResultContent):
            try container.encode("toolresult", forKey: .type)
            try container.encode(toolResultContent, forKey: .toolresult)
        case .tooluse(let toolUseContent):
            try container.encode("tooluse", forKey: .type)
            try container.encode(toolUseContent, forKey: .tooluse)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let imageContent = try container.decode(ImageContent.self, forKey: .image)
            self = .image(imageContent)
        case "document":
            let documentContent = try container.decode(DocumentContent.self, forKey: .document)
            self = .document(documentContent)
        case "thinking":
            let thinkingContent = try container.decode(ThinkingContent.self, forKey: .thinking)
            self = .thinking(thinkingContent)
        case "toolresult":
            let toolResultContent = try container.decode(
                ToolResultContent.self, forKey: .toolresult)
            self = .toolresult(toolResultContent)
        case "tooluse":
            let toolUseContent = try container.decode(ToolUseContent.self, forKey: .tooluse)
            self = .tooluse(toolUseContent)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content type: \(type)"
            )
        }
    }
}

struct BedrockMessage: Codable {
    let role: MessageRole
    var content: [MessageContent]
}

struct ToolUseError: Error {
    let message: String
}

// New struct for tool results in a modal
struct ToolResultInfo: Identifiable {
    let id: UUID = UUID()
    let toolUseId: String
    let toolName: String
    let input: JSONValue
    let result: String
    let status: String
    let timestamp: Date = Date()
}

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Properties
    let chatId: String
    let chatManager: ChatManager
    let sharedMediaDataSource: SharedMediaDataSource
    @ObservedObject private var settingManager = SettingManager.shared
    @ObservedObject private var mcpManager = MCPManager.shared

    @ObservedObject var backendModel: BackendModel
    @Published var chatModel: ChatModel
    @Published var messages: [MessageData] = []
    @Published var userInput: String = ""
    @Published var isMessageBarDisabled: Bool = false
    @Published var isSending: Bool = false
    @Published var isStreamingEnabled: Bool = false
    @Published var selectedPlaceholder: String
    @Published var emptyText: String = ""
    @Published var availableTools: [MCPToolInfo] = []

    // New properties for tool results modal
    @Published var toolResults: [ToolResultInfo] = []
    @Published var isToolResultModalVisible: Bool = false
    @Published var selectedToolResult: ToolResultInfo?

    private var logger = Logger(label: "ChatViewModel")
    private var cancellables: Set<AnyCancellable> = []
    private var messageTask: Task<Void, Never>?

    // Track current message ID being streamed to fix duplicate issue
    private var currentStreamingMessageId: UUID?

    // NEW: Track the last sent message to prevent immediate duplicates
    private var lastSentMessageText: String = ""
    private var lastSentMessageTime: Date = Date.distantPast

    // NEW: Actor for exclusive message sending to prevent race conditions
    private let sendLock = SendMessageLock()

    // Usage handler for displaying token usage information
    var usageHandler: ((String) -> Void)?

    // Actor to ensure only one message is being sent at a time
    actor SendMessageLock {
        private var isLocked = false

        func tryLock(messageText: String) -> Bool {
            guard !isLocked else {
                return false
            }
            isLocked = true
            return true
        }

        func unlock() {
            isLocked = false
        }
    }

    // Edit/Delete/OrganizeContext notification handlers
    private var editMessageNotification: AnyCancellable?
    private var deleteMessageNotification: AnyCancellable?
    private var organizeContextNotification: AnyCancellable?

    // Edit dialog state
    @Published var isEditDialogVisible: Bool = false
    @Published var editingMessageId: UUID?
    @Published var editingMessageText: String = ""
    @Published var isEditingUserMessage: Bool = false

    // Context organization state
    @Published var isContextOrganizationInProgress: Bool = false
    @Published var isContextCacheOptimizationInProgress: Bool = false

    // Format usage information for display
    private func formatUsageString(_ usage: UsageInfo) -> String {
        var parts: [String] = []

        if let input = usage.inputTokens {
            parts.append("Input: \(input)")
        }

        if let output = usage.outputTokens {
            parts.append("Output: \(output)")
        }

        if let cacheRead = usage.cacheReadInputTokens, cacheRead > 0 {
            parts.append("Cache Read: \(cacheRead)")
        }

        if let cacheWrite = usage.cacheCreationInputTokens, cacheWrite > 0 {
            parts.append("Cache Write: \(cacheWrite)")
        }

        return parts.joined(separator: " • ")
    }

    // MARK: - Initialization

    init(
        chatId: String, backendModel: BackendModel, chatManager: ChatManager = .shared,
        sharedMediaDataSource: SharedMediaDataSource
    ) {
        self.chatId = chatId
        self.backendModel = backendModel
        self.chatManager = chatManager
        self.sharedMediaDataSource = sharedMediaDataSource

        // Try to get existing chat model, or create a temporary one if not found
        if let model = chatManager.getChatModel(for: chatId) {
            self.chatModel = model
            self.selectedPlaceholder = ""
            setupStreamingEnabled()
            setupBindings()
        } else {
            // Create a temporary model and load asynchronously
            logger.warning("Chat model not found for id: \(chatId), will attempt to load or create")
            self.chatModel = ChatModel(
                id: chatId,
                chatId: chatId,
                name: "Loading...",
                title: "Loading...",
                description: "",
                provider: "bedrock",
                lastMessageDate: Date()
            )
            self.selectedPlaceholder = ""

            // Try to load the model asynchronously
            Task {
                await loadChatModel()
            }
        }
    }

    // MARK: - Setup Methods

    private func setupStreamingEnabled() {
        self.isStreamingEnabled = isTextGenerationModel(chatModel.id)
    }

    private func setupBindings() {
        chatManager.$chats
            .map { [weak self] chats in
                chats.first { $0.chatId == self?.chatId }
            }
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .assign(to: \.chatModel, on: self)
            .store(in: &cancellables)

        $chatModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] model in
                guard let self = self else { return }
                self.isStreamingEnabled = self.isTextGenerationModel(model.id)
            }
            .store(in: &cancellables)

        // Edit/Delete notification handlers
        setupEditDeleteNotifications()
    }

    private func setupEditDeleteNotifications() {
        // Edit message notification
        editMessageNotification = NotificationCenter.default
            .publisher(for: NSNotification.Name("EditMessage"))
            .sink { [weak self] notification in
                guard let self = self,
                    let userInfo = notification.userInfo,
                    let messageId = userInfo["messageId"] as? UUID,
                    let messageText = userInfo["messageText"] as? String,
                    let isUserMessage = userInfo["isUserMessage"] as? Bool
                else { return }

                self.handleEditMessage(
                    messageId: messageId, messageText: messageText, isUserMessage: isUserMessage)
            }

        // Delete message notification
        deleteMessageNotification = NotificationCenter.default
            .publisher(for: NSNotification.Name("DeleteMessage"))
            .sink { [weak self] notification in
                guard let self = self,
                    let userInfo = notification.userInfo,
                    let messageId = userInfo["messageId"] as? UUID,
                    let isUserMessage = userInfo["isUserMessage"] as? Bool
                else { return }

                self.handleDeleteMessage(messageId: messageId, isUserMessage: isUserMessage)
            }

        // Organize context notification
        organizeContextNotification = NotificationCenter.default
            .publisher(for: NSNotification.Name("OrganizeContext"))
            .sink { [weak self] notification in
                guard let self = self else { return }
                self.organizeContext()
            }

        // Context cache optimization notification
        NotificationCenter.default
            .publisher(for: NSNotification.Name("OptimizeContextCache"))
            .sink { [weak self] notification in
                guard let self = self else { return }
                self.optimizeContextCache()
            }
            .store(in: &cancellables)
    }

    private func loadChatModel() async {
        // Try to find existing model for up to 10 attempts
        for attempt in 0..<10 {
            if let model = chatManager.getChatModel(for: chatId) {
                await MainActor.run {
                    self.chatModel = model
                    setupStreamingEnabled()
                    setupBindings()
                }
                logger.info(
                    "Successfully loaded chat model for id: \(chatId) after \(attempt + 1) attempts"
                )
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
        }

        // If still not found, create a new chat
        logger.warning(
            "Chat model still not found for id: \(chatId) after 10 attempts, creating new chat")

        await MainActor.run {
            // Use default values since we can't access BackendModel properties directly
            chatManager.createNewChat(
                modelId: "claude-3-5-sonnet-20241022-v2:0",  // Default model
                modelName: "Claude 3.5 Sonnet",
                modelProvider: "anthropic"
            ) { [weak self] newModel in
                guard let self = self else { return }

                // Update the chat ID if it was changed during creation
                if newModel.id != self.chatId {
                    logger.info("Chat ID changed from \(self.chatId) to \(newModel.id)")
                }

                self.chatModel = newModel
                self.setupStreamingEnabled()
                self.setupBindings()
                logger.info("Successfully created new chat model with id: \(newModel.id)")
            }
        }
    }

    // MARK: - Public Methods

    func loadInitialData() {
        let loadedMessages = chatManager.getMessages(for: chatId)

        // NEW: Remove consecutive duplicate messages on load
        messages = removeDuplicateConsecutiveMessages(loadedMessages)

        // If duplicates were removed, save the cleaned messages back
        if messages.count < loadedMessages.count {
            logger.info(
                "🔧 Removed \(loadedMessages.count - messages.count) duplicate messages on load")

            // Clean and resave to storage and history
            Task {
                await cleanAndResaveMessages()
            }
        }
    }

    /// Removes consecutive duplicate messages (same role, same text)
    private func removeDuplicateConsecutiveMessages(_ messages: [MessageData]) -> [MessageData] {
        guard messages.count > 1 else { return messages }

        var cleaned: [MessageData] = []
        var previousMessage: MessageData? = nil

        for message in messages {
            // Check if this is a duplicate of the previous message
            if let prev = previousMessage,
                prev.user == message.user,
                prev.text == message.text,
                !prev.isError && !message.isError
            {
                // Skip this duplicate
                logger.info(
                    "🔧 Skipping duplicate message: '\(message.text.prefix(50))...' from \(message.user)"
                )
                continue
            }

            cleaned.append(message)
            previousMessage = message
        }

        return cleaned
    }

    /// Cleans and resaves messages to storage and history
    private func cleanAndResaveMessages() async {
        // Rebuild conversation history from cleaned messages
        var cleanedHistory: [BedrockMessage] = []

        for message in messages {
            let role: MessageRole = message.user == "User" ? .user : .assistant

            // CRITICAL: Check for tool_result user messages FIRST
            if role == .user, let toolUse = message.toolUse, let toolResult = message.toolResult {
                // User message with tool_result: Create ONLY tool_result block
                let toolResultMessage = BedrockMessage(
                    role: role,
                    content: [
                        .toolresult(
                            MessageContent.ToolResultContent(
                                toolUseId: toolUse.id,
                                result: toolResult,
                                status: "success"
                            ))
                    ]
                )
                cleanedHistory.append(toolResultMessage)
                logger.debug(
                    "🔧 [CleanAndResave] Created STRICT tool_result-only user message for tool ID: \(toolUse.id)"
                )
                continue  // Skip all other content processing for this message
            }

            var contents: [MessageContent] = []

            // Add text
            if !message.text.isEmpty {
                contents.append(.text(message.text))
            }

            // Add thinking if present
            if let thinking = message.thinking, !thinking.isEmpty {
                contents.append(
                    .thinking(
                        MessageContent.ThinkingContent(
                            text: thinking,
                            signature: message.signature ?? UUID().uuidString
                        )))
            }

            // Add images if present
            if let imageBase64Strings = message.imageBase64Strings {
                for base64 in imageBase64Strings {
                    contents.append(
                        .image(
                            MessageContent.ImageContent(
                                format: .jpeg,
                                base64Data: base64
                            )))
                }
            }

            // Add documents if present
            if let docBase64 = message.documentBase64Strings,
                let docFormats = message.documentFormats,
                let docNames = message.documentNames
            {
                for i in 0..<min(docBase64.count, min(docFormats.count, docNames.count)) {
                    contents.append(
                        .document(
                            MessageContent.DocumentContent(
                                format: MessageContent.DocumentFormat.fromExtension(docFormats[i]),
                                base64Data: docBase64[i],
                                name: docNames[i]
                            )))
                }
            }

            // Add tool use for assistant messages only
            // CRITICAL: User tool_result messages are handled separately above
            if role == .assistant, let toolUse = message.toolUse {
                contents.append(
                    .tooluse(
                        MessageContent.ToolUseContent(
                            toolUseId: toolUse.id,
                            name: toolUse.name,
                            input: toolUse.input
                        )))
            }

            if !contents.isEmpty {
                cleanedHistory.append(BedrockMessage(role: role, content: contents))
            }
        }

        // Save cleaned history
        await saveConversationHistory(cleanedHistory)
        logger.info(
            "✅ Cleaned and resaved conversation history with \(cleanedHistory.count) messages")
    }

    func sendMessage() {
        guard !userInput.isEmpty else { return }

        // Prevent duplicate sends - check if already sending
        guard !isSending else {
            logger.warning("⚠️ Message send blocked: Already sending a message")
            return
        }

        // Prevent duplicate sends - check if message bar is disabled
        guard !isMessageBarDisabled else {
            logger.warning("⚠️ Message send blocked: Message bar is disabled")
            return
        }

        messageTask?.cancel()
        messageTask = Task { await sendMessageAsync() }
    }

    func cancelSending() {
        messageTask?.cancel()
        chatManager.setIsLoading(false, for: chatId)
    }

    func showToolResultDetails(_ toolResult: ToolResultInfo) {
        selectedToolResult = toolResult
        isToolResultModalVisible = true
    }

    // MARK: - Model Switching

    /// Switches the model for the current chat conversation
    func switchModel(to newModelId: String, modelName: String, provider: String) {
        logger.info("Switching model from \(chatModel.id) to \(newModelId)")

        // Update the chat model
        let updatedChatModel = ChatModel(
            id: newModelId,
            chatId: chatModel.chatId,  // Keep the same chat ID
            name: modelName,
            title: chatModel.title,
            description: newModelId,
            provider: provider,
            lastMessageDate: Date()
        )

        // Update the view model's chat model
        self.chatModel = updatedChatModel

        // Update streaming capability based on new model
        self.isStreamingEnabled = isTextGenerationModel(newModelId)

        // Update the chat manager's record
        chatManager.updateChatModel(
            for: chatId, newModelId: newModelId, modelName: modelName, provider: provider)

        // Add a system message to indicate the model switch
        let switchMessage = MessageData(
            id: UUID(),
            text: "--- モデルを \(modelName) に切り替えました ---",
            user: "System",
            isError: false,
            sentTime: Date()
        )
        addMessage(switchMessage)

        // Check for model capability differences and warn user if needed
        checkModelCapabilityChanges(from: chatModel.id, to: newModelId)

        logger.info("Successfully switched to model: \(modelName)")
    }

    /// Checks for capability differences between models and shows warnings
    private func checkModelCapabilityChanges(from oldModelId: String, to newModelId: String) {
        var warnings: [String] = []

        // Check vision support
        let oldVisionSupport = backendModel.backend.isVisionSupported(oldModelId)
        let newVisionSupport = backendModel.backend.isVisionSupported(newModelId)

        if oldVisionSupport && !newVisionSupport {
            warnings.append("新しいモデルは画像分析をサポートしていません")
        }

        // Check tool use support
        let oldToolSupport = backendModel.backend.isToolUseSupported(oldModelId)
        let newToolSupport = backendModel.backend.isToolUseSupported(newModelId)

        if oldToolSupport && !newToolSupport {
            warnings.append("新しいモデルはツール使用をサポートしていません")
        }

        // Check document chat support
        let oldDocSupport = backendModel.backend.isDocumentChatSupported(oldModelId)
        let newDocSupport = backendModel.backend.isDocumentChatSupported(newModelId)

        if oldDocSupport && !newDocSupport {
            warnings.append("新しいモデルはドキュメント分析をサポートしていません")
        }

        // Check reasoning support
        let oldReasoningSupport = backendModel.backend.isReasoningSupported(oldModelId)
        let newReasoningSupport = backendModel.backend.isReasoningSupported(newModelId)

        if oldReasoningSupport && !newReasoningSupport {
            warnings.append("新しいモデルは推論機能をサポートしていません")
        }

        // Show warnings if any
        if !warnings.isEmpty {
            let warningMessage = MessageData(
                id: UUID(),
                text: "⚠️ 注意: " + warnings.joined(separator: "、"),
                user: "System",
                isError: false,
                sentTime: Date()
            )
            addMessage(warningMessage)
        }
    }

    // MARK: - Tool Use Tracker (Made Sendable)

    actor ToolUseTracker {
        static let shared = ToolUseTracker()

        private var toolUseId: String?
        private var name: String?
        private var inputString = ""
        private var currentBlockIndex: Int?

        func reset() {
            toolUseId = nil
            name = nil
            inputString = ""
            currentBlockIndex = nil
        }

        func setCurrentBlockIndex(_ index: Int) {
            currentBlockIndex = index
        }

        func setToolUseInfo(id: String, name: String) {
            self.toolUseId = id
            self.name = name
        }

        func appendToInputString(_ text: String) {
            inputString += text
        }

        func getCurrentBlockIndex() -> Int? {
            return currentBlockIndex
        }

        func getToolUseId() -> String? {
            return toolUseId
        }

        func getToolName() -> String? {
            return name
        }

        func getInputString() -> String {
            return inputString
        }
    }

    // MARK: - Private Message Handling Methods

    private func sendMessageAsync() async {
        // NEW: Actor-based exclusive lock to prevent race conditions
        let messageText = userInput
        let canProceed = await sendLock.tryLock(messageText: messageText)

        guard canProceed else {
            logger.error(
                "🚫 CRITICAL: Another sendMessageAsync() is already running - BLOCKED by actor lock")
            return
        }

        // Ensure we unlock when done (using defer)
        defer {
            Task {
                await sendLock.unlock()
            }
        }

        let now = Date()

        // Check if this is a duplicate of the last sent message
        if messageText == lastSentMessageText && now.timeIntervalSince(lastSentMessageTime) < 2.0 {
            logger.error(
                "🚫 CRITICAL: Duplicate sendMessageAsync() blocked - same message sent \(now.timeIntervalSince(lastSentMessageTime)) seconds ago"
            )
            return
        }

        // Update tracking before any async operations
        lastSentMessageText = messageText
        lastSentMessageTime = now

        // Set sending flag immediately to prevent duplicate sends
        isSending = true
        chatManager.setIsLoading(true, for: chatId)
        isMessageBarDisabled = true

        let tempInput = messageText
        Task {
            await updateChatTitle(with: tempInput)
        }

        let userMessage = createUserMessage()
        addUIOnlyMessage(userMessage)

        userInput = ""
        sharedMediaDataSource.images.removeAll()
        sharedMediaDataSource.fileExtensions.removeAll()
        sharedMediaDataSource.documents.removeAll()

        do {
            if backendModel.backend.isImageGenerationModel(chatModel.id) {
                try await handleImageGenerationModel(userMessage)
            } else if backendModel.backend.isEmbeddingModel(chatModel.id) {
                try await handleEmbeddingModel(userMessage)
            } else {
                // Check if streaming is enabled for this model
                let modelConfig = settingManager.getInferenceConfig(for: chatModel.id)
                let shouldUseStreaming =
                    modelConfig.overrideDefault ? modelConfig.enableStreaming : true

                if shouldUseStreaming {
                    try await handleTextLLMWithConverseStream(userMessage)
                } else {
                    try await handleTextLLMWithNonStreaming(userMessage)
                }
            }
        } catch let error as ToolUseError {
            let errorMessage = MessageData(
                id: UUID(),
                text: "Tool Use Error: \(error.message)",
                user: "System",
                isError: true,
                sentTime: Date()
            )
            addMessage(errorMessage)
        } catch let error {
            if let nsError = error as NSError?,
                nsError.localizedDescription.contains("ValidationException")
                    && nsError.localizedDescription.contains("maxLength: 512")
            {
                let errorMessage = MessageData(
                    id: UUID(),
                    text:
                        "Error: Your prompt is too long. Titan Image Generator has a 512 character limit for prompts. Please try again with a shorter prompt.",
                    user: "System",
                    isError: true,
                    sentTime: Date()
                )
                addMessage(errorMessage)
            } else {
                await handleModelError(error)
            }
        }

        isMessageBarDisabled = false
        chatManager.setIsLoading(false, for: chatId)
        isSending = false
    }

    private func createUserMessage() -> MessageData {
        // Process images
        let imageBase64Strings = sharedMediaDataSource.images.enumerated().compactMap {
            index, image -> String? in
            guard index < sharedMediaDataSource.fileExtensions.count else {
                logger.error("Missing extension for image at index \(index)")
                return nil
            }

            let fileExtension = sharedMediaDataSource.fileExtensions[index]
            let result = base64EncodeImage(image, withExtension: fileExtension)
            return result.base64String
        }

        // Process documents
        var documentBase64Strings: [String] = []
        var documentFormats: [String] = []
        var documentNames: [String] = []

        for (index, docData) in sharedMediaDataSource.documents.enumerated() {
            let docIndex = sharedMediaDataSource.images.count + index

            let fileExt =
                docIndex < sharedMediaDataSource.fileExtensions.count
                ? sharedMediaDataSource.fileExtensions[docIndex] : "pdf"

            let filename =
                docIndex < sharedMediaDataSource.filenames.count
                ? sharedMediaDataSource.filenames[docIndex] : "document\(index+1)"

            let base64String = docData.base64EncodedString()
            documentBase64Strings.append(base64String)
            documentFormats.append(fileExt)
            documentNames.append(filename)
        }

        return MessageData(
            id: UUID(),
            text: userInput,
            user: "User",
            isError: false,
            sentTime: Date(),
            imageBase64Strings: imageBase64Strings.isEmpty ? nil : imageBase64Strings,
            documentBase64Strings: documentBase64Strings.isEmpty ? nil : documentBase64Strings,
            documentFormats: documentFormats.isEmpty ? nil : documentFormats,
            documentNames: documentNames.isEmpty ? nil : documentNames
        )
    }

    // MARK: - Tool Conversion and Processing

    private func convertMCPToolsToBedrockFormat(_ tools: [MCPToolInfo])
        -> AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration
    {
        logger.debug("Converting \(tools.count) MCP tools to Bedrock format")

        let bedrockTools: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Tool] = tools.compactMap {
            toolInfo in
            var propertiesDict: [String: Any] = [:]
            var required: [String] = []

            if case .object(let schemaDict) = toolInfo.tool.inputSchema {
                if case .object(let propertiesMap)? = schemaDict["properties"] {
                    for (key, value) in propertiesMap {
                        if case .object(let propDetails) = value,
                            case .string(let typeValue)? = propDetails["type"]
                        {
                            propertiesDict[key] = ["type": typeValue]
                            logger.debug(
                                "Added property \(key) with type \(typeValue) for tool \(toolInfo.toolName)"
                            )
                        }
                    }
                }

                if case .array(let requiredArray)? = schemaDict["required"] {
                    for item in requiredArray {
                        if case .string(let fieldName) = item {
                            required.append(fieldName)
                        }
                    }
                }
            }

            let schemaDict: [String: Any] = [
                "properties": propertiesDict,
                "required": required,
                "type": "object",
            ]

            do {
                let jsonDocument = try Smithy.Document.make(from: schemaDict)

                let toolSpec = AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolSpecification(
                    description: toolInfo.tool.description,
                    inputSchema: .json(jsonDocument),
                    name: toolInfo.toolName
                )

                return AWSBedrockRuntime.BedrockRuntimeClientTypes.Tool.toolspec(toolSpec)
            } catch {
                logger.error(
                    "Failed to create schema document for tool \(toolInfo.toolName): \(error)")
                return nil
            }
        }

        return AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration(
            toolChoice: .auto(AWSBedrockRuntime.BedrockRuntimeClientTypes.AutoToolChoice()),
            tools: bedrockTools
        )
    }

    private func extractToolUseFromChunk(_ chunk: BedrockRuntimeClientTypes.ConverseStreamOutput)
        async -> (toolUseId: String, name: String, input: [String: Any])?
    {
        let tracker = ToolUseTracker.shared

        if case .contentblockstart(let blockStartEvent) = chunk,
            let start = blockStartEvent.start,
            case .tooluse(let toolUseBlockStart) = start,
            let contentBlockIndex = blockStartEvent.contentBlockIndex
        {

            guard let toolUseId = toolUseBlockStart.toolUseId,
                let name = toolUseBlockStart.name
            else {
                logger.warning("Received incomplete tool use block start")
                return nil
            }

            await tracker.reset()
            await tracker.setCurrentBlockIndex(contentBlockIndex)
            await tracker.setToolUseInfo(id: toolUseId, name: name)

            logger.info("Tool use start detected: \(name) with ID: \(toolUseId)")
            return nil
        }

        if case .contentblockdelta(let deltaEvent) = chunk,
            let delta = deltaEvent.delta
        {

            let currentBlockIndex = await tracker.getCurrentBlockIndex()

            if currentBlockIndex == deltaEvent.contentBlockIndex,
                case .tooluse(let toolUseDelta) = delta,
                let inputStr = toolUseDelta.input
            {

                await tracker.appendToInputString(inputStr)
                logger.info("Accumulated tool input: \(inputStr)")
            }
            return nil
        }

        if case .contentblockstop(let stopEvent) = chunk {
            let currentBlockIndex = await tracker.getCurrentBlockIndex()

            if currentBlockIndex == stopEvent.contentBlockIndex,
                let toolUseId = await tracker.getToolUseId(),
                let name = await tracker.getToolName()
            {

                let inputString = await tracker.getInputString()

                var inputDict: [String: Any] = [:]

                if inputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    inputDict = [:]
                } else if let data = inputString.data(using: .utf8) {
                    do {
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        {
                            inputDict = json
                        } else if let jsonArray = try JSONSerialization.jsonObject(with: data)
                            as? [Any]
                        {
                            inputDict = ["array": jsonArray]
                        }
                    } catch {
                        inputDict = ["text": inputString]
                    }
                } else {
                    inputDict = ["text": inputString]
                }

                logger.info("Tool use block completed for \(name). Input: \(inputDict)")
                return (toolUseId: toolUseId, name: name, input: inputDict)
            }
        }

        if case .messagestop(let stopEvent) = chunk,
            stopEvent.stopReason == .toolUse,
            let toolUseId = await tracker.getToolUseId(),
            let name = await tracker.getToolName()
        {

            let inputString = await tracker.getInputString()

            var inputDict: [String: Any] = [:]

            if inputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputDict = [:]
            } else if let data = inputString.data(using: .utf8) {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        inputDict = json
                    } else if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any]
                    {
                        inputDict = ["array": jsonArray]
                    }
                } catch {
                    inputDict = ["text": inputString]
                }
            } else {
                inputDict = ["text": inputString]
            }

            logger.info("Tool use detected from messageStop: \(name)")
            return (toolUseId: toolUseId, name: name, input: inputDict)
        }

        return nil
    }

    // MARK: - handleTextLLMWithConverseStream

    private func handleTextLLMWithConverseStream(_ userMessage: MessageData) async throws {
        // Create message content from user message
        var messageContents: [MessageContent] = []

        // Always include a text prompt as required when sending documents
        let textToSend =
            userMessage.text.isEmpty && (userMessage.documentBase64Strings?.isEmpty == false)
            ? "Please analyze this document." : userMessage.text
        messageContents.append(.text(textToSend))

        // Add images if present
        if let imageBase64Strings = userMessage.imageBase64Strings, !imageBase64Strings.isEmpty {
            for (index, base64String) in imageBase64Strings.enumerated() {
                let fileExtension =
                    index < sharedMediaDataSource.fileExtensions.count
                    ? sharedMediaDataSource.fileExtensions[index].lowercased() : "jpeg"

                let format: ImageFormat
                switch fileExtension {
                case "jpg", "jpeg": format = .jpeg
                case "png": format = .png
                case "gif": format = .gif
                case "webp": format = .webp
                default: format = .jpeg
                }

                messageContents.append(
                    .image(
                        MessageContent.ImageContent(
                            format: format,
                            base64Data: base64String
                        )))
            }
        }

        // Add documents if present
        if let documentBase64Strings = userMessage.documentBase64Strings,
            let documentFormats = userMessage.documentFormats,
            let documentNames = userMessage.documentNames,
            !documentBase64Strings.isEmpty
        {

            for (index, base64String) in documentBase64Strings.enumerated() {
                guard index < documentFormats.count && index < documentNames.count else {
                    continue
                }

                let fileExt = documentFormats[index].lowercased()
                let fileName = documentNames[index]

                let docFormat = MessageContent.DocumentFormat.fromExtension(fileExt)
                messageContents.append(
                    .document(
                        MessageContent.DocumentContent(
                            format: docFormat,
                            base64Data: base64String,
                            name: fileName
                        )))
            }
        }

        // Get conversation history (完全な履歴)
        var fullConversationHistory = await getConversationHistory()

        // Add the current user message to conversation history（直前が同一ユーザー同一テキストならスキップ）
        let userBedrockMessage = BedrockMessage(role: .user, content: messageContents)
        let newUserText = extractTextFromContents(userBedrockMessage.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var shouldAppendUser = true
        if let last = fullConversationHistory.last {
            let lastText = extractTextFromContents(last.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if last.role == .user && !newUserText.isEmpty && lastText == newUserText {
                shouldAppendUser = false
                logger.warning(
                    "🔧 Blocked duplicate user message append to history: '\(newUserText.prefix(50))...'"
                )
            }
        }
        if shouldAppendUser {
            fullConversationHistory.append(userBedrockMessage)
        }

        // 完全な履歴を保存（要約されない）
        await saveConversationHistory(fullConversationHistory)

        // Bedrock送信用に最適化された履歴を取得
        let optimizedHistory = await manageConversationByCharacterCount(fullConversationHistory)

        // Get system prompt
        let systemPrompt = settingManager.systemPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines)

        // Get tool configurations if MCP is enabled
        var toolConfig: AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration? = nil

        if settingManager.mcpEnabled && !mcpManager.toolInfos.isEmpty
            && backendModel.backend.isStreamingToolUseSupported(chatModel.id)
        {
            logger.info(
                "MCP enabled with \(mcpManager.toolInfos.count) tools for supported model \(chatModel.id)."
            )
            toolConfig = convertMCPToolsToBedrockFormat(mcpManager.toolInfos)
        } else if settingManager.mcpEnabled && !mcpManager.toolInfos.isEmpty {
            logger.info(
                "MCP enabled, but model \(chatModel.id) does not support streaming tool use. Tools disabled."
            )
        }

        // Reset tool tracker for new conversation
        await ToolUseTracker.shared.reset()

        let maxTurns = settingManager.maxToolUseTurns
        var turn_count = 0

        // Get Bedrock messages in AWS SDK format (最適化された履歴を使用)
        let bedrockMessages = try optimizedHistory.map {
            try convertToBedrockMessage($0, modelId: chatModel.id)
        }

        // Convert to system prompt format used by AWS SDK
        let systemContentBlock: [AWSBedrockRuntime.BedrockRuntimeClientTypes.SystemContentBlock]? =
            systemPrompt.isEmpty ? nil : [.text(systemPrompt)]

        logger.info("Starting converseStream request with model ID: \(chatModel.id)")
        logger.info(
            "Sending \(bedrockMessages.count) optimized messages to Bedrock (full history: \(fullConversationHistory.count) messages)"
        )

        // Start the tool cycling process
        try await processToolCycles(
            bedrockMessages: bedrockMessages, systemContentBlock: systemContentBlock,
            toolConfig: toolConfig, turnCount: turn_count, maxTurns: maxTurns)
    }

    // Process tool cycles recursively with enhanced error handling
    private func processToolCycles(
        bedrockMessages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message],
        systemContentBlock: [AWSBedrockRuntime.BedrockRuntimeClientTypes.SystemContentBlock]?,
        toolConfig: AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration?,
        turnCount: Int,
        maxTurns: Int,
        currentFullHistory: [BedrockMessage]? = nil
    ) async throws {
        // Check if we've reached maximum turns
        if turnCount >= maxTurns {
            logger.info("Maximum number of tool use turns (\(maxTurns)) reached")
            return
        }

        // CRITICAL: Validate history consistency at the start of each cycle
        if let currentHistory = currentFullHistory, !currentHistory.isEmpty {
            let lastMessage = currentHistory.last!

            // Check for consecutive assistant messages (should never happen)
            if currentHistory.count >= 2 {
                let secondToLast = currentHistory[currentHistory.count - 2]
                if lastMessage.role == .assistant && secondToLast.role == .assistant {
                    logger.error("🚨 CRITICAL: Detected consecutive assistant messages in history!")
                    logger.error(
                        "  Second-to-last: \(extractTextFromContents(secondToLast.content).prefix(50))..."
                    )
                    logger.error(
                        "  Last: \(extractTextFromContents(lastMessage.content).prefix(50))...")

                    // This should never happen - indicates a logic error
                    throw ToolUseError(message: "会話履歴に連続するアシスタントメッセージが検出されました。システムエラーの可能性があります。")
                }
            }

            logger.info(
                "✅ History consistency check passed: \(currentHistory.count) messages, last role: \(lastMessage.role)"
            )
        }

        // NEW: Sanitize messages before validation (auto-fix common issues)
        // Use strict sanitizer that preserves tool_use -> tool_result adjacency
        let sanitizedMessages = sanitizeMessagesStrict(bedrockMessages)

        // Enhanced logging before validation
        logger.info(
            "📊 About to validate \(sanitizedMessages.count) sanitized messages for API call")
        for (index, message) in sanitizedMessages.enumerated() {
            let role = message.role ?? .user
            let contentCount = message.content?.count ?? 0
            var contentTypes: [String] = []

            if let contents = message.content {
                for content in contents {
                    switch content {
                    case .text(_): contentTypes.append("text")
                    case .image(_): contentTypes.append("image")
                    case .document(_): contentTypes.append("document")
                    case .tooluse(let toolUse):
                        if let toolUseId = toolUse.toolUseId {
                            contentTypes.append("tool_use[\(toolUseId.suffix(8))]")
                        }
                    case .toolresult(let toolResult):
                        if let toolUseId = toolResult.toolUseId {
                            contentTypes.append("tool_result[\(toolUseId.suffix(8))]")
                        }
                    default: contentTypes.append("other")
                    }
                }
            }

            logger.info(
                "  Message[\(index)]: \(role), \(contentCount) blocks: \(contentTypes.joined(separator: ", "))"
            )
        }

        // Pre-validate message structure before API call
        do {
            try validateMessageStructure(sanitizedMessages)
        } catch {
            logger.error("❌ Message validation failed before API call: \(error)")
            logger.error("📋 Dumping message structure for debugging:")
            for (index, message) in sanitizedMessages.enumerated() {
                logger.error(
                    "  Message[\(index)]: role=\(message.role?.rawValue ?? "nil"), content_count=\(message.content?.count ?? 0)"
                )
            }
            throw ToolUseError(message: "メッセージ構造の検証に失敗しました: \(error.localizedDescription)")
        }

        // State variables for this conversation turn
        var streamedText = ""
        var thinking: String? = nil
        var thinkingSignature: String? = nil
        var isFirstChunk = true
        var toolWasUsed = false
        // CRITICAL FIX: 履歴をDBから読み直さず、メモリ上の最新履歴を使用
        var fullConversationHistory: [BedrockMessage]
        if let currentHistory = currentFullHistory {
            fullConversationHistory = currentHistory
        } else {
            fullConversationHistory = await getConversationHistory()
        }

        // Use for message ID tracking
        let messageId = UUID()
        currentStreamingMessageId = messageId
        var currentToolInfo: ToolInfo? = nil

        // Reset tool tracker
        await ToolUseTracker.shared.reset()

        // Stream chunks from the model (use sanitized messages) with retry handling
        do {
            for try await chunk in try await backendModel.backend.converseStream(
                withId: chatModel.id,
                messages: sanitizedMessages,
                systemContent: systemContentBlock,
                inferenceConfig: nil,
                toolConfig: toolConfig,
                usageHandler: { [weak self] usage in
                    // Format usage information for toast display
                    let formattedUsage = self?.formatUsageString(usage) ?? ""
                    self?.usageHandler?(formattedUsage)
                }
            ) {
                // Check for tool use in each chunk
                if let toolUseInfo = await extractToolUseFromChunk(chunk) {
                    toolWasUsed = true
                    logger.info("Tool use detected in cycle \(turnCount+1): \(toolUseInfo.name)")

                    // Create tool info object from the extracted data
                    currentToolInfo = ToolInfo(
                        id: toolUseInfo.toolUseId,
                        name: toolUseInfo.name,
                        input: JSONValue.from(toolUseInfo.input)
                    )

                    // If this is our first message (no content streamed yet), create a new message
                    if isFirstChunk {
                        // If first message, create initial message but don't update text later
                        let initialMessage = MessageData(
                            id: messageId,
                            text: streamedText.isEmpty ? "Analyzing your request..." : streamedText,
                            user: chatModel.name,
                            isError: false,
                            sentTime: Date(),
                            toolUse: currentToolInfo
                        )
                        addUIOnlyMessage(initialMessage)
                        isFirstChunk = false
                    } else {
                        // If message already exists, keep text as is and only update tool info
                        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                            // Preserve the current displayed text
                            let currentText = self.messages[index].text

                            // Update tool info in UI only
                            self.messages[index].toolUse = currentToolInfo

                            // Update storage (without changing text)
                            chatManager.updateMessageWithToolInfo(
                                for: chatId,
                                messageId: messageId,
                                newText: currentText,  // Keep existing text
                                toolInfo: currentToolInfo!
                            )
                        }
                    }

                    // Execute the tool with fixed Sendable result handling
                    logger.info("Executing MCP tool: \(toolUseInfo.name)")
                    let toolResult = await executeSendableMCPTool(
                        id: toolUseInfo.toolUseId,
                        name: toolUseInfo.name,
                        input: toolUseInfo.input
                    )

                    // Extract result text and status
                    let status = toolResult.status
                    let resultText = toolResult.text

                    logger.info("Tool execution completed with status: \(status)")

                    // Create tool result info for modal
                    let newToolResult = ToolResultInfo(
                        toolUseId: toolUseInfo.toolUseId,
                        toolName: toolUseInfo.name,
                        input: JSONValue.from(toolUseInfo.input),
                        result: resultText,
                        status: status
                    )

                    // Add to tool results collection
                    toolResults.append(newToolResult)

                    // Get the existing message text to preserve in history
                    let preservedText =
                        isFirstChunk
                        ? streamedText
                        : (messages.first(where: { $0.id == messageId })?.text ?? streamedText)

                    // Update both UI and storage consistently
                    updateMessageWithToolInfo(
                        messageId: messageId,
                        newText: nil,  // Pass nil to preserve existing text
                        toolInfo: currentToolInfo,
                        toolResult: resultText
                    )

                    // CRITICAL FIX: Create tool messages in AWS Bedrock API compliant format
                    // AWS Bedrock requires EXACT pairing: assistant(tool_use) -> user(tool_result)

                    // 1. Assistant message with ONLY tool_use (minimal text)
                    let assistantWithToolUse = BedrockMessage(
                        role: .assistant,
                        content: createMinimalToolUseMessage(
                            text: preservedText.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                                ? "I'll help you with that." : preservedText,
                            thinking: thinking,
                            thinkingSignature: thinkingSignature,
                            toolUse: MessageContent.ToolUseContent(
                                toolUseId: toolUseInfo.toolUseId,
                                name: toolUseInfo.name,
                                input: currentToolInfo!.input
                            ),
                            modelId: chatModel.id
                        )
                    )

                    // 2. User message with ONLY tool_result (no other content)
                    let userWithToolResult = BedrockMessage(
                        role: .user,
                        content: [
                            .toolresult(
                                MessageContent.ToolResultContent(
                                    toolUseId: toolUseInfo.toolUseId,
                                    result: resultText,
                                    status: status
                                ))
                        ]
                    )

                    // CRITICAL: Before adding tool pair, verify no duplicate assistant messages
                    if let lastMessage = fullConversationHistory.last {
                        if lastMessage.role == .assistant {
                            // Check if this is a duplicate (same text content)
                            let lastText = extractTextFromContents(lastMessage.content)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let newText = preservedText.trimmingCharacters(
                                in: .whitespacesAndNewlines)

                            if lastText == newText && !newText.isEmpty {
                                logger.warning(
                                    "🔧 Detected duplicate assistant message before adding tool pair, removing duplicate"
                                )
                                fullConversationHistory.removeLast()
                            }
                        }
                    }

                    // Add messages in STRICT order: assistant(tool_use) first, then user(tool_result)
                    fullConversationHistory.append(assistantWithToolUse)
                    fullConversationHistory.append(userWithToolResult)

                    logger.info(
                        "✅ Added AWS compliant tool pair: assistant(tool_use) -> user(tool_result) for ID: \(toolUseInfo.toolUseId)"
                    )
                    logger.info(
                        "📊 Current history state: \(fullConversationHistory.count) messages, last 3 roles: \(fullConversationHistory.suffix(3).map { $0.role.rawValue }.joined(separator: " -> "))"
                    )

                    // 完全な履歴を保存（要約されない）
                    await saveConversationHistory(fullConversationHistory)

                    // Bedrock送信用に最適化
                    let optimizedHistoryForNextCycle = await manageConversationByCharacterCount(
                        fullConversationHistory)

                    // Pre-validate before conversion to catch issues early
                    do {
                        let testMessages = try optimizedHistoryForNextCycle.map {
                            try convertToBedrockMessage($0, modelId: chatModel.id)
                        }
                        try validateMessageStructure(testMessages)
                        logger.info("✅ Pre-validation passed for \(testMessages.count) messages")
                    } catch {
                        logger.error("❌ Pre-validation failed: \(error)")
                        // Use emergency cleanup
                        logger.info("🚨 Activating emergency tool cleanup...")
                        let cleanedHistory = await emergencyToolCleanup(
                            optimizedHistoryForNextCycle)
                        // emergencyToolCleanupは送信用のみに使用、保存はしない

                        // 完全な履歴からツールをクリーンアップして保存
                        let cleanedFullHistory = await emergencyToolCleanup(fullConversationHistory)
                        await saveConversationHistory(cleanedFullHistory)
                    }

                    // Create updated messages for next cycle (最適化された履歴を使用)
                    let updatedMessages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message]
                    do {
                        updatedMessages = try optimizedHistoryForNextCycle.map {
                            try convertToBedrockMessage($0, modelId: chatModel.id)
                        }
                        logger.info(
                            "✅ Successfully converted \(updatedMessages.count) messages for next cycle"
                        )
                    } catch {
                        logger.error("❌ Critical: Message conversion failed: \(error)")
                        throw ToolUseError(
                            message: "メッセージ変換エラー: \(error.localizedDescription). ツール使用を停止します。")
                    }

                    // Recursively continue with next turn
                    // CRITICAL FIX: メモリ上の最新履歴を引き継ぐ
                    try await processToolCycles(
                        bedrockMessages: updatedMessages,
                        systemContentBlock: systemContentBlock,
                        toolConfig: toolConfig,
                        turnCount: turnCount + 1,
                        maxTurns: maxTurns,
                        currentFullHistory: fullConversationHistory
                    )

                    // End this turn's processing
                    return
                }

                // Process regular text chunk if no tool was detected
                if let textChunk = extractTextFromChunk(chunk) {
                    streamedText += textChunk
                    appendTextToMessage(
                        textChunk, messageId: messageId, shouldCreateNewMessage: isFirstChunk)
                    isFirstChunk = false
                }

                // Process thinking chunk
                let thinkingResult = extractThinkingFromChunk(chunk)
                if let thinkingText = thinkingResult.text {
                    thinking = (thinking ?? "") + thinkingText
                    appendThinkingToMessage(
                        thinkingText, messageId: messageId, shouldCreateNewMessage: isFirstChunk)
                    isFirstChunk = false
                }

                if let thinkingSignatureText = thinkingResult.signature {
                    thinkingSignature = thinkingSignatureText
                }
            }
        } catch let streamingError as StreamingRetryableError {
            // Handle streaming retry errors with 30 second wait
            logger.warning(
                "⚠️ StreamingRetryableError caught: \(streamingError.errorType) during streaming, waiting 30 seconds before retry..."
            )

            // Wait 30 seconds
            try await Task.sleep(nanoseconds: 30_000_000_000)

            // Retry the entire processToolCycles with incremented retry count
            logger.info("♻️ Retrying processToolCycles after streaming timeout...")

            return try await processToolCycles(
                bedrockMessages: bedrockMessages,
                systemContentBlock: systemContentBlock,
                toolConfig: toolConfig,
                turnCount: turnCount,
                maxTurns: maxTurns,
                currentFullHistory: fullConversationHistory
            )
        }

        // If we get here, the model completed its response without using a tool
        if !toolWasUsed {
            // Create final assistant message
            let assistantText = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)

            // Only create a new message if we haven't been streaming
            if isFirstChunk {
                let assistantMessage = MessageData(
                    id: messageId,
                    text: assistantText,
                    thinking: thinking,
                    signature: thinkingSignature,
                    user: chatModel.name,
                    isError: false,
                    sentTime: Date()
                )
                addUIOnlyMessage(assistantMessage)
            } else {
                // Update the final message content - both UI and storage
                updateMessageText(messageId: messageId, newText: assistantText)

                if let thinking = thinking {
                    updateMessageThinking(
                        messageId: messageId, newThinking: thinking, signature: thinkingSignature)
                }
            }

            // Create assistant message for conversation history
            let assistantMsg = BedrockMessage(
                role: .assistant,
                content: thinking != nil
                    ? [
                        .thinking(
                            MessageContent.ThinkingContent(
                                text: thinking!,
                                signature: thinkingSignature ?? UUID().uuidString
                            )),
                        .text(assistantText),
                    ] : [.text(assistantText)]
            )

            // Add to full history and save (完全な履歴を保存)
            fullConversationHistory.append(assistantMsg)
            await saveConversationHistory(fullConversationHistory)
        }

        // Clear tracking of streaming message ID
        currentStreamingMessageId = nil
    }

    // Sendable tool result struct
    struct SendableToolResult: Sendable {
        let status: String
        let text: String
        let error: String?
    }

    // Fixed Sendable MCP tool execution
    private func executeSendableMCPTool(id: String, name: String, input: [String: Any]) async
        -> SendableToolResult
    {
        var resultStatus = "error"
        var resultText = "Tool execution failed"
        var resultError: String? = nil

        do {
            let mcpToolResult = await mcpManager.executeBedrockTool(
                id: id, name: name, input: input)

            if let status = mcpToolResult["status"] as? String {
                resultStatus = status

                if status == "success" {
                    // Handle multi-modal content
                    if let content = mcpToolResult["content"] as? [[String: Any]] {
                        var textResults: [String] = []
                        var hasImages = false
                        var hasAudio = false

                        for contentItem in content {
                            if let type = contentItem["type"] as? String {
                                switch type {
                                case "text":
                                    if let text = contentItem["text"] as? String {
                                        textResults.append(text)
                                    }
                                case "image":
                                    hasImages = true
                                    if let description = contentItem["description"] as? String {
                                        textResults.append("🖼️ \(description)")
                                    } else {
                                        textResults.append("🖼️ Generated image")
                                    }
                                case "audio":
                                    hasAudio = true
                                    if let description = contentItem["description"] as? String {
                                        textResults.append("🔊 \(description)")
                                    } else {
                                        textResults.append("🔊 Generated audio")
                                    }
                                case "resource":
                                    if let text = contentItem["text"] as? String {
                                        textResults.append(text)
                                    } else if let description = contentItem["description"]
                                        as? String
                                    {
                                        textResults.append("📄 \(description)")
                                    }
                                default:
                                    if let description = contentItem["description"] as? String {
                                        textResults.append(description)
                                    }
                                }
                            }
                        }

                        resultText =
                            textResults.isEmpty
                            ? "Tool execution completed" : textResults.joined(separator: "\n")
                    } else {
                        resultText = "Tool execution completed"
                    }
                } else {
                    if let error = mcpToolResult["error"] as? String {
                        resultError = error
                        resultText = "Tool execution failed: \(error)"
                    } else if let content = mcpToolResult["content"] as? [[String: Any]],
                        let firstContent = content.first,
                        let text = firstContent["text"] as? String
                    {
                        resultText = text
                    }
                }
            }
        } catch {
            resultStatus = "error"
            resultError = error.localizedDescription
            resultText = "Exception during tool execution: \(error.localizedDescription)"
        }

        return SendableToolResult(status: resultStatus, text: resultText, error: resultError)
    }

    // Helper method to append text during streaming
    private func appendTextToMessage(
        _ text: String, messageId: UUID, shouldCreateNewMessage: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if shouldCreateNewMessage {
                let newMessage = MessageData(
                    id: messageId,
                    text: text,
                    user: self.chatModel.name,
                    isError: false,
                    sentTime: Date()
                )
                self.messages.append(newMessage)
            } else {
                if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                    self.messages[index].text += text
                }
            }

            self.objectWillChange.send()
        }
    }

    private func appendThinkingToMessage(
        _ thinking: String, messageId: UUID, shouldCreateNewMessage: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if shouldCreateNewMessage {
                let newMessage = MessageData(
                    id: messageId,
                    text: "",
                    thinking: thinking,
                    user: self.chatModel.name,
                    isError: false,
                    sentTime: Date()
                )
                self.messages.append(newMessage)
            } else {
                if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                    self.messages[index].thinking = (self.messages[index].thinking ?? "") + thinking
                }
            }

            self.objectWillChange.send()
        }
    }

    private func updateMessageText(messageId: UUID, newText: String) {
        // Update UI
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            self.messages[index].text = newText
        }

        // Update storage
        chatManager.updateMessageText(
            for: chatId,
            messageId: messageId,
            newText: newText
        )
    }

    private func updateMessageThinking(
        messageId: UUID, newThinking: String, signature: String? = nil
    ) {
        // Update UI
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            self.messages[index].thinking = newThinking
            if let sig = signature {
                self.messages[index].signature = sig
            }
        }

        // Update storage
        chatManager.updateMessageThinking(
            for: chatId,
            messageId: messageId,
            newThinking: newThinking,
            signature: signature
        )
    }

    private func updateMessageWithToolInfo(
        messageId: UUID, newText: String? = nil, toolInfo: ToolInfo?, toolResult: String? = nil
    ) {
        // Update UI
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            // Only update text if provided and not nil
            if let text = newText {
                self.messages[index].text = text
            }
            self.messages[index].toolUse = toolInfo
            self.messages[index].toolResult = toolResult
        }

        // Update storage
        if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
            let currentText = self.messages[index].text

            chatManager.updateMessageWithToolInfo(
                for: chatId,
                messageId: messageId,
                newText: currentText,  // Always use current text to preserve original response
                toolInfo: toolInfo!,
                toolResult: toolResult
            )
        }
    }

    // MARK: - Conversation History Management

    /// Gets conversation history for storage (完全な履歴を返す - 保存用)
    private func getConversationHistory() async -> [BedrockMessage] {
        var messages: [BedrockMessage] = []

        // Build conversation history from local storage
        if let history = chatManager.getConversationHistory(for: chatId) {
            messages = convertConversationHistoryToBedrockMessages(history)
        } else if chatManager.getMessages(for: chatId).count > 0 {
            // Migrate from legacy formats if needed
            messages = await migrateAndGetConversationHistory()
        } else {
            // No history exists
            return []
        }

        // NEW: ALWAYS remove consecutive duplicate messages before returning
        return removeDuplicateConsecutiveBedrockMessages(messages)
    }

    /// Removes consecutive duplicate Bedrock messages (same role, same text)
    /// This is the FINAL safety net before sending to API
    private func removeDuplicateConsecutiveBedrockMessages(_ messages: [BedrockMessage])
        -> [BedrockMessage]
    {
        guard messages.count > 1 else { return messages }

        var cleaned: [BedrockMessage] = []
        var previousMessage: BedrockMessage? = nil
        var removedCount = 0

        for message in messages {
            // Check if this is a duplicate of the previous message
            if let prev = previousMessage,
                prev.role == message.role,
                extractTextFromContents(prev.content) == extractTextFromContents(message.content)
            {
                // Skip this duplicate
                removedCount += 1
                logger.warning(
                    "🔧 [FINAL SAFETY NET] Removing duplicate \(message.role) message: '\(extractTextFromContents(message.content).prefix(50))...'"
                )
                continue
            }

            cleaned.append(message)
            previousMessage = message
        }

        if removedCount > 0 {
            logger.info(
                "🔧 [FINAL SAFETY NET] Removed \(removedCount) consecutive duplicate messages from history (\(messages.count) -> \(cleaned.count))"
            )
        }

        return cleaned
    }

    /// Extracts text content from message contents for comparison
    private func extractTextFromContents(_ contents: [MessageContent]) -> String {
        var text = ""
        for content in contents {
            switch content {
            case .text(let t):
                text += t
            default:
                continue
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gets optimized conversation history for Bedrock API (最適化された履歴 - Bedrock送信用)
    /// 10万文字を超える場合、直近10会話 + それ以前の要約を返す
    private func getOptimizedConversationHistoryForBedrock() async -> [BedrockMessage] {
        // 完全な履歴を取得
        let fullHistory = await getConversationHistory()

        // 文字数ベースで最適化
        return await manageConversationByCharacterCount(fullHistory)
    }

    /// 文字数ベースでの会話履歴管理
    /// 10万文字を超える場合、直近10会話 + それ以前の要約を生成
    /// ⚠️ CRITICAL: ツールメッセージがある場合は要約をスキップ（順序保持のため）
    private func manageConversationByCharacterCount(_ messages: [BedrockMessage]) async
        -> [BedrockMessage]
    {
        guard messages.count > 10 else {
            // 10会話以下の場合はそのまま返す
            return messages
        }

        // CRITICAL FIX: ツールメッセージが含まれている場合は要約をスキップ
        // 理由: ツールメッセージの順序を保持する必要があり、分離・再結合で順序が壊れる
        let hasToolMessages = messages.contains { message in
            message.content.contains { content in
                switch content {
                case .tooluse(_), .toolresult(_):
                    return true
                default:
                    return false
                }
            }
        }

        if hasToolMessages {
            logger.info("⚠️ ツールメッセージが含まれているため、要約をスキップして全履歴を使用")
            return messages
        }

        // 全体の文字数をカウント
        let totalCharacters = countCharactersInMessages(messages)

        logger.info("会話履歴の総文字数: \(totalCharacters)文字 (\(messages.count)メッセージ)")

        // 9万文字以下の場合はそのまま返す
        if totalCharacters <= 90_000 {
            logger.info("9万文字以下のため、全履歴を使用")
            return messages
        }

        logger.info("⚠️ 9万文字超過 - 要約処理を開始")

        // 通常メッセージのみから直近10会話を取得
        let (recentMessages, olderMessages) = extractRecentMessagesSimple(
            messages, recentCount: 10)

        // 古いメッセージを要約
        var optimizedHistory: [BedrockMessage] = []

        if !olderMessages.isEmpty {
            do {
                let summary = try await summarizeOlderMessages(olderMessages)

                // 要約メッセージを作成
                let summaryMessage = BedrockMessage(
                    role: .assistant,
                    content: [.text("📋 **以前の会話の要約**\n\n\(summary)")]
                )
                optimizedHistory.append(summaryMessage)

                logger.info("✅ 要約完了: \(olderMessages.count)メッセージ → 要約")

            } catch {
                logger.error("要約処理失敗: \(error.localizedDescription)")
            }
        }

        // 直近メッセージを追加
        optimizedHistory.append(contentsOf: recentMessages)

        logger.info(
            "✅ 最適化完了: 要約 + 直近\(recentMessages.count) = 合計\(optimizedHistory.count)メッセージ"
        )

        return optimizedHistory
    }

    /// メッセージ配列の総文字数をカウント
    private func countCharactersInMessages(_ messages: [BedrockMessage]) -> Int {
        var totalChars = 0

        for message in messages {
            for content in message.content {
                switch content {
                case .text(let text):
                    totalChars += text.count
                case .thinking(let thinking):
                    totalChars += thinking.text.count
                case .image(_):
                    // 画像は約1000文字相当としてカウント
                    totalChars += 1000
                case .document(let doc):
                    // ドキュメントは名前のみカウント（内容はbase64なので除外）
                    totalChars += doc.name.count + 100
                case .tooluse(let tool):
                    totalChars += tool.name.count + 100
                case .toolresult(let result):
                    totalChars += result.result.count
                }
            }
        }

        return totalChars
    }

    /// 古いメッセージ群を要約
    private func summarizeOlderMessages(_ messages: [BedrockMessage]) async throws -> String {
        guard !messages.isEmpty else {
            return ""
        }

        logger.info("古いメッセージの要約開始: \(messages.count)メッセージ")

        // 会話履歴をテキスト形式に変換
        var conversationText = ""

        for (index, message) in messages.enumerated() {
            let role = message.role == .user ? "User" : "Assistant"
            conversationText += "\n--- メッセージ \(index + 1) ---\n"
            conversationText += "\(role):\n"

            for content in message.content {
                switch content {
                case .text(let text):
                    conversationText += text + "\n"
                case .thinking(let thinking):
                    conversationText += "[思考]: \(thinking.text.prefix(200))...\n"
                case .image(_):
                    conversationText += "[画像が添付されました]\n"
                case .document(let doc):
                    conversationText += "[ドキュメント: \(doc.name)]\n"
                case .tooluse(let tool):
                    conversationText += "[ツール使用: \(tool.name)]\n"
                case .toolresult(let result):
                    conversationText += "[結果: \(result.result.prefix(100))...]\n"
                }
            }
        }

        // 要約用のプロンプト
        let summaryPrompt = """
            以下の会話履歴を簡潔に要約してください。

            要約の方針：
            1. 重要な質問と回答の要点を箇条書きで記載
            2. 決定事項や結論を明確に記載
            3. 技術的な詳細は必要最小限に
            4. 全体の流れと文脈を保持
            5. 5000文字以内に収める

            会話履歴（\(messages.count)メッセージ）：
            \(conversationText)

            上記の会話を、重要な情報を失わずに簡潔にまとめてください。
            """

        // 要約リクエスト用のメッセージ
        let summaryRequestMessage = BedrockMessage(
            role: .user,
            content: [.text(summaryPrompt)]
        )

        // AWS SDK形式に変換
        let awsMessage = try convertToBedrockMessage(summaryRequestMessage, modelId: chatModel.id)

        // 軽量モデルで要約（コスト削減）
        // リージョンに応じて利用可能なモデルを選択
        let summaryModelId = selectSummaryModel()

        var summaryText = ""

        // ストリーミングで要約を取得
        for try await chunk in try await backendModel.backend.converseStream(
            withId: summaryModelId,
            messages: [awsMessage],
            systemContent: [.text("あなたは会話要約の専門家です。与えられた会話履歴から重要な情報を抽出し、簡潔にまとめてください。")],
            inferenceConfig: nil,
            usageHandler: { [weak self] usage in
                self?.logger.debug(
                    "要約生成 - Input: \(usage.inputTokens ?? 0), Output: \(usage.outputTokens ?? 0)")
            }
        ) {
            if let textChunk = extractTextFromChunk(chunk) {
                summaryText += textChunk
            }
        }

        let trimmedSummary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("要約生成完了: \(trimmedSummary.count)文字")

        return trimmedSummary
    }

    /// ツールメッセージと通常メッセージを分離
    /// ツールメッセージはtool_use/tool_resultペアとして保持し、要約処理から除外する
    private func separateToolAndNonToolMessages(_ messages: [BedrockMessage])
        -> (toolMessages: [BedrockMessage], nonToolMessages: [BedrockMessage])
    {
        var toolMessages: [BedrockMessage] = []
        var nonToolMessages: [BedrockMessage] = []

        for message in messages {
            var hasToolContent = false

            // メッセージにツール関連のコンテンツが含まれているかチェック
            for content in message.content {
                switch content {
                case .tooluse(_), .toolresult(_):
                    hasToolContent = true
                default:
                    continue
                }
            }

            if hasToolContent {
                toolMessages.append(message)
            } else {
                nonToolMessages.append(message)
            }
        }

        return (toolMessages, nonToolMessages)
    }

    /// シンプルに直近メッセージを抽出（ツールメッセージが既に分離されているため）
    private func extractRecentMessagesSimple(_ messages: [BedrockMessage], recentCount: Int)
        -> (recent: [BedrockMessage], older: [BedrockMessage])
    {
        guard messages.count > recentCount else {
            return (messages, [])
        }

        let splitIndex = messages.count - recentCount
        let recent = Array(messages.suffix(from: splitIndex))
        let older = Array(messages.prefix(splitIndex))

        return (recent, older)
    }

    /// 要約生成用の軽量モデルを選択
    private func selectSummaryModel() -> String {
        // 利用可能なモデルの優先順位リスト
        let preferredModels = [
            chatModel.id,  // フォールバック: 現在のモデル
            "amazon.nova-lite-v1:0",
            "anthropic.claude-3-5-haiku-20241022-v1:0",
            "anthropic.claude-3-haiku-20240307-v1:0",
            "meta.llama3-1-8b-instruct-v1:0",
        ]

        // 最初のモデルを返す（実際の利用可能性チェックは省略）
        return preferredModels.first ?? chatModel.id
    }

    /// Migrates from legacy formats and returns conversation history
    private func migrateAndGetConversationHistory() async -> [BedrockMessage] {
        // Get messages and convert to unified format
        let messages = chatManager.getMessages(for: chatId)

        var bedrockMessages: [BedrockMessage] = []

        for message in messages {
            let role: MessageRole = message.user == "User" ? .user : .assistant

            // STRICT: For user tool_result messages, create ONLY tool_result block
            // CRITICAL: Check this FIRST before processing any other content
            if role == .user, let toolUse = message.toolUse, let toolResult = message.toolResult {
                let bedrockMessage = BedrockMessage(
                    role: role,
                    content: [
                        .toolresult(
                            MessageContent.ToolResultContent(
                                toolUseId: toolUse.id,
                                result: toolResult,
                                status: "success"
                            ))
                    ]
                )
                bedrockMessages.append(bedrockMessage)
                logger.debug(
                    "🔧 [Migration] Created STRICT tool_result-only user message for tool ID: \(toolUse.id)"
                )
                continue  // CRITICAL: Skip all other content processing for this message
            }

            var contents: [MessageContent] = []

            // Add text content
            if !message.text.isEmpty {
                contents.append(.text(message.text))
            }

            // Add thinking content if present
            if let thinking = message.thinking, !thinking.isEmpty {
                contents.append(
                    .thinking(
                        MessageContent.ThinkingContent(
                            text: thinking,
                            signature: message.signature ?? UUID().uuidString
                        )))
            }

            // Add images if present
            if let imageBase64Strings = message.imageBase64Strings {
                for base64String in imageBase64Strings {
                    contents.append(
                        .image(
                            MessageContent.ImageContent(
                                format: .jpeg,
                                base64Data: base64String
                            )))
                }
            }

            // Add documents if present
            if let documentBase64Strings = message.documentBase64Strings,
                let documentFormats = message.documentFormats,
                let documentNames = message.documentNames
            {

                for i
                    in 0..<min(
                        documentBase64Strings.count, min(documentFormats.count, documentNames.count)
                    )
                {
                    let format = MessageContent.DocumentFormat.fromExtension(documentFormats[i])
                    contents.append(
                        .document(
                            MessageContent.DocumentContent(
                                format: format,
                                base64Data: documentBase64Strings[i],
                                name: documentNames[i]
                            )))
                }
            }

            // Add tool info if present (for assistant messages only)
            if role == .assistant, let toolUse = message.toolUse {
                contents.append(
                    .tooluse(
                        MessageContent.ToolUseContent(
                            toolUseId: toolUse.id,
                            name: toolUse.name,
                            input: toolUse.input
                        )))
            }

            if !contents.isEmpty {
                let bedrockMessage = BedrockMessage(role: role, content: contents)
                bedrockMessages.append(bedrockMessage)
            }
        }

        // Save newly converted history
        await saveConversationHistory(bedrockMessages)

        return bedrockMessages
    }

    /// Saves conversation history
    private func saveConversationHistory(_ history: [BedrockMessage]) async {
        var newConversationHistory = ConversationHistory(
            chatId: chatId, modelId: chatModel.id, messages: [])
        logger.debug("[SaveHistory] Processing \(history.count) Bedrock messages for saving.")

        for bedrockMessage in history {
            let role = bedrockMessage.role == .user ? Message.Role.user : Message.Role.assistant
            var text = ""
            var thinkingText: String? = nil
            var thinkingSignature: String? = nil
            var toolUseForStorage: Message.ToolUse? = nil
            var extractedResultTextForUserMessage: String? = nil

            // Add image and document collections
            var imageBase64Strings: [String]? = nil
            var documentBase64Strings: [String]? = nil
            var documentFormats: [String]? = nil
            var documentNames: [String]? = nil

            // Extract content from the current BedrockMessage
            for content in bedrockMessage.content {
                switch content {
                case .text(let txt):
                    text += txt  // Append text chunks

                case .thinking(let tc):
                    thinkingText = (thinkingText ?? "") + tc.text
                    if thinkingSignature == nil {
                        thinkingSignature = tc.signature
                    }

                case .image(let imageContent):
                    // Process image content
                    if imageBase64Strings == nil {
                        imageBase64Strings = [imageContent.base64Data]
                    } else {
                        imageBase64Strings?.append(imageContent.base64Data)
                    }

                case .document(let documentContent):
                    // Process document content
                    if documentBase64Strings == nil {
                        documentBase64Strings = [documentContent.base64Data]
                        documentFormats = [documentContent.format.rawValue]
                        documentNames = [documentContent.name]
                    } else {
                        documentBase64Strings?.append(documentContent.base64Data)
                        documentFormats?.append(documentContent.format.rawValue)
                        documentNames?.append(documentContent.name)
                    }

                case .tooluse(let tu):
                    // If this is an assistant message with toolUse, prepare ToolUse for storage
                    if bedrockMessage.role == .assistant {
                        toolUseForStorage = Message.ToolUse(
                            toolId: tu.toolUseId,
                            toolName: tu.name,
                            inputs: tu.input,
                            result: nil  // Result is initially nil
                        )
                        logger.debug(
                            "[SaveHistory] Found toolUse in ASSISTANT message: ID=\(tu.toolUseId)")
                    } else {
                        logger.warning(
                            "[SaveHistory] Found toolUse in non-assistant message. Ignoring for ToolUse struct."
                        )
                    }

                case .toolresult(let tr):
                    // If this is a user message with toolResult, extract the result text
                    if bedrockMessage.role == .user {
                        // CRITICAL FIX: Use unique text for each tool_result to prevent duplicate consecutive messages
                        // Include tool ID and truncated result to make each message unique
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let resultPreview = tr.result.prefix(50).trimmingCharacters(
                                in: .whitespacesAndNewlines)
                            text = "Tool[\(tr.toolUseId.suffix(8))]: \(resultPreview)"
                        }

                        toolUseForStorage = Message.ToolUse(
                            toolId: tr.toolUseId,
                            toolName: "",
                            inputs: JSONValue.null,
                            result: tr.result
                        )
                        logger.debug(
                            "[SaveHistory] Found toolResult in USER message: ID=\(tr.toolUseId), Result=\(tr.result)"
                        )
                    } else {
                        logger.warning(
                            "[SaveHistory] Found toolResult in non-user message. Ignoring.")
                    }
                }
            }

            // Create the Message
            let unifiedMessage = Message(
                id: UUID(),
                text: text,
                role: role,
                timestamp: Date(),
                isError: false,
                thinking: thinkingText,
                thinkingSignature: thinkingSignature,
                imageBase64Strings: imageBase64Strings,
                documentBase64Strings: documentBase64Strings,
                documentFormats: documentFormats,
                documentNames: documentNames,
                toolUse: toolUseForStorage
            )

            newConversationHistory.addMessage(unifiedMessage)
        }

        logger.info(
            "[SaveHistory] Finished processing. Saving \(newConversationHistory.messages.count) messages."
        )
        chatManager.saveConversationHistory(newConversationHistory, for: chatId)
    }

    /// Converts a ConversationHistory to Bedrock messages
    private func convertConversationHistoryToBedrockMessages(_ history: ConversationHistory)
        -> [BedrockMessage]
    {
        var bedrockMessages: [BedrockMessage] = []

        for message in history.messages {
            let role: MessageRole = message.role == .user ? .user : .assistant

            var contents: [MessageContent] = []

            // STRICT: For user tool_result messages, include ONLY tool_result (no other blocks)
            // CRITICAL: Check this FIRST before processing any other content
            if role == .user, let tu = message.toolUse, let result = tu.result {
                contents = [
                    .toolresult(
                        .init(
                            toolUseId: tu.toolId,
                            result: result,
                            status: "success"
                        ))
                ]
                bedrockMessages.append(BedrockMessage(role: role, content: contents))
                logger.debug(
                    "🔧 Created STRICT tool_result-only user message for tool ID: \(tu.toolId)")
                continue  // CRITICAL: Skip all other content processing for this message
            }

            // Add thinking content if present for assistant messages
            // Skip thinking content for OpenAI models as they don't support signature field
            if role == .assistant, let thinking = message.thinking, !thinking.isEmpty,
                !isOpenAIModel(chatModel.id)
            {
                let signatureToUse = message.thinkingSignature ?? UUID().uuidString
                contents.append(.thinking(.init(text: thinking, signature: signatureToUse)))
            }

            // Add text content
            if !message.text.isEmpty {
                contents.append(.text(message.text))
            }

            // Add images if present
            if let imageBase64Strings = message.imageBase64Strings {
                for base64String in imageBase64Strings {
                    contents.append(
                        .image(
                            MessageContent.ImageContent(
                                format: .jpeg,
                                base64Data: base64String
                            )))
                }
            }

            // Add documents if present
            if let documentBase64Strings = message.documentBase64Strings,
                let documentFormats = message.documentFormats,
                let documentNames = message.documentNames
            {

                for i
                    in 0..<min(
                        documentBase64Strings.count, min(documentFormats.count, documentNames.count)
                    )
                {
                    let format = MessageContent.DocumentFormat.fromExtension(documentFormats[i])
                    contents.append(
                        .document(
                            MessageContent.DocumentContent(
                                format: format,
                                base64Data: documentBase64Strings[i],
                                name: documentNames[i]
                            )))
                }
            }

            // Handle Tool Use for assistant messages only
            // CRITICAL: User tool_result messages are handled separately above
            if role == .assistant, let toolUse = message.toolUse {
                contents.append(
                    .tooluse(
                        .init(
                            toolUseId: toolUse.toolId,
                            name: toolUse.toolName,
                            input: toolUse.inputs
                        )))
            }

            // Only add message if it has content
            if !contents.isEmpty {
                bedrockMessages.append(BedrockMessage(role: role, content: contents))
            } else {
                logger.warning(
                    "⚠️ Skipping message with no content after processing: role=\(role)")
            }
        }

        return bedrockMessages
    }

    // MARK: - Validation and Cleanup Functions

    /// Validates message structure before sending to AWS Bedrock API
    /// CRITICAL: AWS Bedrock requires EXACT pairing of assistant(tool_use) -> user(tool_result)
    private func validateMessageStructure(
        _ messages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message]
    ) throws {
        var toolUseCount = 0
        var toolResultCount = 0
        var toolUseIds: Set<String> = []
        var toolResultIds: Set<String> = []

        // NEW: Track message-level tool_use positions for strict ordering validation
        var toolUsePositions:
            [(
                index: Int, role: AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole,
                id: String
            )] = []
        var toolResultPositions:
            [(
                index: Int, role: AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole,
                id: String
            )] = []

        for (messageIndex, message) in messages.enumerated() {
            for content in message.content ?? [] {
                switch content {
                case .tooluse(let toolUse):
                    if let toolUseId = toolUse.toolUseId {
                        toolUseCount += 1
                        toolUseIds.insert(toolUseId)
                        toolUsePositions.append(
                            (index: messageIndex, role: message.role ?? .user, id: toolUseId))
                    }
                case .toolresult(let toolResult):
                    if let toolUseId = toolResult.toolUseId {
                        toolResultCount += 1
                        toolResultIds.insert(toolUseId)
                        toolResultPositions.append(
                            (index: messageIndex, role: message.role ?? .user, id: toolUseId))
                    }
                default:
                    continue
                }
            }
        }

        // Check for orphaned tool_use or tool_result
        let orphanedToolUse = toolUseIds.subtracting(toolResultIds)
        let orphanedToolResult = toolResultIds.subtracting(toolUseIds)

        if !orphanedToolUse.isEmpty || !orphanedToolResult.isEmpty {
            var errorMessage = "❌ Tool pair validation failed:"
            if !orphanedToolUse.isEmpty {
                errorMessage +=
                    "\n  Missing tool_result for tool_use IDs: \(orphanedToolUse.joined(separator: ", "))"
            }
            if !orphanedToolResult.isEmpty {
                errorMessage +=
                    "\n  Missing tool_use for tool_result IDs: \(orphanedToolResult.joined(separator: ", "))"
            }

            // NEW: Add detailed diagnostic information
            errorMessage += "\n\n📊 Diagnostic Info:"
            errorMessage += "\n  Total messages: \(messages.count)"
            errorMessage += "\n  Tool uses found: \(toolUseCount)"
            errorMessage += "\n  Tool results found: \(toolResultCount)"

            if !toolUsePositions.isEmpty {
                errorMessage += "\n\n  Tool use positions:"
                for pos in toolUsePositions {
                    errorMessage += "\n    - Message[\(pos.index)] (\(pos.role)): \(pos.id)"
                }
            }

            if !toolResultPositions.isEmpty {
                errorMessage += "\n\n  Tool result positions:"
                for pos in toolResultPositions {
                    errorMessage += "\n    - Message[\(pos.index)] (\(pos.role)): \(pos.id)"
                }
            }

            throw ToolUseError(message: errorMessage)
        }

        // NEW: Strict ordering validation - each tool_use must be immediately followed by tool_result
        for toolUsePos in toolUsePositions {
            // Find the corresponding tool_result
            if let resultPos = toolResultPositions.first(where: { $0.id == toolUsePos.id }) {
                // Verify strict ordering: tool_use must be in assistant message, result in user message
                if toolUsePos.role != .assistant {
                    throw ToolUseError(
                        message:
                            "❌ Tool use '\(toolUsePos.id)' at message[\(toolUsePos.index)] must be in assistant message, but found in \(toolUsePos.role) message"
                    )
                }

                if resultPos.role != .user {
                    throw ToolUseError(
                        message:
                            "❌ Tool result '\(resultPos.id)' at message[\(resultPos.index)] must be in user message, but found in \(resultPos.role) message"
                    )
                }

                // Verify tool_result comes after tool_use (not necessarily immediately after due to other messages)
                if resultPos.index <= toolUsePos.index {
                    throw ToolUseError(
                        message:
                            "❌ Tool result '\(resultPos.id)' at message[\(resultPos.index)] must come AFTER tool use at message[\(toolUsePos.index)]"
                    )
                }
            }
        }

        logger.info(
            "✅ Message structure validation passed: \(toolUseCount) tool_use, \(toolResultCount) tool_result, strict ordering verified"
        )

        // NEW: Validate alternating user/assistant pattern (AWS Bedrock requirement)
        try validateAlternatingRoles(messages)
    }

    /// Sanitizes messages to fix common issues before sending to AWS Bedrock
    /// Automatically fixes: consecutive same-role messages, duplicate messages, empty messages, orphaned tool_use
    private func sanitizeMessages(
        _ messages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message]
    ) -> [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message] {
        guard !messages.isEmpty else { return messages }

        var sanitized: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message] = []
        var previousRole: AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole? = nil
        var accumulatedContent: [AWSBedrockRuntime.BedrockRuntimeClientTypes.ContentBlock] = []
        var currentRole: AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole = .user
        var fixCount = 0
        var previousUserText: String? = nil

        for (index, message) in messages.enumerated() {
            let role = message.role ?? .user
            let content = message.content ?? []

            // Skip messages with no content
            if content.isEmpty {
                logger.warning("🔧 Sanitize: Skipping empty message at index \(index)")
                fixCount += 1
                continue
            }

            // NEW: Check for duplicate consecutive user messages with same text content
            if role == .user {
                let textContent = extractTextFromAWSContentBlocks(content)
                if let prevText = previousUserText, prevText == textContent, !textContent.isEmpty {
                    logger.warning(
                        "🔧 Sanitize: Skipping duplicate consecutive user message at index \(index): '\(textContent.prefix(50))...'"
                    )
                    fixCount += 1
                    continue
                }
                previousUserText = textContent
            } else {
                previousUserText = nil
            }

            // Check if this is a consecutive same-role message
            if let prevRole = previousRole, prevRole == role {
                // Merge content into accumulated content
                logger.info("🔧 Sanitize: Merging consecutive \(role) message at index \(index)")
                accumulatedContent.append(contentsOf: content)
                fixCount += 1
                continue
            }

            // If we have accumulated content, create a merged message
            if !accumulatedContent.isEmpty {
                let mergedMessage = AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
                    content: accumulatedContent,
                    role: currentRole
                )
                sanitized.append(mergedMessage)
                accumulatedContent = []
            }

            // Start accumulating new content
            currentRole = role
            accumulatedContent = content
            previousRole = role
        }

        // Add any remaining accumulated content
        if !accumulatedContent.isEmpty {
            let finalMessage = AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
                content: accumulatedContent,
                role: currentRole
            )
            sanitized.append(finalMessage)
        }

        if fixCount > 0 {
            logger.info(
                "🔧 Sanitize: Fixed \(fixCount) issues, \(messages.count) -> \(sanitized.count) messages"
            )
        }

        // NEW: Remove orphaned tool_use blocks (tool_use without immediate tool_result)
        let toolCleaned = removeOrphanedToolUseBlocks(sanitized)

        // Final check: Ensure we start with user and alternate properly
        return ensureProperStartRole(toolCleaned)
    }

    // NEW: Strict sanitizer that does NOT merge across tool_use/tool_result boundaries
    private func sanitizeMessagesStrict(
        _ messages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message]
    ) -> [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message] {
        guard !messages.isEmpty else { return messages }

        var sanitized: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message] = []
        var accumulationRole: AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole? = nil
        var accumulationContent: [AWSBedrockRuntime.BedrockRuntimeClientTypes.ContentBlock] = []
        var accumulationHasTool = false
        var fixCount = 0
        var previousUserText: String? = nil

        func hasToolBlocks(_ blocks: [AWSBedrockRuntime.BedrockRuntimeClientTypes.ContentBlock])
            -> Bool
        {
            for block in blocks {
                switch block {
                case .tooluse(_), .toolresult(_):
                    return true
                default:
                    continue
                }
            }
            return false
        }

        for (index, message) in messages.enumerated() {
            let role = message.role ?? .user
            let content = message.content ?? []

            // Skip empty messages
            if content.isEmpty {
                logger.warning("🔧 SanitizeStrict: Skipping empty message at index \(index)")
                fixCount += 1
                continue
            }

            // Skip duplicate consecutive user text-only messages (ignore tool_result-only messages)
            if role == .user {
                let textContent = extractTextFromAWSContentBlocks(content)
                if let prev = previousUserText, prev == textContent, !textContent.isEmpty {
                    logger.warning(
                        "🔧 SanitizeStrict: Skipping duplicate consecutive user message at index \(index): '\(textContent.prefix(50))...'"
                    )
                    fixCount += 1
                    continue
                }
                previousUserText = textContent
            } else {
                previousUserText = nil
            }

            let currentHasTool = hasToolBlocks(content)

            if let accRole = accumulationRole,
                accRole == role,
                !accumulationHasTool,
                !currentHasTool
            {
                // Safe to merge (no tool blocks involved)
                accumulationContent.append(contentsOf: content)
                fixCount += 1
            } else {
                // Flush previous accumulation if any
                if let accRole = accumulationRole, !accumulationContent.isEmpty {
                    sanitized.append(
                        AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
                            content: accumulationContent,
                            role: accRole
                        )
                    )
                }
                // Start new accumulation
                accumulationRole = role
                accumulationContent = content
                accumulationHasTool = currentHasTool
            }
        }

        // Flush remainder
        if let accRole = accumulationRole, !accumulationContent.isEmpty {
            sanitized.append(
                AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
                    content: accumulationContent,
                    role: accRole
                )
            )
        }

        if fixCount > 0 {
            logger.info(
                "🔧 SanitizeStrict: Fixed \(fixCount) issues, \(messages.count) -> \(sanitized.count) messages (no tool-boundary merges)"
            )
        }

        // Remove orphaned tool_use and ensure proper start role
        let toolCleaned = removeOrphanedToolUseBlocks(sanitized)
        return ensureProperStartRole(toolCleaned)
    }

    /// Extracts text content from AWS ContentBlock array for comparison
    private func extractTextFromAWSContentBlocks(
        _ blocks: [AWSBedrockRuntime.BedrockRuntimeClientTypes.ContentBlock]
    ) -> String {
        var text = ""
        for block in blocks {
            if case .text(let t) = block {
                text += t
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes orphaned tool_use blocks that don't have corresponding tool_result in the next user message
    /// This prevents ValidationException: "tool_use ids were found without tool_result blocks immediately after"
    private func removeOrphanedToolUseBlocks(
        _ messages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message]
    ) -> [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message] {
        guard messages.count > 1 else { return messages }

        var cleaned: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message] = []
        var orphanedToolUseCount = 0

        for i in 0..<messages.count {
            let message = messages[i]
            let role = message.role ?? .user
            var content = message.content ?? []

            // If this is an assistant message, check for tool_use blocks
            if role == .assistant {
                // Extract tool_use IDs from this message
                var toolUseIds: Set<String> = []
                for block in content {
                    if case .tooluse(let toolUse) = block, let toolUseId = toolUse.toolUseId {
                        toolUseIds.insert(toolUseId)
                    }
                }

                // If we have tool_use blocks, check if the next message has corresponding tool_result
                if !toolUseIds.isEmpty && i + 1 < messages.count {
                    let nextMessage = messages[i + 1]
                    let nextRole = nextMessage.role ?? .user

                    // Next message should be user with tool_result
                    if nextRole == .user {
                        // Extract tool_result IDs from next message
                        var toolResultIds: Set<String> = []
                        for block in nextMessage.content ?? [] {
                            if case .toolresult(let toolResult) = block,
                                let toolUseId = toolResult.toolUseId
                            {
                                toolResultIds.insert(toolUseId)
                            }
                        }

                        // Find orphaned tool_use IDs (those without corresponding tool_result)
                        let orphanedIds = toolUseIds.subtracting(toolResultIds)

                        if !orphanedIds.isEmpty {
                            // Remove orphaned tool_use blocks from content
                            content = content.filter { block in
                                if case .tooluse(let toolUse) = block,
                                    let toolUseId = toolUse.toolUseId,
                                    orphanedIds.contains(toolUseId)
                                {
                                    logger.warning(
                                        "🔧 Sanitize: Removing orphaned tool_use block with ID: \(toolUseId)"
                                    )
                                    orphanedToolUseCount += 1
                                    return false
                                }
                                return true
                            }
                        }
                    } else {
                        // Next message is not user, remove all tool_use blocks
                        let originalCount = content.count
                        content = content.filter { block in
                            if case .tooluse(let toolUse) = block {
                                if let toolUseId = toolUse.toolUseId {
                                    logger.warning(
                                        "🔧 Sanitize: Removing tool_use block (next message not user) with ID: \(toolUseId)"
                                    )
                                }
                                orphanedToolUseCount += 1
                                return false
                            }
                            return true
                        }
                        if content.count < originalCount {
                            logger.warning(
                                "🔧 Sanitize: Removed \(originalCount - content.count) tool_use blocks (next message not user)"
                            )
                        }
                    }
                } else if !toolUseIds.isEmpty {
                    // No next message, remove all tool_use blocks
                    let originalCount = content.count
                    content = content.filter { block in
                        if case .tooluse(let toolUse) = block {
                            if let toolUseId = toolUse.toolUseId {
                                logger.warning(
                                    "🔧 Sanitize: Removing tool_use block (no next message) with ID: \(toolUseId)"
                                )
                            }
                            orphanedToolUseCount += 1
                            return false
                        }
                        return true
                    }
                    if content.count < originalCount {
                        logger.warning(
                            "🔧 Sanitize: Removed \(originalCount - content.count) tool_use blocks (no next message)"
                        )
                    }
                }
            }

            // Only add message if it has content after cleaning
            if !content.isEmpty {
                cleaned.append(
                    AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
                        content: content,
                        role: role
                    ))
            } else if role == .assistant {
                // If assistant message has no content after removing tool_use, add a placeholder
                logger.warning(
                    "🔧 Sanitize: Assistant message became empty after tool_use removal, adding placeholder"
                )
                cleaned.append(
                    AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
                        content: [.text("Processing your request...")],
                        role: role
                    ))
            }
        }

        if orphanedToolUseCount > 0 {
            logger.info(
                "🔧 Sanitize: Removed \(orphanedToolUseCount) orphaned tool_use blocks to prevent ValidationException"
            )
        }

        return cleaned
    }

    /// Ensures messages start with user role and maintain alternation
    private func ensureProperStartRole(
        _ messages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message]
    ) -> [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message] {
        guard !messages.isEmpty else { return messages }

        // Check if first message is user
        if let firstRole = messages.first?.role, firstRole == .user {
            return messages
        }

        // First message is assistant, insert a dummy user message
        logger.warning("🔧 Sanitize: First message is not user, inserting dummy user message")

        let dummyUserMessage = AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
            content: [.text("Continue from previous conversation")],
            role: .user
        )

        return [dummyUserMessage] + messages
    }

    /// Validates that messages alternate between user and assistant roles
    /// AWS Bedrock REQUIRES strict alternating pattern: user -> assistant -> user -> assistant
    private func validateAlternatingRoles(
        _ messages: [AWSBedrockRuntime.BedrockRuntimeClientTypes.Message]
    ) throws {
        guard messages.count > 1 else { return }

        var previousRole: AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole? = nil
        var consecutiveRoleViolations:
            [(index: Int, role: AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole)] = []

        for (index, message) in messages.enumerated() {
            let currentRole = message.role ?? .user

            if let prevRole = previousRole, prevRole == currentRole {
                // Found consecutive same-role messages
                consecutiveRoleViolations.append((index: index, role: currentRole))
            }

            previousRole = currentRole
        }

        if !consecutiveRoleViolations.isEmpty {
            var errorMessage =
                "❌ Role alternation validation failed: AWS Bedrock requires strict user <-> assistant alternation"
            errorMessage += "\n\n🚨 Consecutive same-role messages detected:"

            for violation in consecutiveRoleViolations {
                errorMessage +=
                    "\n  - Message[\(violation.index)]: \(violation.role) (previous message also \(violation.role))"
            }

            errorMessage += "\n\n📊 Message role sequence:"
            for (index, message) in messages.enumerated() {
                let role = message.role ?? .user
                let marker =
                    consecutiveRoleViolations.contains(where: { $0.index == index }) ? " ⚠️" : ""
                errorMessage += "\n  [\(index)]: \(role)\(marker)"
            }

            throw ToolUseError(message: errorMessage)
        }

        logger.info("✅ Role alternation validation passed: All messages alternate correctly")
    }

    /// Creates optimal content order for AWS Bedrock API compatibility
    private func createOptimalContentOrder(
        text: String,
        thinking: String?,
        thinkingSignature: String?,
        toolUse: MessageContent.ToolUseContent,
        modelId: String
    ) -> [MessageContent] {
        var contents: [MessageContent] = []

        // For reasoning-capable models, add thinking first if available
        if let thinking = thinking, let signature = thinkingSignature,
            !isDeepSeekModel(modelId) && !isOpenAIModel(modelId)
        {
            contents.append(
                .thinking(MessageContent.ThinkingContent(text: thinking, signature: signature)))
        }

        // Add text content
        contents.append(.text(text))

        // Add tool use last
        contents.append(.tooluse(toolUse))

        return contents
    }

    /// Validates tool pairs in conversation history
    private func validateToolPairs(in history: [BedrockMessage]) throws {
        var toolUseIds: Set<String> = []
        var toolResultIds: Set<String> = []

        for message in history {
            for content in message.content {
                switch content {
                case .tooluse(let toolUse):
                    toolUseIds.insert(toolUse.toolUseId)
                case .toolresult(let toolResult):
                    toolResultIds.insert(toolResult.toolUseId)
                default:
                    continue
                }
            }
        }

        let orphanedToolUse = toolUseIds.subtracting(toolResultIds)
        let orphanedToolResult = toolResultIds.subtracting(toolUseIds)

        if !orphanedToolUse.isEmpty || !orphanedToolResult.isEmpty {
            var errorMessage = "Tool pair validation failed in conversation history:"
            if !orphanedToolUse.isEmpty {
                errorMessage +=
                    " Missing tool_result for IDs: \(orphanedToolUse.joined(separator: ", "))"
            }
            if !orphanedToolResult.isEmpty {
                errorMessage +=
                    " Missing tool_use for IDs: \(orphanedToolResult.joined(separator: ", "))"
            }
            throw ToolUseError(message: errorMessage)
        }
    }

    /// Cleans up broken tool pairs from conversation history
    private func cleanupBrokenToolPairs(_ history: [BedrockMessage]) -> [BedrockMessage] {
        var cleanedHistory: [BedrockMessage] = []
        var validToolIds: Set<String> = []

        // First pass: identify valid tool pairs
        var toolUseIds: Set<String> = []
        var toolResultIds: Set<String> = []

        for message in history {
            for content in message.content {
                switch content {
                case .tooluse(let toolUse):
                    toolUseIds.insert(toolUse.toolUseId)
                case .toolresult(let toolResult):
                    toolResultIds.insert(toolResult.toolUseId)
                default:
                    continue
                }
            }
        }

        // Only keep tool IDs that have both tool_use and tool_result
        validToolIds = toolUseIds.intersection(toolResultIds)

        // Second pass: rebuild history with only valid tool pairs
        for message in history {
            var cleanedContent: [MessageContent] = []

            for content in message.content {
                switch content {
                case .tooluse(let toolUse):
                    if validToolIds.contains(toolUse.toolUseId) {
                        cleanedContent.append(content)
                    } else {
                        logger.warning("Removing orphaned tool_use: \(toolUse.toolUseId)")
                    }
                case .toolresult(let toolResult):
                    if validToolIds.contains(toolResult.toolUseId) {
                        cleanedContent.append(content)
                    } else {
                        logger.warning("Removing orphaned tool_result: \(toolResult.toolUseId)")
                    }
                default:
                    cleanedContent.append(content)
                }
            }

            // Only add message if it has content
            if !cleanedContent.isEmpty {
                cleanedHistory.append(BedrockMessage(role: message.role, content: cleanedContent))
            }
        }

        logger.info("Cleaned up tool pairs: \(history.count) -> \(cleanedHistory.count) messages")
        return cleanedHistory
    }

    /// Creates minimal tool use message content in AWS Bedrock API compliant format
    /// AWS Bedrock requires assistant messages with tool_use to also have text content
    private func createMinimalToolUseMessage(
        text: String,
        thinking: String?,
        thinkingSignature: String?,
        toolUse: MessageContent.ToolUseContent,
        modelId: String
    ) -> [MessageContent] {
        var contents: [MessageContent] = []

        // Add thinking if present (for reasoning-capable models)
        if let thinking = thinking, let signature = thinkingSignature,
            !isDeepSeekModel(modelId) && !isOpenAIModel(modelId)
        {
            contents.append(
                .thinking(MessageContent.ThinkingContent(text: thinking, signature: signature)))
        }

        // CRITICAL: Always add text content before tool_use
        // AWS Bedrock requires text content in assistant messages with tool_use
        let textToUse =
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "I'll help you with that." : text
        contents.append(.text(textToUse))

        // Add tool use
        contents.append(.tooluse(toolUse))

        return contents
    }

    /// Emergency tool cleanup that removes ALL tool-related content from conversation history
    private func emergencyToolCleanup(_ history: [BedrockMessage]) async -> [BedrockMessage] {
        logger.warning(
            "🚨 EMERGENCY: Performing complete tool cleanup to prevent ValidationException")

        var cleanedHistory: [BedrockMessage] = []

        for message in history {
            var cleanedContent: [MessageContent] = []

            // Keep only non-tool content
            for content in message.content {
                switch content {
                case .text(let text):
                    cleanedContent.append(.text(text))
                case .thinking(let thinking):
                    // Keep thinking for supported models
                    if !isDeepSeekModel(chatModel.id) && !isOpenAIModel(chatModel.id) {
                        cleanedContent.append(.thinking(thinking))
                    }
                case .image(let image):
                    cleanedContent.append(.image(image))
                case .document(let document):
                    cleanedContent.append(.document(document))
                case .tooluse(_):
                    // REMOVE all tool_use content
                    logger.warning("🚨 Emergency: Removing tool_use content")
                case .toolresult(_):
                    // REMOVE all tool_result content
                    logger.warning("🚨 Emergency: Removing tool_result content")
                }
            }

            // Only add message if it has meaningful content
            if !cleanedContent.isEmpty {
                cleanedHistory.append(BedrockMessage(role: message.role, content: cleanedContent))
            } else {
                // Add a placeholder text message if no content remains
                cleanedHistory.append(
                    BedrockMessage(
                        role: message.role,
                        content: [
                            .text(message.role == .user ? "Previous request" : "Previous response")
                        ]
                    ))
            }
        }

        logger.warning(
            "🚨 Emergency cleanup completed: \(history.count) -> \(cleanedHistory.count) messages, ALL tools removed"
        )
        return cleanedHistory
    }

    // MARK: - Utility Functions

    // Extracts text content from a streaming chunk
    private func extractTextFromChunk(_ chunk: BedrockRuntimeClientTypes.ConverseStreamOutput)
        -> String?
    {
        if case .contentblockdelta(let deltaEvent) = chunk,
            let delta = deltaEvent.delta
        {
            if case .text(let textChunk) = delta {
                return textChunk
            }
        }
        return nil
    }

    // Extracts thinking content from a streaming chunk
    private func extractThinkingFromChunk(_ chunk: BedrockRuntimeClientTypes.ConverseStreamOutput)
        -> (text: String?, signature: String?)
    {
        var text: String? = nil
        var signature: String? = nil

        if case .contentblockdelta(let deltaEvent) = chunk,
            let delta = deltaEvent.delta,
            case .reasoningcontent(let reasoningChunk) = delta
        {

            switch reasoningChunk {
            case .text(let textContent):
                text = textContent
            case .signature(let signatureContent):
                signature = signatureContent
            case .redactedcontent, .sdkUnknown:
                break
            }
        }

        return (text, signature)
    }

    /// Converts a BedrockMessage to AWS SDK format with enhanced validation
    private func convertToBedrockMessage(_ message: BedrockMessage, modelId: String = "") throws
        -> AWSBedrockRuntime.BedrockRuntimeClientTypes.Message
    {
        var contentBlocks: [AWSBedrockRuntime.BedrockRuntimeClientTypes.ContentBlock] = []
        var debugInfo: [String] = []

        // Log the original message structure for debugging
        logger.debug(
            "🔍 Converting message with \(message.content.count) content blocks, role: \(message.role)"
        )

        // Process all content blocks with enhanced error handling
        for (index, content) in message.content.enumerated() {
            switch content {
            case .text(let text):
                // CRITICAL FIX: Skip empty or whitespace-only text blocks as they cause ValidationException
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    contentBlocks.append(.text(trimmedText))
                    debugInfo.append("text[\(index)]")
                } else {
                    logger.warning("🚨 Skipping empty text block at index \(index)")
                }

            case .thinking(let thinkingContent):
                // Skip reasoning content for user messages
                // Also skip for DeepSeek models due to a server-side validation error
                // Also skip for OpenAI models that don't support signature field
                if message.role == .user || isDeepSeekModel(modelId) || isOpenAIModel(modelId) {
                    logger.debug("Skipping thinking block for \(message.role) or unsupported model")
                    continue
                }

                // CRITICAL FIX: Validate thinking content before processing
                let trimmedThinking = thinkingContent.text.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if !trimmedThinking.isEmpty && !thinkingContent.signature.isEmpty {
                    let reasoningTextBlock = AWSBedrockRuntime.BedrockRuntimeClientTypes
                        .ReasoningTextBlock(
                            signature: thinkingContent.signature,
                            text: trimmedThinking
                        )
                    contentBlocks.append(.reasoningcontent(.reasoningtext(reasoningTextBlock)))
                    debugInfo.append("thinking[\(index)]")
                } else {
                    logger.warning(
                        "🚨 Skipping invalid thinking block at index \(index): empty text or signature"
                    )
                }

            case .image(let imageContent):
                // Convert to AWS image format with validation
                let awsFormat: AWSBedrockRuntime.BedrockRuntimeClientTypes.ImageFormat
                switch imageContent.format {
                case .jpeg: awsFormat = .jpeg
                case .png: awsFormat = .png
                case .gif: awsFormat = .gif
                case .webp: awsFormat = .png  // Fall back to PNG for WebP
                }

                // CRITICAL FIX: Enhanced base64 validation
                guard !imageContent.base64Data.isEmpty,
                    let imageData = Data(base64Encoded: imageContent.base64Data),
                    !imageData.isEmpty
                else {
                    logger.error("🚨 Invalid image data at index \(index), skipping")
                    continue
                }

                contentBlocks.append(
                    .image(
                        AWSBedrockRuntime.BedrockRuntimeClientTypes.ImageBlock(
                            format: awsFormat,
                            source: .bytes(imageData)
                        )))
                debugInfo.append("image[\(index)]")

            case .document(let documentContent):
                // Convert to AWS document format with validation
                let docFormat: AWSBedrockRuntime.BedrockRuntimeClientTypes.DocumentFormat

                switch documentContent.format {
                case .pdf: docFormat = .pdf
                case .csv: docFormat = .csv
                case .doc: docFormat = .doc
                case .docx: docFormat = .docx
                case .xls: docFormat = .xls
                case .xlsx: docFormat = .xlsx
                case .html: docFormat = .html
                case .txt: docFormat = .txt
                case .md: docFormat = .md
                }

                // CRITICAL FIX: Enhanced document validation
                guard !documentContent.base64Data.isEmpty,
                    !documentContent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let documentData = Data(base64Encoded: documentContent.base64Data),
                    !documentData.isEmpty
                else {
                    logger.error("🚨 Invalid document data at index \(index), skipping")
                    continue
                }

                contentBlocks.append(
                    .document(
                        AWSBedrockRuntime.BedrockRuntimeClientTypes.DocumentBlock(
                            format: docFormat,
                            name: documentContent.name.trimmingCharacters(
                                in: .whitespacesAndNewlines),
                            source: .bytes(documentData)
                        )))
                debugInfo.append("document[\(index)]")

            case .toolresult(let toolResultContent):
                // CRITICAL FIX: Enhanced tool result validation
                let trimmedResult = toolResultContent.result.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let trimmedToolUseId = toolResultContent.toolUseId.trimmingCharacters(
                    in: .whitespacesAndNewlines)

                guard !trimmedResult.isEmpty && !trimmedToolUseId.isEmpty else {
                    logger.error(
                        "🚨 Invalid tool result at index \(index): empty result or toolUseId, skipping"
                    )
                    continue
                }

                // Convert to AWS tool result format
                let toolResultBlock = AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolResultBlock(
                    content: [.text(trimmedResult)],
                    status: toolResultContent.status == "success" ? .success : .error,
                    toolUseId: trimmedToolUseId
                )

                contentBlocks.append(.toolresult(toolResultBlock))
                debugInfo.append("toolresult[\(index)]:\(trimmedToolUseId)")

            case .tooluse(let toolUseContent):
                // CRITICAL FIX: Enhanced tool use validation
                let trimmedName = toolUseContent.name.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let trimmedToolUseId = toolUseContent.toolUseId.trimmingCharacters(
                    in: .whitespacesAndNewlines)

                guard !trimmedName.isEmpty && !trimmedToolUseId.isEmpty else {
                    logger.error(
                        "🚨 Invalid tool use at index \(index): empty name or toolUseId, skipping")
                    continue
                }

                // Convert to AWS tool use format with enhanced error handling
                do {
                    // CRITICAL FIX: More robust JSONValue to Document conversion
                    let inputDocument: Smithy.Document

                    switch toolUseContent.input {
                    case .null:
                        inputDocument = try Smithy.Document.make(from: [String: Any]())
                    case .object(let obj):
                        // Ensure we have a valid object
                        if obj.isEmpty {
                            inputDocument = try Smithy.Document.make(from: [String: Any]())
                        } else {
                            let swiftObject = toolUseContent.input.asAny
                            inputDocument = try Smithy.Document.make(from: swiftObject)
                        }
                    default:
                        let swiftObject = toolUseContent.input.asAny
                        inputDocument = try Smithy.Document.make(from: swiftObject)
                    }

                    let toolUseBlock = AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolUseBlock(
                        input: inputDocument,
                        name: trimmedName,
                        toolUseId: trimmedToolUseId
                    )

                    contentBlocks.append(.tooluse(toolUseBlock))
                    debugInfo.append("tooluse[\(index)]:\(trimmedToolUseId)")
                    logger.debug(
                        "✅ Successfully converted toolUse '\(trimmedName)' ID:\(trimmedToolUseId)")

                } catch {
                    logger.error(
                        "🚨 Failed to convert tool use at index \(index) - Name: '\(trimmedName)', ID: '\(trimmedToolUseId)', Input: \(toolUseContent.input), Error: \(error)"
                    )
                    // CRITICAL: Don't skip tool_use as it would create orphaned tool_result
                    throw ToolUseError(
                        message:
                            "Tool use conversion failed for '\(trimmedName)': \(error.localizedDescription)"
                    )
                }
            }
        }

        // CRITICAL FIX: Ensure message has content
        if contentBlocks.isEmpty {
            logger.error("🚨 CRITICAL: Message would have no content blocks after processing")
            // Add a minimal text block to prevent ValidationException
            contentBlocks.append(.text("Empty message"))
            debugInfo.append("fallback_text")
        }

        logger.debug("🔍 Final message structure: \(debugInfo.joined(separator: ", "))")

        return AWSBedrockRuntime.BedrockRuntimeClientTypes.Message(
            content: contentBlocks,
            role: convertToAWSRole(message.role)
        )
    }

    /// Converts MessageRole to AWS SDK role
    private func convertToAWSRole(_ role: MessageRole)
        -> AWSBedrockRuntime.BedrockRuntimeClientTypes.ConversationRole
    {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        }
    }

    // MARK: - Image Generation Model Handling

    /// Determines if the model ID represents a text generation model that can support streaming
    private func isTextGenerationModel(_ modelId: String) -> Bool {
        let id = modelId.lowercased()

        // Special case: check for non-text generation models first
        if id.contains("embed") || id.contains("image") || id.contains("video")
            || id.contains("stable-") || id.contains("-canvas") || id.contains("titan-embed")
            || id.contains("titan-e1t")
        {
            return false
        } else {
            // Text generation models - be more specific with nova to exclude nova-canvas
            let isNova = id.contains("nova") && !id.contains("canvas")

            return id.contains("mistral") || id.contains("claude") || id.contains("llama") || isNova
                || id.contains("titan") || id.contains("deepseek") || id.contains("command")
                || id.contains("jurassic") || id.contains("jamba") || id.contains("openai")
        }
    }

    private func isDeepSeekModel(_ modelId: String) -> Bool {
        return modelId.lowercased().contains("deepseek")
    }

    private func isOpenAIModel(_ modelId: String) -> Bool {
        let modelType = backendModel.backend.getModelType(modelId)
        return modelType == .openaiGptOss120b || modelType == .openaiGptOss20b
    }

    /// Handles image generation models that don't use converseStream
    private func handleImageGenerationModel(_ userMessage: MessageData) async throws {
        let modelId = chatModel.id

        if modelId.contains("titan-image") {
            try await invokeTitanImageModel(prompt: userMessage.text)
        } else if modelId.contains("nova-canvas") {
            try await invokeNovaCanvasModel(prompt: userMessage.text)
        } else if modelId.contains("stable") || modelId.contains("sd3") {
            try await invokeStableDiffusionModel(prompt: userMessage.text)
        } else {
            throw NSError(
                domain: "ChatViewModel", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported image generation model: \(modelId)"
                ])
        }
    }

    /// Handles embedding models by directly parsing JSON responses
    private func handleEmbeddingModel(_ userMessage: MessageData) async throws {
        // Invoke embedding model to get raw data response
        let responseData = try await backendModel.backend.invokeEmbeddingModel(
            withId: chatModel.id,
            text: userMessage.text
        )

        let modelId = chatModel.id.lowercased()
        var responseText = ""

        // Parse JSON data directly
        if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) {
            if modelId.contains("titan-embed") || modelId.contains("titan-e1t") {
                if let jsonDict = json as? [String: Any],
                    let embedding = jsonDict["embedding"] as? [Double]
                {
                    responseText = embedding.map { "\($0)" }.joined(separator: ",")
                } else {
                    responseText = "Failed to extract Titan embedding data"
                }
            } else if modelId.contains("cohere") {
                if let jsonDict = json as? [String: Any],
                    let embeddings = jsonDict["embeddings"] as? [[Double]],
                    let firstEmbedding = embeddings.first
                {
                    responseText = firstEmbedding.map { "\($0)" }.joined(separator: ",")
                } else {
                    responseText = "Failed to extract Cohere embedding data"
                }
            } else {
                if let jsonData = try? JSONSerialization.data(
                    withJSONObject: json, options: [.prettyPrinted]),
                    let jsonString = String(data: jsonData, encoding: .utf8)
                {
                    responseText = jsonString
                } else {
                    responseText = "Unknown embedding format"
                }
            }
        } else {
            responseText =
                String(data: responseData, encoding: .utf8) ?? "Unable to decode response"
        }

        // Create response message
        let assistantMessage = MessageData(
            id: UUID(),
            text: responseText,
            user: chatModel.name,
            isError: false,
            sentTime: Date()
        )

        // Add message to chat
        addMessage(assistantMessage)

        // Update conversation history
        var conversationHistory = await getConversationHistory()
        conversationHistory.append(
            BedrockMessage(
                role: .assistant,
                content: [.text(responseText)]
            ))
        await saveConversationHistory(conversationHistory)
    }

    /// Invokes Titan Image model
    private func invokeTitanImageModel(prompt: String) async throws {
        let data = try await backendModel.backend.invokeImageModel(
            withId: chatModel.id,
            prompt: prompt,
            modelType: .titanImage
        )

        try processImageModelResponse(data)
    }

    /// Invokes Nova Canvas image model
    private func invokeNovaCanvasModel(prompt: String) async throws {
        let data = try await backendModel.backend.invokeImageModel(
            withId: chatModel.id,
            prompt: prompt,
            modelType: .novaCanvas
        )

        try processImageModelResponse(data)
    }

    /// Invokes Stable Diffusion image model
    private func invokeStableDiffusionModel(prompt: String) async throws {
        let data = try await backendModel.backend.invokeImageModel(
            withId: chatModel.id,
            prompt: prompt,
            modelType: .stableDiffusion
        )

        try processImageModelResponse(data)
    }

    /// Process and save image data from image generation models
    private func processImageModelResponse(_ data: Data) throws {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let timestamp = formatter.string(from: now)
        let fileName = "\(timestamp).png"
        let tempDir = URL(fileURLWithPath: settingManager.defaultDirectory)
        let fileURL = tempDir.appendingPathComponent(fileName)

        try data.write(to: fileURL)

        if let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            let markdownImage = "![](http://localhost:8080/\(encoded))"
            let imageMessage = MessageData(
                id: UUID(),
                text: markdownImage,
                user: chatModel.name,
                isError: false,
                sentTime: Date()
            )
            addMessage(imageMessage)

            // Update history
            var history = chatManager.getHistory(for: chatId)
            history += "\nAssistant: [Generated Image]\n"
            chatManager.setHistory(history, for: chatId)
        } else {
            throw NSError(
                domain: "ImageEncodingError",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode image filename"]
            )
        }
    }

    // MARK: - Basic Message Operations

    func addMessage(_ message: MessageData) {
        // NEW: Check for duplicate messages (same text from same user within 2 seconds)
        let isDuplicate = messages.contains { existing in
            existing.user == message.user && existing.text == message.text
                && abs(existing.sentTime.timeIntervalSince(message.sentTime)) < 2.0
                && existing.id != message.id
        }

        if isDuplicate {
            logger.warning(
                "🚫 Duplicate message blocked: Same text '\(message.text.prefix(50))...' from \(message.user)"
            )
            return
        }

        // Check if we're updating an existing message (for streaming)
        if let id = currentStreamingMessageId,
            message.id == id,
            let index = messages.firstIndex(where: { $0.id == id })
        {
            // Update existing message
            messages[index] = message
        } else {
            // Add as new message
            messages.append(message)
        }

        // Convert MessageData to Message struct
        let convertedMessage = Message(
            id: message.id,
            text: message.text,
            role: message.user == "User" ? .user : .assistant,
            timestamp: message.sentTime,
            isError: message.isError,
            thinking: message.thinking,
            thinkingSignature: message.signature,
            imageBase64Strings: message.imageBase64Strings,
            documentBase64Strings: message.documentBase64Strings,
            documentFormats: message.documentFormats,
            documentNames: message.documentNames,
            toolUse: message.toolUse.map { toolUse in
                Message.ToolUse(
                    toolId: toolUse.id,
                    toolName: toolUse.name,
                    inputs: toolUse.input,
                    result: message.toolResult
                )
            }
        )

        // Add to chat manager
        chatManager.addMessage(convertedMessage, to: chatId)
    }

    // UIのみ追加（ストレージへは保存しない）ためのヘルパー
    private func addUIOnlyMessage(_ message: MessageData) {
        // NEW: 重複（同一ユーザー・同一テキスト・2秒以内）をブロック
        let isDuplicate = messages.contains { existing in
            existing.user == message.user && existing.text == message.text
                && abs(existing.sentTime.timeIntervalSince(message.sentTime)) < 2.0
                && existing.id != message.id
        }

        if isDuplicate {
            logger.warning(
                "🚫 Duplicate UI-only message blocked: '\(message.text.prefix(50))...' from \(message.user)"
            )
            return
        }

        // ストリーミング中メッセージの更新に対応
        if let id = currentStreamingMessageId,
            message.id == id,
            let index = messages.firstIndex(where: { $0.id == id })
        {
            messages[index] = message
        } else {
            messages.append(message)
        }

        // ストレージへは保存しない（ChatManager.addMessageは呼ばない）
        self.objectWillChange.send()
    }

    private func handleModelError(_ error: Error) async {
        logger.error("Error invoking the model: \(error)")

        // 詳細なエラー分析
        var errorDetails = "Error invoking the model: \(error.localizedDescription)"

        if let nsError = error as NSError? {
            errorDetails += "\n\nError Details:"
            errorDetails += "\n- Domain: \(nsError.domain)"
            errorDetails += "\n- Code: \(nsError.code)"

            // ValidationException の詳細分析
            if nsError.domain.contains("ValidationException") {
                errorDetails += "\n- Type: AWS Bedrock Runtime ValidationException"
                errorDetails += "\n\n考えられる原因:"
                errorDetails += "\n1. tool_use/tool_result のペアが不整合"
                errorDetails += "\n2. メッセージの順序が不正"
                errorDetails += "\n3. リクエストの形式が無効"

                // 会話履歴の状態をログ出力
                if let history = chatManager.getConversationHistory(for: chatId) {
                    logger.error("Conversation history state at error:")
                    for (index, message) in history.messages.enumerated() {
                        if let toolUse = message.toolUse {
                            logger.error(
                                "Message[\(index)] \(message.role): tool_id=\(toolUse.toolId), has_result=\(toolUse.result != nil)"
                            )
                        } else {
                            logger.error("Message[\(index)] \(message.role): no_tool")
                        }
                    }
                } else {
                    logger.error("No conversation history available for analysis")
                }

                errorDetails += "\n\n📋 会話履歴の状態がログに出力されました"
            }

            // タイムアウトエラーの場合の詳細情報
            if nsError.code == -1001 {
                errorDetails += "\n- Type: Request Timeout (NSURLErrorTimedOut)"
                errorDetails += "\n\n対処法:"
                errorDetails += "\n1. ネットワーク接続を確認してください"
                errorDetails += "\n2. 複雑な質問の場合、より短い質問に分割してみてください"
                errorDetails += "\n3. しばらく待ってから再試行してください"
                errorDetails += "\n4. 別のモデル（Nova Pro等）を試してみてください"

                if let failingURL = nsError.userInfo["NSErrorFailingURLStringKey"] as? String {
                    errorDetails += "\n- Failing URL: \(failingURL)"
                }
            }

            // その他の詳細情報
            for (key, value) in nsError.userInfo {
                if key != NSLocalizedDescriptionKey && key != "NSErrorFailingURLStringKey" {
                    errorDetails += "\n- \(key): \(value)"
                }
            }
        }

        let errorMessage = MessageData(
            id: UUID(),
            text: errorDetails,
            user: "System",
            isError: true,
            sentTime: Date()
        )
        addMessage(errorMessage)
    }

    /// Encodes an image to Base64.
    func base64EncodeImage(_ image: NSImage, withExtension fileExtension: String) -> (
        base64String: String?, mediaType: String?
    ) {
        guard let tiffRepresentation = image.tiffRepresentation,
            let bitmapImage = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return (nil, nil)
        }

        let imageData: Data?
        let mediaType: String

        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            imageData = bitmapImage.representation(using: .jpeg, properties: [:])
            mediaType = "image/jpeg"
        case "png":
            imageData = bitmapImage.representation(using: .png, properties: [:])
            mediaType = "image/png"
        case "webp":
            imageData = nil
            mediaType = "image/webp"
        case "gif":
            imageData = nil
            mediaType = "image/gif"
        default:
            return (nil, nil)
        }

        guard let data = imageData else {
            return (nil, nil)
        }

        return (data.base64EncodedString(), mediaType)
    }

    /// Updates the chat title with a summary of the input.
    func updateChatTitle(with input: String) async {
        let summaryPrompt = """
            Summarize user input <input>\(input)</input> as short as possible. Just in few words without punctuation. It should not be more than 5 words. Do as best as you can. please do summary this without punctuation:
            """

        // Create message for converseStream
        let userMsg = BedrockMessage(
            role: .user,
            content: [.text(summaryPrompt)]
        )

        // Determine the best model for title generation
        let titleGenerationModelId = selectTitleGenerationModel()

        do {
            // Convert to AWS SDK format
            let awsMessage = try convertToBedrockMessage(userMsg, modelId: titleGenerationModelId)

            // Use converseStream API to get the title
            var title = ""

            let systemContentBlocks: [BedrockRuntimeClientTypes.SystemContentBlock]? = nil

            for try await chunk in try await backendModel.backend.converseStream(
                withId: titleGenerationModelId,
                messages: [awsMessage],
                systemContent: systemContentBlocks,
                inferenceConfig: nil,
                usageHandler: { [weak self] usage in
                    // Title generation usage info
                    self?.logger.debug(
                        "Title generation usage - Input: \(usage.inputTokens ?? 0), Output: \(usage.outputTokens ?? 0)"
                    )
                }
            ) {
                if let textChunk = extractTextFromChunk(chunk) {
                    title += textChunk
                }
            }

            // Update chat title with the generated summary
            if !title.isEmpty {
                chatManager.updateChatTitle(
                    for: chatModel.chatId,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } catch {
            logger.error("Error updating chat title: \(error)")
            // If title generation fails, create a simple fallback title
            createFallbackTitle(from: input)
        }
    }

    /// Selects the best available model for title generation
    private func selectTitleGenerationModel() -> String {
        // First, try to use the current model if it's a text generation model
        if isTextGenerationModel(chatModel.id) {
            logger.debug("Using current model for title generation: \(chatModel.id)")
            return chatModel.id
        }

        // Priority list of preferred models for title generation (lightweight and efficient)
        let preferredModels = [
            // Amazon Nova models (lightweight)
            "amazon.nova-lite-v1:0",
            "us.amazon.nova-lite-v1:0",
            "amazon.nova-micro-v1:0",
            "us.amazon.nova-micro-v1:0",

            // Claude models (Haiku is lightweight)
            "anthropic.claude-3-haiku-20240307-v1:0",
            "anthropic.claude-3-5-haiku-20241022-v1:0",

            // Meta Llama models (smaller variants)
            "meta.llama3-8b-instruct-v1:0",
            "meta.llama3-1-8b-instruct-v1:0",

            // Mistral models (lightweight)
            "mistral.mistral-7b-instruct-v0:2",

            // Fallback to any available Nova Pro
            "amazon.nova-pro-v1:0",
            "us.amazon.nova-pro-v1:0",

            // Fallback to Claude Sonnet
            "anthropic.claude-3-5-sonnet-20241022-v2:0",
            "anthropic.claude-3-5-sonnet-20240620-v1:0",

            // Additional fallbacks
            "meta.llama3-1-70b-instruct-v1:0",
            "anthropic.claude-3-opus-20240229-v1:0",
        ]

        // Try to find a preferred model that's available by checking each one
        for preferredModel in preferredModels {
            // For now, we'll try to use the preferred models directly
            // since checking availability requires async calls
            logger.info("Attempting to use preferred model for title generation: \(preferredModel)")
            return preferredModel
        }

        // Final fallback - use the current model even if it's not ideal
        logger.warning(
            "No suitable model found for title generation, using current model: \(chatModel.id)")
        return chatModel.id
    }

    /// Creates a simple fallback title when automatic generation fails
    private func createFallbackTitle(from input: String) {
        let words = input.split(separator: " ").prefix(5)
        let fallbackTitle = words.joined(separator: " ")

        if !fallbackTitle.isEmpty {
            chatManager.updateChatTitle(
                for: chatModel.chatId,
                title: String(fallbackTitle)
            )
            logger.info("Created fallback title: \(fallbackTitle)")
        }
    }

    // MARK: - Context Organization

    /// Organizes the conversation context by summarizing and reducing information
    func organizeContext() {
        guard !messages.isEmpty else {
            logger.info("No messages to organize")
            return
        }

        guard !isContextOrganizationInProgress else {
            logger.info("Context organization already in progress")
            return
        }

        isContextOrganizationInProgress = true

        Task {
            await performContextOrganization()
        }
    }

    private func performContextOrganization() async {
        logger.info("Starting context organization for \(messages.count) messages")

        do {
            // Get current conversation history
            let conversationHistory = await getConversationHistory()

            // Create a prompt for context organization
            let organizationPrompt = createContextOrganizationPrompt(from: conversationHistory)

            // Use the current model to organize the context
            let organizedSummary = try await requestContextOrganization(prompt: organizationPrompt)

            // Create a new organized message to replace the conversation
            await replaceConversationWithOrganizedSummary(organizedSummary)

            logger.info("Context organization completed successfully")

        } catch {
            logger.error("Context organization failed: \(error)")

            // Show error message to user
            let errorMessage = MessageData(
                id: UUID(),
                text: "コンテキスト整理中にエラーが発生しました: \(error.localizedDescription)",
                user: "System",
                isError: true,
                sentTime: Date()
            )
            addMessage(errorMessage)
        }

        await MainActor.run {
            isContextOrganizationInProgress = false
        }
    }

    private func createContextOrganizationPrompt(from history: [BedrockMessage]) -> String {
        var conversationText = ""

        for message in history {
            let role = message.role == .user ? "User" : "Assistant"

            for content in message.content {
                switch content {
                case .text(let text):
                    conversationText += "\n\(role): \(text)\n"
                case .thinking(let thinking):
                    conversationText += "\n[Assistant Thinking]: \(thinking.text)\n"
                case .image(_):
                    conversationText += "\n[Image attached]\n"
                case .document(let doc):
                    conversationText += "\n[Document: \(doc.name)]\n"
                case .tooluse(let tool):
                    conversationText += "\n[Tool Used: \(tool.name)]\n"
                case .toolresult(let result):
                    conversationText += "\n[Tool Result: \(result.result.prefix(100))...]\n"
                }
            }
        }

        return """
            以下の会話履歴を整理して、重要な情報を保持しながら情報量を削減してください。

            整理の方針：
            1. 重要な質問と回答は保持する
            2. 重複する情報は統合する
            3. 詳細な技術的説明は要点をまとめる
            4. ツールの使用結果は重要な部分のみ残す
            5. 会話の流れと文脈は維持する

            会話履歴：
            \(conversationText)

            上記の会話を整理して、重要な情報を保持しながらより簡潔にまとめてください。
            整理後の内容は、元の会話の文脈と重要な情報を失わないようにしてください。
            """
    }

    private func requestContextOrganization(prompt: String) async throws -> String {
        // Create a message for the organization request
        let organizationMessage = BedrockMessage(
            role: .user,
            content: [.text(prompt)]
        )

        // Convert to AWS SDK format
        let awsMessage = try convertToBedrockMessage(organizationMessage, modelId: chatModel.id)

        // Use the current model for organization
        var organizedText = ""

        // Use streaming to get the organized content
        for try await chunk in try await backendModel.backend.converseStream(
            withId: chatModel.id,
            messages: [awsMessage],
            systemContent: [.text("あなたは会話の整理を専門とするアシスタントです。与えられた会話履歴を簡潔にまとめ、重要な情報を保持してください。")],
            inferenceConfig: nil,
            usageHandler: { [weak self] usage in
                let formattedUsage = self?.formatUsageString(usage) ?? ""
                self?.usageHandler?(formattedUsage)
            }
        ) {
            if let textChunk = extractTextFromChunk(chunk) {
                organizedText += textChunk
            }
        }

        return organizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replaceConversationWithOrganizedSummary(_ summary: String) async {
        // Clear current messages
        await MainActor.run {
            messages.removeAll()
        }

        // Create a new summary message
        let summaryMessage = MessageData(
            id: UUID(),
            text: "📋 **会話コンテキストが整理されました**\n\n\(summary)",
            user: "System",
            isError: false,
            sentTime: Date()
        )

        // Add the summary message
        addMessage(summaryMessage)

        // Create new conversation history with just the summary
        let newHistory = [
            BedrockMessage(
                role: .assistant,
                content: [.text(summary)]
            )
        ]

        // Save the new organized history
        await saveConversationHistory(newHistory)

        logger.info("Conversation replaced with organized summary")
    }

    // MARK: - Context Cache Optimization

    /// Optimizes the conversation context for better cache efficiency
    func optimizeContextCache() {
        guard !messages.isEmpty else {
            logger.info("No messages to optimize for cache")
            return
        }

        guard !isContextCacheOptimizationInProgress else {
            logger.info("Context cache optimization already in progress")
            return
        }

        isContextCacheOptimizationInProgress = true

        Task {
            await performContextCacheOptimization()
        }
    }

    private func performContextCacheOptimization() async {
        logger.info("Starting context cache optimization for \(messages.count) messages")

        do {
            // Get current conversation history
            let conversationHistory = await getConversationHistory()

            // Analyze and optimize the conversation for cache efficiency
            let optimizedHistory = await optimizeHistoryForCache(conversationHistory)

            // Update the conversation with optimized content
            await updateConversationWithOptimizedHistory(optimizedHistory)

            logger.info("Context cache optimization completed successfully")

        } catch {
            logger.error("Context cache optimization failed: \(error)")

            // Show error message to user
            let errorMessage = MessageData(
                id: UUID(),
                text: "コンテキストキャッシュ最適化中にエラーが発生しました: \(error.localizedDescription)",
                user: "System",
                isError: true,
                sentTime: Date()
            )
            addMessage(errorMessage)
        }

        await MainActor.run {
            isContextCacheOptimizationInProgress = false
        }
    }

    private func optimizeHistoryForCache(_ history: [BedrockMessage]) async -> [BedrockMessage] {
        logger.info("Optimizing \(history.count) messages for cache efficiency")

        // Calculate token usage and determine optimal message count for 200K context window
        let targetTokenLimit = 180_000  // Leave 20K tokens for new conversation
        let (recentMessageCount, estimatedTokens) = calculateOptimalMessageCount(
            history, targetLimit: targetTokenLimit)

        logger.info(
            "Calculated optimal message count: \(recentMessageCount) (estimated tokens: \(estimatedTokens))"
        )

        let recentMessages = Array(history.suffix(recentMessageCount))
        let olderMessages = Array(history.prefix(history.count - recentMessageCount))

        var optimizedHistory: [BedrockMessage] = []

        // If there are older messages, create a summary
        if !olderMessages.isEmpty {
            do {
                let compressedSummary = try await compressMessagesForCache(olderMessages)

                // Create a single compressed message
                let compressedMessage = BedrockMessage(
                    role: .assistant,
                    content: [.text("📋 **前の会話の要約**: \(compressedSummary)")]
                )
                optimizedHistory.append(compressedMessage)

                logger.info("Compressed \(olderMessages.count) older messages into summary")
            } catch {
                logger.error("Failed to compress older messages: \(error)")
                // If compression fails, create a simple placeholder
                let placeholderMessage = BedrockMessage(
                    role: .assistant,
                    content: [.text("📋 **前の会話**: 以前の会話履歴（\(olderMessages.count)メッセージ）が圧縮されました。")]
                )
                optimizedHistory.append(placeholderMessage)
            }
        }

        // Add recent messages with smart filtering
        for message in recentMessages {
            var filteredContent: [MessageContent] = []

            for content in message.content {
                switch content {
                case .text(let text):
                    // Keep full text for recent messages but limit extremely long texts
                    let truncatedText =
                        text.count > 10000 ? String(text.prefix(10000)) + "..." : text
                    filteredContent.append(.text(truncatedText))
                case .thinking(let thinking):
                    // Keep thinking for Claude models but limit length
                    if !isOpenAIModel(chatModel.id) && !isDeepSeekModel(chatModel.id) {
                        let truncatedThinking =
                            thinking.text.count > 5000
                            ? String(thinking.text.prefix(5000)) + "..." : thinking.text
                        filteredContent.append(
                            .thinking(
                                MessageContent.ThinkingContent(
                                    text: truncatedThinking, signature: thinking.signature)))
                    }
                case .image(_):
                    // Replace images with placeholder to save tokens
                    filteredContent.append(.text("[画像が添付されていました]"))
                case .document(let doc):
                    // Replace documents with name reference
                    filteredContent.append(.text("[ドキュメント: \(doc.name)]"))
                case .tooluse(let tool):
                    // Keep tool use but simplify input
                    let simplifiedInput = simplifyToolInput(tool.input)
                    filteredContent.append(
                        .tooluse(
                            MessageContent.ToolUseContent(
                                toolUseId: tool.toolUseId,
                                name: tool.name,
                                input: simplifiedInput
                            )))
                case .toolresult(let result):
                    // Keep tool results but limit length
                    let truncatedResult =
                        result.result.count > 2000
                        ? String(result.result.prefix(2000)) + "..." : result.result
                    filteredContent.append(
                        .toolresult(
                            MessageContent.ToolResultContent(
                                toolUseId: result.toolUseId,
                                result: truncatedResult,
                                status: result.status
                            )))
                }
            }

            if !filteredContent.isEmpty {
                let filteredMessage = BedrockMessage(role: message.role, content: filteredContent)
                optimizedHistory.append(filteredMessage)
            }
        }

        logger.info("Optimized history: \(optimizedHistory.count) messages (was \(history.count))")
        return optimizedHistory
    }

    private func compressMessagesForCache(_ messages: [BedrockMessage]) async throws -> String {
        var conversationText = ""

        for message in messages {
            let role = message.role == .user ? "User" : "Assistant"

            for content in message.content {
                switch content {
                case .text(let text):
                    conversationText += "\n\(role): \(text)\n"
                case .thinking(let thinking):
                    // Include key insights from thinking
                    conversationText += "\n[Key Insight]: \(thinking.text.prefix(200))...\n"
                case .image(_):
                    conversationText += "\n[Image discussed]\n"
                case .document(let doc):
                    conversationText += "\n[Document analyzed: \(doc.name)]\n"
                case .tooluse(let tool):
                    conversationText += "\n[Tool used: \(tool.name)]\n"
                case .toolresult(let result):
                    // Include key results
                    conversationText += "\n[Result: \(result.result.prefix(150))...]\n"
                }
            }
        }

        let compressionPrompt = """
            以下の会話履歴をキャッシュ効率を考慮して圧縮してください。

            圧縮の方針：
            1. 重要な情報と文脈は保持する
            2. 冗長な表現を削除する
            3. キーポイントを箇条書きで整理する
            4. 技術的な詳細は要約する
            5. 会話の流れは簡潔に保つ

            会話履歴：
            \(conversationText)

            上記の内容を、重要な情報を失わずにキャッシュ効率の良い形で圧縮してください。
            """

        // Create a message for the compression request
        let compressionMessage = BedrockMessage(
            role: .user,
            content: [.text(compressionPrompt)]
        )

        // Convert to AWS SDK format
        let awsMessage = try convertToBedrockMessage(compressionMessage, modelId: chatModel.id)

        // Use a lightweight model for compression to save costs
        let compressionModelId = "us.amazon.nova-lite-v1:0"  // Use Nova Lite for efficiency

        var compressedText = ""

        // Use streaming to get the compressed content
        for try await chunk in try await backendModel.backend.converseStream(
            withId: compressionModelId,
            messages: [awsMessage],
            systemContent: [
                .text("あなたは効率的なコンテキスト圧縮の専門家です。重要な情報を保持しながら、キャッシュ効率を最大化する形で内容を圧縮してください。")
            ],
            inferenceConfig: nil,
            usageHandler: { [weak self] usage in
                let formattedUsage = self?.formatUsageString(usage) ?? ""
                self?.usageHandler?(formattedUsage)
            }
        ) {
            if let textChunk = extractTextFromChunk(chunk) {
                compressedText += textChunk
            }
        }

        return compressedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Token Calculation Helpers

    /// Calculates optimal message count based on target token limit
    private func calculateOptimalMessageCount(_ history: [BedrockMessage], targetLimit: Int) -> (
        messageCount: Int, estimatedTokens: Int
    ) {
        var totalTokens = 0
        var messageCount = 0

        // Process messages from newest to oldest
        for message in history.reversed() {
            let messageTokens = estimateTokensForMessage(message)

            if totalTokens + messageTokens <= targetLimit {
                totalTokens += messageTokens
                messageCount += 1
            } else {
                break
            }
        }

        // Ensure we keep at least 1 message if history is not empty
        if messageCount == 0 && !history.isEmpty {
            messageCount = 1
            totalTokens = estimateTokensForMessage(history.last!)
        }

        return (messageCount, totalTokens)
    }

    /// Estimates token count for a single message
    private func estimateTokensForMessage(_ message: BedrockMessage) -> Int {
        var tokens = 0

        for content in message.content {
            switch content {
            case .text(let text):
                // Rough estimation: 1 token per 4 characters for English/Japanese mixed text
                tokens += max(1, text.count / 3)
            case .thinking(let thinking):
                // Thinking content uses more tokens due to XML structure
                tokens += max(1, thinking.text.count / 3) + 50  // XML overhead
            case .image(_):
                // Images use significant tokens (Claude 3.5 uses ~1600 tokens per image)
                tokens += 1600
            case .document(let doc):
                // Documents vary greatly, estimate based on name and assume moderate content
                tokens += 500 + (doc.name.count / 4)
            case .tooluse(let tool):
                // Tool use has JSON structure overhead
                let inputTokens = estimateTokensForJSONValue(tool.input)
                tokens += 100 + inputTokens  // Base overhead + input
            case .toolresult(let result):
                // Tool results can be lengthy
                tokens += max(50, result.result.count / 3) + 50  // Content + XML overhead
            }
        }

        // Add base message overhead (role, structure, etc.)
        tokens += 20

        return tokens
    }

    /// Estimates tokens for JSONValue content
    private func estimateTokensForJSONValue(_ jsonValue: JSONValue) -> Int {
        switch jsonValue {
        case .null:
            return 1
        case .bool(_):
            return 1
        case .number(_):
            return 1
        case .string(let str):
            return max(1, str.count / 4)
        case .array(let arr):
            return arr.reduce(10) { total, item in  // 10 for array structure
                total + estimateTokensForJSONValue(item)
            }
        case .object(let obj):
            return obj.reduce(10) { total, pair in  // 10 for object structure
                let keyTokens = pair.key.count / 4
                let valueTokens = estimateTokensForJSONValue(pair.value)
                return total + keyTokens + valueTokens
            }
        }
    }

    /// Simplifies tool input to reduce token usage
    private func simplifyToolInput(_ input: JSONValue) -> JSONValue {
        switch input {
        case .string(let str):
            // Truncate long strings
            if str.count > 200 {
                return .string(String(str.prefix(200)) + "...")
            }
            return input
        case .array(let arr):
            // Limit array size and simplify elements
            let simplified = Array(arr.prefix(5)).map { simplifyToolInput($0) }
            return .array(simplified)
        case .object(let obj):
            // Keep only essential keys and simplify values
            var simplified: [String: JSONValue] = [:]
            let essentialKeys = Array(obj.keys.prefix(5))  // Keep first 5 keys
            for key in essentialKeys {
                if let value = obj[key] {
                    simplified[key] = simplifyToolInput(value)
                }
            }
            return .object(simplified)
        default:
            return input
        }
    }

    private func updateConversationWithOptimizedHistory(_ optimizedHistory: [BedrockMessage]) async
    {
        // Update UI messages
        await MainActor.run {
            messages.removeAll()
        }

        // Convert optimized history back to UI messages
        for bedrockMessage in optimizedHistory {
            let role = bedrockMessage.role == .user ? "User" : chatModel.name
            var text = ""
            var thinking: String? = nil
            var signature: String? = nil

            for content in bedrockMessage.content {
                switch content {
                case .text(let txt):
                    text += txt
                case .thinking(let tc):
                    thinking = (thinking ?? "") + tc.text
                    if signature == nil {
                        signature = tc.signature
                    }
                default:
                    break
                }
            }

            let messageData = MessageData(
                id: UUID(),
                text: text,
                thinking: thinking,
                signature: signature,
                user: role,
                isError: false,
                sentTime: Date()
            )

            addMessage(messageData)
        }

        // Save the optimized history
        await saveConversationHistory(optimizedHistory)

        logger.info("Conversation updated with optimized cache-friendly history")
    }

    // MARK: - Edit/Delete Message Handlers

    private func handleEditMessage(messageId: UUID, messageText: String, isUserMessage: Bool) {
        logger.info("Handling edit message request for ID: \(messageId), isUser: \(isUserMessage)")

        if isUserMessage {
            // ユーザーメッセージの編集
            editingMessageId = messageId
            editingMessageText = messageText
            isEditingUserMessage = true
            isEditDialogVisible = true
        } else {
            // アシスタントメッセージの編集
            editingMessageId = messageId
            editingMessageText = messageText
            isEditingUserMessage = false
            isEditDialogVisible = true
        }
    }

    private func handleDeleteMessage(messageId: UUID, isUserMessage: Bool) {
        logger.info(
            "Handling delete message request for ID: \(messageId), isUser: \(isUserMessage)")

        // 指定されたメッセージ以降をすべて削除
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageId }) else {
            logger.warning("Message with ID \(messageId) not found for deletion")
            return
        }

        logger.info("Deleting \(messages.count - messageIndex) messages from index \(messageIndex)")

        // 即座にUIから削除してユーザーフィードバックを提供
        let messagesToDelete = Array(messages.suffix(from: messageIndex))
        messages.removeSubrange(messageIndex...)

        // 削除されたメッセージのIDをログ出力
        let deletedIds = messagesToDelete.map { $0.id }
        logger.info("Deleted message IDs: \(deletedIds)")

        // バックグラウンドで履歴とストレージから削除
        Task {
            await deleteMessagesFromStorageAndHistory(
                messageIndex: messageIndex, messageId: messageId)
        }
    }

    func confirmEditMessage() {
        guard let messageId = editingMessageId else {
            logger.warning("No message ID set for editing")
            return
        }

        logger.info("Confirming edit for message ID: \(messageId), isUser: \(isEditingUserMessage)")

        if isEditingUserMessage {
            // ユーザーメッセージの編集：該当メッセージ以降を削除して再投稿

            // 編集ダイアログを先に閉じる
            isEditDialogVisible = false
            editingMessageId = nil
            let editedText = editingMessageText
            editingMessageText = ""

            // 該当メッセージ以降を削除し、会話履歴の整合性を確保してから再送信
            Task {
                await cleanDeleteAndResend(messageId: messageId, newText: editedText)
            }
        } else {
            // アシスタントメッセージの編集：テキストのみ更新
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages[index].text = editingMessageText

                // ストレージも更新
                chatManager.updateMessageText(
                    for: chatId,
                    messageId: messageId,
                    newText: editingMessageText
                )

                // 会話履歴も更新
                Task {
                    await updateMessageInHistory(messageId: messageId, newText: editingMessageText)
                }

                logger.info("Updated assistant message text for ID: \(messageId)")
            } else {
                logger.warning("Could not find message with ID \(messageId) in UI messages")
            }

            // 編集ダイアログを閉じる
            isEditDialogVisible = false
            editingMessageId = nil
            editingMessageText = ""
        }
    }

    func cancelEditMessage() {
        logger.info("Cancelling edit message dialog")
        isEditDialogVisible = false
        editingMessageId = nil
        editingMessageText = ""
    }

    // MARK: - Clean Delete and Resend

    /// Clean delete and resend mechanism to maintain conversation history integrity
    private func cleanDeleteAndResend(messageId: UUID, newText: String) async {
        logger.info("Starting clean delete and resend for message ID: \(messageId)")

        // Find the message index
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageId }) else {
            logger.warning("Message with ID \(messageId) not found for clean delete")
            return
        }

        logger.info(
            "Found message at index \(messageIndex), will delete \(messages.count - messageIndex) messages"
        )

        // Get conversation history before deletion
        guard let history = chatManager.getConversationHistory(for: chatId) else {
            logger.warning("No conversation history found for clean delete")
            // Fallback to simple deletion and resend
            await fallbackDeleteAndResend(messageIndex: messageIndex, newText: newText)
            return
        }

        // NEW: Aggressive tool cleanup approach to prevent ValidationException
        // If ValidationException persists, clean all tool-related messages completely
        let shouldUseAggressiveCleanup = await shouldUseAggressiveToolCleanup(history: history)

        if shouldUseAggressiveCleanup {
            logger.info("🔧 Using aggressive tool cleanup to prevent ValidationException")
            await aggressiveToolCleanupAndResend(
                messageIndex: messageIndex, newText: newText, history: history)
            return
        }

        // Original approach with tool pair analysis
        let (cleanHistoryIndex, brokenToolPairs) = await analyzeToolPairIntegrity(
            history: history,
            uiMessageIndex: messageIndex
        )

        logger.info(
            "Clean deletion will remove from history index \(cleanHistoryIndex), broken tool pairs: \(brokenToolPairs.count)"
        )

        // Remove messages from UI immediately for responsiveness
        messages.removeSubrange(messageIndex...)

        // Clean delete from conversation history maintaining tool_use/tool_result integrity
        await cleanDeleteFromHistory(
            history: history,
            fromIndex: cleanHistoryIndex,
            brokenToolPairs: brokenToolPairs
        )

        // Clean delete from storage
        let _ = await chatManager.deleteMessagesFromIndex(messageIndex, for: chatId)

        // Set the new text and resend
        await MainActor.run {
            self.userInput = newText
        }

        // Small delay to ensure cleanup is complete
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second

        // Resend the message
        await MainActor.run {
            self.sendMessage()
        }

        logger.info("Clean delete and resend completed successfully")
    }

    /// Analyzes conversation history to identify tool pairs that would be broken by deletion
    private func analyzeToolPairIntegrity(
        history: ConversationHistory,
        uiMessageIndex: Int
    ) async -> (cleanHistoryIndex: Int, brokenToolPairs: Set<String>) {

        // Map UI message index to conversation history index
        let historyIndex = min(uiMessageIndex, history.messages.count - 1)

        var brokenToolPairs: Set<String> = []
        var cleanHistoryIndex = historyIndex

        // Look for tool_use messages in the deletion range that need their tool_result partners removed too
        for i in historyIndex..<history.messages.count {
            let message = history.messages[i]

            if message.role == .assistant, let toolUse = message.toolUse {
                // This assistant message has tool_use, we need to also remove any corresponding tool_result
                brokenToolPairs.insert(toolUse.toolId)
                logger.debug(
                    "Found tool_use ID \(toolUse.toolId) in deletion range, marking for cleanup")
            }

            if message.role == .user, let toolUse = message.toolUse, toolUse.result != nil {
                // This user message has tool_result, we need to also remove any corresponding tool_use
                brokenToolPairs.insert(toolUse.toolId)
                logger.debug(
                    "Found tool_result ID \(toolUse.toolId) in deletion range, marking for cleanup")
            }
        }

        // If we have broken tool pairs, we need to clean backwards to remove orphaned partners
        if !brokenToolPairs.isEmpty {
            // Scan backwards from the deletion point to find and include orphaned tool partners
            for i in stride(from: historyIndex - 1, through: 0, by: -1) {
                let message = history.messages[i]
                var shouldIncludeInDeletion = false

                if message.role == .assistant, let toolUse = message.toolUse {
                    // Assistant message with tool_use - check if its partner will be deleted
                    if brokenToolPairs.contains(toolUse.toolId) {
                        shouldIncludeInDeletion = true
                        logger.debug(
                            "Including assistant tool_use message at index \(i) for tool ID \(toolUse.toolId)"
                        )
                    }
                }

                if message.role == .user, let toolUse = message.toolUse, toolUse.result != nil {
                    // User message with tool_result - check if its partner will be deleted
                    if brokenToolPairs.contains(toolUse.toolId) {
                        shouldIncludeInDeletion = true
                        logger.debug(
                            "Including user tool_result message at index \(i) for tool ID \(toolUse.toolId)"
                        )
                    }
                }

                if shouldIncludeInDeletion {
                    cleanHistoryIndex = i
                } else {
                    // If this message doesn't need to be included, stop scanning backwards
                    break
                }
            }
        }

        return (cleanHistoryIndex, brokenToolPairs)
    }

    /// Performs clean deletion from conversation history maintaining tool_use/tool_result integrity
    private func cleanDeleteFromHistory(
        history: ConversationHistory,
        fromIndex: Int,
        brokenToolPairs: Set<String>
    ) async {

        var updatedHistory = history

        if fromIndex < updatedHistory.messages.count && fromIndex >= 0 {
            let messagesToDelete = updatedHistory.messages.count - fromIndex

            // Log what we're about to delete
            logger.info(
                "Clean deleting \(messagesToDelete) messages from history starting at index \(fromIndex)"
            )

            for i in fromIndex..<updatedHistory.messages.count {
                let message = updatedHistory.messages[i]
                if let toolUse = message.toolUse {
                    logger.debug("Deleting message with tool ID: \(toolUse.toolId)")
                }
            }

            // Perform the deletion
            updatedHistory.messages.removeSubrange(fromIndex...)

            // Verify we didn't leave any orphaned tool_use or tool_result
            await validateHistoryIntegrity(updatedHistory)

            // Save the cleaned history
            chatManager.saveConversationHistory(updatedHistory, for: chatId)

            logger.info(
                "Clean deletion completed. Remaining messages: \(updatedHistory.messages.count)")
        } else {
            logger.warning("Invalid clean deletion index: \(fromIndex)")
        }
    }

    /// Validates that conversation history doesn't have orphaned tool_use or tool_result messages
    private func validateHistoryIntegrity(_ history: ConversationHistory) async {
        var toolUseIds: Set<String> = []
        var toolResultIds: Set<String> = []
        var orphanedTools: [String] = []

        for message in history.messages {
            if let toolUse = message.toolUse {
                if message.role == .assistant {
                    // Assistant message with tool_use
                    toolUseIds.insert(toolUse.toolId)
                } else if message.role == .user && toolUse.result != nil {
                    // User message with tool_result
                    toolResultIds.insert(toolUse.toolId)
                }
            }
        }

        // Find orphaned tool_use (no corresponding tool_result)
        for toolId in toolUseIds {
            if !toolResultIds.contains(toolId) {
                orphanedTools.append("tool_use:\(toolId)")
            }
        }

        // Find orphaned tool_result (no corresponding tool_use)
        for toolId in toolResultIds {
            if !toolUseIds.contains(toolId) {
                orphanedTools.append("tool_result:\(toolId)")
            }
        }

        if !orphanedTools.isEmpty {
            logger.warning(
                "⚠️ History integrity check found orphaned tools: \(orphanedTools.joined(separator: ", "))"
            )
            // In a production app, you might want to clean these up automatically
        } else {
            logger.info("✅ History integrity check passed - no orphaned tool pairs")
        }
    }

    /// Determines whether to use aggressive tool cleanup based on history analysis
    private func shouldUseAggressiveToolCleanup(history: ConversationHistory) async -> Bool {
        // Count tool-related messages in the history
        var toolUseCount = 0
        var toolResultCount = 0
        var toolIdsUsed: Set<String> = []
        var toolIdsCompleted: Set<String> = []

        for message in history.messages {
            if let toolUse = message.toolUse {
                if message.role == .assistant {
                    // Assistant message with tool_use
                    toolUseCount += 1
                    toolIdsUsed.insert(toolUse.toolId)
                } else if message.role == .user && toolUse.result != nil {
                    // User message with tool_result
                    toolResultCount += 1
                    toolIdsCompleted.insert(toolUse.toolId)
                }
            }
        }

        // Use aggressive cleanup if:
        // 1. There are tool-related messages present
        // 2. There are unmatched tool pairs (more tool_use than tool_result, or vice versa)
        // 3. There are tool IDs that don't have complete pairs

        let hasToolMessages = toolUseCount > 0 || toolResultCount > 0
        let hasMismatchedCounts = toolUseCount != toolResultCount
        let hasOrphanedToolIds =
            !toolIdsUsed.isSubset(of: toolIdsCompleted)
            || !toolIdsCompleted.isSubset(of: toolIdsUsed)

        let shouldUseAggressive = hasToolMessages && (hasMismatchedCounts || hasOrphanedToolIds)

        if shouldUseAggressive {
            logger.info(
                "🔧 Aggressive cleanup triggered: toolUse=\(toolUseCount), toolResult=\(toolResultCount), orphaned=\(hasOrphanedToolIds)"
            )
        }

        return shouldUseAggressive
    }

    /// Aggressive tool cleanup that removes all tool-related messages to prevent ValidationException
    private func aggressiveToolCleanupAndResend(
        messageIndex: Int, newText: String, history: ConversationHistory
    ) async {
        logger.info("🔧 Starting aggressive tool cleanup for \(history.messages.count) messages")

        // Strategy: Create a completely clean conversation history with only text messages
        // This ensures no orphaned tool_use/tool_result pairs can cause ValidationException

        var cleanHistory = ConversationHistory(chatId: chatId, modelId: chatModel.id)

        // Process messages up to the edit point, removing all tool-related content
        let processingLimit = min(messageIndex, history.messages.count)

        for i in 0..<processingLimit {
            let message = history.messages[i]

            // Create a clean message with only text content, no tool information
            let cleanMessage = Message(
                id: UUID(),
                text: message.text,
                role: message.role,
                timestamp: message.timestamp,
                isError: message.isError,
                thinking: message.thinking,
                thinkingSignature: message.thinkingSignature,
                imageBase64Strings: message.imageBase64Strings,
                documentBase64Strings: message.documentBase64Strings,
                documentFormats: message.documentFormats,
                documentNames: message.documentNames,
                toolUse: nil  // Remove all tool usage information
            )

            // Only add messages with meaningful content
            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || message.imageBase64Strings?.isEmpty == false
                || message.documentBase64Strings?.isEmpty == false
            {
                cleanHistory.addMessage(cleanMessage)
            }
        }

        logger.info(
            "🔧 Created clean history with \(cleanHistory.messages.count) messages (was \(history.messages.count))"
        )

        // Update UI messages to match clean history
        await MainActor.run {
            self.messages.removeAll()

            // Convert clean history back to UI messages
            for message in cleanHistory.messages {
                let role = message.role == .user ? "User" : self.chatModel.name

                let messageData = MessageData(
                    id: message.id,
                    text: message.text,
                    thinking: message.thinking,
                    signature: message.thinkingSignature,
                    user: role,
                    isError: message.isError,
                    sentTime: message.timestamp,
                    imageBase64Strings: message.imageBase64Strings,
                    documentBase64Strings: message.documentBase64Strings,
                    documentFormats: message.documentFormats,
                    documentNames: message.documentNames
                        // Note: No toolUse or toolResult - completely clean
                )

                self.messages.append(messageData)
            }
        }

        // Save the clean history
        chatManager.saveConversationHistory(cleanHistory, for: chatId)

        // Clean delete from storage as well
        let _ = await chatManager.deleteMessagesFromIndex(
            max(0, cleanHistory.messages.count), for: chatId)

        // Set the new text and resend
        await MainActor.run {
            self.userInput = newText
        }

        // Small delay to ensure cleanup is complete
        try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2 second (longer for aggressive cleanup)

        // Resend the message
        await MainActor.run {
            self.sendMessage()
        }

        logger.info("🔧 Aggressive tool cleanup and resend completed successfully")
    }

    /// Fallback method for simple deletion and resend when conversation history is not available
    private func fallbackDeleteAndResend(messageIndex: Int, newText: String) async {
        logger.info("Using fallback delete and resend method")

        // Simple deletion from storage
        let _ = await chatManager.deleteMessagesFromIndex(messageIndex, for: chatId)

        // Set the new text and resend
        await MainActor.run {
            self.userInput = newText
        }

        // Small delay
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second

        // Resend the message
        await MainActor.run {
            self.sendMessage()
        }
    }

    // MARK: - Storage Reload Methods

    /// ストレージからメッセージを再読み込みしてUIを更新
    private func reloadMessagesFromStorage() {
        logger.info("Reloading messages from storage for chat: \(chatId)")

        // ChatManagerから最新のメッセージを取得
        let reloadedMessages = chatManager.getMessages(for: chatId)

        // UIを更新
        messages = reloadedMessages

        logger.info("Reloaded \(reloadedMessages.count) messages from storage")
    }

    /// ストレージと履歴から指定されたメッセージ以降を削除する統合メソッド
    private func deleteMessagesFromStorageAndHistory(messageIndex: Int, messageId: UUID) async {
        logger.info(
            "Deleting messages from storage and history starting from index: \(messageIndex)")

        // ChatManagerから指定インデックス以降のメッセージを削除
        let deletedCount = await chatManager.deleteMessagesFromIndex(messageIndex, for: chatId)
        logger.info("Deleted \(deletedCount) messages from ChatManager storage")

        // 会話履歴からも削除
        await deleteMessagesFromHistory(startingFromIndex: messageIndex)

        logger.info("Successfully completed storage and history cleanup")
    }

    private func deleteMessagesFromHistory(startingFromIndex index: Int) async {
        logger.info("Deleting messages from history starting from index: \(index)")

        guard let history = chatManager.getConversationHistory(for: chatId) else {
            logger.warning("No conversation history found for chat \(chatId)")
            return
        }

        // 指定されたインデックス以降の履歴を削除
        let historyIndexToDelete = min(index, history.messages.count - 1)

        if historyIndexToDelete < history.messages.count && historyIndexToDelete >= 0 {
            var updatedHistory = history
            let messagesToDelete = updatedHistory.messages.count - historyIndexToDelete

            // 削除前のカウントをログ出力
            logger.info("History before deletion: \(updatedHistory.messages.count) messages")

            // 指定インデックス以降を削除
            updatedHistory.messages.removeSubrange(historyIndexToDelete...)

            // 更新された履歴を保存
            chatManager.saveConversationHistory(updatedHistory, for: chatId)

            logger.info(
                "Deleted \(messagesToDelete) messages from history. Remaining: \(updatedHistory.messages.count) messages"
            )
        } else {
            logger.warning("Invalid history index for deletion: \(historyIndexToDelete)")
        }
    }

    private func updateMessageInHistory(messageId: UUID, newText: String) async {
        logger.info("Updating message text in history for ID: \(messageId)")

        guard let history = chatManager.getConversationHistory(for: chatId) else {
            logger.warning("No conversation history found for chat \(chatId)")
            return
        }

        // UI上のメッセージインデックスを取得
        guard let uiMessageIndex = messages.firstIndex(where: { $0.id == messageId }) else {
            logger.warning("Message with ID \(messageId) not found in UI messages")
            return
        }

        // 履歴の対応するメッセージを更新
        // 通常、アシスタントメッセージは履歴の最後の方にあるため、
        // UI上のインデックスに対応する履歴のインデックスを計算
        let historyIndex = min(uiMessageIndex, history.messages.count - 1)

        var updatedHistory = history
        if historyIndex < updatedHistory.messages.count {
            // アシスタントメッセージの場合、roleがassistantのものを探す
            var targetIndex = historyIndex

            // 後方から検索してアシスタントメッセージを見つける
            for i in stride(from: updatedHistory.messages.count - 1, through: historyIndex, by: -1)
            {
                if updatedHistory.messages[i].role == .assistant {
                    targetIndex = i
                    break
                }
            }

            if targetIndex < updatedHistory.messages.count
                && updatedHistory.messages[targetIndex].role == .assistant
            {
                updatedHistory.messages[targetIndex].text = newText

                // 更新された履歴を保存
                chatManager.saveConversationHistory(updatedHistory, for: chatId)

                logger.info("Updated message text in history at index \(targetIndex)")
            } else {
                logger.warning("Could not find assistant message in history for update")
            }
        } else {
            logger.warning("Invalid history index for update: \(historyIndex)")
        }
    }

    // MARK: - Non-Streaming Text LLM Handling

    private func handleTextLLMWithNonStreaming(_ userMessage: MessageData) async throws {
        // Create message content from user message (similar to streaming version)
        var messageContents: [MessageContent] = []

        // Always include a text prompt as required when sending documents
        let textToSend =
            userMessage.text.isEmpty && (userMessage.documentBase64Strings?.isEmpty == false)
            ? "Please analyze this document." : userMessage.text
        messageContents.append(.text(textToSend))

        // Add images if present
        if let imageBase64Strings = userMessage.imageBase64Strings, !imageBase64Strings.isEmpty {
            for (index, base64String) in imageBase64Strings.enumerated() {
                let fileExtension =
                    index < sharedMediaDataSource.fileExtensions.count
                    ? sharedMediaDataSource.fileExtensions[index].lowercased() : "jpeg"

                let format: ImageFormat
                switch fileExtension {
                case "jpg", "jpeg": format = .jpeg
                case "png": format = .png
                case "gif": format = .gif
                case "webp": format = .webp
                default: format = .jpeg
                }

                messageContents.append(
                    .image(
                        MessageContent.ImageContent(
                            format: format,
                            base64Data: base64String
                        )))
            }
        }

        // Add documents if present
        if let documentBase64Strings = userMessage.documentBase64Strings,
            let documentFormats = userMessage.documentFormats,
            let documentNames = userMessage.documentNames,
            !documentBase64Strings.isEmpty
        {

            for (index, base64String) in documentBase64Strings.enumerated() {
                guard index < documentFormats.count && index < documentNames.count else {
                    continue
                }

                let fileExt = documentFormats[index].lowercased()
                let fileName = documentNames[index]

                let docFormat = MessageContent.DocumentFormat.fromExtension(fileExt)
                messageContents.append(
                    .document(
                        MessageContent.DocumentContent(
                            format: docFormat,
                            base64Data: base64String,
                            name: fileName
                        )))
            }
        }

        // Get conversation history (完全な履歴)
        var fullConversationHistory = await getConversationHistory()

        // Add user message to full history（直前が同一ユーザー同一テキストならスキップ）
        let userBedrockMessage = BedrockMessage(role: .user, content: messageContents)
        let newUserText = extractTextFromContents(userBedrockMessage.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var shouldAppendUser = true
        if let last = fullConversationHistory.last {
            let lastText = extractTextFromContents(last.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if last.role == .user && !newUserText.isEmpty && lastText == newUserText {
                shouldAppendUser = false
                logger.warning(
                    "🔧 Blocked duplicate user message append to history: '\(newUserText.prefix(50))...'"
                )
            }
        }
        if shouldAppendUser {
            fullConversationHistory.append(userBedrockMessage)
        }

        // 完全な履歴を保存
        await saveConversationHistory(fullConversationHistory)

        // Bedrock送信用に最適化
        let optimizedHistory = await manageConversationByCharacterCount(fullConversationHistory)

        // Get system prompt
        let systemPrompt = settingManager.systemPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines)

        // Get tool configurations if MCP is enabled (but disable for non-streaming for now)
        let toolConfig: AWSBedrockRuntime.BedrockRuntimeClientTypes.ToolConfiguration? = nil

        // Get Bedrock messages in AWS SDK format (最適化された履歴を使用)
        let bedrockMessages = try optimizedHistory.map {
            try convertToBedrockMessage($0, modelId: chatModel.id)
        }

        // Convert to system prompt format used by AWS SDK
        let systemContentBlock: [AWSBedrockRuntime.BedrockRuntimeClientTypes.SystemContentBlock]? =
            systemPrompt.isEmpty ? nil : [.text(systemPrompt)]

        logger.info("Starting non-streaming converse request with model ID: \(chatModel.id)")

        // Use the non-streaming Converse API with retry logic
        let request = AWSBedrockRuntime.ConverseInput(
            inferenceConfig: nil,
            messages: bedrockMessages,
            modelId: chatModel.id,
            system: backendModel.backend.isSystemPromptSupported(chatModel.id)
                ? systemContentBlock : nil,
            toolConfig: toolConfig
        )

        let response = try await backendModel.backend.converse(input: request)

        // Process the response
        var responseText = ""
        var thinking: String? = nil
        var thinkingSignature: String? = nil

        if let output = response.output {
            switch output {
            case .message(let message):
                for content in message.content ?? [] {
                    switch content {
                    case .text(let text):
                        responseText += text
                    case .reasoningcontent(let reasoning):
                        switch reasoning {
                        case .reasoningtext(let reasoningText):
                            thinking = (thinking ?? "") + (reasoningText.text ?? "")
                            if thinkingSignature == nil {
                                thinkingSignature = reasoningText.signature
                            }
                        default:
                            break
                        }
                    default:
                        break
                    }
                }
            case .sdkUnknown(let unknownValue):
                logger.warning("Unknown output type received: \(unknownValue)")
            }
        }

        // Create assistant message
        let assistantMessage = MessageData(
            id: UUID(),
            text: responseText,
            thinking: thinking,
            signature: thinkingSignature,
            user: chatModel.name,
            isError: false,
            sentTime: Date()
        )
        addMessage(assistantMessage)

        // Create assistant message for conversation history
        let assistantMsg = BedrockMessage(
            role: .assistant,
            content: thinking != nil
                ? [
                    .thinking(
                        MessageContent.ThinkingContent(
                            text: thinking!,
                            signature: thinkingSignature ?? UUID().uuidString
                        )),
                    .text(responseText),
                ] : [.text(responseText)]
        )

        // Add to full history and save (完全な履歴を保存)
        fullConversationHistory.append(assistantMsg)
        await saveConversationHistory(fullConversationHistory)
    }
}
