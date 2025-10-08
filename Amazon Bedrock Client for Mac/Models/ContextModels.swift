//
//  ContextModels.swift
//  Amazon Bedrock Client for Mac
//
//  Created for persistent context management system
//

import Foundation

// MARK: - Project Constitution (プロジェクト憲法)
/// プロジェクトの基本方針と設計思想を定義
struct ProjectConstitution: Codable {
    let projectId: String
    let projectName: String
    let description: String
    let corePrinciples: [String]  // 核となる原則
    let designPhilosophy: [String]  // 設計思想
    let technicalStack: [String]  // 技術スタック
    let codingStandards: [String]  // コーディング規約
    let architectureNotes: String  // アーキテクチャメモ
    let createdAt: Date
    let updatedAt: Date

    init(
        projectId: String,
        projectName: String,
        description: String,
        corePrinciples: [String] = [],
        designPhilosophy: [String] = [],
        technicalStack: [String] = [],
        codingStandards: [String] = [],
        architectureNotes: String = ""
    ) {
        self.projectId = projectId
        self.projectName = projectName
        self.description = description
        self.corePrinciples = corePrinciples
        self.designPhilosophy = designPhilosophy
        self.technicalStack = technicalStack
        self.codingStandards = codingStandards
        self.architectureNotes = architectureNotes
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    func toMarkdown() -> String {
        var md = """
            # プロジェクト憲法: \(projectName)

            **プロジェクトID**: `\(projectId)`
            **作成日**: \(ISO8601DateFormatter().string(from: createdAt))
            **更新日**: \(ISO8601DateFormatter().string(from: updatedAt))

            ## 概要
            \(description)

            """

        if !corePrinciples.isEmpty {
            md += "\n## 核となる原則\n"
            for (index, principle) in corePrinciples.enumerated() {
                md += "\(index + 1). \(principle)\n"
            }
        }

        if !designPhilosophy.isEmpty {
            md += "\n## 設計思想\n"
            for (index, philosophy) in designPhilosophy.enumerated() {
                md += "\(index + 1). \(philosophy)\n"
            }
        }

        if !technicalStack.isEmpty {
            md += "\n## 技術スタック\n"
            for tech in technicalStack {
                md += "- \(tech)\n"
            }
        }

        if !codingStandards.isEmpty {
            md += "\n## コーディング規約\n"
            for standard in codingStandards {
                md += "- \(standard)\n"
            }
        }

        if !architectureNotes.isEmpty {
            md += "\n## アーキテクチャメモ\n\(architectureNotes)\n"
        }

        return md
    }
}

// MARK: - Design Decision (設計判断)
/// 重要な設計判断を記録
struct DesignDecision: Codable {
    let id: String
    let title: String
    let description: String
    let rationale: String  // 理由
    let alternatives: [String]  // 検討した代替案
    let consequences: [String]  // 結果・影響
    let relatedFiles: [String]  // 関連ファイル
    let tags: [String]  // タグ
    let createdAt: Date

    init(
        title: String,
        description: String,
        rationale: String,
        alternatives: [String] = [],
        consequences: [String] = [],
        relatedFiles: [String] = [],
        tags: [String] = []
    ) {
        self.id = UUID().uuidString
        self.title = title
        self.description = description
        self.rationale = rationale
        self.alternatives = alternatives
        self.consequences = consequences
        self.relatedFiles = relatedFiles
        self.tags = tags
        self.createdAt = Date()
    }

    func toMarkdown() -> String {
        var md = """
            # 設計判断: \(title)

            **ID**: `\(id)`
            **日時**: \(ISO8601DateFormatter().string(from: createdAt))

            ## 概要
            \(description)

            ## 理由
            \(rationale)

            """

        if !alternatives.isEmpty {
            md += "\n## 検討した代替案\n"
            for (index, alt) in alternatives.enumerated() {
                md += "\(index + 1). \(alt)\n"
            }
        }

        if !consequences.isEmpty {
            md += "\n## 結果・影響\n"
            for consequence in consequences {
                md += "- \(consequence)\n"
            }
        }

        if !relatedFiles.isEmpty {
            md += "\n## 関連ファイル\n"
            for file in relatedFiles {
                md += "- `\(file)`\n"
            }
        }

        if !tags.isEmpty {
            md += "\n## タグ\n"
            md += tags.map { "`\($0)`" }.joined(separator: ", ")
            md += "\n"
        }

        return md
    }
}

// MARK: - Work Log (作業ログ)
/// セッションの作業内容を記録
struct WorkLog: Codable {
    let sessionId: String
    let startTime: Date
    let endTime: Date?
    let summary: String  // 作業概要
    let accomplishments: [String]  // 完了したこと
    let challenges: [String]  // 課題・問題
    let nextSteps: [String]  // 次のステップ
    let filesModified: [String]  // 変更したファイル
    let decisions: [String]  // 決定事項（DecisionのIDリスト）
    let notes: String  // メモ

