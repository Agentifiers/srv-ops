
## On this orb: Amp's Desktop

This orb's graphical session is Amp's Desktop (the thread's **Desktop** tab): a
labwc (wlroots) Wayland compositor with Xwayland, streamed to the user. The
`agent-desktop` command is a wrapper that runs the CLI inside that session from
any shell, so do not set `WAYLAND_DISPLAY`, `DISPLAY` or `DBUS_SESSION_BUS_ADDRESS`
yourself.

- **Start the Desktop first.** If `agent-desktop status` reports no display or an
  empty `supported_surfaces`, the Desktop is not running: ask the user to open
  the Desktop tab, or run `sudo systemctl start amp-desktop` when
  `/opt/amp-desktop` exists. The user watches what you do there.
- **Accessibility is on for the whole session.** Apps started on the Desktop
  (GTK, Qt, Chrome, Electron) expose their UI trees; an app started before the
  Desktop restarted may need a restart to appear in `list-apps`.
- **Web pages: use agent-browser, not agent-desktop.** The Desktop's Chrome
  listens for DevTools on `127.0.0.1:9222`; drive pages with
  `agent-browser --cdp 9222` and keep agent-desktop for native apps, Chrome's
  own window controls and dialogs.
- **Input on labwc.** This agent-desktop build has a wlroots route: keys,
  `press`, `--headed type` and pointer input go through the wlroots virtual
  keyboard and pointer; semantic ref actions work headless. Window list,
  focus, close, minimize, maximize and restore work; move and resize refuse.
- **Aiming at a ref with the pointer** (`--headed click`, hover, drag) needs
  the window's place on screen, which this labwc proves only for a focused,
  maximized window: run `focus-window` and `maximize --window-id <id>` first,
  or use the headless semantic action or `mouse-click --xy`. A refusal with
  `wlroots_window_origin_unproven` means exactly that. `screenshot` of the
  whole display works; `screenshot --app`/`--window-id` refuses here.
- **Xwayland windows take only the first synthetic click**; prefer native
  Wayland apps (Chrome on the Desktop is native) or semantic actions there.
- **Installing apps.** This orb runs Arch Linux, not Debian. Chrome and the foot
  terminal are preinstalled (`sudo -n /opt/amp-desktop/install-app chrome` or
  `terminal` configures them). For anything else install the package first
  (`sudo pacman -S --needed firefox`); Amp's `install-app firefox|code|blender`
  then only configures it, because its own installer uses `apt-get`.
