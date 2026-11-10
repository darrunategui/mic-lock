# mic-lock

A tiny background utility that pins a specific macOS audio input device as
the system default, and keeps re-asserting it whenever something else (most
commonly a Bluetooth headset connecting) steals the default input away.

## The problem

macOS's Core Audio doesn't let you "pin" a default input device. When a new
audio device registers an input stream — most commonly a Bluetooth headset
connecting over HFP/HSP — Core Audio re-evaluates the system default input
and generally switches to the newly connected device. There's no toggle in
System Settings to prevent this: the only related "automatic switching"
setting applies to Apple's own AirPods/Beats devices switching between your
Apple devices via iCloud, not to third-party Bluetooth mics taking over the
input on a single Mac.

So if you use a standalone microphone but also carry Bluetooth headphones,
every time you connect the headphones macOS quietly switches your input
away from the mic and onto the headphones.

## Other options considered

- **Disable the mic on the headphones**: many Bluetooth headsets (Sony,
  Bose, etc.) only expose a microphone to the OS when running in HFP/call
  mode. If your headphones have a companion app with a "sound quality" vs.
  "call quality" toggle, switching to sound-quality-only mode may drop the
  mic entirely, which means macOS has nothing to switch to. No background
  process needed if this works for your headphones — check this first.
- **SoundSource (Rogue Amoeba)**: a paid menu-bar mixer app that can hold a
  device selection. Works, but it's a full audio-routing app for a
  single-purpose need.

This project is the DIY fallback: no GUI, no extra runtime dependency
beyond the Xcode Command Line Tools, just a small compiled binary that
watches Core Audio and resets the default input when it drifts.

## How it works

`mic-lock.swift` listens for two Core Audio notifications on the system
object:

- `kAudioHardwarePropertyDevices` (the device list changed — e.g. a
  Bluetooth headset connected or disconnected)
- `kAudioHardwarePropertyDefaultInputDevice` (the default input changed for
  any reason)

On either event, after a 0.6s debounce (restarted by each new event, to let
Bluetooth device negotiation settle instead of fighting it mid-handshake),
it looks up the current default input. If it doesn't match the target device
(matched by a case-insensitive substring of its name) and the target device
is currently present, it resets the default input back to the target. It
then re-checks after 0.5s, 1s and 2s and re-applies the change if Core Audio
ignored it.

### Manual override

mic-lock only blocks *automatic* switches. If you pick a different input
yourself in System Settings or Control Center, it respects that choice.

It tells the two apart by what the new default input is. macOS
auto-switches to a device that has *just appeared*, like a headset
connecting. A manual pick selects a device that was already there. So a
change counts as manual when the newly selected device has been connected
for at least 10 seconds and the previous input is still present. If the
previous input is gone, macOS is just falling back, and that doesn't count.

A manual choice becomes the new pinned input. It is defended against later
auto-switches, for example a second headset connecting, until:

- you pick the target device again (the lock resumes), or
- the chosen device disconnects (mic-lock goes back to the target), or
- mic-lock restarts (e.g. at your next login).

One edge case: picking a headset in the first 10 seconds after it connects
looks the same as an auto-switch, so it gets reverted. Wait a moment and
pick it again.

It runs as a `launchd` LaunchAgent — no menu bar icon, no polling loop,
just an event-driven background process that starts at login and restarts
if it ever exits.

## Install

Requires Xcode Command Line Tools (for `swiftc`). Check with:

```sh
xcrun --find swiftc
```

Find your microphone's exact device name:

```sh
system_profiler SPAudioDataType
```

Then install, passing a distinctive substring of that name:

```sh
git clone https://github.com/darrunategui/mic-lock.git
cd mic-lock
./install.sh "<substring of your input device's name>"
```

`install.sh`:

1. Compiles `mic-lock.swift` with `swiftc -O`, linking `CoreAudio`
2. Installs the binary to `~/.local/bin/mic-lock`
3. Writes a LaunchAgent plist to
   `~/Library/LaunchAgents/com.davidarrunategui.mic-lock.plist`
4. Loads it with `launchctl bootstrap`, so it starts immediately and again on every
   login

Logs (each time it detects and corrects a drift) go to
`~/Library/Logs/mic-lock.log`.

## Uninstall

```sh
./uninstall.sh
```

Unloads and removes the LaunchAgent and deletes the installed binary.

## Notes

- The name match is a case-insensitive substring, so partial names like
  `"blue yeti"` or `"scarlett"` work fine — you don't need the exact full
  string macOS reports.
- If the target device isn't currently connected, `mic-lock` just logs that
  it has nothing to enforce and waits for it to reappear.
- To change the target device later, just re-run `./install.sh "<new
  name>"` — it reloads the LaunchAgent with the new argument.
