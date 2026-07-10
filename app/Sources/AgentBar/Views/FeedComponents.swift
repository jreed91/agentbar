import SwiftUI

// MARK: - Palette
//
// The live-feed design (2a) is a dark-green phosphor terminal. These constants are the
// design's hex values, named by role so the views read intentionally. Colors that map to
// a feed status also have a `FeedStatus` accessor below.

extension Color {
    /// #080d0a — the terminal background.
    static let feedBG = Color(red: 8 / 255, green: 13 / 255, blue: 10 / 255)
    /// #46e07f — bright phosphor green (primary accent, keycaps, "LIVE").
    static let feedGreen = Color(red: 70 / 255, green: 224 / 255, blue: 127 / 255)
    /// #8affb0 — body text.
    static let feedText = Color(red: 138 / 255, green: 255 / 255, blue: 176 / 255)
    /// #c8ffd8 — brightest green, headings and project names.
    static let feedHead = Color(red: 200 / 255, green: 255 / 255, blue: 216 / 255)
    /// #5fbf83 — secondary green, sublines.
    static let feedSub = Color(red: 95 / 255, green: 191 / 255, blue: 131 / 255)
    /// #3a7a52 — dim green, timestamps and rules.
    static let feedDim = Color(red: 58 / 255, green: 122 / 255, blue: 82 / 255)
    /// #062012 — near-black green, text on bright-green fills.
    static let feedInk = Color(red: 6 / 255, green: 32 / 255, blue: 18 / 255)

    /// #ffb000 — amber, the `$` prompt sigil.
    static let feedAmber = Color(red: 255 / 255, green: 176 / 255, blue: 0 / 255)
    /// #ffce6b — amber text inside the command box.
    static let feedAmberText = Color(red: 255 / 255, green: 206 / 255, blue: 107 / 255)

    // Status accents (design `tagColor`).
    static let stPermission = Color(red: 255 / 255, green: 95 / 255, blue: 86 / 255)   // #ff5f56
    static let stQuestion = Color(red: 255 / 255, green: 176 / 255, blue: 0 / 255)     // #ffb000
    static let stWorking = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)     // #0a84ff
    static let stDone = Color(red: 70 / 255, green: 224 / 255, blue: 127 / 255)        // #46e07f

    // Mascot mood tints (design `la-mascot`).
    static let moodPermission = Color(red: 255 / 255, green: 107 / 255, blue: 95 / 255) // #ff6b5f
    static let moodQuestion = Color(red: 255 / 255, green: 206 / 255, blue: 107 / 255)  // #ffce6b

    // Keycap fills (design `kc-btn`).
    static let kbdDeny = Color(red: 58 / 255, green: 74 / 255, blue: 64 / 255)   // #3a4a40
    static let kbdFocus = Color(red: 42 / 255, green: 90 / 255, blue: 58 / 255)  // #2a5a3a
}

/// JetBrains Mono is the design's face; it is not bundled, so we fall back to the system
/// monospaced font at the design's sizes. One helper keeps every call site consistent.
func feedFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

extension FeedStatus {
    /// The uppercase tag text shown at the head of a feed line.
    var label: String {
        switch self {
        case .permission: return "PERMISSION"
        case .question: return "QUESTION"
        case .working: return "WORKING"
        case .done: return "DONE"
        case .error: return "ERROR"
        }
    }

    /// The accent color for the status tag and line dot.
    var color: Color {
        switch self {
        case .permission, .error: return .stPermission
        case .question: return .stQuestion
        case .working: return .stWorking
        case .done: return .stDone
        }
    }
}

extension FeedMood {
    /// The phosphor tint the mascot glows in (design `la-mascot[data-mood]`).
    var color: Color {
        switch self {
        case .permission: return .moodPermission
        case .question: return .moodQuestion
        default: return .feedGreen
        }
    }
}

// MARK: - Status tag

/// The small filled, uppercase status label that heads each feed line.
struct StatusTag: View {
    let status: FeedStatus

