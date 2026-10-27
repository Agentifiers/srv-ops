---
name: iphone
description: Use the shared physical iPhone (USB-attached to the srv host) from this orb — take an exclusive lease, sign and install .ipa builds, launch apps with console output and deep links, take screenshots, tap/swipe/type, read app logs, forward device ports. Use whenever an iOS app has to run on a real device.
---

# iphone

One real iPhone is wired to the srv host. The host's broker lends it to one orb at a time.
`iphone` talks to the broker (`$IPHONE_BROKER_URL`, set by the image). The broker knows
this orb by its tailnet node, so you need no credentials.

## The lease

```bash
iphone status                # who holds the phone, plus battery, DDI and screen state
iphone lease acquire         # optional: device commands take a free lease on their own
iphone lease release         # ALWAYS release when you are done
```

- Only the leaseholder can run device commands. Each command renews the lease.
- The lease lapses after **10 minutes without a command** (the broker's default idle timeout). Commands that run long (install, `--console`,
  `syslog`) keep renewing it while they run.
- If another thread holds the phone, commands exit with code 3 and say who holds it and how long it has been idle.
  Wait for it: retry every minute or two, and keep doing other work (Android, a build) in the meantime.
  Never try to get around the lease.
- Release the lease as soon as you stop using the phone. Other threads are waiting for it.

## Build, sign, install, run

```bash
expo-ios build --configuration Release
expo-ios sign --configuration Release      # uses `iphone sign` when this orb has no ASC key
expo-ios install --configuration Release --launch 30
# the same steps by hand:
iphone sign ios/build/expo-ios/Release/App-unsigned.ipa -o App.ipa   # also takes an .app dir or a zip of one
iphone install App.ipa
iphone launch ${IPHONE_BUNDLE_PREFIX}myapp --console 30     # streams stdout/stderr for 30 s
iphone launch ${IPHONE_BUNDLE_PREFIX}myapp --env FOO=1 --arg -SomeFlag YES
iphone terminate ${IPHONE_BUNDLE_PREFIX}myapp
iphone uninstall ${IPHONE_BUNDLE_PREFIX}myapp              # clean up test apps when you are done
```

- **Bundle ids must start with `$IPHONE_BUNDLE_PREFIX`** (run `echo $IPHONE_BUNDLE_PREFIX`; for example
  `<prefix><project>`). Set `ios.bundleIdentifier` in app.json to the expanded value. The host's signing
  refuses any other id and any wildcard.
- The host signs the app with a development profile for this one phone. The team's App Store Connect key
  never leaves the host.
- You can launch, terminate, uninstall and kill only apps that went in through `iphone install`. Settings
  (`com.apple.Preferences`) and Safari (`com.apple.mobilesafari`) can also be launched. The rest of the
  phone belongs to its owner: never open personal apps or data.
- An app that is already on the phone but was not installed through the broker cannot be replaced.

## See and drive the screen

```bash
iphone screenshot                      # ./iphone-<time>.png at the phone's full pixel resolution; prints the path
iphone screenshot -o s.jpg --jpeg --scale 0.33   # small, cheap to read
iphone tap 590 1400                    # pixel coordinates in the full-size screenshot
iphone tap 196 466 --pt                # or points (pixels / the screen scale, 3 on most current iPhones)
iphone swipe 590 2000 590 600          # finger drag (scroll up)
iphone swipe 5 1200 800 1200 --duration 0.4   # left-edge swipe = back
iphone type 'hello world\n'            # into the focused text field; \n = Return
iphone key backspace --count 3
iphone button home                     # also: lock volume-up volume-down mute siri
iphone wake                            # screen off -> wakes and unlocks (no passcode)
iphone open-url https://example.com    # http(s) opens in Safari
iphone launch ${IPHONE_BUNDLE_PREFIX}myapp --url 'myapp://path'   # deep link into your app
```

- Coordinates you get from a `--scale`d screenshot must be divided by the scale before you tap.
- Always take a screenshot after an action to check it worked. Taps and swipes go through
  Apple's HID service, so no on-device helper app is needed.
- If a screenshot is black, the screen is off: run `iphone wake`.

## Logs

```bash
iphone syslog MyApp --seconds 60            # the app's executable name (CFBundleExecutable)
iphone syslog MyApp --match 'ReactNativeJS' --seconds 120
iphone launch ${IPHONE_BUNDLE_PREFIX}myapp --console 60   # stdout/stderr of a fresh launch
iphone crashes MyApp                       # newest crash reports -> ./iphone-crashes/
```

You can read the logs of your own apps and of SpringBoard, installd, runningboardd,
testmanagerd, amfid and kernel. You can read crash reports of your own apps only.

## Expo dev client and Metro

The phone is on the tailnet (Tailscale on the phone), so it reaches Metro in this orb directly:

```bash
REACT_NATIVE_PACKAGER_HOSTNAME=$(hostname) npx expo start --dev-client &
iphone launch ${IPHONE_BUNDLE_PREFIX}myapp \
  --url "exp+<scheme>://expo-development-client/?url=http%3A%2F%2F$(hostname)%3A8081"
```

## Device ports, XCUITest, live view

```bash
iphone forward 8100            # prints HOST:PORT; only this orb can connect, closed on release
iphone xcuitest start ${IPHONE_BUNDLE_PREFIX}x.xctrunner --target ${IPHONE_BUNDLE_PREFIX}x --env KEY=V
iphone xcuitest status --follow
iphone xcuitest stop
iphone live                    # URL + password of a live, controllable view for a human (Safari/Chrome on a Mac or iPhone)
```

The live view is for a human to watch: give the user the URL and password. The first frame
can take up to about 45 s to appear. The live view cannot be watched from this orb, because
it needs HEVC decoding. `iphone tap`/`swipe`/`type` calls can freeze it; if that happens,
restart it with `iphone live --stop; iphone live`.

For semantic UI automation (element trees, `snapshot`, `click @ref`), use the `agent-device-ios`
skill, when it is installed. It drives this same phone through the broker.

## Other

`iphone info`, `iphone apps [--all]`, `iphone processes`, `iphone kill PID`,
`iphone location set LAT LON` / `iphone location clear`, `iphone whoami`,
`iphone api GET /v1/status` (raw API; see srv-mobile-host/README.md on the host).
Exit codes: 1 error, 2 usage, 3 leased by another orb, 4 phone or broker unavailable.
