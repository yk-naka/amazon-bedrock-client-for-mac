//
//  ContextManager.swift
//  Amazon Bedrock Client for Mac
//
//  永続的コンテキスト管理システム
//

import Combine
import Foundation
import Logging

/// 永続的コンテキスト管理マネージャー
/// semantic_cache_serverを使用してプロジェクトコンテキストを長期保存・管理
class ContextManager: ObservableObject {
    static let shared = ContextManager()

    private var logger = Logger(label: "ContextManager")
    private let config: ContextManagerConfig
    private var cancellables = Set<AnyCancellable>()

    // 現在のセッション情報
    @Published private(set) var currentSession: SessionContext?
    @Published private(set) var currentProjectId: String?
    @Published private(set) var isSessionActive: Bool = false

    // セッション内で収集したファイル変更情報
    private var sessionFilesModified: Set<String> = []
    private var sessionDecisions: [DesignDecision] = []

    // MCP Server名（semantic_cache_serverの設定名）
    private let mcpServerName = "semantic-cache"

    private init(config: ContextManagerConfig = .default) {
        self.config = config
    }

    // MARK: - Project Initialization

    /// プロジェクトを初期化し、憲法を登録
    func initializeProject(constitution: ProjectConstitution) async throws {
        logger.info("プロジェクトを初期化: \(constitution.projectName)")

        // 1. conversation_idを生成
        let conversationId = try await generateConversationId(prefix: "project")

        // 2. プロジェクト憲法を保存
        let constitutionMarkdown = constitution.toMarkdown()
        try await addTextToCache(
            text: constitutionMarkdown,
            conversationId: conversationId,
            title: "プロジェクト憲法: \(constitution.projectName)",
            metadata: [
                "type": "constitution",
                "project_id": constitution.projectId,
                "project_name": constitution.projectName,
            ]
        )

        // プロジェクトIDを保存
        await MainActor.run {
            self.currentProjectId = conversationId
        }

        logger.info("プロジェクト初期化完了: conversationId=\(conversationId)")
    }

    /// 既存コードベースを一括登録
    func registerCodebase(projectId: String, files: [String]) async throws {
        logger.info("コードベースを登録: \(files.count)ファイル")

        for filePath in files {
            do {
                try await addFileToCache(
                    filePath: filePath,
                    conversationId: projectId,
                    enableChunking: true
                )
                logger.debug("ファイル登録完了: \(filePath)")
            } catch {
                logger.warning("ファイル登録失敗: \(filePath) - \(error.localizedDescription)")
            }
        }

        logger.info("コードベース登録完了")
    }

    // MARK: - Session Management

    /// セッションを開始し、コンテキストを復元
    func startSession(projectId: String? = nil) async throws -> SessionContext {
        logger.info("セッション開始")

        let pid = projectId ?? currentProjectId ?? ""
        guard !pid.isEmpty else {
            throw ContextManagerError.projectNotInitialized
        }

        let sessionId = UUID().uuidString

        // 1. プロジェクト憲法を取得
        let constitution = try await fetchConstitution(projectId: pid)

        // 2. 前回のワークログを取得
        let previousWorkLog = try await fetchLatestWorkLog(projectId: pid)

        // 3. 関連する設計判断を取得
        let relevantDecisions = try await fetchRecentDecisions(projectId: pid, limit: 5)

        // 4. 前回の作業から関連コンテキストを取得
        var relevantContext: [ContextItem] = []
        if let previousLog = previousWorkLog {
            let query = """
                前回の作業: \(previousLog.summary)
                次のステップ: \(previousLog.nextSteps.joined(separator: ", "))
                """
            relevantContext = try await search(query: query, projectId: pid, maxResults: 5)
        }

        // セッションコンテキストを構築
        let sessionContext = SessionContext(
            sessionId: sessionId,
            projectId: pid,
            startTime: Date(),
            constitution: constitution,
            previousWorkLog: previousWorkLog,
            relevantDecisions: relevantDecisions,
            relevantContext: relevantContext,
            nextSteps: previousWorkLog?.nextSteps ?? []
        )

        await MainActor.run {
            self.currentSession = sessionContext
            self.currentProjectId = pid
            self.isSessionActive = true
            self.sessionFilesModified.removeAll()
            self.sessionDecisions.removeAll()
        }

        logger.info("セッション開始完了: sessionId=\(sessionId)")
        return sessionContext
    }

