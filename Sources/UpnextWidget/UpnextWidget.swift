import AppKit
import SwiftUI
import WidgetKit
// Under SwiftPM the shared code is a separate module. The Xcode widget target
// (UpnextWidget.xcodeproj) compiles those files straight into the extension.
#if canImport(UpnextCore)
import UpnextCore
#endif

@main
struct UpnextWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpdatesWidget()
    }
}

struct UpdatesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.widgetKind, provider: Provider()) { entry in
            UpdatesWidgetView(entry: entry)
        }
        .configurationDisplayName("Upnext")
        .description("Apps with updates waiting, and a one-click Update All.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: context.isPreview ? .placeholder : WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // Upnext pushes a reload whenever something changes; this is just a fallback.
        let entry = Entry(date: Date(), snapshot: WidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

// MARK: - Views

struct UpdatesWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private var updates: [WidgetSnapshot.Update] { entry.snapshot?.updates ?? [] }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            default: list(maxRows: family == .systemLarge ? 7 : 3)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(WidgetStore.openURL)
    }

    // Small: a count and a few icons.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                LogoMark(size: 22)
                Spacer()
                IconStack(updates: Array(updates.prefix(3)))
            }
            Spacer(minLength: 4)
            if entry.snapshot == nil {
                Text("Open Upnext")
                    .font(.headline)
                Text("to check for updates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if updates.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("Up to date")
                    .font(.headline)
                    .padding(.top, 2)
                lastChecked.font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("\(updates.count)")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(updates.count == 1 ? "update" : "updates")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // Medium / large: header with Update All, then one row per app.
    private func list(maxRows: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LogoMark(size: 20)
                Text(headline)
                    .font(.headline)
                Spacer()
                if updates.contains(where: { !$0.isInstalling }) {
                    Link(destination: WidgetStore.updateAllURL) {
                        Text("Update All")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    }
                }
            }

            if entry.snapshot == nil {
                Spacer()
                Text("Open Upnext once to check your apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if updates.isEmpty {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("All \(entry.snapshot?.appCount ?? 0) apps are up to date")
                        .font(.callout)
                }
                Spacer()
            } else {
                VStack(spacing: 6) {
                    ForEach(updates.prefix(maxRows)) { update in
                        UpdateRow(update: update)
                    }
                }
                if updates.count > maxRows {
                    Text("and \(updates.count - maxRows) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if family == .systemLarge, entry.snapshot != nil {
                lastChecked.font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headline: String {
        if entry.snapshot?.isChecking == true { return "Checking…" }
        switch updates.count {
        case 0: return "Upnext"
        case 1: return "1 update"
        default: return "\(updates.count) updates"
        }
    }

    @ViewBuilder
    private var lastChecked: some View {
        if let date = entry.snapshot?.lastChecked {
            Text("Checked ") + Text(date, style: .relative) + Text(" ago")
        }
    }
}

struct UpdateRow: View {
    let update: WidgetSnapshot.Update

    var body: some View {
        HStack(spacing: 8) {
            AppIconImage(bundleIdentifier: update.bundleIdentifier)
                .frame(width: 20, height: 20)
            Text(update.name)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 6)
            if update.isInstalling {
                Text("Updating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(update.currentVersion) → \(update.newVersion)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Overlapping icons of the first few apps with updates.
struct IconStack: View {
    let updates: [WidgetSnapshot.Update]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(updates) { update in
                AppIconImage(bundleIdentifier: update.bundleIdentifier)
                    .frame(width: 22, height: 22)
            }
        }
    }
}

struct AppIconImage: View {
    let bundleIdentifier: String

    var body: some View {
        if let image = NSImage(contentsOf: WidgetStore.iconFile(for: bundleIdentifier)) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
        }
    }
}

/// The app icon (Design/AppIcon.svg) drawn small: graphite tile, blue arrow
/// over a baseline.
struct LogoMark: View {
    let size: CGFloat

    static let glyphColor = Color(red: 0x6F / 255, green: 0xA8 / 255, blue: 0xF5 / 255)

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255),
                         Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x21 / 255)],
                startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .overlay(ArrowGlyph().stroke(Self.glyphColor, style: StrokeStyle(
                lineWidth: size * 0.053, lineCap: .round, lineJoin: .round)))
            .frame(width: size, height: size)
    }
}

/// The icon's glyph on a unit square (824-point tile coordinates / 824).
struct ArrowGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Icon tile spans 100…924 on the 1024 grid.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 100) / 824 * rect.width,
                    y: rect.minY + (y - 100) / 824 * rect.height)
        }
        var path = Path()
        path.move(to: p(512, 648)); path.addLine(to: p(512, 312))
        path.move(to: p(370, 454)); path.addLine(to: p(512, 312)); path.addLine(to: p(654, 454))
        path.move(to: p(364, 736)); path.addLine(to: p(660, 736))
        return path
    }
}