    var body: some View {
        Text(status.label)
            .font(feedFont(9.5, .bold))
            .tracking(0.5)
            .foregroundStyle(Color.feedInk)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(status.color)
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

// MARK: - Keycap button

/// A `[key] label` action styled like a terminal keycap. AgentBar is notify-only, so these
/// never resolve a prompt — they bring your terminal forward (focus) or clear the row
/// (dismiss). The design's `y allow / n deny` become honest focus/dismiss actions.
struct KeycapButton: View {
    enum Style { case primary, deny, focus }

    let key: String
    let label: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key)
                    .font(feedFont(10, .bold))
                    .foregroundStyle(keyForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(minWidth: 16)
                    .background(keyBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(keyShadow)
                            .frame(height: 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(label)
                    .font(feedFont(10.5))
                    .foregroundStyle(Color.feedSub)
            }
        }
        .buttonStyle(.plain)
    }

    private var keyForeground: Color {
        style == .primary ? .feedInk : .feedText
    }

    private var keyBackground: Color {
        switch style {
        case .primary: return .feedGreen
        case .deny: return .kbdDeny
        case .focus: return .kbdFocus
        }
    }

    private var keyShadow: Color {
        switch style {
        case .primary: return Color(red: 42 / 255, green: 138 / 255, blue: 79 / 255)  // #2a8a4f
        case .deny: return Color(red: 26 / 255, green: 42 / 255, blue: 32 / 255)      // #1a2a20
        case .focus: return Color(red: 20 / 255, green: 48 / 255, blue: 32 / 255)     // #143020
        }
    }
}

// MARK: - Mascot

/// The boxed ASCII mascot in the popover hero. Its face and glow reflect the overall mood.
struct MascotView: View {
    let mood: FeedMood

    var body: some View {
        Text(mood.bigFace)
            .font(feedFont(11, .bold))
            .lineSpacing(1)
            .foregroundStyle(mood.color)
            .shadow(color: mood.color.opacity(0.5), radius: 5)
            .fixedSize()
    }
}

// MARK: - CRT scanlines

/// A faint horizontal scanline pattern drawn over the whole popover for the CRT feel
/// (design's `repeating-linear-gradient`). Non-interactive.
struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            let line = Path(CGRect(x: 0, y: 0, width: size.width, height: 1))
            while y < size.height {
                context.fill(line.offsetBy(dx: 0, dy: y + 2), with: .color(.black.opacity(0.16)))
                y += 3
            }
        }
        .allowsHitTesting(false)
        .blendMode(.multiply)
    }
}

// MARK: - Dashed rule

/// The dashed separator drawn above each feed line (design `.la-line` top border).
struct DashedRule: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 1)
            .overlay(
                Rectangle()
                    .stroke(
                        Color.feedGreen.opacity(0.16),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                    )
            )
    }
}

// MARK: - LIVE badge

/// The blinking "LIVE" pill in the popover's title bar.
///
/// The blink is driven by `TimelineView`, not `withAnimation(...).repeatForever(...)`. In a
/// `MenuBarExtra(.window)` popover a repeating implicit animation leaks its transaction into
/// the hosting window and makes the whole popover bounce/jitter; a timeline just recomputes
/// opacity per tick with no animation transaction. The hard on/off step also matches the
/// design's `steps(1)` blink.
struct LiveBadge: View {
    private let period = 0.7

    var body: some View {
        TimelineView(.periodic(from: .now, by: period)) { context in
            let lit = Int(context.date.timeIntervalSinceReferenceDate / period) % 2 == 0
            Text("LIVE")
                .font(feedFont(9, .bold))
                .tracking(0.7)
                .foregroundStyle(Color.feedInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.feedGreen)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .opacity(lit ? 1 : 0.4)
        }
    }
}

/// A small triangular cluster of dots for the bottom-leading resize handle — more dots
/// toward the corner, reading as a grip.
struct ResizeGripShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dot = 1.8
        let step = 4.0
        let cols = [rect.minX, rect.minX + step, rect.minX + 2 * step]
        let rows = [rect.maxY - 2 * step, rect.maxY - step, rect.maxY]
        for (rowIndex, y) in rows.enumerated() {
            for x in cols.prefix(rowIndex + 1) {
                path.addEllipse(in: CGRect(x: x, y: y - dot, width: dot, height: dot))
            }
        }
        return path
    }
}

/// The three faux traffic-light dots used in the title bar.
struct TrafficDots: View {
    var body: some View {
        HStack(spacing: 6) {
            dot(Color(red: 255 / 255, green: 95 / 255, blue: 86 / 255))   // #ff5f56
            dot(Color(red: 255 / 255, green: 189 / 255, blue: 46 / 255))  // #ffbd2e
            dot(Color(red: 39 / 255, green: 201 / 255, blue: 63 / 255))   // #27c93f
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}
