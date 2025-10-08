# クイックスタートガイド - 自動初期化版

## 🎯 重要: プロジェクト初期化は自動化されています

**手動で初期化コードを実行する必要はありません！**

アプリ起動時に、`AppDelegate`が自動的にContextManagerを初期化します。

## 🚀 使い始める3ステップ

### ステップ1: Xcodeでビルド＆実行

```bash
cd "/Users/a15109/git/amazon-bedrock-client-for-mac"
open "Amazon Bedrock Client for Mac.xcodeproj"
```

Xcodeが開いたら、`⌘ + R` を押すだけ！

### ステップ2: アプリが自動的に初期化

アプリ起動時に`AppDelegate.swift`の`initializeContextManager()`が自動実行され：

```swift
// AppDelegate.swift - 自動実行される
private func initializeContextManager() {
    Task {
        // プロジェクト憲法を定義
        let constitution = ProjectConstitution(
            projectId: "bedrock-mac-client",
            projectName: "Amazon Bedrock Client for Mac",
            description: "macOS向けのAmazon Bedrockクライアント",
            // ... 詳細な設定
        )
        
        // 自動的に初期化
        try await ContextManager.shared.initializeProject(constitution: constitution)
        // ✅ これで完了！
    }
}
```

### ステップ3: 通常通り使用

初期化後は、**何もする必要なし**：

1. **チャットを作成**
   - 新しいチャットを開始

2. **メッセージを送信**
   - 普通にメッセージを入力

3. **自動的に保存される**
   - メッセージは自動的にsemantic_cacheに保存
   - 各チャットは完全に分離
   - 何もしなくても動作

## ✨ 自動化されていること

### 1. アプリ起動時（自動）
```
[アプリ起動]
    ↓
[AppDelegate.applicationDidFinishLaunching] ← 自動実行
    ↓
[initializeContextManager()] ← 自動実行
    ↓
[ContextManager.initializeProject()] ← 自動実行
    ↓
[conversation_id生成] ← 自動実行
    ↓
[プロジェクト憲法保存] ← 自動実行
    ↓
✅ 初期化完了！
```

### 2. メッセージ送信時（自動）
```
[ユーザーがメッセージ送信]
    ↓
[ChatManager.addMessage] ← 自動実行
    ↓
[ローカルファイル保存] ← 自動実行
    ↓
[saveMessageToSemanticCache] ← 自動実行
    ↓
[semantic_cacheに保存] ← 自動実行
    conversation_id: "chat_<chatId>"  ← 自動的にチャット専用ID
    ↓
✅ 保存完了！
```

### 3. 過去の会話検索（手動でも可能）
```swift
// 必要な時だけ呼び出す（オプション）
let context = await ChatManager.shared.getRelevantContextFromCache(
    query: "MCPサーバーの設定",
    chatId: currentChatId,
    limit: 5
)
```

## 🔍 動作確認方法

### コンソールログで確認

Xcodeのコンソールに以下のログが表示されれば成功：

```
[2025-10-03T20:41:00+0900] [info] [AppDelegate.swift:70] ContextManager initialized successfully with project: Amazon Bedrock Client for Mac
```

### 実際の動作確認

1. **チャットを作成**して何かメッセージを送信

2. **コンソールで確認**:
   ```
   [info] [ChatManager.swift:1150] Saved message to semantic cache with conversation_id: chat_XXXX-YYYY-...
   ```

3. **保存されていることを確認**（オプション）:
   ```swift
   Task {
       let stats = try await ContextManager.shared.getCacheStats()
       print(stats)
       // → conversations: ["project_...", "chat_..."]
   }
   ```

## ⚠️ よくある質問

### Q1: 手動で初期化コードを実行する必要は？

**A**: **不要です！** AppDelegateが自動的に実行します。

### Q2: 2回目の起動時は？

**A**: 既に初期化されているかチェックされ、2回目以降はスキップされます：

```swift
if ContextManager.shared.currentProjectId != nil {
    logger.info("ContextManager already initialized")
    return  // ← スキップ
}
```

### Q3: semantic_cache_serverが起動していない場合は？

**A**: エラーログが出ますが、**アプリは正常に動作し続けます**：

```
[warning] Failed to initialize ContextManager: ...
[info] App will continue without persistent context management
```

ローカルファイルへの保存は継続され、チャット機能は影響を受けません。

### Q4: 初期化設定を変更したい場合は？

**A**: `AppDelegate.swift`の`initializeContextManager()`メソッド内の`ProjectConstitution`を編集してください：

```swift
// AppDelegate.swift
let constitution = ProjectConstitution(
    projectId: "your-project-id",      // ← 変更可能
    projectName: "Your Project Name",   // ← 変更可能
    description: "Your description",    // ← 変更可能
    // ...
)
```

## 🎉 まとめ

### 必要な作業

1. ✅ Xcodeで `⌘ + R` を押す
2. ✅ 以上！

### 自動的に実行されること

- ✅ プロジェクト初期化
- ✅ conversation_id生成
- ✅ プロジェクト憲法保存
- ✅ メッセージの自動保存
- ✅ 会話の完全分離

### 手動で行うこと

- ❌ なし！すべて自動化されています

**アプリを起動するだけで、永続的コンテキスト管理システムが動作開始します！**
