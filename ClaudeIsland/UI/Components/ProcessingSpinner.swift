//
//  ProcessingSpinner.swift
//  ClaudeIsland
//
//  Animated symbol spinner and shimmer text for processing state
//

import Combine
import SwiftUI

struct ProcessingSpinner: View {
    @State private var phase: Int = 0

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let color = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange

    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(symbols[phase % symbols.count])
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            .frame(width: 12, alignment: .center)
            .onReceive(timer) { _ in
                phase = (phase + 1) % symbols.count
            }
    }
}

/// Text with animated shimmer/sweep effect - white highlight moves across colored text
struct ShimmerText: View {
    let text: String
    var font: Font = .system(size: 11, weight: .medium)
    var color: Color = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange default

    @State private var shimmerOffset: CGFloat = -1.0

    private let timer = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .foregroundColor(.clear)
            .overlay(
                GeometryReader { geometry in
                    // Base color
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .foregroundColor(color)

                    // Shimmer overlay - white highlight that sweeps across
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .foregroundColor(.white)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: max(0, shimmerOffset - 0.15)),
                                    .init(color: .white.opacity(0.8), location: shimmerOffset),
                                    .init(color: .clear, location: min(1, shimmerOffset + 0.15)),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            )
            .onReceive(timer) { _ in
                // Animate shimmer from left to right, then reset
                shimmerOffset += 0.02
                if shimmerOffset > 1.3 {
                    shimmerOffset = -0.3
                }
            }
    }
}

/// Animated counter that smoothly counts up to target value
struct AnimatedTokenCounter: View {
    let value: Int
    var font: Font = .system(size: 10, design: .monospaced)
    var color: Color = .white.opacity(0.3)

    @State private var displayValue: Double = 0
    @State private var targetValue: Double = 0

    // Timer at 20fps for slower, more visible counting
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect() // 20fps

    var body: some View {
        Text(formatTokenCount(Int(displayValue)))
            .font(font)
            .foregroundColor(color)
            .onChange(of: value) { oldValue, newValue in
                targetValue = Double(newValue)
            }
            .onAppear {
                displayValue = Double(value)
                targetValue = Double(value)
            }
            .onReceive(timer) { _ in
                // Smoothly interpolate towards target
                if abs(displayValue - targetValue) < 1 {
                    displayValue = targetValue
                } else {
                    let diff = targetValue - displayValue
                    // Slow counting: ~2 seconds to count up
                    // At 20fps = 40 frames over 2 seconds
                    // Small counts (<500): move ~15 tokens/frame
                    // Medium counts (500-2000): move ~40 tokens/frame
                    // Large counts (>2000): move 2% of diff/frame
                    let step: Double
                    if abs(diff) < 500 {
                        step = 15 * (diff > 0 ? 1 : -1)
                    } else if abs(diff) < 2000 {
                        step = 40 * (diff > 0 ? 1 : -1)
                    } else {
                        step = diff * 0.02
                    }
                    displayValue += step
                    // Don't overshoot
                    if (diff > 0 && displayValue > targetValue) || (diff < 0 && displayValue < targetValue) {
                        displayValue = targetValue
                    }
                }
            }
    }

    private func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk tok", Double(tokens) / 1000.0)
        } else {
            return "\(tokens) tok"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ProcessingSpinner()
            .frame(width: 30, height: 30)

        ShimmerText(text: "Fixing green dot logic...")

        ShimmerText(text: "Running build...", font: .system(size: 14, weight: .semibold))

        AnimatedTokenCounter(value: 1500)
    }
    .padding()
    .background(.black)
}
