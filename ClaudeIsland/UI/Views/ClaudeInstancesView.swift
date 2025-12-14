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
    @State private var isDragging = false

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

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

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
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
            // Background action buttons revealed on swipe
            HStack(spacing: 0) {
                // Left action (swipe right to reveal): Chat
                // Only show when swiping right
                if swipeOffset > 0 {
                    SwipeActionButton(
                        icon: "bubble.left.fill",
                        color: Color.blue,
                        revealProgress: chatRevealProgress,
                        isPastThreshold: swipeOffset > swipeThreshold,
                        isLeading: true
                    )
                    .frame(width: max(swipeOffset, 0))
                }

                Spacer()

                // Right action (swipe left to reveal): Archive
                // Only show when swiping left
                if swipeOffset < 0 {
                    SwipeActionButton(
                        icon: "archivebox.fill",
                        color: canArchive ? Color.red : Color.gray.opacity(0.5),
                        revealProgress: archiveRevealProgress,
                        isPastThreshold: swipeOffset < -swipeThreshold,
                        isLeading: false
                    )
                    .frame(width: max(-swipeOffset, 0))
                }
            }

            // Main content that slides
            mainContent
                .offset(x: swipeOffset)
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            isDragging = true
                            let translation = value.translation.width
                            // Add resistance at edges
                            if translation > 0 {
                                // Swiping right (reveal chat)
                                swipeOffset = min(translation, actionWidth + 20)
                            } else {
                                // Swiping left (reveal archive)
                                if canArchive {
                                    swipeOffset = max(translation, -(actionWidth + 20))
                                } else {
                                    // Add more resistance if can't archive
                                    swipeOffset = max(translation * 0.3, -30)
                                }
                            }
                        }
                        .onEnded { value in
                            isDragging = false
                            let translation = value.translation.width

                            if translation > swipeThreshold {
                                // Swiped right past threshold - open chat
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    swipeOffset = 0
                                }
                                onChat()
                            } else if translation < -swipeThreshold && canArchive {
                                // Swiped left past threshold - archive
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    swipeOffset = 0
                                }
                                onArchive()
                            } else {
                                // Didn't pass threshold - snap back
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    swipeOffset = 0
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
        HStack(alignment: .center, spacing: 10) {
            // State indicator on left
            stateIndicator
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    // Project pill (neutral)
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)

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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }

                // Show tool call when waiting for approval, otherwise last activity
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
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
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        // Tool call - show tool name + input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
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
                    onChat: onChat,
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
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

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
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
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
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
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

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
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
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
