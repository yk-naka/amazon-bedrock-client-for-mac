# 永続的コンテキスト管理システム 使用ガイド

## 📚 概要

このシステムは、Bedrock Claude 4との長期的な開発セッションで、コンテキスト長の制限を克服し、最初の指示や設計判断を劣化させずに保持し続けるための永続的コンテキスト管理システムです。

## 🎯 目的

- **コンテキスト長の制限を克服**: 長期セッションでもプロジェクトの憲法や設計判断を保持
- **設計判断の記録**: 重要な技術的決定を自動的に記録・検索
- **セッション間の継続性**: 前回の作業内容と次のステップを自動的に引き継ぎ
- **インテリジェント検索**: 意味検索により関連情報を自動取得

## 🔄 自動統合機能

ChatManagerは、**自動的に**すべてのメッセージをsemantic_cacheに保存するように統合されています：

✅ **自動保存**: メッセージ追加時に自動的にsemantic_cacheに保存  
✅ **重複回避**: 類似度が0.95以上の場合は保存をスキップ  
✅ **非同期処理**: UIをブロックせずにバックグラウンドで保存  
✅ **エラー耐性**: semantic cache保存失敗でもチャット機能は継続  

## 📋 前提条件

### 1. MCPサーバーのセットアップ

`semantic_cache_server`がインストールされ、設定されている必要があります。

設定例（`~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json`）:

```json
{
  "mcpServers": {
    "semantic-cache": {
      "command": "python3",
      "args": ["/Users/your-username/git/mcp-server-test/mcp/semantic-cache/semantic_cache_server.py"],
      "disabled": false,
      "alwaysAllow": []
    }
  }
}
```

### 2. Xcodeプロジェクトへのファイル追加

以下の新しいファイルをXcodeプロジェクトに追加してください：

1. Xcodeでプロジェクトを開く
2. 以下のファイルを右クリックしてXcodeプロジェクトに追加:
   - `Amazon Bedrock Client for Mac/Models/ContextModels.swift`
   - `Amazon Bedrock Client for Mac/Managers/ContextManager.swift`
3. "Copy items if needed"にチェックを入れる
4. ターゲット"Amazon Bedrock Client for Mac"を選択
5. プロジェクトをビルドしてエラーがないことを確認

## 🚀 使用方法

### 1. プロジェクトの初期化

```swift
import Foundation

// プロジェクト憲法を作成
let constitution = ProjectConstitution(
    projectId: "bedrock-mac-client",
    projectName: "Amazon Bedrock Client for Mac",
    description: "macOS向けのAmazon Bedrockクライアントアプリケーション",
    corePrinciples: [
        "ユーザーフレンドリーなインターフェース",
        "高速なレスポンス",
        "セキュアな認証"
    ],
    designPhilosophy: [
        "SwiftUIによるモダンなUI設計",
        "MVVM アーキテクチャパターン",
        "非同期処理の徹底"
    ],
    technicalStack: [
        "Swift 5.9+",
        "SwiftUI",
        "AWS SDK for Swift",
        "Combine"
    ],
    codingStandards: [
        "Swift APIデザインガイドラインに準拠",
        "async/awaitを使用した非同期処理",
        "適切なエラーハンドリング"
    ],
    architectureNotes: """
    MVVMアーキテクチャを採用し、ビジネスロジックとUI層を分離。
    MCPサーバーとの統合により、外部ツールとのシームレスな連携を実現。
    """
)

// プロジェクトを初期化
Task {
    do {
        try await ContextManager.shared.initializeProject(constitution: constitution)
        print("プロジェクトが初期化されました")
    } catch {
        print("エラー: \(error)")
    }
}
```

### 2. コードベースの登録（オプション）

```swift
// 既存のコードベースを一括登録
Task {
    let projectId = ContextManager.shared.currentProjectId ?? ""
    let files = [
        "/path/to/Amazon Bedrock Client for Mac/Managers/BedrockClient.swift",
        "/path/to/Amazon Bedrock Client for Mac/Managers/ChatManager.swift",
        "/path/to/Amazon Bedrock Client for Mac/Models/ChatModel.swift"
    ]
    
    do {
        try await ContextManager.shared.registerCodebase(
            projectId: projectId,
            files: files
        )
        print("コードベースが登録されました")
    } catch {
        print("エラー: \(error)")
    }
}
```

### 3. セッションの開始

```swift
Task {
    do {
        let sessionContext = try await ContextManager.shared.startSession()
        
        // セッションコンテキストを表示
        print(sessionContext.toMarkdown())
        
        // 前回の作業内容
        if let previousLog = sessionContext.previousWorkLog {
            print("前回の作業: \(previousLog.summary)")
            print("次のステップ: \(previousLog.nextSteps)")
        }
        
        // 関連する設計判断
        for decision in sessionContext.relevantDecisions {
            print("設計判断: \(decision.title)")
        }
        
    } catch {
        print("セッション開始エラー: \(error)")
    }
}
```

