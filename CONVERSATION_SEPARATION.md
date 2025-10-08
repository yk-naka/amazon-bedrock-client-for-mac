# 会話分離の仕組み - 詳細説明

## 🎯 概要

このシステムでは、**各チャットセッションが完全に分離**されており、異なる会話の情報が混ざることはありません。

## 🔐 会話分離の実装

### 1. conversation_idの割り当て

各チャットには独自の`conversation_id`が割り当てられます：

```swift
// ChatManager.swift
private func saveMessageToSemanticCache(_ message: Message, chatId: String) async {
    // 各チャット専用のconversation_idを使用（会話の分離）
    let chatConversationId = "chat_\(chatId)"  // ← チャットごとに一意
    
    // semantic cacheに保存
    _ = try await ContextManager.shared.executeMCPTool(
        serverName: "semantic-cache",
        toolName: "add_text_data",
        arguments: [
            "text": messageText,
            "conversation_id": chatConversationId,  // ← チャット専用ID
            // ...
        ]
    )
}
```

### 2. conversation_idの構造

```
プロジェクト全体: project_<UUID>
チャットA:       chat_<chatId-A>  ← 独立
チャットB:       chat_<chatId-B>  ← 独立
チャットC:       chat_<chatId-C>  ← 独立
```

**例**:
```
project_12345678-1234-1234-1234-123456789012  ← プロジェクト憲法、設計判断など
chat_AAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE         ← チャットAの会話のみ
chat_1111-2222-3333-4444-555555555555         ← チャットBの会話のみ
```

### 3. ChromaDBでの保存

semantic_cache_serverは、conversation_idごとにデータを分離して保存：

```python
# semantic_cache_server.py
def search_similar(self, query: str, conversation_id: str = None):
    where_clause = {}
    if conversation_id:
        where_clause["conversation_id"] = conversation_id  # ← フィルタリング
    
    results = self.collection.query(
        query_embeddings=[query_embedding],
        where=where_clause  # ← このconversation_idのデータのみ取得
    )
```

## ✅ 分離の保証

### 検索時の動作

**チャットAでの検索**:
```swift
// chatId = "AAAA-BBBB-CCCC-..."
let context = await ChatManager.shared.getRelevantContextFromCache(
    query: "質問",
    chatId: chatId,  // ← チャットIDを指定
    limit: 5
)
// → conversation_id="chat_AAAA-BBBB-CCCC-..." のデータのみ取得
// → チャットBやCの会話は含まれない
```

### データベースレベルでの分離

ChromaDBでは、各ドキュメントに`conversation_id`メタデータが付与され、クエリ時にフィルタリングされます：

```json
{
  "id": "doc_12345",
  "document": "[チャット: chat_AAAA...] ...",
  "metadata": {
    "conversation_id": "chat_AAAA-BBBB-CCCC-...",
    "chat_id": "AAAA-BBBB-CCCC-...",
    "type": "chat_message"
  }
}
```

## 📊 実装の検証

### 確認方法

1. **conversation_idの一覧確認**
   ```swift
   Task {
       let stats = try await ContextManager.shared.getCacheStats()
       print(stats)
       // → conversations: ["project_...", "chat_A...", "chat_B..."]
   }
   ```

2. **特定チャットのデータのみ取得**
   ```swift
   let contextA = await ChatManager.shared.getRelevantContextFromCache(
       query: "テスト",
       chatId: "chat_A_id",
       limit: 10
   )
   // → チャットAのメッセージのみ返される
   ```

3. **検索結果の確認**
   ```swift
   for item in contextA {
       print("chat_id: \(item.metadata["chat_id"])")
       // → すべて同じchat_id
   }
   ```

## 🔍 conversation_id階層構造

```
semantic_cache (ChromaDB)
├── project_<UUID>                    ← プロジェクト全体の情報
│   ├── プロジェクト憲法
│   ├── 設計判断
│   ├── 作業ログ
│   └── コードベース情報
│
├── chat_<chatId-1>                   ← チャット1専用
│   ├── ユーザーメッセージ
│   ├── アシスタント返答
│   └── ...
│
├── chat_<chatId-2>                   ← チャット2専用
│   ├── ユーザーメッセージ
│   ├── アシスタント返答
│   └── ...
│
└── chat_<chatId-3>                   ← チャット3専用
    └── ...
```

## ⚠️ 重要な注意点

### 1. 会話の完全分離

- ✅ **各チャットは独立したconversation_idを持つ**
- ✅ **検索時に自動的にフィルタリング**
- ✅ **他のチャットのデータは絶対に取得されない**

### 2. プロジェクトレベルの情報

プロジェクト憲法や設計判断は、プロジェクト全体の`conversation_id`に保存されます：

```swift
// ContextManager.swift
func initializeProject(constitution: ProjectConstitution) async throws {
    // プロジェクトレベルのconversation_id
    let conversationId = try await generateConversationId(prefix: "project")
    // → "project_12345678-1234-..."
    
    // プロジェクト全体の情報として保存
    try await addTextToCache(
        text: constitutionMarkdown,
        conversationId: conversationId,  // ← プロジェクトID
        // ...
    )
}
```

### 3. 2階層のデータ管理

```
[プロジェクトレベル]
- conversation_id: "project_<UUID>"
- 用途: プロジェクト憲法、設計判断、作業ログ
- スコープ: プロジェクト全体

[チャットレベル]
- conversation_id: "chat_<chatId>"
- 用途: チャットの会話履歴
- スコープ: 各チャット専用（完全分離）
```

## 🧪 テスト例

### 分離の確認

```swift
// チャットA
let chatIdA = "AAAA-1111-..."
ChatManager.shared.addUserMessage(text: "質問A", chatId: chatIdA)

// チャットB
let chatIdB = "BBBB-2222-..."
ChatManager.shared.addUserMessage(text: "質問B", chatId: chatIdB)

// チャットAから検索
let contextA = await ChatManager.shared.getRelevantContextFromCache(
    query: "質問",
    chatId: chatIdA,
    limit: 10
)
// → 「質問A」のみが返される
// → 「質問B」は含まれない（完全分離）

// チャットBから検索
let contextB = await ChatManager.shared.getRelevantContextFromCache(
    query: "質問",
    chatId: chatIdB,
    limit: 10
)
// → 「質問B」のみが返される
// → 「質問A」は含まれない（完全分離）
```

## 🎉 まとめ

### 保証される動作

✅ **各チャットは完全に分離**
- チャットAの会話はチャットBから見えない
- チャットBの会話はチャットAから見えない

✅ **自動的な分離**
- conversation_idは自動生成
- 開発者が意識する必要なし

✅ **プライバシー保護**
- 異なるチャットの情報が混ざることは絶対にない
- conversation_idレベルでデータベースが分離

✅ **検索の正確性**
- 現在のチャット内の情報のみ検索
- 関連度の高い情報のみを取得

これにより、安心して複数のチャットを使い分けることができます！
