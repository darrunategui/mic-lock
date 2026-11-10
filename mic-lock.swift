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

func inputDeviceIDs() -> [AudioDeviceID] {
    allDeviceIDs().filter(deviceHasInputStreams)
}

func targetMatches(among inputs: [AudioDeviceID]) -> [AudioDeviceID] {
    inputs.filter { deviceName($0)?.lowercased().contains(targetNameFragment) ?? false }
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

let debounceInterval: TimeInterval = 0.6
var pendingEnforce: DispatchWorkItem?

// Core Audio can accept a default-device change (noErr) and then ignore it,
// e.g. while a Bluetooth device is still negotiating. After each reset we
// re-check after these delays and try again, then give up until the next
// Core Audio event.
let retryDelays: [TimeInterval] = [0.5, 1.0, 2.0]
var pendingRetry: DispatchWorkItem?

// Manual override
// ---------------
// macOS auto-switches the default input to a device that has just appeared
// (e.g. a Bluetooth headset connecting). A person picking an input in System
// Settings or Control Center instead selects a device that was already
// there. So a change of default input is treated as a manual choice when:
//   - the newly selected device has been present for at least
//     `autoSwitchWindow` (it isn't a fresh arrival), and
//   - the previously selected device is still present (otherwise macOS is
//     just falling back because the old default disappeared).
// A manual choice is then held (and defended against later auto-switches)
// until it disconnects, the person picks the target again, or mic-lock
// restarts.
let autoSwitchWindow: TimeInterval = 10

var firstSeen: [AudioDeviceID: Date] = [:]  // when each input device appeared
var lastSeenDefault: AudioDeviceID?         // default input at the previous check
var manualChoice: AudioDeviceID?            // overrides the target while present
var reportedTarget: AudioDeviceID?          // last target device we logged

func describe(_ id: AudioDeviceID) -> String {
    "\"\(deviceName(id) ?? "unknown(\(id))")\""
}

@MainActor
func enforce(attempt: Int = 0) {
    pendingRetry?.cancel()
    pendingRetry = nil

    let now = Date()
    let inputs = inputDeviceIDs()
    let present = Set(inputs)
    for id in inputs where firstSeen[id] == nil { firstSeen[id] = now }
    firstSeen = firstSeen.filter { present.contains($0.key) }

    let current = currentDefaultInput()
    let previous = lastSeenDefault
    lastSeenDefault = current

    if let choice = manualChoice, !present.contains(choice) {
        log("manually chosen input disconnected — reverting to target")
        manualChoice = nil
    }
    let matches = targetMatches(among: inputs)
    let target = matches.first
    if let target, target != reportedTarget {
        log("target resolved to \(describe(target))")
        if matches.count > 1 {
            let names = matches.map(describe).joined(separator: ", ")
            log("warning: \(matches.count) input devices match \"\(targetNameFragment)\" (\(names)); using the first — reinstall with a more specific name")
        }
    }
    reportedTarget = target
    guard let desired = manualChoice ?? target else {
        log("target device matching \"\(targetNameFragment)\" not currently present, nothing to enforce")
        return
    }
    guard current != desired else { return }

    if attempt == 0,
       let previous, previous != current, present.contains(previous),
       let arrived = firstSeen[current], now.timeIntervalSince(arrived) >= autoSwitchWindow {
        if current == target {
            log("target \(describe(current)) manually reselected — resuming lock")
            manualChoice = nil
        } else {
            log("default input manually changed to \(describe(current)) — respecting it until it disconnects or the target is reselected")
            manualChoice = current
        }
        return
    }

    if attempt == 0 {
        log("default input is \(describe(current)), expected \(describe(desired)) — resetting")
    } else if attempt < retryDelays.count {
        log("default input is still \(describe(current)) after reset attempt \(attempt) — retrying")
    } else {
        log("default input is still \(describe(current)) after \(attempt) reset attempts — giving up until the next device change")
        return
    }
    setDefaultInput(desired)

    let retry = DispatchWorkItem { enforce(attempt: attempt + 1) }
    pendingRetry = retry
    DispatchQueue.main.asyncAfter(deadline: .now() + retryDelays[attempt], execute: retry)
}

@MainActor
func scheduleEnforce() {
    // Debounce: device negotiation after a BT connect/disconnect can take
    // a moment to settle, and re-asserting mid-negotiation can be ignored.
    // Each new event restarts the timer, so we act only once the burst of
    // notifications has gone quiet for `debounceInterval`.
    pendingEnforce?.cancel()
    let work = DispatchWorkItem { enforce() }
    pendingEnforce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
}

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

// Listeners are delivered on the main queue so all state (e.g. the debounce
// flag) is only ever touched from one thread.
let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
    MainActor.assumeIsolated { scheduleEnforce() }
}

_ = checkStatus(
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, listenerBlock),
    "add devices listener"
)
_ = checkStatus(
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, DispatchQueue.main, listenerBlock),
    "add default-input listener"
)

log("mic-lock started, watching for input device \"\(targetNameFragment)\"")
MainActor.assumeIsolated {
    // Devices present at startup are not fresh arrivals.
    for id in inputDeviceIDs() { firstSeen[id] = .distantPast }
    enforce()
}

RunLoop.main.run()
