//
//  AppKitWindowFocuser.swift
//  ClaudeIsland
//
//  Focuses terminal windows using AppKit (no yabai required)
//

import AppKit
import Foundation
import os.log

/// Logger for AppKit window focuser
private let logger = Logger(subsystem: "com.claudeisland", category: "AppKitFocus")

/// Focuses windows using native macOS AppKit APIs
/// Falls back to this when yabai is not available
actor AppKitWindowFocuser {
    static let shared = AppKitWindowFocuser()

    private init() {}

    // MARK: - Public API

    /// Focus the terminal window for a Claude process
    /// Returns true if successfully focused
    func focusTerminal(forClaudePid claudePid: Int, workingDirectory: String? = nil) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // Get the working directory for window matching
        let cwd = workingDirectory ?? ProcessTreeBuilder.shared.getWorkingDirectory(forPid: claudePid)
        let projectName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }

        // Check if this is a tmux session
        if ProcessTreeBuilder.shared.isInTmux(pid: claudePid, tree: tree) {
            logger.debug("Claude \(claudePid) is in tmux, finding tmux client terminal")
            if let terminalPid = await findTmuxClientTerminal(forClaudePid: claudePid, tree: tree) {
                let mainAppPid = findMainAppPid(from: terminalPid, tree: tree)
                logger.debug("Found tmux client terminal PID \(mainAppPid)")
                return await activateApp(pid: pid_t(mainAppPid), windowHint: projectName)
            }
            logger.warning("Could not find tmux client terminal for Claude \(claudePid)")
            return false
        }

        // Find the terminal app PID by walking up the process tree
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: claudePid, tree: tree) else {
            logger.warning("Could not find terminal PID for Claude process \(claudePid)")
            return false
        }

        logger.debug("Found terminal PID \(terminalPid) for Claude \(claudePid)")

        // For VS Code and Electron apps, we need to find the main app process
        // Helper processes can't be activated directly
        let mainAppPid = findMainAppPid(from: terminalPid, tree: tree)
        logger.debug("Using main app PID \(mainAppPid) for activation")

        // Activate the app using NSRunningApplication
        return await activateApp(pid: pid_t(mainAppPid), windowHint: projectName)
    }

    /// Find the terminal running the tmux client for a Claude process
    private func findTmuxClientTerminal(forClaudePid claudePid: Int, tree: [Int: ProcessInfo]) async -> Int? {
        // First, find which tmux session this Claude process is in
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            // Get all panes and their PIDs
            let panesOutput = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}"
            ])

            // Find which pane contains our Claude process
            var targetSession: String?
            for line in panesOutput.components(separatedBy: "\n") where !line.isEmpty {
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 2, let panePid = Int(parts[1]) else { continue }

                // Check if Claude is a descendant of this pane
                if ProcessTreeBuilder.shared.isDescendant(targetPid: claudePid, ofAncestor: panePid, tree: tree) {
                    targetSession = parts[0].components(separatedBy: ":").first
                    break
                }
            }

            guard let session = targetSession else { return nil }

            // Find clients attached to this session
            let clientsOutput = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-clients", "-t", session, "-F", "#{client_pid}"
            ])

            // Find which terminal app owns the client
            for line in clientsOutput.components(separatedBy: "\n") {
                guard let clientPid = Int(line.trimmingCharacters(in: .whitespaces)), clientPid > 0 else { continue }

                // Walk up from client to find terminal app
                if let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: clientPid, tree: tree) {
                    return terminalPid
                }
            }
        } catch {
            logger.error("Error finding tmux client: \(error.localizedDescription)")
        }

        return nil
    }

    /// Find the main application PID by walking up from a helper process
    /// For VS Code: Code Helper → Electron (main app)
    private func findMainAppPid(from pid: Int, tree: [Int: ProcessInfo]) -> Int {
        var current = pid
        var mainPid = pid
        var depth = 0

        while current > 1 && depth < 10 {
            guard let info = tree[current] else { break }

            // Check if this looks like a main app process (not a helper)
            let command = info.command.lowercased()
            let isHelper = command.contains("helper")
            let isMainApp = command.contains("electron") ||
                            command.contains(".app/contents/macos/") && !isHelper

            if isMainApp || (!isHelper && TerminalAppRegistry.isTerminal(info.command)) {
                mainPid = current
            }

            current = info.ppid
            depth += 1
        }

        return mainPid
    }

    /// Focus a terminal by its PID directly
    func focusTerminal(pid: Int) async -> Bool {
        return await activateApp(pid: pid_t(pid))
    }

    /// Focus the terminal for a working directory (searches process tree)
    func focusTerminal(forWorkingDirectory workingDir: String) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // Find Claude process with matching cwd
        for (pid, info) in tree {
            guard info.command.lowercased().contains("claude") else { continue }

            if let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid),
               cwd == workingDir {
                // Found matching Claude process, find its terminal
                if let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) {
                    return await activateApp(pid: pid_t(terminalPid))
                }
            }
        }

        logger.warning("Could not find terminal for working directory: \(workingDir)")
        return false
    }

    // MARK: - Private

    /// Activate an application by PID using NSRunningApplication
    private func activateApp(pid: pid_t, windowHint: String? = nil) async -> Bool {
        // NSRunningApplication must be accessed on MainActor
        let appInfo = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                logger.warning("No running application found for PID \(pid)")
                return (name: nil as String?, bundleId: nil as String?)
            }
            return (name: app.localizedName, bundleId: app.bundleIdentifier)
        }

        guard let bundleId = appInfo.bundleId else {
            return false
        }

        let appName = appInfo.name ?? "Unknown"
        logger.debug("Activating app: \(appName) (PID: \(pid)), window hint: \(windowHint ?? "none")")

        // Use AppleScript to activate and optionally focus specific window
        return await activateViaAppleScript(bundleIdentifier: bundleId, windowHint: windowHint)
    }

    /// Activate an application using AppleScript, optionally focusing a specific window by title
    private func activateViaAppleScript(bundleIdentifier: String, windowHint: String? = nil) async -> Bool {
        // First try window-specific focus if we have a hint
        if let hint = windowHint {
            logger.info("Trying window-specific focus for: '\(hint)'")
            let windowScript = """
            tell application "System Events"
                tell process "Code"
                    set frontmost to true
                    repeat with w in windows
                        set winName to name of w
                        if winName contains "— \(hint)" or winName ends with "\(hint)" then
                            perform action "AXRaise" of w
                            keystroke "`" using control down
                            return "found"
                        end if
                    end repeat
                end tell
            end tell
            return "notfound"
            """

            if let result = runAppleScript(windowScript), result.contains("found") {
                logger.info("Successfully focused window matching '\(hint)'")
                return true
            }
            logger.info("Window-specific focus failed, falling back to simple activate")
        }

        // Fallback: just activate the app
        let simpleScript = """
        tell application id "\(bundleIdentifier)"
            activate
        end tell
        """

        let success = runAppleScript(simpleScript) != nil
        if success {
            logger.info("Activated \(bundleIdentifier)")
        }
        return success
    }

    /// Run an AppleScript and return output (nil if failed)
    private func runAppleScript(_ script: String) -> String? {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe() // Suppress errors

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            }
            return nil
        } catch {
            return nil
        }
    }
}
