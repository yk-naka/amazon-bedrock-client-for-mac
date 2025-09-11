//
//  EditMessageDialog.swift
//  Amazon Bedrock Client for Mac
//
//  Created by Assistant on 2025/01/11.
//

import SwiftUI

struct EditMessageDialog: View {
    @Binding var messageText: String
    let isUserMessage: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var editedText: String = ""

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text(isUserMessage ? "ユーザーメッセージを編集" : "アシスタントメッセージを編集")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            // Text editor
            VStack(alignment: .leading, spacing: 8) {
                Text("メッセージ内容:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextEditor(text: $editedText)
                    .font(.system(size: 14))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                colorScheme == .dark
                                    ? Color.gray.opacity(0.2) : Color.gray.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .frame(minHeight: 120)
            }

            // Warning for user messages
            if isUserMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("ユーザーメッセージを編集すると、このメッセージ以降の会話履歴がすべて削除され、編集後のメッセージで再度AIに回答させます。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                )
            }

            // Buttons
            HStack(spacing: 12) {
                Button("キャンセル") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("確定") {
                    messageText = editedText
                    onConfirm()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500, height: isUserMessage ? 350 : 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(NSColor.windowBackgroundColor) : Color.white)
        )
        .onAppear {
            editedText = messageText
        }
    }
}

#Preview {
    EditMessageDialog(
        messageText: .constant("サンプルメッセージテキスト"),
        isUserMessage: true,
        onConfirm: {},
        onCancel: {}
    )
}
