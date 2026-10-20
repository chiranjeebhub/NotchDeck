# NotchUtility

An open-source clone of [NotchNook](https://getnotchnook.com/) for macOS: hover over the notch and it
expands into a small hub with media controls, a file tray with AirDrop, and today's calendar.

Works on Macs without a notch too: a slim handle at the top of the screen opens the same panel.

## Features

- **Media**: controls Spotify and Apple Music, with artwork, progress/seek and a live activity in the
  closed notch while music plays.
- **Tray**: drag files onto the notch to stash them, drag them back out, Quick Look thumbnails,
  AirDrop from the tray.
- **Calendar**: today's remaining events with one-click Join for Meet, Zoom, Teams and Webex.
- **Settings**: launch at login, show on all displays, haptics, which player to follow.

See [docs/PLAN.md](docs/PLAN.md) for the full NotchNook feature comparison and roadmap.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (or the Swift 5.9+ command line tools)

## Build and run

```sh
./scripts/build-app.sh
open build/NotchUtility.app
```

The app lives in the menu bar (no Dock icon). Use the menu bar icon to open Settings or quit.

You can also open `Package.swift` in Xcode and run the `NotchUtility` scheme, but privacy prompts
(Calendar, Automation) only work properly from the bundled `.app`.

### Permissions

- **Automation**: asked the first time NotchUtility talks to Spotify or Music.
- **Calendar**: asked when you click "Allow Calendar Access" in the notch.

The build is ad-hoc signed, so macOS may ask for permissions again after each rebuild.

## Project layout

```
Sources/NotchUtility/
  App/       entry point, app delegate, settings keys
  Notch/     panel, per-screen controller (hover/drag detection), geometry, view model
  Services/  now playing, tray store, calendar
  Views/     SwiftUI views
Resources/Info.plist
scripts/build-app.sh
```
