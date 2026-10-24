// Renders an SVG to a square PNG with a transparent background through
// WebKit, which supports the gradients, clip paths and blur filters the app
// icon uses. The SVG must have a 1024x1024 viewBox.
//
// Usage: render-svg <in.svg> <out.png> <pixels>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), size > 0 else {
    FileHandle.standardError.write("usage: render-svg <in.svg> <out.png> <pixels>\n".data(using: .utf8)!)
    exit(2)
}
let pixels: Int = size
let svgURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

final class Snapshotter: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let filters finish painting before the snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            config.snapshotWidth = NSNumber(value: Double(pixels) / Double(scale))
            webView.takeSnapshot(with: config) { image, error in
                guard let image else {
                    FileHandle.standardError.write("render-svg: \(error?.localizedDescription ?? "snapshot failed")\n".data(using: .utf8)!)
                    exit(1)
                }
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                do {
                    try rep.representation(using: .png, properties: [:])!.write(to: outURL)
                    exit(0)
                } catch {
                    FileHandle.standardError.write("render-svg: \(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }
}

let app = NSApplication.shared
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
webView.setValue(false, forKey: "drawsBackground")
let snapshotter = Snapshotter()
webView.navigationDelegate = snapshotter
let svg = try String(contentsOf: svgURL, encoding: .utf8)
webView.loadHTMLString("""
    <html><head><style>
    html, body { margin: 0; padding: 0; background: transparent; overflow: hidden }
    svg { display: block; width: 1024px; height: 1024px }
    </style></head><body>\(svg)</body></html>
    """, baseURL: nil)
app.run()