### 4. 設計判断の記録

開発中に重要な技術的決定を行った場合：

```swift
Task {
    let decision = DesignDecision(
        title: "MCPサーバー統合アーキテクチャ",
        description: "Model Context Protocolを使用した外部ツール統合",
        rationale: """
        MCPを採用することで、様々な外部ツールやサービスとの
        統合が容易になり、拡張性が大幅に向上する。
        """,
        alternatives: [
            "独自のプラグインシステムを構築",
            "REST APIベースの統合"
        ],
        consequences: [
            "標準化されたプロトコルにより、サードパーティツールの統合が容易",
            "MCPサーバーの管理が必要",
            "非同期処理の複雑さが増加"
        ],
        relatedFiles: [
            "Managers/MCPManager.swift",
            "Models/MCPModels.swift"
        ],
        tags: ["architecture", "integration", "mcp"]
    )
    
    do {
        try await ContextManager.shared.recordDecision(decision: decision)
        print("設計判断を記録しました")
    } catch {
        print("エラー: \(error)")
    }
}
```

### 5. ファイル変更の追跡

```swift
// ファイルを変更した際に呼び出す
ContextManager.shared.trackFileModification(
    "Amazon Bedrock Client for Mac/Managers/BedrockClient.swift"
)
```

### 6. コンテキスト検索

作業中に関連情報を検索：

```swift
Task {
    do {
        let results = try await ContextManager.shared.search(
            query: "MCPサーバーとの通信方法",
            maxResults: 5
        )
        
        for item in results {
            print("タイトル: \(item.title)")
            print("類似度: \(item.similarity)")
            print("内容: \(item.content)")
            print("---")
        }
    } catch {
        print("検索エラー: \(error)")
    }
}
```

### 7. セッションの終了

作業を終了する際：

```swift
Task {
    let workLog = WorkLog(
        sessionId: ContextManager.shared.currentSession?.sessionId ?? "",
        summary: "MCPサーバー統合の実装を完了",
        accomplishments: [
            "MCPManagerの実装完了",
            "ツール実行機能の追加",
            "エラーハンドリングの改善"
        ],
        challenges: [
            "非同期処理の複雑さ",
            "型変換の問題"
        ],
        nextSteps: [
            "ユニットテストの追加",
            "UIの統合",
            "ドキュメントの更新"
        ],
        notes: """
        MCPサーバーとの統合は正常に動作している。
        次はUIからツールを呼び出せるようにする必要がある。
        """
    )
    
    do {
        try await ContextManager.shared.endSession(log: workLog)
        print("セッションを終了しました")
    } catch {
        print("エラー: \(error)")
    }
}
```

### 8. プロジェクトコンテキストの取得

```swift
Task {
    do {
        let context = try await ContextManager.shared.getCurrentContext()
        
        print("プロジェクトID: \(context.projectId)")
        print("総セッション数: \(context.totalSessions)")
        print("総設計判断数: \(context.totalDecisions)")
        print("最近変更されたファイル: \(context.recentFiles)")
    } catch {
        print("エラー: \(error)")
    }
}
```

## 🔧 自動統合の動作

### 1. メッセージの自動保存

ChatManagerの`addMessage`関数が呼ばれると、自動的にsemantic_cacheに保存されます：

```swift
// ユーザーがメッセージを送信
ChatManager.shared.addUserMessage(text: "MCPサーバーの設定方法は？", chatId: chatId)

// ↓ 自動的に実行される（手動呼び出し不要）
// 1. ローカルファイルに保存
// 2. semantic_cacheに保存（バックグラウンド）
```

### 2. 関連コンテキストの取得

チャット開始時や必要な時に、過去の関連会話を取得できます：

```swift
// チャット開始時
let summary = await ChatManager.shared.getContextSummaryForNewChat(chatId: chatId)
if let summary = summary {
    print(summary)  // 関連する過去の会話が表示される
}

// 任意のクエリで検索
let context = await ChatManager.shared.getRelevantContextFromCache(
    query: "MCPサーバーの設定",
    limit: 5
)
```

### 3. semantic cache機能の有効/無効

```swift
// 無効にする場合（ChatManager内で直接設定）
// private var enableSemanticCache: Bool = false
```

## 🔧 統合例

### ChatViewModelとの関連コンテキスト取得

