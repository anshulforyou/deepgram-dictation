// GrandmaDrag: drags a file the way Finder does, for drop zones that only take drag and drop.
//
//   GrandmaDrag <file> <x> <y>
//
// Opens a tiny window at (x, y) (global points, top-left origin like Hammerspoon), prints
// "ready", and starts a real file drag when the mouse goes down on it. Hammerspoon then moves the
// mouse to the drop zone and lets go. Prints "dropped" or "cancelled" when the drag ends and
// exits. It only receives the mouse, so it needs no permissions of its own. Gives up after 10 s.

import AppKit

final class DragView: NSView, NSDraggingSource {
    let file: URL
    init(file: URL, frame: NSRect) {
        self.file = file
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.98, green: 0.6, blue: 0.64, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: file.path)
        icon.size = NSSize(width: 48, height: 48)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        print(operation.isEmpty ? "cancelled" : "dropped")
        fflush(stdout)
        exit(operation.isEmpty ? 1 : 0)
    }
}

let args = CommandLine.arguments
guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]) else {
    FileHandle.standardError.write("usage: GrandmaDrag <file> <x> <y>\n".data(using: .utf8)!)
    exit(2)
}
let file = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: file.path) else {
    FileHandle.standardError.write("no such file: \(file.path)\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Cocoa measures from the bottom of the primary display; Hammerspoon from its top.
let primary = NSScreen.screens.first?.frame.height ?? 0
let size: CGFloat = 44
let rect = NSRect(x: x - size / 2, y: primary - y - size / 2, width: size, height: size)
let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
window.level = .popUpMenu
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = false
window.contentView = DragView(file: file, frame: NSRect(x: 0, y: 0, width: size, height: size))
window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
    print("ready")
    fflush(stdout)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    print("cancelled")
    fflush(stdout)
    exit(1)
}
app.run()
