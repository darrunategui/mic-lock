# mic-lock

A tiny background utility that pins a specific macOS audio input device as
the system default, and keeps re-asserting it whenever something else (most
commonly a Bluetooth headset connecting) steals the default input away.

## The problem

macOS's Core Audio doesn't let you "pin" a default input device. When a new
audio device registers an input stream — most commonly a Bluetooth headset
connecting over HFP/HSP — Core Audio re-evaluates the system default input
and generally switches to the newly connected device. There's no toggle in
System Settings to prevent this: the "automatic switching" setting you may
have seen only applies to Apple's own AirPods/Beats devices switching
between your Apple devices via iCloud, not to third-party Bluetooth mics
taking over the input on a single Mac.

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

On either event, after a 0.6s debounce (to let Bluetooth device negotiation
settle instead of fighting it mid-handshake), it looks up the current
default input. If it doesn't match the target device (matched by a
case-insensitive substring of its name) and the target device is currently
present, it resets the default input back to the target.

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
git clone <this-repo-url>
cd mic-lock
./install.sh "<substring of your input device's name>"
```

`install.sh`:

1. Compiles `mic-lock.swift` with `swiftc -O`, linking `CoreAudio`
2. Installs the binary to `~/.local/bin/mic-lock`
3. Writes a LaunchAgent plist to
   `~/Library/LaunchAgents/com.davidarrunategui.mic-lock.plist`
4. Loads it with `launchctl`, so it starts immediately and again on every
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
