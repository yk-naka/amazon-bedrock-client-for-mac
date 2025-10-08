# Semantic Cache 完全保存の実装案

## 現状の課題

現在、semantic_cacheには**メッセージテキストのみ**が保存されており、以下は保存されていません：
- 添付ファイル（画像、ドキュメント）
- thinking（思考プロセス）
- ツール実行結果
- システムプロンプト

## 改善案1: 完全なメッセージ情報の保存

### 実装方法

```swift
// ChatManager.swift の saveMessageToSemanticCache を拡張

private func saveMessageToSemanticCache(_ message: Message, chatId: String) async {
    guard let projectId = ContextManager.shared.currentProjectId else {
        logger.debug("ContextManager not initialized, skipping semantic cache save")
        return
    }

    do {
        // 完全な情報を含むJSON構造
        var fullMessageData: [String: Any] = [
            "chat_id": chatId,
            "role": message.role.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: message.timestamp),
            "text": message.text,
            "is_error": message.isError
        ]
        
        // thinking（思考プロセス）
        if let thinking = message.thinking {
            fullMessageData["thinking"] = thinking
        }
        if let signature = message.thinkingSignature {
            fullMessageData["thinking_signature"] = signature
        }
        
        // 添付ファイル情報
        if let images = message.imageBase64Strings, !images.isEmpty {
            fullMessageData["has_images"] = true
            fullMessageData["image_count"] = images.count
            // 注意: Base64データは大きいので、存在フラグのみ保存
            // 実際のデータはローカルファイルから取得
        }
        
        if let docs = message.documentBase64Strings, !docs.isEmpty {
            fullMessageData["has_documents"] = true
            fullMessageData["document_count"] = docs.count
            fullMessageData["document_names"] = message.documentNames
        }
        
        // ツール使用情報
        if let toolUse = message.toolUse {
            fullMessageData["tool_use"] = [
                "tool_id": toolUse.toolId,
                "tool_name": toolUse.toolName,
                "has_result": toolUse.result != nil
            ]
        }
        
        // JSON化
        let jsonData = try JSONSerialization.data(withJSONObject: fullMessageData)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
        
        // 検索用のテキスト（人間が読める形式）
        let searchableText = """
            [チャット: \(chatId)]
            [ロール: \(message.role.rawValue)]
            [タイムスタンプ: \(ISO8601DateFormatter().string(from: message.timestamp))]
            
            \(message.text)
            
            \(message.thinking ?? "")
            """
        
        // semantic cacheに保存
        _ = try await ContextManager.shared.executeMCPTool(
            serverName: "semantic-cache",
            toolName: "add_text_data",
            arguments: [
                "text": searchableText,
                "conversation_id": projectId,
                "enable_chunking": false,
                "metadata": [
                    "type": "chat_message",
                    "chat_id": chatId,
                    "role": message.role.rawValue,
                    "timestamp": ISO8601DateFormatter().string(from: message.timestamp),
                    "full_data": jsonString  // 完全なデータをメタデータに保存
                ]
            ]
        )
        
        logger.debug("Saved complete message to semantic cache")
    } catch {
        logger.warning("Failed to save to semantic cache: \(error.localizedDescription)")
    }
}
```

## 改善案2: システムプロンプトの保存

```swift
// ContextManager.swift に追加

func saveSystemPrompt(_ prompt: String, projectId: String) async throws {
    let promptData = """
        # システムプロンプト
        
        \(prompt)
        
        保存日時: \(ISO8601DateFormatter().string(from: Date()))
        """
    
    try await addTextToCache(
        text: promptData,
        conversationId: projectId,
        title: "システムプロンプト",
        metadata: [
            "type": "system_prompt",
            "project_id": projectId
        ]
    )
}
```

## 改善案3: 重要な指示の明示的マーキング

```swift
// 重要な指示を明示的に保存
func saveImportantInstruction(_ instruction: String, projectId: String) async throws {
    let instructionData = """
        # 重要な指示
        
        \(instruction)
        
        優先度: 最高
        保存日時: \(ISO8601DateFormatter().string(from: Date()))
        """
    
    try await addTextToCache(
        text: instructionData,
        conversationId: projectId,
        title: "重要指示: \(instruction.prefix(50))...",
        metadata: [
            "type": "important_instruction",
            "priority": "highest",
            "project_id": projectId
        ]
    )
}
```

## データの完全性保証

### 1. 二重保存による冗長性
- **ローカルファイル**: 完全なデータ（画像、ドキュメント含む）
- **semantic_cache**: テキスト + メタデータ（検索用）

### 2. 取得時の復元
```swift
func getCompleteMessage(contextItem: ContextItem) -> Message? {
    // メタデータから完全なデータを復元
    guard let fullDataJson = contextItem.metadata["full_data"],
          let data = fullDataJson.data(using: .utf8),
          let fullData = try? JSONDecoder().decode([String: Any].self, from: data) else {
        return nil
    }
    
    // Messageオブジェクトを復元
    // ...
}
```

## 推奨: 段階的実装

### フェーズ1（現在）
✅ メッセージテキストの保存
✅ 基本メタデータの保存
✅ 意味検索機能

### フェーズ2（次のステップ）
- [ ] thinking情報の保存
- [ ] ツール実行情報の保存
- [ ] 添付ファイルメタデータの保存

### フェーズ3（完全版）
- [ ] システムプロンプトの保存
- [ ] 重要指示の明示的マーキング
- [ ] 完全なデータ復元機能

## まとめ

**現状**: 
- ✅ テキストは完全に保存（劣化なし）
- ⚠️ 添付ファイルやthinkingは未保存

**保証**:
- semantic_cacheの`documents`フィールドに元のテキストが**そのまま**保存される
- 埋め込みベクトルは検索用のみで、元データは保持される
- ローカルファイルにも完全なデータが保存される（二重化）

**推奨対応**:
1. 現状でもテキストベースの指示は完全保存されている
2. より完全な保存が必要な場合は、上記の改善案を実装
3. 重要な指示は明示的に`saveImportantInstruction`で保存
