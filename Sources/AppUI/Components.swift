import AppKit
import DiagnosticsCore
import InputCore
import SessionCore
import SwiftUI

/// Small, reusable building blocks shared by the Host, Viewer and Loopback screens. They stick to stock AppKit /
/// SwiftUI styling (system colours, SF Symbols, `GroupBox`, `LabeledContent`) so the app looks native in light,
/// dark and increased-contrast modes without custom theming.

/// Monospaced, selectable identity fingerprint. Fingerprints are compared by eye across two screens, so they use
/// a fixed-width face and the full value is one click away (tooltip and copy).
struct FingerprintText: View {
    let display: String
    var full: String?
    var font: Font = .system(.body, design: .monospaced)

    var body: some View {
        HStack(spacing: 6) {
            Text(display)
                .font(font)
                .textSelection(.enabled)
                .help(full ?? display)
            CopyButton(value: full ?? display, label: "Copy fingerprint")
        }
    }
}

/// Copies a short, non-sensitive string (an address or a fingerprint) to the pasteboard.
struct CopyButton: View {
    let value: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? Symbols.granted : Symbols.copy)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Coloured capsule tag, e.g. "Tailscale" next to an address.
struct TagLabel: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// A status dot plus text, used in screen headers.
struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: pulsing ? 4 : 0))
            .accessibilityHidden(true)
    }
}

/// A single live metric with an icon, a value and a caption (Host live metrics, Loopback summary).
struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title3.monospacedDigit().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A row of the most important live numbers of a session.
struct LiveMetricsGrid: View {
    let metrics: MetricsSnapshot
    let role: MetricsRole

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            MetricTile(title: "RTT", value: MetricsFormat.rtt(metrics.rtt), symbol: Symbols.rtt)
            MetricTile(title: role == .host ? "Sent FPS" : "FPS", value: MetricsFormat.fps(metrics.fps), symbol: Symbols.fps)
            MetricTile(title: "Bitrate", value: MetricsFormat.bitrate(kbps: metrics.bitrateKbps), symbol: Symbols.bitrate)
            MetricTile(title: "Loss", value: MetricsFormat.percent(metrics.packetLossPercent), symbol: Symbols.loss)
            MetricTile(title: "Resolution", value: MetricsFormat.resolution(width: metrics.width, height: metrics.height),
                       symbol: Symbols.resolution)
            MetricTile(title: "Path", value: metrics.pathDescription.isEmpty ? MetricsFormat.placeholder : metrics.pathDescription,
                       symbol: Symbols.path)
        }
    }
}

/// The "Diagnostics" disclosure: every field of a `MetricsSnapshot`, grouped (persona "Troubleshooter").
struct DiagnosticsDisclosure: View {
    let metrics: MetricsSnapshot
    let role: MetricsRole
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            DiagnosticsGrid(metrics: metrics, role: role)
                .padding(.top, 6)
        } label: {
            Label("Diagnostics", systemImage: Symbols.diagnostics)
        }
    }
}

/// Grid body shared by the disclosure and the Viewer's diagnostics popover.
struct DiagnosticsGrid: View {
    let metrics: MetricsSnapshot
    let role: MetricsRole

    var body: some View {
        let sections = DiagnosticsRows.sections(for: metrics, role: role)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(sections) { section in
                GridRow {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .gridCellColumns(2)
                        .padding(.top, section.id == sections.first?.id ? 0 : 8)
                }
                ForEach(section.rows) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Explains one macOS privacy permission and links to the real system prompt / System Settings pane.
/// SwiftDesk never imitates or obscures the system UI (PRD §7); these buttons only ask macOS to show it.
struct PermissionCard: View {
    let title: String
    let symbol: String
    let granted: Bool
    let explanation: String
    var missingConsequence: String
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Label(granted ? "Allowed" : "Not allowed",
                          systemImage: granted ? Symbols.granted : Symbols.missing)
                        .foregroundStyle(granted ? Color.green : Color.orange)
                        .font(.callout.weight(.medium))
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    Text(missingConsequence)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Request Access…", action: request)
                        Button("Open System Settings", action: openSettings)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// A coloured notice row (problem / info / identity change).
struct NoticeBanner: View {
    let symbol: String
    let message: String
    var color: Color = .orange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// One-line explanation of the macOS paste-privacy prompt (or block), with a button to the Privacy & Security pane
/// where SwiftDesk can be set to Allow under "Paste from Other Apps".
struct PasteboardAccessHint: View {
    let message: String
    /// macOS refuses reads (orange); otherwise it only may ask (secondary).
    let blocked: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: blocked ? Symbols.warning : Symbols.lock)
                .foregroundStyle(blocked ? Color.orange : Color.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Settings…") { PasteboardAccessBehavior.openSettings() }
                .controlSize(.small)
        }
    }
}

/// The Send Keys items (0.1.7), grouped like the macOS shortcut settings. Shared by the stream toolbar's menu, the
/// Session menu and the menu-bar panel. Each item shows its keys as a subtitle; none installs a key equivalent (they
/// are combinations this Mac reserves, and a menu shortcut must never steal them from the remote Mac).
struct SendKeysMenuItems: View {
    let send: (SystemShortcut) -> Void

    var body: some View {
        ForEach(Array(SystemShortcut.Group.allCases.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(SystemShortcut.shortcuts(in: group)) { shortcut in
                Button {
                    send(shortcut)
                } label: {
                    Text(ShortcutPresentation.menuTitle(shortcut))
                    Text(shortcut.keysDescription)
                }
                .accessibilityLabel("\(shortcut.title), \(shortcut.keysDescription)")
            }
        }
    }
}

/// Accessibility is missing (or the keyboard tap was refused) while "Send system shortcuts" is on: what to do, with
/// the system prompt and a link to Privacy & Security › Accessibility.
struct ShortcutPermissionHint: View {
    let message: String
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Symbols.warning)
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Allow…", action: request)
                .controlSize(.small)
            Button("Open Settings…", action: openSettings)
                .controlSize(.small)
        }
    }
}
