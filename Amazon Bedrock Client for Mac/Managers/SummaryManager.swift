//
//  SummaryManager.swift
//  Amazon Bedrock Client for Mac
//
//  会話要約管理マネージャー
//

import Foundation
import Logging

/// 会話要約を管理するマネージャー
/// 会話履歴とは別に、要約情報のみを管理
class SummaryManager {
    static let shared = SummaryManager()

    private var logger = Logger(label: "SummaryManager")
    private let fileManager = FileManager.default
    private var summaryCache: [String: ConversationSummary] = [:]

    private init() {}

    /// 要約ファイルのURLを取得
    private func getSummaryFileURL(for conversationId: String) -> URL {
        let baseDir = URL(fileURLWithPath: SettingManager.shared.defaultDirectory)
        let summaryDir = baseDir.appendingPathComponent("summaries")

        // ディレクトリが存在しない場合は作成
        try? fileManager.createDirectory(at: summaryDir, withIntermediateDirectories: true)

        return summaryDir.appendingPathComponent("\(conversationId)_summary.json")
    }

    /// 要約を読み込む
    func loadSummary(for conversationId: String) -> ConversationSummary {
        // キャッシュにあればそれを返す
        if let cached = summaryCache[conversationId] {
            return cached
        }

        let fileURL = getSummaryFileURL(for: conversationId)

        guard fileManager.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL),
            let summary = try? JSONDecoder().decode(ConversationSummary.self, from: data)
        else {
            // ファイルがない場合は新規作成
            let newSummary = ConversationSummary(conversationId: conversationId)
            summaryCache[conversationId] = newSummary
            return newSummary
        }

        summaryCache[conversationId] = summary
        return summary
    }

    /// 要約を保存
    func saveSummary(_ summary: ConversationSummary) {
        let fileURL = getSummaryFileURL(for: summary.conversationId)

        do {
            let data = try JSONEncoder().encode(summary)
            try data.write(to: fileURL)

            // キャッシュも更新
            summaryCache[summary.conversationId] = summary

            logger.info("要約を保存: \(summary.conversationId), 総メッセージ: \(summary.totalMessages)")
        } catch {
            logger.error("要約の保存に失敗: \(error.localizedDescription)")
        }
    }

    /// 新しいメッセージを記録
    func recordNewMessage(conversationId: String) {
        var summary = loadSummary(for: conversationId)
        summary.incrementMessageCount()
        saveSummary(summary)

        logger.debug("新しいメッセージを記録: 総数=\(summary.totalMessages)")
    }

    /// 新しい要約セグメントを追加（5回ごと）
    func addSummarySegment(conversationId: String, startIndex: Int, endIndex: Int, summary: String)
    {
        var summaryData = loadSummary(for: conversationId)
        summaryData.addSummarySegment(startIndex: startIndex, endIndex: endIndex, summary: summary)
        saveSummary(summaryData)

        logger.info(
            "要約セグメントを追加: [\(startIndex)-\(endIndex)], 文字数=\(summary.count), セグメント数=\(summaryData.summarySegments.count)"
        )
    }

    /// 要約が必要かチェック
    func needsSummaryUpdate(for conversationId: String) -> Bool {
        let summary = loadSummary(for: conversationId)
        return summary.needsSummaryUpdate()
    }

    /// 要約対象の範囲を取得
    func getSummaryRange(for conversationId: String) -> (start: Int, end: Int)? {
        let summary = loadSummary(for: conversationId)
        return summary.getSummaryRange()
    }

    /// 要約をクリア（チャット削除時など）
    func clearSummary(for conversationId: String) {
        let fileURL = getSummaryFileURL(for: conversationId)
        try? fileManager.removeItem(at: fileURL)
        summaryCache.removeValue(forKey: conversationId)

        logger.info("要約をクリア: \(conversationId)")
    }
}
