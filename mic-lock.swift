import CoreAudio
import Foundation

// mic-lock: keeps a specific audio input device pinned as the macOS
// default input, re-asserting it whenever the device list or default
// input changes (e.g. a Bluetooth headset connects and steals it).
//
// Usage: mic-lock "<substring of desired input device name>"

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: mic-lock <device name substring>\n".data(using: .utf8)!)
    exit(1)
}
let targetNameFragment = CommandLine.arguments[1].lowercased()

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
}

func checkStatus(_ status: OSStatus, _ context: String) -> Bool {
    if status != noErr {
        log("\(context) failed: OSStatus \(status)")
        return false
    }
    return true
}

func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard checkStatus(
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize),
        "get device list size"
    ) else { return [] }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard checkStatus(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs),
        "get device list"
    ) else { return [] }

    return deviceIDs
}

func deviceName(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var dataSize = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
        AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, ptr)
    }
    guard status == noErr else { return nil }
    return name as String
}

func deviceHasInputStreams(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
        return false
    }
    let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
    defer { bufferListPtr.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferListPtr) == noErr else {
        return false
    }
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
    return bufferList.contains { $0.mNumberChannels > 0 }
}

func findTargetDevice() -> AudioDeviceID? {
    for id in allDeviceIDs() {
        guard deviceHasInputStreams(id), let name = deviceName(id) else { continue }
        if name.lowercased().contains(targetNameFragment) {
            return id
        }
    }
    return nil
}

func currentDefaultInput() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = 0
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
    return deviceID
}

func setDefaultInput(_ id: AudioDeviceID) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var mutableID = id
    let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = checkStatus(
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, dataSize, &mutableID),
        "set default input device"
    )
}

var enforcing = false

func enforce() {
    guard let target = findTargetDevice() else {
        log("target device matching \"\(targetNameFragment)\" not currently present, nothing to enforce")
        return
    }
    let current = currentDefaultInput()
    if current != target {
        let currentName = deviceName(current) ?? "unknown(\(current))"
        let targetName = deviceName(target) ?? "unknown(\(target))"
        log("default input is \"\(currentName)\", expected \"\(targetName)\" — resetting")
        setDefaultInput(target)
    }
}

func scheduleEnforce() {
    // Debounce: device negotiation after a BT connect/disconnect can take
    // a moment to settle, and re-asserting mid-negotiation can be ignored.
    if enforcing { return }
    enforcing = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        enforcing = false
        enforce()
    }
}

let listenerQueue = DispatchQueue(label: "mic-lock.listener")

var devicesAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var defaultInputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
    scheduleEnforce()
}

_ = checkStatus(
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, listenerQueue, listenerBlock),
    "add devices listener"
)
_ = checkStatus(
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, listenerQueue, listenerBlock),
    "add default-input listener"
)

log("mic-lock started, watching for input device \"\(targetNameFragment)\"")
enforce()

RunLoop.main.run()
