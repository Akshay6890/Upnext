import AppKit
import UpnextCore
import WidgetKit

/// Writes what the widget should show and asks WidgetKit to redraw it.
@MainActor
enum WidgetPublisher {
    private static var lastPublished: WidgetSnapshot?

    static func publish(from model: AppModel) {
        let snapshot = WidgetSnapshot(
            updates: model.updates.compactMap { row in
                guard let update = row.update else { return nil }
                return WidgetSnapshot.Update(
                    name: row.app.name,
                    bundleIdentifier: row.app.bundleIdentifier,
                    currentVersion: row.app.shortVersion.isEmpty ? row.app.buildVersion : row.app.shortVersion,
                    newVersion: update.newVersion,
                    isInstalling: model.installStates[row.id]?.isWorking == true)
            },
            appCount: model.checkableCount,
            isChecking: model.isChecking,
            lastChecked: model.lastChecked)

        guard snapshot != lastPublished else { return }
        lastPublished = snapshot

        for row in model.updates { writeIconIfNeeded(for: row.app) }
        do {
            try WidgetStore.save(snapshot)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.widgetKind)
        } catch {
            NSLog("Upnext: couldn't write widget snapshot: \(error)")
        }
    }

    /// Small PNG icons, so the sandboxed widget doesn't need to read app bundles.
    private static func writeIconIfNeeded(for app: InstalledApp) {
        let file = WidgetStore.iconFile(for: app.bundleIdentifier)
        let iconDate = (try? app.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let fileDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let fileDate, let iconDate, fileDate >= iconDate { return }

        let size = 64
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: file, options: .atomic)
    }
}