    /// セッションを終了し、作業ログを保存
    func endSession(log: WorkLog) async throws {
        guard let session = currentSession else {
            throw ContextManagerError.noActiveSession
        }

        logger.info("セッション終了: \(session.sessionId)")

        // ワークログをMarkdownとして保存
        var updatedLog = log
        updatedLog = WorkLog(
            sessionId: session.sessionId,
            summary: log.summary,
            accomplishments: log.accomplishments,
            challenges: log.challenges,
            nextSteps: log.nextSteps,
            filesModified: Array(sessionFilesModified),
            decisions: sessionDecisions.map { $0.id },
            notes: log.notes
        )

        let workLogMarkdown = updatedLog.toMarkdown()
        try await addTextToCache(
            text: workLogMarkdown,
            conversationId: session.projectId,
            title: "作業ログ: \(session.sessionId)",
            metadata: [
                "type": "worklog",
                "session_id": session.sessionId,
                "project_id": session.projectId,
            ]
        )

        await MainActor.run {
            self.isSessionActive = false
            self.currentSession = nil
        }

        logger.info("セッション終了完了")
    }

    // MARK: - Search & Retrieval

    /// コンテキストを検索
    func search(query: String, projectId: String? = nil, maxResults: Int = 5) async throws
        -> [ContextItem]
    {
        let pid = projectId ?? currentProjectId ?? ""
        guard !pid.isEmpty else {
            throw ContextManagerError.projectNotInitialized
        }

        logger.debug("コンテキスト検索: \(query)")

        let results = try await searchCache(
            query: query,
            conversationId: pid,
            nResults: maxResults,
            minSimilarity: config.minSimilarityScore
        )

        return results.map { result in
            ContextItem(
                id: result["id"] as? String ?? "",
                content: result["document"] as? String ?? "",
                similarity: result["similarity_score"] as? Double ?? 0.0,
                metadata: convertMetadataToStringDict(result["metadata"] as? [String: Any] ?? [:]),
                source: (result["metadata"] as? [String: Any])?["type"] as? String ?? "unknown"
            )
        }
    }

    /// プロジェクトの現在のコンテキストを取得
    func getCurrentContext() async throws -> ProjectContext {
        guard let projectId = currentProjectId else {
            throw ContextManagerError.projectNotInitialized
        }

        let constitution = try await fetchConstitution(projectId: projectId)
        let stats = try await getCacheStats()

        // 統計情報から関連情報を抽出
        let conversations =
            (stats["statistics"] as? [String: Any])?["conversations"] as? [String] ?? []
        let totalDocs = (stats["statistics"] as? [String: Any])?["total_documents"] as? Int ?? 0

        return ProjectContext(
            projectId: projectId,
            constitution: constitution
                ?? ProjectConstitution(
                    projectId: projectId,
                    projectName: "Unknown Project",
                    description: ""
                ),
            totalSessions: conversations.count,
            totalDecisions: sessionDecisions.count,
            recentFiles: Array(sessionFilesModified),
            lastUpdated: Date()
        )
    }

    // MARK: - Decision Tracking

    /// 設計判断を記録
    func recordDecision(decision: DesignDecision) async throws {
        guard let projectId = currentProjectId else {
            throw ContextManagerError.projectNotInitialized
        }

        logger.info("設計判断を記録: \(decision.title)")

        // セッション内で追跡
        await MainActor.run {
            self.sessionDecisions.append(decision)
        }

        // Markdownとして保存
        let decisionMarkdown = decision.toMarkdown()
        try await addTextToCache(
            text: decisionMarkdown,
            conversationId: projectId,
            title: "設計判断: \(decision.title)",
            metadata: [
                "type": "decision",
                "decision_id": decision.id,
                "project_id": projectId,
                "tags": decision.tags.joined(separator: ","),
            ]
        )

        logger.info("設計判断記録完了: \(decision.id)")
    }

