//
//  YabaiController.swift
//  ClaudeIsland
//
//  High-level yabai window management controller
//

import Foundation
import os.log

/// Logger for yabai controller
private let logger = Logger(subsystem: "com.claudeisland", category: "YabaiController")

/// Controller for yabai window management
actor YabaiController {
    static let shared = YabaiController()

    private init() {}

    // MARK: - Public API

    /// Focus the terminal window for a given Claude PID
    /// Uses yabai if available, falls back to AppKit
    func focusWindow(forClaudePid claudePid: Int) async -> Bool {
        // Try yabai first for tmux sessions (more precise window targeting)
        if await WindowFinder.shared.isYabaiAvailable() {
            let windows = await WindowFinder.shared.getAllWindows()
            let tree = ProcessTreeBuilder.shared.buildTree()

            // Check if this is a tmux session
            if ProcessTreeBuilder.shared.isInTmux(pid: claudePid, tree: tree) {
                let result = await focusTmuxInstance(claudePid: claudePid, tree: tree, windows: windows)
                if result {
                    return true
                }
            }

            // Try direct terminal focus via yabai
            if let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: claudePid, tree: tree) {
                if let window = windows.first(where: { $0.pid == terminalPid }) {
                    let result = await WindowFocuser.shared.focusWindow(id: window.id)
                    if result {
                        return true
                    }
                }
            }
        }

        // Fall back to AppKit (works without yabai)
        logger.debug("Falling back to AppKit focus for PID \(claudePid)")
        return await AppKitWindowFocuser.shared.focusTerminal(forClaudePid: claudePid)
    }

    /// Focus the terminal window for a given working directory
    /// Uses yabai if available, falls back to AppKit
    func focusWindow(forWorkingDirectory workingDirectory: String) async -> Bool {
        // Try yabai first
        if await WindowFinder.shared.isYabaiAvailable() {
            let result = await focusWindow(forWorkingDir: workingDirectory)
            if result {
                return true
            }
        }

        // Fall back to AppKit
        logger.debug("Falling back to AppKit focus for cwd: \(workingDirectory)")
        return await AppKitWindowFocuser.shared.focusTerminal(forWorkingDirectory: workingDirectory)
    }

    /// Check if window focusing is available (always true now with AppKit fallback)
    func isFocusAvailable() async -> Bool {
        return true
    }

    // MARK: - Private Implementation

    private func focusTmuxInstance(claudePid: Int, tree: [Int: ProcessInfo], windows: [YabaiWindow]) async -> Bool {
        // Find the tmux target for this Claude process
        guard let target = await TmuxController.shared.findTmuxTarget(forClaudePid: claudePid) else {
            return false
        }

        // Switch to the correct pane
        _ = await TmuxController.shared.switchToPane(target: target)

        // Find terminal for this specific tmux session
        if let terminalPid = await findTmuxClientTerminal(forSession: target.session, tree: tree, windows: windows) {
            return await WindowFocuser.shared.focusTmuxWindow(terminalPid: terminalPid, windows: windows)
        }

        return false
    }

    private func focusWindow(forWorkingDir workingDir: String) async -> Bool {
        let windows = await WindowFinder.shared.getAllWindows()
        let tree = ProcessTreeBuilder.shared.buildTree()

        return await focusTmuxPane(forWorkingDir: workingDir, tree: tree, windows: windows)
    }

    // MARK: - Tmux Helpers

    private func findTmuxClientTerminal(forSession session: String, tree: [Int: ProcessInfo], windows: [YabaiWindow]) async -> Int? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return nil }

        do {
            // Get clients attached to this specific session
            let output = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-clients", "-t", session, "-F", "#{client_pid}"
            ])

            let clientPids = output.components(separatedBy: "\n")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

            let windowPids = Set(windows.map { $0.pid })

            for clientPid in clientPids {
                var currentPid = clientPid
                while currentPid > 1 {
                    guard let info = tree[currentPid] else { break }
                    if isTerminalProcess(info.command) && windowPids.contains(currentPid) {
                        return currentPid
                    }
                    currentPid = info.ppid
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Check if command is a terminal (nonisolated helper to avoid MainActor access)
    private nonisolated func isTerminalProcess(_ command: String) -> Bool {
        let terminalCommands = ["Terminal", "iTerm", "iTerm2", "Alacritty", "kitty", "WezTerm", "wezterm-gui", "Hyper"]
        return terminalCommands.contains { command.contains($0) }
    }

    private func focusTmuxPane(forWorkingDir workingDir: String, tree: [Int: ProcessInfo], windows: [YabaiWindow]) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }

        do {
            let panesOutput = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}"
            ])

            let panes = panesOutput.components(separatedBy: "\n").filter { !$0.isEmpty }

            for pane in panes {
                let parts = pane.components(separatedBy: "|")
                guard parts.count >= 2,
                      let panePid = Int(parts[1]) else { continue }

                let targetString = parts[0]

                // Check if this pane has a Claude child with matching cwd
                for (pid, info) in tree {
                    let isChild = ProcessTreeBuilder.shared.isDescendant(targetPid: pid, ofAncestor: panePid, tree: tree)
                    let isClaude = info.command.lowercased().contains("claude")

                    guard isChild, isClaude else { continue }

                    guard let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid),
                          cwd == workingDir else { continue }

                    // Found matching pane - switch to it
                    if let target = TmuxTarget(from: targetString) {
                        _ = await TmuxController.shared.switchToPane(target: target)

                        // Focus the terminal window for this session
                        if let terminalPid = await findTmuxClientTerminal(forSession: target.session, tree: tree, windows: windows) {
                            return await WindowFocuser.shared.focusTmuxWindow(terminalPid: terminalPid, windows: windows)
                        }
                    }
                    return true
                }
            }
        } catch {
            return false
        }

        return false
    }
}
