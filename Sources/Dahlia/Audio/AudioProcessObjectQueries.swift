import CoreAudio
import Foundation

struct AudioProcessObjectQueries: Sendable {
    struct QueryFailure: Error, Equatable, Sendable, CustomStringConvertible {
        enum Operation: String, Sendable {
            case readData = "read-data"
            case readDataSize = "read-data-size"
        }

        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let operation: Operation
        let status: OSStatus

        var description: String {
            "objectID=\(objectID) selector=\(Self.fourCharacterCode(selector)) operation=\(operation.rawValue) osStatus=\(status)"
        }

        private static func fourCharacterCode(_ value: UInt32) -> String {
            let characters = (0 ..< 4).map { offset in
                Character(UnicodeScalar((value >> UInt32((3 - offset) * 8)) & 0xFF) ?? "?")
            }
            return String(characters)
        }
    }

    func processObjectIDs() -> Result<[AudioObjectID], QueryFailure> {
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.globalAddress(kAudioHardwarePropertyProcessObjectList)
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr else {
            return .failure(QueryFailure(
                objectID: objectID,
                selector: address.mSelector,
                operation: .readDataSize,
                status: sizeStatus
            ))
        }
        guard dataSize > 0 else { return .success([]) }

        let objectIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard dataSize.isMultiple(of: objectIDSize) else {
            return .failure(QueryFailure(
                objectID: objectID,
                selector: address.mSelector,
                operation: .readDataSize,
                status: kAudioHardwareBadPropertySizeError
            ))
        }

        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(dataSize / objectIDSize))
        let dataStatus = objectIDs.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard dataStatus == noErr else {
            return .failure(QueryFailure(
                objectID: objectID,
                selector: address.mSelector,
                operation: .readData,
                status: dataStatus
            ))
        }

        return .success(Array(objectIDs.prefix(Int(dataSize / objectIDSize))))
    }

    func pid(for objectID: AudioObjectID) -> Result<pid_t, QueryFailure> {
        scalarValue(for: objectID, selector: kAudioProcessPropertyPID, initialValue: pid_t(0))
    }

    func bundleID(for objectID: AudioObjectID) -> Result<String?, QueryFailure> {
        var address = Self.globalAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return .failure(QueryFailure(
                objectID: objectID,
                selector: address.mSelector,
                operation: .readData,
                status: status
            ))
        }
        return .success(value.map { $0.takeRetainedValue() as String })
    }

    func isRunningInput(for objectID: AudioObjectID) -> Result<Bool, QueryFailure> {
        runningState(for: objectID, selector: kAudioProcessPropertyIsRunningInput)
    }

    func isRunningOutput(for objectID: AudioObjectID) -> Result<Bool, QueryFailure> {
        runningState(for: objectID, selector: kAudioProcessPropertyIsRunningOutput)
    }

    private func runningState(
        for objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Result<Bool, QueryFailure> {
        scalarValue(for: objectID, selector: selector, initialValue: UInt32(0)).map { $0 != 0 }
    }

    private func scalarValue<Value: BitwiseCopyable>(
        for objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        initialValue: Value
    ) -> Result<Value, QueryFailure> {
        var address = Self.globalAddress(selector)
        var value = initialValue
        var dataSize = UInt32(MemoryLayout<Value>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return .failure(QueryFailure(
                objectID: objectID,
                selector: address.mSelector,
                operation: .readData,
                status: status
            ))
        }
        return .success(value)
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
