#if DEBUG
import AppKit
import CoreVideo
import LiveKit
import ScreenCaptureKit
import VideoToolbox

/// `--color-selftest`: shows bars of known colours in the viewer's two renderers
/// (Metal and Apple's sample-buffer display), fed as video-range and full-range
/// frames, then reads the pixels back off the screen. Prints the results and quits.
@MainActor
enum ColorSelfTest {
    static let bars: [(name: String, rgb: (UInt8, UInt8, UInt8))] = [
        ("black", (0, 0, 0)), ("white", (255, 255, 255)), ("red", (255, 0, 0)),
        ("green", (0, 255, 0)), ("blue", (0, 0, 255)), ("grey", (128, 128, 128)),
    ]

    private static var window: NSWindow?

    static func runIfAsked() {
        guard CommandLine.arguments.contains("--color-selftest") else { return }
        Task { @MainActor in
            for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
                for mode in [VideoView.RenderMode.metal, .sampleBuffer] {
                    await measure(format: format, mode: mode)
                }
            }
            print("COLOR-SELFTEST done")
            exit(0)
        }
    }

    private static func measure(format: OSType, mode: VideoView.RenderMode) async {
        let width = 1200, height = 400
        let track = await LocalVideoTrack.createBufferTrack()
        let capturer = track.capturer as! BufferCapturer
        try? await track.start()

        let frame = NSRect(x: 200, y: 200, width: 600, height: 200)
        let win = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.backgroundColor = .black
        let view = VideoView(frame: NSRect(origin: .zero, size: frame.size))
        view.layoutMode = .fill
        view.renderMode = mode
        view.track = track
        win.contentView = view
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        window = win

        let buffer = makeBars(width: width, height: height, format: format)
        for _ in 0 ..< 40 {
            capturer.capture(buffer)
            try? await Task.sleep(for: .milliseconds(50))
        }

        let label = (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "video-range" : "full-range")
            + " / " + (mode == .metal ? "metal" : "sampleBuffer")
        if let image = await snapshot(win) {
            var line = "COLOR-SELFTEST \(label):"
            for (i, bar) in bars.enumerated() {
                let x = Int((Double(i) + 0.5) / Double(bars.count) * Double(image.width))
                let p = pixel(image, x: x, y: image.height / 2)
                line += "  \(bar.name)=\(p.0),\(p.1),\(p.2)"
            }
            print(line)
        } else {
            print("COLOR-SELFTEST \(label): no snapshot")
        }
        win.orderOut(nil)
        view.track = nil
        try? await track.stop()
    }

    /// Colour bars drawn in sRGB, converted to YUV by VideoToolbox (as the
    /// encoder/decoder would hand them over).
    private static func makeBars(width: Int, height: Int, format: OSType) -> CVPixelBuffer {
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &bgra)
        CVPixelBufferLockBaseAddress(bgra!, [])
        let base = CVPixelBufferGetBaseAddress(bgra!)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(bgra!)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let c = bars[x * bars.count / width].rgb
                let p = base + y * stride + x * 4
                p[0] = c.2; p[1] = c.1; p[2] = c.0; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(bgra!, [])
        CVBufferSetAttachment(bgra!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(bgra!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)

        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        CVBufferSetAttachment(out!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        VTSessionSetProperty(session!, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        VTPixelTransferSessionTransferImage(session!, from: bgra!, to: out!)
        return out!
    }

    private static func snapshot(_ win: NSWindow) async -> CGImage? {
        guard let content = try? await SCShareableContent.current,
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(win.windowNumber) })
        else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width) * 2
        config.height = Int(scWindow.frame.height) * 2
        config.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config)
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
#endif
