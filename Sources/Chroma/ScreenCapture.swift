import AppKit
import ScreenCaptureKit

/// A full-resolution still of one display, taken just before the overlay appears.
struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
    let buffer: PixelBuffer
    /// Pixels per point on this display.
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

enum ScreenCapture {
    enum Failure: Error { case noPermission, nothingCaptured }

    /// Captures every connected display without Chroma's own windows.
    static func captureAllScreens() async throws -> [ScreenSnapshot] {
        guard CGPreflightScreenCaptureAccess() else { throw Failure.noPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let screens = await MainActor.run {
            NSScreen.screens.map { (id: $0.displayID, size: $0.frame.size, scale: $0.backingScaleFactor) }
        }

        let captures = try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage, PixelBuffer)?.self) { group in
            for display in content.displays {
                guard let screen = screens.first(where: { $0.id == display.displayID }) else { continue }
                group.addTask {
                    let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = Int(screen.size.width * screen.scale)
                    config.height = Int(screen.size.height * screen.scale)
                    config.showsCursor = false
                    config.captureResolution = .best
                    config.colorSpaceName = CGColorSpace.sRGB
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard let buffer = PixelBuffer(image: image) else { return nil }
                    return (display.displayID, image, buffer)
                }
            }
            var results: [(CGDirectDisplayID, CGImage, PixelBuffer)] = []
            for try await capture in group {
                if let capture { results.append(capture) }
            }
            return results
        }
        let snapshots = await MainActor.run {
            captures.compactMap { id, image, buffer in
                NSScreen.screens.first { $0.displayID == id }.map { ScreenSnapshot(screen: $0, image: image, buffer: buffer) }
            }
        }
        guard !snapshots.isEmpty else { throw Failure.nothingCaptured }
        return snapshots
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
