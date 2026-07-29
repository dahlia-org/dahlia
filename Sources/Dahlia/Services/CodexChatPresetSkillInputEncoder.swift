import Foundation

struct CodexChatPresetSkillInputEncoder: Sendable {
    private let homeLocator: any CodexHomeLocating

    init(homeLocator: any CodexHomeLocating) {
        self.homeLocator = homeLocator
    }

    func appServerInputs(from inputs: [CodexAppServerInput]) throws -> [JSONValue] {
        var encodedInputs = inputs.map(Self.jsonInput)
        guard inputs.contains(where: Self.invokesPresetSkill) else {
            return encodedInputs
        }

        let skillFileURL = try BundledCodexPresetSkillInstaller.skillFileURL(in: homeLocator.homeURL())
        encodedInputs.append(.object([
            "name": .string(BundledCodexPresetSkillInstaller.skillName),
            "path": .string(skillFileURL.path),
            "type": .string("skill"),
        ]))
        return encodedInputs
    }

    private static func invokesPresetSkill(_ input: CodexAppServerInput) -> Bool {
        guard let text = input.textValue else { return false }
        let mention = "$\(BundledCodexPresetSkillInstaller.skillName)"
        var searchStart = text.startIndex

        while let range = text.range(of: mention, range: searchStart ..< text.endIndex) {
            if range.upperBound == text.endIndex || !isSkillNameCharacter(text[range.upperBound]) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isSkillNameCharacter(_ character: Character) -> Bool {
        if character == "-" || character == "_" {
            return true
        }
        return character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    private static func jsonInput(_ input: CodexAppServerInput) -> JSONValue {
        switch input {
        case let .text(text), let .imageMetadata(text):
            .object(["type": .string("text"), "text": .string(text)])
        case let .imageDataURI(uri):
            .object(["type": .string("image"), "url": .string(uri)])
        }
    }
}
