import CoreGraphics
import Foundation

// Sends trackpad-like pixel scroll events straight to one process, without moving the pointer or using Accessibility.
//   wheel-driver <pid> <x> <y> <pixels-per-event> <events> <interval-ms> <round-trips>
// x and y are global screen points (top-left origin) inside the view to scroll.
let args = CommandLine.arguments
guard args.count == 8, let pid = pid_t(args[1]), let x = Double(args[2]), let y = Double(args[3]),
      let step = Int32(args[4]), let events = Int(args[5]), let interval = UInt32(args[6]), let trips = Int(args[7]) else {
    FileHandle.standardError.write(Data("usage: wheel-driver <pid> <x> <y> <pixels> <events> <interval-ms> <round-trips>\n".utf8))
    exit(2)
}
let start = Date()
for _ in 0 ..< trips {
    for direction: Int32 in [-1, 1] {
        for _ in 0 ..< events {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: direction * step, wheel2: 0, wheel3: 0) else { exit(1) }
            event.location = CGPoint(x: x, y: y)
            event.postToPid(pid)
            usleep(interval * 1000)
        }
    }
}
print(String(format: "sent %d events x %d round trips in %.1fs", events * 2, trips, Date().timeIntervalSince(start)))
