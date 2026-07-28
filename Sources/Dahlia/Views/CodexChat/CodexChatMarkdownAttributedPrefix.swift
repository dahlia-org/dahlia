import Foundation

extension CodexChatMarkdownTextDocument {
    static func reusablePrefixLength(
        in current: NSAttributedString,
        startingAt currentLocation: Int,
        and updated: NSAttributedString
    ) -> Int {
        let currentText = current.string as NSString
        let updatedText = updated.string as NSString
        let comparableLength = min(
            current.length - currentLocation,
            updated.length
        )
        var commonTextLength = 0
        while commonTextLength < comparableLength,
              currentText.character(at: currentLocation + commonTextLength)
              == updatedText.character(at: commonTextLength) {
            commonTextLength += 1
        }
        if commonTextLength > 0 {
            let finalSequenceRange = currentText.rangeOfComposedCharacterSequence(
                at: currentLocation + commonTextLength - 1
            )
            if NSMaxRange(finalSequenceRange) > currentLocation + commonTextLength {
                commonTextLength = finalSequenceRange.location - currentLocation
            }
        }

        var location = 0

        while location < commonTextLength {
            var currentRange = NSRange()
            var updatedRange = NSRange()
            let currentAttributes = current.attributes(
                at: currentLocation + location,
                effectiveRange: &currentRange
            )
            let updatedAttributes = updated.attributes(
                at: location,
                effectiveRange: &updatedRange
            )
            guard NSDictionary(dictionary: currentAttributes).isEqual(to: updatedAttributes) else {
                break
            }

            location = min(
                commonTextLength,
                NSMaxRange(currentRange) - currentLocation,
                NSMaxRange(updatedRange)
            )
        }

        return location
    }
}
