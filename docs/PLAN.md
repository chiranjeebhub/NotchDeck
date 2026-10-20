# Feature plan

NotchUtility is an open-source take on [NotchNook](https://getnotchnook.com/): the MacBook notch
becomes an interactive "dynamic island" that expands on hover.

## NotchNook feature inventory

| Area | NotchNook | Permission |
|---|---|---|
| Media | Now Playing controls for Spotify, Apple Music and any app macOS lists as Now Playing; choose which app to follow | Automation |
| Calendar | Today's events, Join buttons for Meet / Zoom / Teams / Webex (Google via Calendar.app) | Calendar |
| Tray | Drop files on the notch to keep them; AirDrop from the tray | — |
| Notes / To-dos / Timers | Small productivity widgets | — |
| Mirror | Camera preview | Camera |
| Shortcuts | Run your Shortcuts from the notch | — |
| HUDs | Volume and brightness indicators, Bluetooth device connections | Accessibility, Bluetooth |
| Full-screen | Hides in full-screen apps | Accessibility |
| Displays | One nook per display; slim handle on screens without a notch | — |

Requirements to match: macOS 14+, Apple silicon and Intel, notch optional.

## Phase 1: MVP (this PR)

- [x] Notch window per display, hover to expand, spring animation, concave notch shape
- [x] Slim handle on displays without a notch
- [x] Closed-state "live activity": album art + level meter while music plays
- [x] Media: Spotify and Apple Music via distributed notifications + AppleScript
      (title, artist, artwork, progress/seek, play/pause/next/previous, player preference)
- [x] Tray: drop files on the notch (opens straight to the Tray), drag out, Quick Look
      thumbnails, open / reveal / remove, persisted across launches
- [x] AirDrop: drop files on the AirDrop tile, or AirDrop the whole tray
- [x] Calendar: today's remaining events with calendar colours and Join buttons
- [x] Menu bar item, Settings window (launch at login, displays, haptics, player)

## Phase 2

- [x] System-wide Now Playing for any app (MediaRemote via a helper loaded into
      /usr/bin/perl, the approach needed on macOS 15.4+), with Spotify/Music fallback
- [x] Open on click option and hover delay setting
- [x] Dev tab: listening ports / local dev servers with Open and Kill
- [ ] Notes, To-dos and Timers widgets
- [ ] Mirror (camera preview)
- [ ] Shortcuts list and runner
- [ ] Hide in full-screen apps

## Phase 3

- [ ] Volume / brightness HUD replacement
- [ ] Bluetooth device connected notifications with battery level
- [x] Home tab calendar with Day / Month views; Dev tab grows when many servers run
- [ ] Customisable widget layout
- [ ] Signed + notarised release builds, Sparkle auto-updates