    /// ファイル変更を追跡
    func trackFileModification(_ filePath: String) {
        sessionFilesModified.insert(filePath)
        logger.debug("ファイル変更追跡: \(filePath)")
    }

    // MARK: - Private Helper Methods

    private func generateConversationId(prefix: String) async throws -> String {
        let result = try await executeMCPTool(
            serverName: mcpServerName,
            toolName: "generate_conversation_id",
            arguments: ["prefix": prefix]
        )

        guard let conversationId = result["conversation_id"] as? String else {
            throw ContextManagerError.mcpToolError("conversation_id not found in result")
        }

        return conversationId
    }

    private func addTextToCache(
        text: String,
        conversationId: String,
        title: String? = nil,
        metadata: [String: String] = [:]
    ) async throws {
        var args: [String: Any] = [
            "text": text,
            "conversation_id": conversationId,
            "enable_chunking": true,
            "chunk_size": 1000,
            "chunk_overlap": 200,
        ]

        if let title = title {
            args["title"] = title
        }

        if !metadata.isEmpty {
            args["metadata"] = metadata
        }

        _ = try await executeMCPTool(
            serverName: mcpServerName,
            toolName: "add_text_data",
            arguments: args
        )
    }

    private func addFileToCache(
        filePath: String,
        conversationId: String,
        enableChunking: Bool = true
    ) async throws {
        let args: [String: Any] = [
            "file_path": filePath,
            "conversation_id": conversationId,
            "enable_chunking": enableChunking,
            "chunk_size": 1000,
            "chunk_overlap": 200,
        ]

        _ = try await executeMCPTool(
            serverName: mcpServerName,
            toolName: "add_file_data",
            arguments: args
        )
    }

    private func searchCache(
        query: String,
        conversationId: String,
        nResults: Int = 5,
        minSimilarity: Double = 0.0
    ) async throws -> [[String: Any]] {
        let args: [String: Any] = [
            "query": query,
            "n_results": nResults,
            "conversation_id": conversationId,
            "min_similarity": minSimilarity,
            "search_mode": "semantic",
        ]

        let result = try await executeMCPTool(
            serverName: mcpServerName,
            toolName: "search_cache",
            arguments: args
        )

        guard let results = result["results"] as? [[String: Any]] else {
            return []
        }

        return results
    }

    private func getCacheStats() async throws -> [String: Any] {
        return try await executeMCPTool(
            serverName: mcpServerName,
            toolName: "get_cache_stats",
            arguments: [:]
        )
    }

    private func fetchConstitution(projectId: String) async throws -> ProjectConstitution? {
        let results = try await searchCache(
            query: "プロジェクト憲法",
            conversationId: projectId,
            nResults: 1
        )

        guard let first = results.first,
            let document = first["document"] as? String
        else {
            return nil
        }

        // Markdownから復元（簡易実装）
        // 本番では適切なパーサーを実装
        return parseConstitutionFromMarkdown(document, projectId: projectId)
    }

    private func fetchLatestWorkLog(projectId: String) async throws -> WorkLog? {
        let results = try await searchCache(
            query: "作業ログ",
            conversationId: projectId,
            nResults: 1
        )

        guard let first = results.first,
            let document = first["document"] as? String,
            let metadata = first["metadata"] as? [String: Any],
            let sessionId = metadata["session_id"] as? String
        else {
            return nil
        }

        return parseWorkLogFromMarkdown(document, sessionId: sessionId)
    }

    private func fetchRecentDecisions(projectId: String, limit: Int) async throws
        -> [DesignDecision]
    {
        let results = try await searchCache(
            query: "設計判断",
            conversationId: projectId,
            nResults: limit
        )

        return results.compactMap { result in
            guard let document = result["document"] as? String else {
                return nil
            }
            return parseDecisionFromMarkdown(document)
        }
    }

    // MARK: - MCP Tool Execution