    init(
        sessionId: String,
        summary: String,
        accomplishments: [String] = [],
        challenges: [String] = [],
        nextSteps: [String] = [],
        filesModified: [String] = [],
        decisions: [String] = [],
        notes: String = ""
    ) {
        self.sessionId = sessionId
        self.startTime = Date()
        self.endTime = nil
        self.summary = summary
        self.accomplishments = accomplishments
        self.challenges = challenges
        self.nextSteps = nextSteps
        self.filesModified = filesModified
        self.decisions = decisions
        self.notes = notes
    }

    func toMarkdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")

        var md = """
            # 作業ログ

            **セッションID**: `\(sessionId)`
            **開始時刻**: \(formatter.string(from: startTime))
            """

        if let endTime = endTime {
            md += "\n**終了時刻**: \(formatter.string(from: endTime))"
            let duration = endTime.timeIntervalSince(startTime)
            let hours = Int(duration) / 3600
            let minutes = (Int(duration) % 3600) / 60
            md += "\n**所要時間**: \(hours)時間\(minutes)分"
        }

        md += "\n\n## 作業概要\n\(summary)\n"

        if !accomplishments.isEmpty {
            md += "\n## 完了したこと\n"
            for accomplishment in accomplishments {
                md += "- ✅ \(accomplishment)\n"
            }
        }

        if !challenges.isEmpty {
            md += "\n## 課題・問題\n"
            for challenge in challenges {
                md += "- ⚠️ \(challenge)\n"
            }
        }

        if !nextSteps.isEmpty {
            md += "\n## 次のステップ\n"
            for (index, step) in nextSteps.enumerated() {
                md += "\(index + 1). \(step)\n"
            }
        }

        if !filesModified.isEmpty {
            md += "\n## 変更したファイル\n"
            for file in filesModified {
                md += "- `\(file)`\n"
            }
        }

        if !notes.isEmpty {
            md += "\n## メモ\n\(notes)\n"
        }

        return md
    }
}

// MARK: - Context Item (コンテキストアイテム)
/// 検索結果から取得したコンテキスト情報
struct ContextItem: Codable {
    let id: String
    let content: String
    let similarity: Double
    let metadata: [String: String]
    let source: String  // "constitution", "decision", "worklog", "code", etc.

    var title: String {
        metadata["title"] ?? metadata["document_name"] ?? "Untitled"
    }
}

// MARK: - Session Context (セッションコンテキスト)
/// セッション開始時に提供されるコンテキスト
struct SessionContext: Codable {
    let sessionId: String
    let projectId: String
    let startTime: Date
    let constitution: ProjectConstitution?
    let previousWorkLog: WorkLog?
    let relevantDecisions: [DesignDecision]
    let relevantContext: [ContextItem]
    let nextSteps: [String]

    func toMarkdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")

        var md = """
            # セッションコンテキスト

            **セッションID**: `\(sessionId)`
            **プロジェクトID**: `\(projectId)`
            **開始時刻**: \(formatter.string(from: startTime))

            """

        if let constitution = constitution {
            md += "\n---\n\n"
            md += constitution.toMarkdown()
        }

        if let previousLog = previousWorkLog {
            md += "\n---\n\n## 前回のセッション\n\n"
            md += previousLog.toMarkdown()
        }

        if !relevantDecisions.isEmpty {
            md += "\n---\n\n## 関連する設計判断\n\n"
            for decision in relevantDecisions {
                md += decision.toMarkdown()
                md += "\n---\n\n"
            }
        }

        if !nextSteps.isEmpty {
            md += "\n## 次に取り組むべきこと\n"
            for (index, step) in nextSteps.enumerated() {
                md += "\(index + 1). \(step)\n"
            }
        }

        return md
    }
}

// MARK: - Project Context (プロジェクトコンテキスト)
/// プロジェクト全体のコンテキスト
struct ProjectContext: Codable {
    let projectId: String
    let constitution: ProjectConstitution
    let totalSessions: Int
    let totalDecisions: Int
    let recentFiles: [String]
    let lastUpdated: Date
}

// MARK: - Context Manager Configuration
/// ContextManagerの設定
struct ContextManagerConfig {
    let enableAutoSave: Bool
    let autoSaveInterval: TimeInterval
    let maxContextItems: Int
    let minSimilarityScore: Double
    let enableDecisionTracking: Bool

    static let `default` = ContextManagerConfig(
        enableAutoSave: true,
        autoSaveInterval: 300,  // 5分
        maxContextItems: 10,
        minSimilarityScore: 0.7,
        enableDecisionTracking: true
    )
}
