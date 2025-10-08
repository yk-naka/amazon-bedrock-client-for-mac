//
//  ConversationSummary.swift
//  Amazon Bedrock Client for Mac
//
//  会話要約管理用のデータモデル
//

import Foundation

/// 個別の要約セグメント
struct SummarySegment: Codable {
    let startIndex: Int  // 開始メッセージインデックス
    let endIndex: Int  // 終了メッセージインデックス
    let summary: String  // 要約テキスト（約1000文字）
    let createdAt: Date
}

/// 会話要約管理データ
/// 会話履歴とは別に、要約情報を時系列で管理
struct ConversationSummary: Codable {
    let conversationId: String  // チャットID
    var summarySegments: [SummarySegment]  // 時系列の要約リスト
    var lastSummaryIndex: Int  // 最後に要約したメッセージのインデックス
    var totalMessages: Int  // 総メッセージ数
    var lastUpdated: Date

    init(conversationId: String) {
        self.conversationId = conversationId
        self.summarySegments = []
        self.lastSummaryIndex = -1
        self.totalMessages = 0
        self.lastUpdated = Date()
    }

    /// 新しいメッセージが追加されたときに呼ぶ
    mutating func incrementMessageCount() {
        totalMessages += 1
        lastUpdated = Date()
    }

    /// 新しい要約セグメントを追加
    mutating func addSummarySegment(startIndex: Int, endIndex: Int, summary: String) {
        let segment = SummarySegment(
            startIndex: startIndex,
            endIndex: endIndex,
            summary: summary,
            createdAt: Date()
        )
        summarySegments.append(segment)
        lastSummaryIndex = endIndex
        lastUpdated = Date()
    }

    /// 5回ごとの更新が必要かチェック
    func needsSummaryUpdate() -> Bool {
        // 最後の要約から5回以上経過しているかチェック
        let messagesSinceLastSummary = totalMessages - lastSummaryIndex - 1
        return messagesSinceLastSummary >= 5
    }

    /// 要約対象の範囲を取得
    func getSummaryRange() -> (start: Int, end: Int)? {
        guard needsSummaryUpdate() else {
            return nil
        }

        let start = lastSummaryIndex + 1
        let end = totalMessages - 10  // 直近10件は除く

        guard start < end else {
            return nil
        }

        return (start, end)
    }

    /// すべての要約を結合したテキストを取得
    func getCombinedSummaries() -> String {
        guard !summarySegments.isEmpty else {
            return ""
        }

        return summarySegments.enumerated().map { index, segment in
            "【要約\(index + 1)】(メッセージ\(segment.startIndex)-\(segment.endIndex))\n\(segment.summary)"
        }.joined(separator: "\n\n")
    }

    /// 要約の総文字数を取得
    func getTotalSummaryLength() -> Int {
        return summarySegments.reduce(0) { $0 + $1.summary.count }
    }
}
