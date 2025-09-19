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
        VStack(spacing: 12) {
            // Compact Header
            HStack {
                Text(isUserMessage ? "編集" : "編集")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }

            // Compact Text editor
            TextEditor(text: $editedText)
                .font(.system(size: 13))
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            colorScheme == .dark
                                ? Color.gray.opacity(0.15) : Color.gray.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                )
                .frame(minHeight: 80, maxHeight: 120)

            // Compact Warning for user messages
            if isUserMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("編集後、以降の履歴が削除されます")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.orange.opacity(0.1))
                )
            }

            // Compact Buttons
            HStack(spacing: 8) {
                Button("キャンセル") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .font(.system(size: 12))

                Button("確定") {
                    messageText = editedText
                    onConfirm()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12))
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320, height: isUserMessage ? 200 : 170)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? Color(NSColor.windowBackgroundColor) : Color.white)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
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
