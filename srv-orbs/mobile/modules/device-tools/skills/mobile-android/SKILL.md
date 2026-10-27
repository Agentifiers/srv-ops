---
name: mobile-android
description: Run, build and drive Android apps in this orb. Use when you need an Android device (redroid in the orb or a phone on the tailnet), want to build and install an Expo/React Native Android app, stream a device to the user through a portal with expo-device-hub, or drive the UI with agent-device.
---

# Android in this orb

There is no Android emulator here (no KVM). Use **redroid**, Android 16 in a
Docker container with a software GPU, or a **phone on the tailnet**. Both are
plain adb devices. The SDK is at `$ANDROID_HOME` (`/opt/android-sdk`, writable,
so Gradle can add packages). JDK 17 is installed.

## Start / stop redroid

```bash
redroid-up        # loads the image on first use, boots, waits for sys.boot_completed, adb connect 127.0.0.1:5555
adb devices       # 127.0.0.1:5555  device
redroid-down      # stop (apps and data persist in the docker volume)
redroid-down --wipe   # delete the container and its /data
```

The first `redroid-up` after the orb is created takes longer, because it runs
`docker load`. Extra `androidboot.*` arguments go to a new container, for
example `redroid-up androidboot.redroid_width=1080 androidboot.redroid_height=2340 androidboot.redroid_dpi=440`.
Run `redroid-down --wipe` first to change them.
redroid is x86_64-only. Build x86_64 native code for it, as shown below.
redroid needs `/dev/ashmem`, binderfs and PSI from the orb's `-mobile` kernel;
`redroid-up` names whichever is missing and exits.

## Connect an Android phone over the tailnet

The phone needs the Tailscale app running and Developer options enabled. mDNS
does not cross the tailnet, so always use the phone's tailnet IP (`100.x.y.z`):

- **Wireless debugging** (Android 11+): in Developer options → Wireless debugging → *Pair device with pairing code*,
  run `adb pair 100.x.y.z:<pair-port> <code>`, then
  `adb connect 100.x.y.z:<port>`. Use the port shown on the Wireless debugging screen.
- **Classic**: after the user has once run `adb tcpip 5555` over USB, run `adb connect 100.x.y.z:5555`.

`adb devices` lists it as `100.x.y.z:<port>`. Pass `-s <serial>` (adb) or
`--serial <serial>` (agent-device) when more than one device is connected.

## Build and run an Expo / React Native app

```bash
npx expo prebuild -p android        # once, or after changing native config
cd android && ./gradlew assembleDebug -PreactNativeArchitectures=x86_64   # redroid; use arm64-v8a for phones
adb -s 127.0.0.1:5555 install -r app/build/outputs/apk/debug/app-debug.apk
```

Building only one ABI is much faster than the template's four. Debug builds
load JS from Metro. Run Metro as a supervised service, not in the background:
`amp orb service start metro --command 'npx expo start --port 8081' --port 8081`.
Then run `adb -s <serial> reverse tcp:8081 tcp:8081` so the app reaches
`localhost:8081`. Repeat the reverse after reconnecting the device. Launch the
app with `adb shell am start -W -n <applicationId>/.MainActivity`, or use agent-device `open <applicationId>`.
`npx expo run:android` builds, installs and starts Metro in one step. It uses
the same Gradle build.

## Show the device to the user: expo-device-hub in a portal

expo-device-hub streams adb devices to a browser (scrcpy) and accepts touch and
keyboard input. Declare it in `.amp/services.yaml`:

```yaml
services:
  device-hub:
    platforms: [linux]
    command: expo-device-hub --platform android --host 127.0.0.1 --port "$PORT" --require-token --frame-ancestor 'https://*.onamp.dev' --cors-origin 'https://*.onamp.dev'
    portal:
      title: Android device
```

Run `amp orb services ensure`. The token changes on every start. Read it from
`amp orb service logs device-hub`, from the `Local: http://localhost:<port>/?token=…`
line, and give the user the printed portal URL with `/?token=<token>` appended.
Always use `--require-token`: the hub can run commands on this machine.
`curl -s "http://127.0.0.1:<port>/api/devices?token=<token>"` lists devices.

## Drive the UI: agent-device

Read the `agent-device` skill for the full workflow (`agent-device help workflow`). Quick loop:

```bash
agent-device devices --platform android
agent-device open com.android.settings --platform android
agent-device snapshot -i          # accessibility tree with @eN refs
agent-device press @e3            # or: fill @e5 "text", scroll down, back
agent-device screenshot /tmp/screen.png
agent-device close
```

The first snapshot on a device installs agent-device's small helper APKs. iOS
is not available through agent-device here: it requires macOS.
