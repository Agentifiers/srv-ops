---
name: agent-device-ios
description: Drive the shared physical iPhone's UI semantically with agent-device (`--platform ios`) — accessibility snapshots with @refs, press/fill/scroll/swipe, screenshots, open/close apps — through the host's phone broker. Use for UI testing or checking an iOS app on the real iPhone; read the `iphone` skill for leasing, signing and installing builds.
---

# agent-device on the iPhone

`agent-device` (see the `agent-device` skill and `agent-device help workflow`) drives the one
real iPhone wired to the srv host. In this orb there is no Xcode, simulator or USB: agent-device's
iOS backend runs through the host's phone broker (the `iphone` skill). Its XCUITest runner
(`${IPHONE_BUNDLE_PREFIX}agentdevice.runner.uitests.xctrunner`, plus the target app
`${IPHONE_BUNDLE_PREFIX}agentdevice.runner`) is prebuilt in the image; the first iOS command after an
image update signs and installs it through the broker (about 30 s), later ones reuse it.

## The lease

agent-device takes the broker lease by itself (same lease as `iphone`). If another orb holds the
phone, commands fail with "leased by <node>"; do other work and retry in a minute or two.
**Release it when you are done:**

```bash
agent-device close                 # stops the session and the runner
iphone lease release               # or: agent-device-ios release
```

## Loop

```bash
agent-device devices --platform ios                 # the iPhone (name, iOS version, UDID)
agent-device open ${IPHONE_BUNDLE_PREFIX}myapp --platform ios   # launch your app (installed with `iphone install` / `expo-ios install`)
agent-device snapshot -i                            # interactive elements as @e1, @e2, ...
agent-device press @e7                              # tap by ref
agent-device snapshot -i                            # refs go stale after the UI changes: snapshot again
agent-device fill @e19 "hello"                      # focus a text field and type
agent-device screenshot ./screen.png                # full-resolution PNG
agent-device close
```

- Pass `--platform ios` on `open` (or `devices`); later commands in the session reuse the device.
  Without it, agent-device may ask you to choose between the iPhone and this Linux desktop.
- Take a new `snapshot -i` after anything that changes the screen before using refs again
  (a stale ref fails with "The UI may have changed").
- Apps you can open: those installed through the broker (`iphone install`, `expo-ios install`,
  `agent-device install <App.app|App.ipa>`, which signs unsigned builds through the broker),
  plus Settings (`com.apple.Preferences`) and Safari (`com.apple.mobilesafari`). Never open or
  inspect the owner's personal apps or data.
- Bundle ids must start with `$IPHONE_BUNDLE_PREFIX` (run `echo $IPHONE_BUNDLE_PREFIX`; the broker signs
  nothing else).

## When something fails

```bash
agent-device-ios status            # broker, lease, phone state, prebuilt runner build
agent-device-ios install-runner --force   # re-sign and reinstall the runner
iphone xcuitest status             # the runner's XCTest log on the host
```

- The runner log of a session is `~/.agent-device/sessions/<session>/runner.log`.
- Screen off or locked: `iphone wake`, then retry.
- Not available on the physical phone here: simulators (`boot`, `settings`, `push`, clipboard,
  `clear-app-state`), app console logs through agent-device (use `iphone syslog` / `iphone launch --console`),
  screen recording and performance traces. `iphone` covers the raw device actions
  (HID taps by pixel, logs, crash reports, port forwards).
