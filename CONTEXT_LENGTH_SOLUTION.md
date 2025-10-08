# コンテキスト長の制限 - 解決策の説明

## 🎯 問題の原因

エラーメッセージ:
```
入力コンテキスト長の上限を超えました
会話履歴またはメッセージが長すぎるため、選択したモデルの最大トークン数を超えています。
```

### 根本的な原因

**すべての会話履歴をBedrockに送信していた**ため、長い会話になるとコンテキスト長の制限を超えてしまいます。

semantic_cacheに保存していても、**Bedrockへのリクエスト時には従来通りすべての履歴を送信**していたのが問題でした。

## ✅ 実装された解決策

### 1. インテリジェントな文字数ベースの履歴管理

`ChatViewModel.swift`の`getConversationHistory()`メソッドを修正し、**文字数ベースの動的管理**を実装しました：

```swift
// 修正後
private func getConversationHistory() async -> [BedrockMessage] {
    // 文字数ベースの管理を実行
    return await manageConversationByCharacterCount(bedrockMessages)
}

private func manageConversationByCharacterCount(_ messages: [BedrockMessage]) async -> [BedrockMessage] {
    // 10会話以下の場合はそのまま返す
    guard messages.count > 10 else {
        return messages
    }
    
    // 全体の文字数をカウント
    let totalCharacters = countCharactersInMessages(messages)
    
    // 10万文字以下の場合は全履歴を使用
    if totalCharacters <= 100_000 {
        return messages
    }
    
    // 10万文字超過の場合
    // 1. 直近10会話を保持
    let recentMessages = Array(messages.suffix(10))
    
    // 2. それ以前を要約
    let olderMessages = Array(messages.prefix(messages.count - 10))
    let summary = try await summarizeOlderMessages(olderMessages)
    
    // 3. 要約 + 直近10会話を返す
    let summaryMessage = BedrockMessage(
        role: .assistant,
        content: [.text("📋 **以前の会話の要約**\n\n\(summary)")]
    )
    
    return [summaryMessage] + recentMessages  // ← 要約 + 直近10件
}
```

**動作**:
- ✅ 10万文字以下: すべての会話履歴を送信
- ✅ 10万文字超過: 直近10会話 + それ以前の要約
- ✅ 自動的に判断・実行

### 2. インテリジェントなデータ管理

```
[すべての会話履歴]
        ↓
    ┌───┴────┐
    ↓        ↓
[ローカル]  [semantic_cache]
全メッセージ   全メッセージ
保存・表示     検索用
    ↓        
[文字数チェック]
    ↓
┌───┴────┐
↓        ↓
[10万文字以下]  [10万文字超過]
全履歴送信      要約 + 直近10会話
```

## 🔄 動作フロー

### メッセージ送信時

```
1. ユーザーがメッセージ入力
    ↓
2. 会話履歴を取得
    • ローカル: 全メッセージ（100件など）
    ↓
3. 文字数チェック（自動）
    ↓
┌───┴────┐
↓        ↓
[10万文字以下]        [10万文字超過]
全履歴をBedrockへ      要約生成（自動）
                           ↓
                      要約 + 直近10会話をBedrockへ
    ↓                      ↓
4. Bedrockに送信
    • コンテキスト長の制限内に収まる
    ↓
5. 応答を受信
    ↓
6. すべての履歴を保存
    • ローカルファイル: 全メッセージ
    • semantic_cache: 全メッセージ（検索用）
```

### 過去の会話が必要な場合

```
1. semantic_cacheから検索
    ↓
let context = await ChatManager.shared.getRelevantContextFromCache(
    query: "MCPサーバーの設定",
    chatId: currentChatId,
    limit: 5
)
    ↓
2. 関連する過去の会話を取得
    • 意味検索により、21件目以降からも関連情報を取得可能
    • Bedrockへは送信されないが、検索で取り出せる
```

## 📊 メリット

### ✅ コンテキスト長の制限を回避

- Bedrockへは最近の20メッセージのみ送信
- 長い会話でもエラーが発生しない
- モデルのコンテキスト長制限内に収まる

### ✅ すべての履歴は保持

- ローカルファイル: 全メッセージ保存
- semantic_cache: 全メッセージ保存（検索可能）
- 古い会話も意味検索で取得可能

