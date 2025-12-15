//
//  SessionState.swift
//  ClaudeIsland
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    let sessionId: String
    let cwd: String
    let projectName: String
    var gitBranch: String?

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Todo Status (from ~/.claude/todos/)

    /// Current in-progress todo's activeForm text (e.g., "Adding compacting color")
    var currentTodoActiveForm: String?

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Permission Socket State

    /// Whether there's an open socket waiting for permission response
    /// This is distinct from phase - phase can be waitingForApproval but socket may be closed
    /// (e.g., if tool was auto-approved via terminal). Only show approval UI when socket is open.
    var hasPendingSocket: Bool

    /// The tool name for the pending socket (stored separately from phase for resilience)
    var pendingSocketToolName: String?

    /// The tool use ID for the pending socket
    var pendingSocketToolId: String?

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date
    var turnEndTime: Date?  // Set when turn completes (phase -> waitingForInput)

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        gitBranch: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil,
            turnStartTime: nil, turnInputTokens: nil, turnOutputTokens: nil, turnCacheReadTokens: nil,
            isThinking: false, lastThinkingText: nil, lastTextOutput: nil
        ),
        currentTodoActiveForm: String? = nil,
        needsClearReconciliation: Bool = false,
        hasPendingSocket: Bool = false,
        pendingSocketToolName: String? = nil,
        pendingSocketToolId: String? = nil,
        lastActivity: Date = Date(),
        createdAt: Date = Date(),
        turnEndTime: Date? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? GitUtils.getRepoName(cwd: cwd)
        self.gitBranch = gitBranch
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.currentTodoActiveForm = currentTodoActiveForm
        self.needsClearReconciliation = needsClearReconciliation
        self.hasPendingSocket = hasPendingSocket
        self.pendingSocketToolName = pendingSocketToolName
        self.pendingSocketToolId = pendingSocketToolId
        self.lastActivity = lastActivity
        self.createdAt = createdAt
        self.turnEndTime = turnEndTime
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    var needsAttention: Bool {
        phase.needsAttention
    }

    /// The active permission context, if any
    var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Project/branch label for the pill: "project/branch" or "project"
    var projectBranchLabel: String {
        if let branch = gitBranch {
            return "\(projectName)/\(branch)"
        }
        return projectName
    }

    /// Detail text (summary or first message), if any
    var titleDetail: String? {
        conversationInfo.summary ?? conversationInfo.firstUserMessage
    }

    /// Full display title for other uses
    var displayTitle: String {
        if let detail = titleDetail {
            return "\(projectBranchLabel): \(detail)"
        }
        return projectBranchLabel
    }

    /// Best hint for matching window title
    var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    /// Pending tool name if waiting for approval
    /// Prefers the socket-stored value (more reliable) over phase-derived value
    var pendingToolName: String? {
        pendingSocketToolName ?? activePermission?.toolName
    }

    /// Pending tool use ID
    /// Prefers the socket-stored value (more reliable) over phase-derived value
    var pendingToolId: String? {
        pendingSocketToolId ?? activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    var lastMessage: String? {
        conversationInfo.lastMessage
    }

    /// Last message role
    var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Whether the session can be interacted with
    var canInteract: Bool {
        phase.needsAttention
    }

    // MARK: - Live Activity Properties

    /// Currently running tool (if any) - for status display
    var currentToolInProgress: ToolInProgress? {
        // Return the most recent tool in progress
        toolTracker.inProgress.values.max(by: { $0.startTime < $1.startTime })
    }

    /// Active subagent/task description (if any)
    var activeSubagentDescription: String? {
        // Get the most recent active task's description
        guard let mostRecentTask = subagentState.activeTasks.values.max(by: { $0.startTime < $1.startTime }) else {
            return nil
        }
        return mostRecentTask.description
    }

    /// Active subagent type (e.g., "Explore", "Plan", "code-reviewer")
    var activeSubagentType: String? {
        guard let mostRecentTask = subagentState.activeTasks.values.max(by: { $0.startTime < $1.startTime }) else {
            return nil
        }
        return mostRecentTask.agentType
    }

    /// Whether there's an active subagent running
    var hasActiveSubagent: Bool {
        subagentState.hasActiveSubagent
    }

    /// Get the current subagent's most recent tool (if any)
    var subagentCurrentTool: SubagentToolCall? {
        guard let mostRecentTask = subagentState.activeTasks.values.max(by: { $0.startTime < $1.startTime }) else {
            return nil
        }
        // Return the most recent running tool, or just the last one
        return mostRecentTask.subagentTools.last(where: { $0.status == .running }) ?? mostRecentTask.subagentTools.last
    }

    // MARK: - Turn Stats

    /// When the current turn started
    var turnStartTime: Date? {
        conversationInfo.turnStartTime
    }

    /// Elapsed time for current turn (uses turnEndTime if turn completed)
    var turnElapsedSeconds: TimeInterval? {
        guard let start = turnStartTime else { return nil }
        let end = turnEndTime ?? Date()
        return end.timeIntervalSince(start)
    }

    /// Total tokens for current turn (input + output)
    var turnTotalTokens: Int? {
        let input = conversationInfo.turnInputTokens ?? 0
        let output = conversationInfo.turnOutputTokens ?? 0
        guard input > 0 || output > 0 else { return nil }
        return input + output
    }

    /// Output tokens for current turn
    var turnOutputTokens: Int? {
        conversationInfo.turnOutputTokens
    }

    /// Whether Claude is currently thinking
    var isThinking: Bool {
        conversationInfo.isThinking
    }

    /// The current thinking text (for status line display)
    var lastThinkingText: String? {
        conversationInfo.lastThinkingText
    }

    /// Most recent text output from assistant (for status line display)
    var lastTextOutput: String? {
        conversationInfo.lastTextOutput
    }

    /// Input tokens for current turn
    var turnInputTokens: Int? {
        conversationInfo.turnInputTokens
    }

    /// Formatted turn stats string (e.g., "12s · 1.5k")
    var turnStatsString: String? {
        var parts: [String] = []

        // Elapsed time (whole seconds)
        if let elapsed = turnElapsedSeconds, elapsed >= 1 {
            let secs = Int(elapsed)
            if secs < 60 {
                parts.append("\(secs)s")
            } else {
                let mins = secs / 60
                let remainingSecs = secs % 60
                parts.append("\(mins)m \(remainingSecs)s")
            }
        }

        // Total tokens (input + output combined)
        if let totalTokens = turnTotalTokens, totalTokens > 0 {
            parts.append(formatTokenCount(totalTokens))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Format token count for display
    private func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000.0)
        } else {
            return "\(tokens)"
        }
    }
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil, agentType: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            agentType: agentType,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var agentType: String?  // e.g., "Explore", "Plan", "code-reviewer"
    var subagentTools: [SubagentToolCall]
}
