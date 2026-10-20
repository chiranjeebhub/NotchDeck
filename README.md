# NotchDeck

An open-source clone of [NotchNook](https://getnotchnook.com/) for macOS: hover over the notch and it
expands into a small hub with media controls, a file tray with AirDrop, and today's calendar.

Works on Macs without a notch too: a slim handle at the top of the screen opens the same panel.

## Features

- **Media**: shows and controls whatever macOS lists as Now Playing (Spotify, Music, Podcasts,
  YouTube in a browser, …), with artwork, progress/seek and a live activity in the closed notch.
- **Tray**: drag files onto the notch to stash them, drag them back out, Quick Look thumbnails,
  AirDrop from the tray.
- **Calendar**: today's remaining events with one-click Join for Meet, Zoom, Teams and Webex.
- **Dev**: live CPU and memory, Docker containers (start / stop / logs), and local servers
  listening on TCP ports (e.g. `localhost:3000`) with project folder, CPU and memory, plus Open,
  Copy URL and Stop.
- **Settings**: open on hover or click, hover delay, launch at login, show on all displays, haptics.

See [docs/PLAN.md](docs/PLAN.md) for the full NotchNook feature comparison and roadmap.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (or the Swift 5.9+ command line tools)

## Build and run

```sh
./scripts/build-app.sh
open build/NotchDeck.app
```

The app lives in the menu bar (no Dock icon). Use the menu bar icon to open Settings or quit.

You can also open `Package.swift` in Xcode and run the `NotchDeck` scheme, but privacy prompts
(Calendar, Automation) only work properly from the bundled `.app`.

### Permissions

- **Automation**: only needed for the Spotify/Music fallback, used if system Now Playing is unavailable.
- **Calendar**: asked when you click "Allow Calendar Access" in the notch.

The build is ad-hoc signed, so macOS may ask for permissions again after each rebuild.

## Project layout

```
Sources/NotchDeck/
  App/       entry point, app delegate, settings keys
  Notch/     panel, per-screen controller (hover/drag detection), geometry, view model
  Services/  now playing, tray store, calendar
  Views/     SwiftUI views
Adapter/         MediaRemote helper run under /usr/bin/perl for system-wide Now Playing
Resources/       Info.plist, AppIcon.png (icon master, drawn by scripts/render-icon.py)
scripts/build-app.sh
```

## Releasing

NotchDeck ships as a notarized download rather than on the Mac App Store: the App Store sandbox
would rule out system-wide Now Playing and the whole Dev tab (ports, stopping servers, Docker).

`scripts/release.sh` builds `build/NotchDeck-<version>.dmg`, signed with your Developer ID
Application certificate and notarized by Apple. One-time setup is described at the top of the
script. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` for each
release.