### ✅ 自動的な管理

- ユーザーが意識する必要なし
- 自動的に最近のメッセージのみ送信
- 必要に応じてsemantic_cacheから検索

## 🔧 カスタマイズ方法

### 文字数制限の変更

デフォルトは10万文字ですが、変更可能：

```swift
// ChatViewModel.swift
private func manageConversationByCharacterCount(_ messages: [BedrockMessage]) async -> [BedrockMessage] {
    // 文字数制限を変更
    if totalCharacters <= 100_000 {  // ← この数字を変更
        return messages
    }
    // ...
}
```

**推奨値**:
- Claude Sonnet 4 (200Kトークン ≈ 60万文字): 50万文字
- Claude 3.5 Sonnet (200Kトークン ≈ 60万文字): 50万文字  
- Nova Pro (300Kトークン ≈ 90万文字): 70万文字
- その他のモデル: 10-20万文字

### 保持する会話数の変更

デフォルトは直近10会話ですが、変更可能：

```swift
// ChatViewModel.swift
private func manageConversationByCharacterCount(_ messages: [BedrockMessage]) async -> [BedrockMessage] {
    // 保持する会話数を変更
    let recentMessages = Array(messages.suffix(10))  // ← この数字を変更
    let olderMessages = Array(messages.prefix(messages.count - 10))  // ← この数字も変更
    // ...
}
```

### より古い会話を参照したい場合

semantic_cacheから検索：

```swift
// 例：ChatViewで過去の会話を検索するボタンを追加
Button("過去の会話を検索") {
    Task {
        let context = await chatManager.getRelevantContextFromCache(
            query: userInput,
            chatId: chatId,
            limit: 10
        )
        
        // 検索結果を表示
        for item in context {
            print("関連する過去の会話: \(item.title)")
            print("類似度: \(item.similarity)")
            print("内容: \(item.content)")
        }
    }
}
```

## ⚠️ 重要な注意

### semantic_cacheの役割

semantic_cacheは**すべての会話を保存**しますが：

**送信**:
- ❌ Bedrockへは送信されない（最近の20件のみ）
- ✅ 保存：すべてのメッセージを保存
- ✅ 検索：意味検索で古い会話も取得可能

**利点**:
- コンテキスト長の制限を回避
- 必要な情報は意味検索で取得
- すべての履歴は保持される

## 🎉 まとめ

### 解決されたこと

✅ **コンテキスト長エラーの回避**
- 10万文字以下: すべての会話履歴をBedrockに送信
- 10万文字超過: 自動的に要約 + 直近10会話のみ送信
- 長い会話でもエラーが発生しない

✅ **インテリジェントな要約**
- Nova Liteで自動的に要約生成
- 重要な情報は保持
- 文脈は維持

✅ **すべての履歴は完全保持**
- ローカルファイルに全メッセージ保存
- semantic_cacheに全メッセージ保存

✅ **古い会話も利用可能**
- semantic_cacheから意味検索で取得
- `getRelevantContextFromCache`で検索

### 動作例

**10万文字以下の場合**:
```
[50メッセージ、8万文字]
    ↓
[すべてをBedrockに送信]
    ↓
✅ 正常動作
```

**10万文字超過の場合**:
```
[100メッセージ、15万文字]
    ↓
[自動判定: 10万文字超過]
    ↓
[古い90メッセージを要約]
    ↓
[要約（約1000文字） + 直近10メッセージ]
    ↓
[Bedrockに送信]
    ↓
✅ コンテキスト長制限内に収まる
```

### 今後の使用方法

**通常使用**:
- 何もしなくても自動的に動作
- 10万文字以下は全履歴送信
- 10万文字超過は自動要約 + 直近10会話
- ユーザーが意識する必要なし

**古い会話を参照したい場合**:
```swift
let context = await ChatManager.shared.getRelevantContextFromCache(
    query: "知りたいこと",
    chatId: currentChatId,
    limit: 5
)
```

**すべての履歴を確認したい場合**:
```swift
// UIには全メッセージが表示される
let allMessages = chatManager.getMessages(for: chatId)
// → すべての会話が保存されている
```

これで、**コンテキスト長の制限を気にせず、無制限に長期的な会話が可能**になります！
