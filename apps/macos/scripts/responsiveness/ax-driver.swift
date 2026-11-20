import ApplicationServices
import Foundation

// Drives one Dahlia window through Accessibility without moving the pointer or changing focus.
//   ax-driver <pid> scroll <scrollbar-index> <steps> <interval-ms> <round-trips>
//   ax-driver <pid> set <scrollbar-index> <value>
//   ax-driver <pid> press <text>
//   ax-driver <pid> select-row <text>
//   ax-driver <pid> type <text>          (first text area or field)
//   ax-driver <pid> buttons               (lists pressable labels)
let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: ax-driver <pid> scroll|set|press|select-row ...\n".utf8))
    exit(2)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 10)

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] { attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func windows() -> [AXUIElement] { attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
func ownLabel(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attr(element, $0) as? String }.joined(separator: " ")
}
func deepLabel(_ element: AXUIElement, _ depth: Int = 0) -> String {
    depth < 6 ? ([ownLabel(element)] + children(element).map { deepLabel($0, depth + 1) }).joined(separator: " ") : ""
}
func all(_ element: AXUIElement, _ depth: Int = 0, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
    guard depth < 16 else { return [] }
    return (match(element) ? [element] : []) + children(element).flatMap { all($0, depth + 1, where: match) }
}
func verticalScrollBars() -> [AXUIElement] {
    windows().flatMap { all($0) { attr($0, kAXRoleAttribute) as? String == "AXScrollBar" && attr($0, kAXOrientationAttribute) as? String == "AXVerticalOrientation" } }
}
func scrollBar(_ index: Int) -> AXUIElement {
    let bars = verticalScrollBars()
    guard index < bars.count else { print("scrollbar \(index) not found; \(bars.count) available"); exit(1) }
    return bars[index]
}

switch args[2] {
case "scroll":
    let bar = scrollBar(Int(args[3])!)
    let steps = Int(args[4])!, interval = UInt32(args[5])!, trips = Int(args[6])!
    let start = Date()
    for _ in 0 ..< trips {
        for reverse in [false, true] {
            for step in 0 ... steps {
                let value = Double(reverse ? steps - step : step) / Double(steps)
                AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, value as CFNumber)
                usleep(interval * 1000)
            }
        }
    }
    print(String(format: "scrolled %d steps x %d round trips in %.1fs", steps, trips, Date().timeIntervalSince(start)))
case "set":
    AXUIElementSetAttributeValue(scrollBar(Int(args[3])!), kAXValueAttribute as CFString, Double(args[4])! as CFNumber)
case "press":
    let needle = args[3]
    let hits = windows().flatMap { all($0) { element in
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String] ?? []).contains(kAXPressAction) && ownLabel(element).contains(needle)
    } }
    guard let hit = hits.first else { print("not found: \(needle)"); exit(1) }
    AXUIElementPerformAction(hit, kAXPressAction as CFString)
case "select-row":
    let needle = args[3]
    for outline in windows().flatMap({ all($0) { attr($0, kAXRoleAttribute) as? String == "AXOutline" } }) {
        for row in (attr(outline, kAXRowsAttribute) as? [AXUIElement] ?? []) where deepLabel(row).contains(needle) {
            AXUIElementSetAttributeValue(outline, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
            exit(0)
        }
    }
    print("not found: \(needle)")
    exit(1)
case "type":
    let areas = windows().flatMap { all($0) { ["AXTextArea", "AXTextField"].contains(attr($0, kAXRoleAttribute) as? String ?? "") } }
    guard let area = areas.first else { print("no text area"); exit(1) }
    AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, args[3] as CFString)
case "buttons":
    for element in windows().flatMap({ all($0) { attr($0, kAXRoleAttribute) as? String == "AXButton" } }) {
        print(ownLabel(element))
    }
default:
    print("unknown command \(args[2])")
    exit(2)
}