    /// MCPツールを実行（内部およびChatManagerから使用）
    func executeMCPTool(
        serverName: String,
        toolName: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let toolResult = await MCPManager.shared.executeBedrockTool(
            id: UUID().uuidString,
            name: toolName,
            input: arguments
        )

        guard toolResult["status"] as? String == "success" else {
            let errorContent = toolResult["content"] as? [[String: Any]] ?? []
            let errorText = errorContent.compactMap { $0["text"] as? String }.joined(
                separator: "\n")
            throw ContextManagerError.mcpToolError(errorText)
        }

        // レスポンスからJSONを抽出
        if let content = toolResult["content"] as? [[String: Any]],
            let firstContent = content.first
        {
            if let text = firstContent["text"] as? String,
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return json
            }
        }

        return toolResult
    }

    // MARK: - Parsing Helpers (簡易実装)

    private func parseConstitutionFromMarkdown(_ markdown: String, projectId: String)
        -> ProjectConstitution?
    {
        // 簡易的なパース実装
        // 本番ではより堅牢なパーサーを実装
        let lines = markdown.components(separatedBy: .newlines)
        var projectName = ""
        var description = ""

        for line in lines {
            if line.hasPrefix("# プロジェクト憲法:") {
                projectName = line.replacingOccurrences(of: "# プロジェクト憲法:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## 概要") {
                // 次の行が説明
                if let index = lines.firstIndex(of: line), index + 1 < lines.count {
                    description = lines[index + 1]
                }
            }
        }

        return ProjectConstitution(
            projectId: projectId,
            projectName: projectName.isEmpty ? "Unknown Project" : projectName,
            description: description
        )
    }

    private func parseWorkLogFromMarkdown(_ markdown: String, sessionId: String) -> WorkLog? {
        let lines = markdown.components(separatedBy: .newlines)
        var summary = ""
        var accomplishments: [String] = []
        var nextSteps: [String] = []

        var currentSection = ""

        for line in lines {
            if line.hasPrefix("## 作業概要") {
                currentSection = "summary"
            } else if line.hasPrefix("## 完了したこと") {
                currentSection = "accomplishments"
            } else if line.hasPrefix("## 次のステップ") {
                currentSection = "nextSteps"
            } else if line.hasPrefix("- ✅") {
                accomplishments.append(line.replacingOccurrences(of: "- ✅ ", with: ""))
            } else if currentSection == "summary" && !line.isEmpty && !line.hasPrefix("#") {
                summary = line
            }
        }

        return WorkLog(
            sessionId: sessionId,
            summary: summary,
            accomplishments: accomplishments,
            nextSteps: nextSteps
        )
    }

    private func parseDecisionFromMarkdown(_ markdown: String) -> DesignDecision? {
        let lines = markdown.components(separatedBy: .newlines)
        var title = ""
        var description = ""
        var rationale = ""

        for line in lines {
            if line.hasPrefix("# 設計判断:") {
                title = line.replacingOccurrences(of: "# 設計判断:", with: "").trimmingCharacters(
                    in: .whitespaces)
            } else if line.hasPrefix("## 概要") {
                if let index = lines.firstIndex(of: line), index + 1 < lines.count {
                    description = lines[index + 1]
                }
            } else if line.hasPrefix("## 理由") {
                if let index = lines.firstIndex(of: line), index + 1 < lines.count {
                    rationale = lines[index + 1]
                }
            }
        }

        return DesignDecision(
            title: title,
            description: description,
            rationale: rationale
        )
    }

    private func convertMetadataToStringDict(_ metadata: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata {
            result[key] = String(describing: value)
        }
        return result
    }
}

// MARK: - Errors

enum ContextManagerError: LocalizedError {
    case projectNotInitialized
    case noActiveSession
    case mcpToolError(String)
    case parsingError(String)

    var errorDescription: String? {
        switch self {
        case .projectNotInitialized:
            return "プロジェクトが初期化されていません"
        case .noActiveSession:
            return "アクティブなセッションがありません"
        case .mcpToolError(let message):
            return "MCPツールエラー: \(message)"
        case .parsingError(let message):
            return "パースエラー: \(message)"
        }
    }
}
