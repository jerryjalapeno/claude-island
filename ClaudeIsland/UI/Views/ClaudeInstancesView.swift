//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run claude in terminal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(sortedInstances) { session in
                    InstanceRow(
                        session: session,
                        onFocus: { focusSession(session) },
                        onChat: { openChat(session) },
                        onArchive: { archiveSession(session) },
                        onApprove: { approveSession(session) },
                        onReject: { rejectSession(session) }
                    )
                    .id(session.stableId)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var spinnerPhase = 0
    @State private var isFocusAvailable = false
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeYOffset: CGFloat = 0
    @State private var swipeScale: CGFloat = 1.0
    @State private var isDragging = false
    @State private var secondsTick: Int = 0  // Force refresh for elapsed time

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
    private let secondsTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // Branch color palette - 12 perceptually-spaced colors for dark backgrounds
    private let branchColors: [Color] = [
        Color(hex: 0x60A5FA),  // Blue (217°)
        Color(hex: 0x818CF8),  // Indigo (239°)
        Color(hex: 0xA78BFA),  // Purple (258°)
        Color(hex: 0xE879F9),  // Magenta (292°)
        Color(hex: 0xF472B6),  // Pink (330°)
        Color(hex: 0xF87171),  // Coral (0°)
        Color(hex: 0xFB923C),  // Orange (27°)
        Color(hex: 0xFBBF24),  // Gold (43°)
        Color(hex: 0xA3E635),  // Lime (82°)
        Color(hex: 0x4ADE80),  // Green (142°)
        Color(hex: 0x2DD4BF),  // Teal (168°)
        Color(hex: 0x22D3EE),  // Cyan (189°)
    ]

    /// Get consistent color for a branch name based on hash
    private func branchColor(for branch: String) -> Color {
        let hash = abs(branch.hashValue)
        return branchColors[hash % branchColors.count]
    }

    private let actionWidth: CGFloat = 60
    private let swipeThreshold: CGFloat = 50

    // Fun gerund words for status display (inspired by Claude Code's whimsical loading messages)
    private let funGerunds = [
        "Spelunking", "Percolating", "Fermenting", "Conjuring", "Manifesting",
        "Synthesizing", "Orchestrating", "Crystallizing", "Brewing", "Weaving",
        "Cultivating", "Composing", "Sculpting", "Kindling", "Flourishing",
        "Blossoming", "Illuminating", "Harmonizing", "Radiating", "Cascading",
        "Resonating", "Emanating", "Unfurling", "Galvanizing", "Catalyzing",
        "Transmuting", "Distilling", "Incubating", "Germinating", "Pollinating",
        "Simmering", "Steeping", "Marinating", "Infusing", "Decanting",
        "Aerating", "Effervescing", "Bubbling", "Fizzing", "Permeating",
        "Diffusing", "Osmosing", "Coalescing", "Converging", "Amalgamating",
        "Fusing", "Melding", "Intertwining", "Entwining", "Braiding",
        "Knitting", "Crocheting", "Embroidering", "Quilting", "Stitching",
        "Forging", "Tempering", "Annealing", "Smelting", "Alloying",
        "Chiseling", "Carving", "Etching", "Engraving", "Embossing",
        "Glazing", "Burnishing", "Polishing", "Buffing", "Honing",
        "Whittling", "Shaping", "Molding", "Forming", "Fashioning",
        "Crafting", "Assembling", "Constructing", "Architecting", "Engineering",
        "Devising", "Inventing", "Innovating", "Pioneering", "Trailblazing",
        "Venturing", "Embarking", "Voyaging", "Navigating", "Charting",
        "Mapping", "Surveying", "Scouting", "Reconnoitering", "Investigating",
        "Sleuthing", "Deciphering", "Decoding", "Unraveling", "Untangling"
    ]

    /// Get a deterministic fun gerund based on session ID (stable per session)
    private func funGerund(for sessionId: String) -> String {
        let hash = abs(sessionId.hashValue)
        return funGerunds[hash % funGerunds.count]
    }

    /// Whether we're showing the approval UI
    /// Uses hasPendingSocket as the source of truth (not phase) because the socket
    /// being open means there's a real pending request that needs a response
    private var isWaitingForApproval: Bool {
        session.hasPendingSocket
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// Whether archive is allowed in current phase
    private var canArchive: Bool {
        session.phase == .idle || session.phase == .waitingForInput
    }

    /// Whether text output was recent enough to display (within 2 seconds)
    private var isTextOutputRecent: Bool {
        guard let outputTime = session.lastTextOutputTime else { return false }
        return Date().timeIntervalSince(outputTime) < 2.0
    }

    /// Progress for chat button reveal (0 to 1)
    private var chatRevealProgress: CGFloat {
        guard swipeOffset > 0 else { return 0 }
        return min(swipeOffset / actionWidth, 1.0)
    }

    /// Progress for archive button reveal (0 to 1)
    private var archiveRevealProgress: CGFloat {
        guard swipeOffset < 0 else { return 0 }
        return min(-swipeOffset / actionWidth, 1.0)
    }

    var body: some View {
        ZStack {
            // Chat preview that fades in as you swipe right (behind main content)
            if swipeOffset > 0 {
                chatPreview
                    .opacity(chatRevealProgress)
            }

            // Main content - fades out when swiping right, slides when swiping left
            mainContent
                .scaleEffect(swipeScale)
                .offset(x: swipeOffset < 0 ? swipeOffset : 0, y: swipeYOffset)  // Only offset when swiping left
                .opacity(swipeOffset > 0 ? (1.0 - chatRevealProgress * 0.9) : 1.0)  // Fade out when swiping right
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            isDragging = true
                            let translation = value.translation.width
                            // Add resistance at edges
                            if translation > 0 {
                                // Swiping right (reveal chat) - with resistance
                                swipeOffset = min(translation * 0.8, actionWidth + 30)
                            } else if canArchive {
                                // Swiping left (archive) - allow free movement
                                swipeOffset = translation
                            }
                        }
                        .onEnded { value in
                            isDragging = false
                            let translation = value.translation.width

                            if translation > swipeThreshold {
                                // Swiped right past threshold - complete fade and open chat
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeOffset = actionWidth + 40  // Fade out fully
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    onChat()
                                    // Reset after transition
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        swipeOffset = 0
                                    }
                                }
                            } else if translation < -swipeThreshold && canArchive {
                                // Swiped left past threshold - vanish into top-left
                                withAnimation(.easeIn(duration: 0.12)) {
                                    swipeOffset = -300
                                    swipeYOffset = -40
                                    swipeScale = 0.01
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                    onArchive()
                                }
                            } else {
                                // Didn't pass threshold - snap back
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    swipeOffset = 0
                                    swipeYOffset = 0
                                    swipeScale = 1.0
                                }
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .onHover { isHovered = $0 }
        .task {
            isFocusAvailable = await YabaiController.shared.isFocusAvailable()
        }
    }

    private var mainContent: some View {
        // Text content with state indicator in status line
        VStack(alignment: .leading, spacing: 2) {
            // Row 1: project/branch + title
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Project name (plain text, no pill) - matches compact blue
                Text(session.projectName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.compact)

                // Branch pill (hash-based color) - skip main/master as they're implied
                if let branch = session.gitBranch, branch != "main" && branch != "master" {
                    let color = branchColor(for: branch)
                    Text(branch)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.2))
                        .cornerRadius(4)
                }

                // Summary/detail as main text
                if let detail = session.titleDetail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, 20)  // Align with status text (14pt indicator + 6pt spacing)
            .padding(.trailing, 20)  // Match left padding for symmetry

            // Row 2: State indicator + activity status
            HStack(alignment: .center, spacing: 6) {
                stateIndicator
                    .frame(width: 14)

                // Show activity status with priority: approval > compacting > subagent > tool in progress > last message
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // 1. Waiting for approval - amber shimmer
                    HStack(spacing: 4) {
                        ShimmerText(
                            text: MCPToolFormatter.formatToolName(toolName),
                            font: .system(size: 11, weight: .medium),
                            color: TerminalColors.amber
                        )
                        if isInteractiveTool {
                            Text("Needs your input")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                } else if session.phase == .compacting {
                    // 1.5. Compacting - blue shimmer
                    ShimmerText(
                        text: "Compacting conversation...",
                        font: .system(size: 11, weight: .medium),
                        color: TerminalColors.compact
                    )
                } else if session.hasActiveSubagent {
                    // 2. Active subagent - show agent type + description/tool with shimmer
                    let agentLabel = session.activeSubagentType ?? "Agent"
                    if let desc = session.activeSubagentDescription {
                        if let subTool = session.subagentCurrentTool {
                            ShimmerText(
                                text: "\(agentLabel): \(desc) · \(MCPToolFormatter.formatToolName(subTool.name))",
                                font: .system(size: 11, weight: .medium)
                            )
                        } else {
                            ShimmerText(
                                text: "\(agentLabel): \(desc)",
                                font: .system(size: 11, weight: .medium)
                            )
                        }
                    } else if let subTool = session.subagentCurrentTool {
                        ShimmerText(
                            text: "\(agentLabel): \(MCPToolFormatter.formatToolName(subTool.name))",
                            font: .system(size: 11, weight: .medium)
                        )
                    } else {
                        ShimmerText(
                            text: "\(agentLabel) running...",
                            font: .system(size: 11, weight: .medium)
                        )
                    }
                } else if let tool = session.currentToolInProgress {
                    // 3. Tool currently running - show with shimmer + details
                    let toolDisplay = toolDisplayText(tool)
                    ShimmerText(
                        text: toolDisplay,
                        font: .system(size: 11, weight: .medium)
                    )
                } else if session.isThinking {
                    // 4. Actively thinking - show thinking text in italics
                    if let thinkingText = session.lastThinkingText {
                        let cleaned = thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ")
                        let truncated = cleaned.count > 60 ? String(cleaned.prefix(57)) + "..." : cleaned
                        ShimmerText(text: truncated, font: .system(size: 11, weight: .medium).italic())
                    } else {
                        ShimmerText(text: "Thinking...", font: .system(size: 11, weight: .medium).italic())
                    }
                } else if session.phase == .processing, let textOutput = session.lastTextOutput, isTextOutputRecent {
                    // 5. Recent text output - show for minimum 2 seconds
                    ShimmerText(
                        text: textOutput,
                        font: .system(size: 11, weight: .medium)
                    )
                } else if session.phase == .processing, let thinkingText = session.lastThinkingText {
                    // 6. Recent thinking (not actively thinking) - show in italics
                    let cleaned = thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                    let truncated = cleaned.count > 60 ? String(cleaned.prefix(57)) + "..." : cleaned
                    ShimmerText(text: truncated, font: .system(size: 11, weight: .medium).italic())
                } else if let todoActiveForm = session.currentTodoActiveForm {
                    // 7. Show current todo task from status line
                    ShimmerText(
                        text: "\(todoActiveForm)...",
                        font: .system(size: 11, weight: .medium)
                    )
                } else if session.phase == .processing {
                    // 8. Processing but no specific info - show fun transitional word
                    ShimmerText(
                        text: "\(funGerund(for: session.sessionId))...",
                        font: .system(size: 11, weight: .medium)
                    )
                } else if let role = session.lastMessageRole {
                    // 8. Fall back to last message (static - not processing)
                    switch role {
                    case "tool":
                        // Tool call - shimmer tool name + static input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                ShimmerText(
                                    text: MCPToolFormatter.formatToolName(toolName),
                                    font: .system(size: 11, weight: .medium),
                                    color: claudeOrange
                                )
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                    case "user":
                        // User message - prefix with "You:"
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                            if let msg = session.lastMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    default:
                        // Assistant message - just show text
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // Only show approval buttons when needed
                if isWaitingForApproval && isInteractiveTool {
                    TerminalButton(
                        isEnabled: true,
                        onTap: { onFocus() }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if isWaitingForApproval {
                    InlineApprovalButtons(
                        onApprove: onApprove,
                        onReject: onReject
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.trailing, 20)  // Match Row 1 trailing padding for symmetry

            // Row 3: Turn stats (time elapsed + tokens) - show when processing or just completed
            if session.turnElapsedSeconds != nil || session.turnTotalTokens != nil {
                HStack(spacing: 0) {
                    // Time elapsed
                    if let elapsed = session.turnElapsedSeconds, elapsed >= 1 {
                        Text(formatElapsedTime(elapsed))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                            .id(secondsTick)  // Force redraw when tick changes
                            .onReceive(secondsTimer) { _ in
                                if session.phase == .processing || session.phase == .compacting {
                                    secondsTick += 1
                                }
                            }
                    }

                    // Separator
                    if session.turnElapsedSeconds != nil && session.turnTotalTokens != nil {
                        Text(" · ")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }

                    // Animated token counter
                    if let tokens = session.turnTotalTokens, tokens > 0 {
                        AnimatedTokenCounter(value: tokens)
                    }
                }
                .padding(.leading, 20)  // Indent to align with status text
                .padding(.trailing, 20)  // Match other rows for symmetry
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered && !isDragging ? Color.white.opacity(0.06) : Color.black)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Single tap to focus terminal
            onFocus()
        }
    }

    /// Format elapsed time for display
    private func formatElapsedTime(_ elapsed: TimeInterval) -> String {
        let secs = Int(elapsed)
        if secs < 60 {
            return "\(secs)s"
        } else {
            let mins = secs / 60
            let remainingSecs = secs % 60
            return "\(mins)m \(remainingSecs)s"
        }
    }

    /// Format tool display text - uses lastMessage for input details since ToolInProgress doesn't store input
    private func toolDisplayText(_ tool: ToolInProgress) -> String {
        let name = MCPToolFormatter.formatToolName(tool.name)
        // Use lastMessage for input details when tool matches
        if session.lastToolName == tool.name, let input = session.lastMessage, !input.isEmpty {
            // Remove newlines and collapse whitespace for single-line display
            let singleLine = input.replacingOccurrences(of: "\n", with: " ")
                                  .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            switch tool.name {
            case "Bash":
                let truncated = singleLine.count > 35 ? String(singleLine.prefix(32)) + "..." : singleLine
                return "Bash(\(truncated))"
            default:
                let truncated = singleLine.count > 50 ? String(singleLine.prefix(47)) + "..." : singleLine
                return "\(name): \(truncated)"
            }
        }
        // For Bash with no command details, show a fun gerund instead of boring "Bash..."
        if tool.name == "Bash" {
            return "\(funGerund(for: session.sessionId))..."
        }
        return "\(name)..."
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.compact)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForInput:
            // Only show green dot if turn has truly ended (turnEndTime is set)
            // This matches the timer stop logic in SessionStore.processFileUpdate
            if session.turnEndTime != nil {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
            } else {
                // Still processing - show spinner
                Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(claudeOrange)
                    .onReceive(spinnerTimer) { _ in
                        spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                    }
            }
        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

    /// Chat preview that fades in when swiping right
    private var chatPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header with Claude logo and project name
            HStack(spacing: 8) {
                Image("ClaudeLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)

                Text(session.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                if let branch = session.gitBranch, branch != "main" && branch != "master" {
                    Text("/ \(branch)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(branchColor(for: branch).opacity(0.8))
                }

                Spacer()

                // Hint arrow
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(swipeOffset > swipeThreshold ? 0.8 : 0.4))
            }

            // Title/summary preview
            if let detail = session.titleDetail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
        )
    }

}

// MARK: - Swipe Action Button

/// Colored square button revealed during swipe
struct SwipeActionButton: View {
    let icon: String
    let color: Color
    let revealProgress: CGFloat  // 0 to 1, how much revealed
    let isPastThreshold: Bool
    var isLeading: Bool = true  // true = left side (chat), false = right side (archive)

    var body: some View {
        ZStack {
            color
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .scaleEffect(isPastThreshold ? 1.15 : 0.85 + (revealProgress * 0.15))
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: isLeading ? 0 : 12,
                bottomLeadingRadius: isLeading ? 0 : 12,
                bottomTrailingRadius: isLeading ? 12 : 0,
                topTrailingRadius: isLeading ? 12 : 0
            )
        )
        .opacity(revealProgress)
    }
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            if !disabled {
                action()
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(disabled ? .white.opacity(0.15) : (isHovered ? .white.opacity(0.8) : .white.opacity(0.4)))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered && !disabled ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .allowsHitTesting(!disabled)
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: Int) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
