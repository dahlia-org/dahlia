import SwiftUI

struct MeetingProcessingFlowBounds: PreferenceKey {
    static let defaultValue: [MeetingProcessingFlow.Node: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [MeetingProcessingFlow.Node: Anchor<CGRect>],
        nextValue: () -> [MeetingProcessingFlow.Node: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
