//
//  AppDelegate.swift
//  Amazon Bedrock Client for Mac
//
//  Created by Na, Sanghwa on 6/29/24.
//

import Cocoa
import Combine
import Foundation
import Logging
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    // UI components
    var settingsWindow: NSWindow?
    var localhostServer: LocalhostServer?

    // Use a lazy property for UpdateManager to ensure it's only initialized when needed
    private lazy var updateManager: UpdateManager? = {
        Logger(label: "AppDelegate").info("Initializing UpdateManager lazily")
        return UpdateManager.shared
    }()

    private var logger = Logger(label: "AppDelegate")

    // Track last update check time to prevent excessive checking
    private var lastUpdateCheckTime: Date?
    private let updateCheckInterval: TimeInterval = 3600 * 24  // 60 * 24 minutes minimum between checks

    // Flag to track if this is the first activation
    private var isFirstActivation = true

    @objc func newChat(_ sender: Any?) {
        // Trigger new chat creation through the coordinator
        AppCoordinator.shared.shouldCreateNewChat = true
    }

    @objc func deleteChat(_ sender: Any?) {
        // Set the flag in AppCoordinator to trigger deletion
        DispatchQueue.main.async {
            AppCoordinator.shared.shouldDeleteChat = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application finished launching")

        // Disable automatic window tabbing
        NSWindow.allowsAutomaticWindowTabbing = false

        // Start the localhost server for local communication
        startLocalhostServer()

        // Initialize Context Manager for persistent context management
        initializeContextManager()

        // Register for app activation notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // No update check here - only in applicationDidBecomeActive
        logger.info("App finished launching, update check will happen on first activation")
    }

    private func initializeContextManager() {
        Task {
            do {
                // プロジェクトが既に初期化されているか確認
                if ContextManager.shared.currentProjectId != nil {
                    logger.info("ContextManager already initialized")
                    return
                }

                // プロジェクト憲法を定義
                let constitution = ProjectConstitution(
                    projectId: "bedrock-mac-client",
                    projectName: "Amazon Bedrock Client for Mac",
                    description: "macOS向けのAmazon Bedrockクライアントアプリケーション",
                    corePrinciples: [
                        "ユーザーフレンドリーなインターフェース",
                        "高速なレスポンス",
                        "セキュアな認証とAWS統合",
                    ],
                    designPhilosophy: [
                        "SwiftUIによるモダンなUI設計",
                        "MVVMアーキテクチャパターンの採用",
                        "非同期処理の徹底（async/await）",
                        "MCPサーバーとのシームレスな統合",
                    ],
                    technicalStack: [
                        "Swift 5.9+",
                        "SwiftUI",
                        "AWS SDK for Swift",
                        "Combine",
                        "CoreData",
                        "Model Context Protocol (MCP)",
                    ],
                    codingStandards: [
                        "Swift APIデザインガイドラインに準拠",
                        "async/awaitを使用した非同期処理",
                        "適切なエラーハンドリング",
                        "@MainActorによるUI更新の保証",
                    ],
                    architectureNotes: """
                        MVVMアーキテクチャを採用し、ビジネスロジックとUI層を明確に分離。
                        MCPサーバーとの統合により、外部ツールやサービスとのシームレスな連携を実現。
                        semantic_cacheを使用した永続的コンテキスト管理により、長期セッションでも
                        プロジェクトの設計思想と重要な決定事項を保持。
                        """
                )

                // プロジェクトを初期化
                try await ContextManager.shared.initializeProject(constitution: constitution)
                logger.info(
                    "ContextManager initialized successfully with project: \(constitution.projectName)"
                )

            } catch {
                logger.warning("Failed to initialize ContextManager: \(error.localizedDescription)")
                logger.info("App will continue without persistent context management")
            }
        }
    }

    @objc func applicationDidBecomeActive(_ notification: Notification) {
        if isFirstActivation {
            // First activation after launch - do initial update check
            isFirstActivation = false
            logger.info("First activation - performing initial update check")
            performUpdateCheck()
        } else {
            // Regular activation - check if we should update based on time interval
            logger.info("App became active - checking if update check is needed")
            checkForUpdatesIfNeeded()
        }
    }

    private func checkForUpdatesIfNeeded() {
        let now = Date()

        // Check if enough time has passed since last update check
        if let lastCheck = lastUpdateCheckTime {
            let timeSinceLastCheck = now.timeIntervalSince(lastCheck)
            if timeSinceLastCheck < updateCheckInterval {
                logger.info(
                    "Skipping update check - only \(Int(timeSinceLastCheck)) seconds since last check"
                )
                return
            }
        }

        performUpdateCheck()
    }

    private func performUpdateCheck() {
        lastUpdateCheckTime = Date()
        logger.info("Performing update check")
        updateManager?.checkForUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application will terminate")

        // Remove notification observers
        NotificationCenter.default.removeObserver(self)

        // Only access updateManager if it was previously initialized
        if let manager = updateManager {
            manager.cleanup()
        }
    }

    private func startLocalhostServer() {
        logger.info("Starting localhost server")

        DispatchQueue.global(qos: .background).async {
            do {
                self.localhostServer = try LocalhostServer()
                try self.localhostServer?.start()
                self.logger.info("Localhost server started successfully")
            } catch {
                self.logger.error("Could not start localhost server: \(error)")
                print("Could not start localhost server: \(error)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Return false to keep app running when all windows are closed
        return false
    }

    @objc func openSettings(_ sender: Any?) {
        // Open the settings window using the singleton manager
        logger.info("Opening settings window")
        SettingsWindowManager.shared.openSettings(view: SettingsView())
    }
}
