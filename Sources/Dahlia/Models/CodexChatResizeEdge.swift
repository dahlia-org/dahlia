import AppKit

enum CodexChatResizeEdge: CaseIterable, Hashable {
    case top
    case left
    case right
    case topLeft
    case topRight

    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition = switch self {
        case .top:
            .top
        case .left:
            .left
        case .right:
            .right
        case .topLeft:
            .topLeft
        case .topRight:
            .topRight
        }
        return .frameResize(position: position, directions: .all)
    }

    var resizesTop: Bool {
        switch self {
        case .top, .topLeft, .topRight:
            true
        case .left, .right:
            false
        }
    }

    var resizesLeft: Bool {
        switch self {
        case .left, .topLeft:
            true
        case .top, .right, .topRight:
            false
        }
    }

    var resizesRight: Bool {
        switch self {
        case .right, .topRight:
            true
        case .top, .left, .topLeft:
            false
        }
    }
}