```swift
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    
    func startNewSession(chatId: String) {
        Task {
            do {
                // 1. セッションコンテキストを取得
                let sessionContext = try await ContextManager.shared.startSession()
                
                // 2. 関連する過去の会話を取得
                let relevantContext = await ChatManager.shared.getContextSummaryForNewChat(chatId: chatId)
                
                var contextText = "セッションを開始しました。\n\n"
                contextText += sessionContext.toMarkdown()
                
                if let relevantContext = relevantContext {
                    contextText += "\n\n---\n\n"
                    contextText += relevantContext
                }
                
                // セッションコンテキストをチャットに表示
                let contextMessage = Message(
                    id: UUID(),
                    text: contextText,
                    role: .assistant,
                    timestamp: Date(),
                    isError: false
                )
                
                await MainActor.run {
                    self.messages.append(contextMessage)
                }
            } catch {
                print("セッション開始エラー: \(error)")
            }
        }
    }
    
    func searchRelatedConversations(query: String) {
        Task {
            let context = await ChatManager.shared.getRelevantContextFromCache(
                query: query,
                limit: 5
            )
            
            if !context.isEmpty {
                var summary = "## 関連する過去の会話\n\n"
                for (index, item) in context.enumerated() {
                    summary += "### \(index + 1). \(item.title)\n"
                    summary += "類似度: \(String(format: "%.2f", item.similarity))\n"
                    summary += "\(item.content.prefix(300))...\n\n"
                }
                
                await MainActor.run {
                    // UIに表示
                    let message = Message(
                        id: UUID(),
                        text: summary,
                        role: .assistant,
                        timestamp: Date(),
                        isError: false
                    )
                    self.messages.append(message)
                }
            }
        }
    }
    
    func recordImportantDecision(title: String, description: String, rationale: String) {
        Task {
            let decision = DesignDecision(
                title: title,
                description: description,
                rationale: rationale
            )
            
            do {
                try await ContextManager.shared.recordDecision(decision: decision)
            } catch {
                print("決定記録エラー: \(error)")
            }
        }
    }
}
```

## 📊 データ構造

### ProjectConstitution
プロジェクトの基本方針と設計思想を定義

### DesignDecision
重要な設計判断を記録

### WorkLog
セッションの作業内容を記録

### SessionContext
セッション開始時に提供されるコンテキスト

### ProjectContext
プロジェクト全体のコンテキスト

## ⚠️ 注意事項

1. **MCPサーバーの起動確認**: semantic_cache_serverが起動していることを確認
2. **ContextManagerの初期化**: アプリ起動時に`ContextManager.shared.initializeProject`を呼び出す
3. **conversationIDの管理**: 一度生成したconversationIDは保持し、再利用
4. **自動保存の動作**: 
   - メッセージは自動的にsemantic_cacheに保存されます
   - 保存失敗してもチャット機能は継続します
   - 重複する内容（類似度0.95以上）は自動的にスキップされます
5. **パフォーマンス**: 
   - semantic cache保存は非同期で実行されるため、UIはブロックされません
   - 大量のファイルを登録する場合は時間がかかることがあります

## 🐛 トラブルシューティング

### MCPツールが見つからない

```
エラー: MCPツールエラー: Tool 'generate_conversation_id' not found
```

**解決策**:
1. semantic_cache_serverが起動しているか確認
2. MCP設定が正しいか確認
3. Xcodeを再起動してMCPManagerを再初期化

### コンテキストが保存されない

**解決策**:
1. semantic_cache_serverのログを確認
2. ChromaDBのデータベースパスが存在するか確認
3. 書き込み権限があるか確認

## 📚 さらなる情報

- [MCP公式ドキュメント](https://modelcontextprotocol.io/)
- [semantic_cache_server実装](/Users/a15109/git/mcp-server-test/mcp/semantic-cache/)

## 🎉 まとめ

この永続的コンテキスト管理システムにより：

✅ **自動的な会話保存**: メッセージは自動的にsemantic_cacheに保存される  
✅ **過去の会話を活用**: 関連する過去の会話を意味検索で取得可能  
✅ **長期セッション対応**: プロジェクトの基本方針を永続的に保持  
✅ **設計判断の記録**: 重要な技術的決定を自動記録・検索  
✅ **シームレスな引き継ぎ**: セッション間で作業内容を自動引き継ぎ  
✅ **効率的な情報取得**: 意味検索による高精度な情報取得  

### 🔄 動作フロー

1. **ユーザーがメッセージ送信** 
   → ChatManager.addMessage呼び出し

2. **自動的に2箇所に保存**
   - ローカルファイル（従来通り）
   - semantic_cache（新機能・自動）

3. **必要な時に過去の会話を検索**
   - `getRelevantContextFromCache`で意味検索
   - `getContextSummaryForNewChat`でチャット開始時に関連会話表示

4. **コンテキストの劣化なし**
   - 何ヶ月前の会話でも意味検索で取得可能
   - プロジェクトの初期の設計判断も保持

これにより、Bedrock Claude 4との開発が**より効率的で継続的**なものになります！
