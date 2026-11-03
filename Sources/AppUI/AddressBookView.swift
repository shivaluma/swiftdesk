import AppKit
import SessionCore
import SwiftUI
import WireProtocol

/// The connect screen's saved Hosts (0.1.8, AnyDesk-style home): a grid of cards, each with the picture of the
/// remote screen from the last session, the Host's name, address and when it was last used. One click connects;
/// the context menu renames, adds to / removes from Favorites, copies the address or removes the entry.
///
/// Connecting from a card is exactly like typing its address: the address's pinned fingerprint applies, otherwise
/// the verification sheet appears, and the Host still approves (or checks the password).
struct SavedHostGrid: View {
    let entries: [SavedHost]
    let viewer: ViewerSession
    let connect: (SavedHost, SavedHostAddress?) -> Void
    let rename: (SavedHost) -> Void

    private let columns = [GridItem(.adaptive(minimum: 172, maximum: 260), spacing: 14, alignment: .top)]

    var body: some View {
        // Captions such as "Connected 5 min ago" refresh once a minute.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(entries) { entry in
                    SavedHostCard(entry: entry,
                                  thumbnailURL: viewer.thumbnailURL(for: entry),
                                  pinState: viewer.pinState(of: entry),
                                  now: context.date,
                                  connect: { address in connect(entry, address) },
                                  rename: { rename(entry) },
                                  toggleFavorite: { viewer.setFavorite(id: entry.id, !entry.isFavorite) },
                                  remove: { viewer.removeSavedHost(id: entry.id) })
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// One saved Host. A plain button (keyboard and VoiceOver activate it) with a hover highlight.
struct SavedHostCard: View {
    let entry: SavedHost
    let thumbnailURL: URL?
    let pinState: SavedHostPinState
    let now: Date
    let connect: (SavedHostAddress?) -> Void
    let rename: () -> Void
    let toggleFavorite: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        Button { connect(nil) } label: {
            VStack(alignment: .leading, spacing: 8) {
                SavedHostThumbnail(entry: entry, url: thumbnailURL)
                    .overlay(alignment: .topTrailing) {
                        if entry.isFavorite {
                            Image(systemName: Symbols.favorite)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.yellow)
                                .padding(5)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(6)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay {
                        if hovering {
                            Image(systemName: Symbols.connect)
                                .font(.system(size: 30, weight: .regular))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                                .transition(.opacity)
                                .accessibilityHidden(true)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        pinBadge
                    }
                    Text(AddressBookPresentation.addressLine(entry, defaultPort: WireConstants.defaultPort))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(AddressBookPresentation.lastConnected(entry.lastConnectedAt, now: now))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu { menu }
        .help("Connect to \(entry.displayName)")
        .accessibilityLabel(AddressBookPresentation.accessibilityLabel(entry, defaultPort: WireConstants.defaultPort,
                                                                       now: now))
        .accessibilityHint("Connects. More actions in the context menu.")
    }

    @ViewBuilder
    private var pinBadge: some View {
        if let caption = AddressBookPresentation.pinCaption(pinState) {
            let mismatch = pinState == .pinnedToOtherIdentity
            Image(systemName: mismatch ? Symbols.identityChanged : Symbols.trusted)
                .font(.caption)
                .foregroundStyle(mismatch ? Color.red : Color.green)
                .help(caption)
                .accessibilityLabel(caption)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button { connect(nil) } label: { Label("Connect", systemImage: Symbols.connect) }
        if entry.addresses.count > 1 {
            Menu("Connect Via") {
                ForEach(entry.addresses, id: \.self) { address in
                    Button(address.endpoint) { connect(address) }
                }
            }
        }
        Divider()
        Button(action: rename) { Label("Rename…", systemImage: Symbols.rename) }
        Button(action: toggleFavorite) {
            if entry.isFavorite {
                Label("Remove from Favorites", systemImage: Symbols.unfavorite)
            } else {
                Label("Add to Favorites", systemImage: Symbols.favorite)
            }
        }
        Button {
            guard let address = entry.primaryAddress else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address.shareable(defaultPort: WireConstants.defaultPort), forType: .string)
        } label: {
            Label("Copy Address", systemImage: Symbols.copy)
        }
        Divider()
        Button(role: .destructive, action: remove) { Label("Remove", systemImage: Symbols.trash) }
    }
}

/// The remote screen as it looked at the end of the last session, or a tinted placeholder with the Host's initials.
struct SavedHostThumbnail: View {
    let entry: SavedHost
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .task(id: cacheKey) { image = await SavedHostThumbnailCache.shared.image(for: cacheKey, url: url) }
        .accessibilityHidden(true)
    }

    /// A new thumbnail (or none) is a new key, so the card reloads exactly when the file changed.
    private var cacheKey: String {
        guard let updated = entry.thumbnailUpdatedAt, url != nil else { return "\(entry.id.uuidString)-none" }
        return "\(entry.id.uuidString)-\(updated.timeIntervalSinceReferenceDate)"
    }

    private var placeholder: some View {
        let hue = Self.hue(for: entry.fingerprintHex)
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.75),
                                    Color(hue: hue, saturation: 0.6, brightness: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 4) {
                Image(systemName: Symbols.savedHostPlaceholder)
                    .font(.system(size: 26, weight: .light))
                Text(AddressBookPresentation.initials(entry.displayName))
                    .font(.system(.callout, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.92))
        }
    }

    /// A stable colour per identity, so the same Mac keeps its colour across renames.
    static func hue(for fingerprintHex: String) -> Double {
        let byte = TrustedHostStore.data(fromHex: String(fingerprintHex.prefix(2)))?.first ?? 0
        return Double(byte) / 255.0
    }
}

/// Decoded thumbnails by `SavedHostThumbnail.cacheKey`, so scrolling or re-rendering the connect screen never
/// re-reads a file. The file is read off the main actor; at most ~20 small images live here.
@MainActor
final class SavedHostThumbnailCache {
    static let shared = SavedHostThumbnailCache()
    private var images: [String: NSImage] = [:]

    func image(for key: String, url: URL?) async -> NSImage? {
        if let cached = images[key] { return cached }
        guard let url else { return nil }
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        if images.count > 64 { images.removeAll() }
        images[key] = image
        return image
    }
}
