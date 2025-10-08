# 新しい要約システム - 最終仕様

## 🎯 システム概要

会話履歴とは別に、要約情報を独立管理する新しいアプローチ。

## 📊 データ構造

### 1. 会話履歴（従来通り・完全保持）
```
history/<chatId>_unified_history.json
- すべてのメッセージを保存
- 削除・変更なし
- UI表示用
```

### 2. 要約情報（新規・別ファイル）
```
summaries/<chatId>_summary.json
{
  "conversationId": "chat_12345",
  "summarySegments": [
    {
      "startIndex": 0,
      "endIndex": 5,
      "summary": "最初の会話の要約...",
      "createdAt": "2025-10-07T09:00:00Z"
    },
    {
      "startIndex": 5,
      "endIndex": 10,
      "summary": "次の5会話の要約...",
      "createdAt": "2025-10-07T09:05:00Z"
    },
    {
      "startIndex": 10,
      "endIndex": 15,
      "summary": "さらに次の5会話の要約...",
      "createdAt": "2025-10-07T09:10:00Z"
    }
    // ... 時系列で追加されていく
  ],
  "lastSummaryIndex": 15,
  "totalMessages": 50,
  "lastUpdated": "2025-10-07T..."
}
```

## 🔄 動作フロー

### メッセージ送信時

```
1. ユーザーがメッセージ送信
    ↓
2. 会話履歴に追加（完全保存）
    history.json: 50メッセージ（全保持）
    ↓
3. SummaryManagerに記録
    summary.json: totalMessages++
    ↓
4. 5回ごとに要約更新チェック
    ↓
┌───┴────┐
↓        ↓
[5回未満]     [5回経過]
何もしない      要約生成
    ↓            ↓
    │      統合要約を更新
    │      (既存要約 + 新しい要約)
    │            ↓
    └──────┬─────┘
           ↓
5. Bedrock送信用データ作成
    ↓
┌───┴────┐
↓        ↓
[9万文字以下]     [9万文字超過]
全履歴送信        要約 + 直近10会話
                  ↓
              summary.summary + 直近10メッセージ
```

## 📝 実装の要点

### SummaryManager.swift（作成済み）
```swift
class SummaryManager {
    static let shared = SummaryManager()
    
    // 新しいメッセージを記録
    func recordNewMessage(conversationId: String, atIndex index: Int)
    
    // 要約を更新（5回ごと）
    func updateSummary(conversationId: String, newSummary: String, upToIndex: Int)
    
    // 要約が必要かチェック
    func needsSummaryUpdate(for conversationId: String) -> Bool
}
```

### ChatManager.swift（統合必要）
```swift
func addMessage(_ message: Message, to chatId: String) {
    // 1. 会話履歴に保存（完全保存）
    history.addMessage(message)
    saveConversationHistory(history, for: chatId)
    
    // 2. SummaryManagerに記録
    let messageIndex = history.messages.count - 1
    SummaryManager.shared.recordNewMessage(
        conversationId: chatId, 
        atIndex: messageIndex
    )
    
    // 3. 5回ごとに要約更新（バックグラウンド）
    Task {
        if SummaryManager.shared.needsSummaryUpdate(for: chatId) {
            await updateSummaryIfNeeded(chatId: chatId)
        }
    }
}
```

### ChatViewModel.swift（統合必要）
```swift
private func manageConversationByCharacterCount(_ messages: [BedrockMessage]) async -> [BedrockMessage] {
    // 文字数チェック
    if totalCharacters <= 90_000 {
        return messages  // 全履歴
    }
    
    // 9万文字超過
    // SummaryManagerから要約を取得
    let summary = SummaryManager.shared.loadSummary(for: chatId)
    let recentMessages = Array(messages.suffix(10))
    
    // 要約メッセージ作成
    let summaryMessage = BedrockMessage(
        role: .assistant,
        content: [.text("📋 **以前の会話の要約**\n\n\(summary.summary)")]
    )
    
    return [summaryMessage] + recentMessages
}
```

## ✅ メリット

### 1. 完全な履歴保持
- ✅ 会話履歴JSONは絶対に削除・変更されない
- ✅ すべてのメッセージが完全保存
- ✅ いつでも過去の全会話を参照可能

### 2. インテリジェントな要約
- ✅ 5回ごとに自動更新
- ✅ 既存要約と統合（5000字以内）
- ✅ 重要な情報は累積

### 3. 効率的な送信
- ✅ 9万文字以下: 全履歴送信
- ✅ 9万文字超過: 要約 + 直近10会話
- ✅ コンテキスト長エラーを回避

## 📁 ファイル構造

```
~/Library/Application Support/Amazon Bedrock Client/
├── history/
│   └── <chatId>_unified_history.json  ← 全メッセージ（完全保持）
│
└── summaries/
    └── <chatId>_summary.json  ← 要約情報のみ
        {
          "summary": "統合要約",
          "lastSummaryIndex": 45,
          "recentMessageIndices": [41-50],
          "totalMessages": 50
        }
```

## 🎯 実装の次のステップ

### 1. ChatManagerにSummaryManager統合
- addMessage時にrecordNewMessage呼び出し
- 5回ごとに要約更新

### 2. ChatViewModelでSummaryManager使用
- manageConversationByCharacterCountで要約を取得
- 要約 + 直近10会話を送信

### 3. チャット削除時のクリーンアップ
- ChatManager.deleteChat でclearSummary呼び出し

## 🎉 期待される動作

```
メッセージ0-5:    要約なし、全履歴送信
                  
メッセージ6:      要約1生成（0-5を要約）
                  summarySegments: [要約1]
                  
メッセージ7-10:   要約なし、全履歴送信

メッセージ11:     要約2追加（5-10を要約）
                  summarySegments: [要約1, 要約2]  ← 追記
                  
メッセージ12-15:  要約なし、全履歴送信

メッセージ16:     要約3追加（10-15を要約）
                  summarySegments: [要約1, 要約2, 要約3]  ← 追記
...

メッセージ50+:    9万文字超過時
                  ↓
                  全要約 + 直近10会話を送信
                  [要約1, 要約2, ..., 要約8] + [メッセージ41-50]
                  
                  history.json: 50メッセージ完全保持
                  summary.json: 8個の要約セグメント（時系列）
```

### ✅ 利点

**情報損失の最小化**:
- 各5会話ごとの要約が独立して保持
- 時系列で追跡可能
- 統合による情報損失なし

**コンテキスト効率**:
- 各要約: 約1000文字
- 8個の要約 = 約8000文字
- 直近10会話: 変動
- 合計でも9万文字以内に収まる

**完全な履歴保持**:
- history.json: すべてのメッセージ（永久保存）
- summary.json: 時系列の要約セグメント（情報の階層化）

**会話履歴は絶対に失われず、要約は時系列で蓄積されます！**
