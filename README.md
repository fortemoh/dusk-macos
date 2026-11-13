# dusk-macos

A small tool for Apple Silicon Macs with external displays (SDR), with a menu bar icon and a command line. It does three things:

- **No dithering.** It stops temporal dithering, both the GPU's and the monitor's own (FRC).
- **A warm screen at night.** A warm tint and dimming follow the sun in Montreal: a fade to Evening at sunset, to pure red before 9 PM, and back to Day by sunrise.
- **HiDPI on any monitor.** HiDPI (Retina) at the size you use, like 2560x1440 HiDPI on a 1440p monitor: the same size on screen, drawn at twice the resolution and scaled down, with smoother text. Standard resolution while a game runs, and HiDPI kept when monitors come and go. Optionally, more HiDPI sizes in System Settings.

dusk is the successor of `nodither`; `dusk install` replaces it.

## No dithering

You need both of these:

1. **GPU dithering off.** macOS renders into a 10-bit framebuffer, and the display coprocessor (DCP) temporally dithers it down to the link's bit depth. dusk sets `enableDither = No` on each external display pipe.
2. **An 8-bit RGB link (full range).** On a 10-bit link, monitors whose panel is really 8-bit + FRC fake the extra 2 bits by flickering between neighbouring shades. That is temporal dithering too, done by the monitor. With an 8-bit link it has nothing to dither. This also replaces YCbCr / limited-range links with RGB full range.

The 8-bit link alone just moves the dithering from the monitor to the GPU. Turning GPU dithering off alone leaves the monitor's FRC in place. With both, the Mac rounds to 8 bits and the monitor displays them as-is. Smooth gradients can show slightly more banding; that is the expected trade-off.

## Warm tint and dimming

Three looks, with these defaults:

| | Warmth | Brightness |
|---|---|---|
| Day | 4000 K | 100% |
| Evening | 2700 K | 85% |
| Night | 0 K (pure red) | 70% |

The schedule, for Montreal (45.50° N, 73.57° W) in local time:

- **Day → Evening:** a 30-minute fade centred on sunset.
- **Evening → Night:** fully red at sunset + ¾ of the time left until 9 PM, so always before 9 PM, after a 30-minute fade. In summer the two fades overlap and merge into one.
- **Night → Evening:** a 30-minute fade when the last quarter of the time from sunset to sunrise starts, around 3–4 AM.
- **Evening → Day:** a 30-minute fade that ends at sunrise.

| | Sunset | Fully red | Red until | Sunrise |
|---|---|---|---|---|
| Jun 21 | 20:46 | 20:56 | 03:00 | 05:05 |
| Oct 11 | 18:17 | 20:19 | 03:53 | 07:05 |
| Dec 21 | 16:13 | 19:48 | 03:42 | 07:31 |

Fades follow the clock, so after sleep the screen goes straight to where the fade should be. A fade updates the screen each time a colour channel moves one of its 256 levels, and ends exactly on the next look.

The menu bar icon (sun, sunset or moon) opens a menu with:

- what's on screen now: the look or fade, and its warmth and brightness (an estimate during a fade, e.g. "about 2900 K, 88%")
- a warmth and a brightness slider for each look, previewed live while you drag
- Pause for 1 hour: no tint or dimming, then a 30-minute fade back into the schedule
- Night until sunrise: Night until half an hour before sunrise, then a fade to Day
- Warm tint & dimming on/off, No dithering on/off, HiDPI on/off (like `dusk set hidpi`, so on also keeps it when monitors come and go)
- Reset to defaults
- tonight's sunset, sunrise and red times

Everything in the menu is also a command (see [Usage](#usage)), and `dusk set icon off` hides the icon.

## HiDPI

`dusk set hidpi on` (or HiDPI in the menu) switches each external monitor to the HiDPI mode that looks the same size as what it shows now: 1920x1080 becomes 1920x1080 HiDPI, drawn at 3840x2160 and scaled down to the panel, and 2560x1440 becomes 2560x1440 HiDPI, drawn at 5120x2880. `dusk set hidpi off` switches back to the standard mode of that size.

macOS has these modes for a monitor's own resolution and a few other sizes, but only for mirroring, so System Settings doesn't list them; dusk sets them anyway, as BetterDisplay's HiDPI toggle does. No administrator password needed. A mode drawn at 5120x2880 takes more of the display pipe's bandwidth, which can rule out the highest refresh rates: on a 1440p 240 Hz monitor, 2560x1440 HiDPI goes up to 180 Hz (`dusk set hidpi on` says so, and `off` goes back to 240 Hz).

### Keeping HiDPI

macOS saves the display modes for each set of connected monitors, and keeps HiDPI through a monitor's power cycle and display sleep. A set it hasn't seen in HiDPI comes up in standard, though: with two monitors in HiDPI, turning one off leaves the other in standard.

So `dusk set hidpi on` (or HiDPI in the menu) also keeps HiDPI: after a monitor attaches or leaves, or the monitors wake, dusk puts the ones that were in HiDPI back in it, and macOS then keeps it for that set too. It does nothing on other display changes or while a game runs, and follows the modes you pick in System Settings. `dusk set hidpi off` stops it.

### Games

While a game runs, monitors in HiDPI show the standard mode of the same size instead, at its highest refresh rate: the game draws at the monitor's own resolution rather than at twice the size, and isn't held to HiDPI's lower refresh rates. They go back to HiDPI 3 seconds after the last game quits. dusk switches only when it finds a game and when the game quits, not when you switch apps, since each switch blanks the monitor for a moment. `dusk set games off` turns this off.

dusk finds games by what they do, with no list to keep, so Steam games, Wine programs (CrossOver, Whisky or Sikarugir wrappers), ports and games started as a bare executable all count. A game is the app in front when it fills a display, full screen or in a window that size, and either:

- keeps the GPU busy, at least 15% of the time for 4 seconds, or
- says it's a game in its Info.plist (`LSApplicationCategoryType` is `public.app-category.games` or `public.app-category.<kind>-games`), which covers light games that hardly use the GPU.

Games use far more, even light ones: openmohaa used 30 to 38% at 1920x1080. Other apps in full screen use far less: VLC playing a 1080p video full screen used 3 to 5%. Launchers like Steam and Epic Games Launcher don't fill the screen. A game played in a window doesn't count, and neither does a browser game, since browsers draw in a separate process.

The switch comes when a game fills the screen: right away if its Info.plist says it's a game, otherwise about 6 seconds later, while it runs. The game then sees its monitor go from HiDPI to standard at the same size, as when a window moves to a non-Retina monitor.

For an app dusk gets wrong, `dusk set game <app> on` makes it a game as soon as it starts, `off` never one, and `auto` goes back to what it does. `<app>` is its name in Activity Monitor, its bundle ID or its path; a Wine wrapper's name covers every program it runs. `dusk status` lists the games running.

### More sizes

`dusk set scaling on` adds HiDPI sizes in between, listed in System Settings > Displays like macOS's own, the way BetterDisplay's flexible scaling does. For each monitor model, in its aspect ratio:

| Monitor | Added HiDPI sizes (looks like) |
|---|---|
| 1920x1080 | 1200x675, 1280x720, 1440x810, 1600x900, 1680x945 |
| 2560x1440 | 1600x900, 1920x1080, 2048x1152, 2240x1260, 2304x1296 |
| 3840x2160 | 2048x1152, 2304x1296, 2400x1350, 2560x1440, 2880x1620, 3200x1800, 3360x1890 |

That asks for an administrator password, since macOS reads them from `/Library/Displays`, and the monitors go blank for a few seconds while dusk reconnects them to load the sizes. macOS drops the ones the display pipe can't draw: 2304x1296 HiDPI on a 1440p monitor goes up to 180 Hz, 2240x1260 up to 240 Hz. `dusk set scaling off` removes them again.

## Install

Prebuilt binary from the [latest release](https://github.com/pstngh/dusk-macos/releases/latest) (arm64, macOS 13 or later):

```bash
curl -L https://github.com/pstngh/dusk-macos/releases/latest/download/dusk-macos-arm64.tar.gz | tar xz
./dusk install
```

The binary is ad-hoc signed, not notarized. Downloads made with `curl` run as-is; if you download the archive in a browser, macOS blocks the binary until you run `xattr -d com.apple.quarantine dusk`.

Or build from source (needs the Xcode Command Line Tools):

```bash
git clone https://github.com/pstngh/dusk-macos
cd dusk-macos
swift build -c release
.build/release/dusk install
```

Either way, `install` copies the binary to `~/.local/bin/dusk` and loads two LaunchAgents from `~/Library/LaunchAgents`. No root needed (only `dusk set scaling on|off` asks for an administrator password, see [HiDPI](#hidpi)).

| LaunchAgent | Runs | When |
|---|---|---|
| `local.dusk.display` | `dusk agent` | At login and whenever a monitor attaches; applies no dithering, then exits |
| `local.dusk.tint` | `dusk tint` | Always (launchd restarts it if it quits); shows the tint and dimming, and the menu bar icon |

`install` also removes `nodither` (its LaunchAgent and `~/.local/bin/nodither`).

## Usage

| Command | |
|---|---|
| `dusk status` | Show `enableDither`, the link, the mode, HiDPI and scaling per external display, HiDPI's settings, the games running, the three looks, tonight's times and what's on screen now |
| `dusk set day\|evening\|night warmth <K>` | Day 1700 to 6500 (no tint), Evening 1200 to 4000, Night 0 (pure red) to 2700 |
| `dusk set day\|evening\|night brightness <percent>` | 30 to 100 |
| `dusk set tint on\|off` | Turn the warm tint and dimming on or off |
| `dusk set dither on\|off` | `off` (the default) applies no dithering; `on` gives macOS back its default link and dithering |
| `dusk set icon on\|off` | Show or hide the menu bar icon |
| `dusk set hidpi on\|off` | Show each external monitor in HiDPI, or in standard resolution, at the size it has now; `on` also keeps it when monitors come and go |
| `dusk set games on\|off` | Standard resolution while a game runs (on by default) |
| `dusk set game <app> on\|off\|auto` | Mark an app as a game or as not a game, or go back to telling by what it does |
| `dusk set scaling on\|off` | Add or remove the HiDPI sizes in between, in System Settings (administrator password) |
| `dusk pause [minutes]` | No tint or dimming for a while (60 minutes by default), then a 30-minute fade back |
| `dusk night` | Night until half an hour before sunrise, then a fade to Day |
| `dusk resume` | End a pause or night |
| `dusk reset` | Back to the default looks |
| `dusk apply` | Apply no dithering and the tint again now, e.g. after another app reset the colours |
| `dusk install` | Install the binary and LaunchAgents |
| `dusk uninstall` | Remove them, restore the default link and dithering, switch HiDPI off and remove the sizes `scaling` added |

```
$ dusk status
AW2726DL
  enableDither  No
  link          8-bit RGB, full range
  mode          2560x1440 HiDPI (5120x2880), 180 Hz
  hidpi         on
  scaling       on: 1600x900, 1920x1080, 2048x1152, 2240x1260, 2304x1296
DELL G2524H
  enableDither  No
  link          8-bit RGB, full range
  mode          1920x1080 HiDPI (3840x2160), 240 Hz
  hidpi         on
  scaling       on: 1200x675, 1280x720, 1440x810, 1600x900, 1680x945
HiDPI
  kept          yes, after monitors come and go or wake
  in games      standard while a game runs
  games now     none
  marked        CS2Runtime, blackops
Tint
  day           4000 K, 100%
  evening       2700 K, 85%
  night         0 K (red), 70%
  sunset        18:17
  fully red by  20:19
  red until     03:53
  sunrise       07:05
  now           Day, Evening from 18:02 · 4000 K, 100%
```

Settings are kept in `~/Library/Preferences/local.dusk.plist`. The log, `~/Library/Logs/dusk.log`, gets a line when a fade starts or ends, when a pause, Night or off begins, and when no dithering is applied.

## How it works

### No dithering

- **Dithering:** `IORegistryEntrySetCFProperty(enableDither = false)` on every `IOMobileFramebufferAP` marked `external` (the parent class of `AppleCLCD2` and `IOMobileFramebufferShim`).
- **Link:** WindowServer's private SkyLight output-mode API. `SLSGetDisplayOutputModeLinkDescriptions` lists the links the current display mode supports, and `SLSConfigureDisplayOutputMode` selects an 8-bit SDR link: RGB full range when offered, otherwise RGB limited, then YCbCr 4:4:4, then 4:2:2. Any 8-bit link leaves the monitor nothing to dither; encoding and range only affect color accuracy. WindowServer saves the choice as `LinkDescription` in its display preferences and restores it when the monitor reconnects, so macOS keeps it on its own across monitor power cycles, sleep/wake and mode switches, with nothing running in between.
- **Status:** `enableDither` comes from the IORegistry (what `ioreg -lw0 | grep enableDither` shows). The link comes from the DCP itself via `IOAVVideoInterfaceGetLinkData`, so it reports what is actually on the cable. Monitors are matched across IOKit, the DCP and CoreGraphics by their EDID product ID and serial.
- **Reapplying:** `local.dusk.display` uses launchd's `com.apple.iokit.matching` event stream on `DCPAVServiceProxy` (`Location = External`), which the DCP publishes each time a monitor attaches, including after the Mac wakes from sleep. launchd starts `dusk agent`, which waits for WindowServer to bring the display online, applies, and exits.

### HiDPI

- **Modes.** dusk reads SkyLight's full mode list (`SLSGetDisplayModeDescriptionOfLength`), which also has the modes marked valid for mirroring only (`kDisplayModeValidForMirroringFlag`) that the public CoreGraphics list and System Settings leave out. WindowServer makes those for a monitor's own resolution and some standard sizes, at twice their size. `hidpi on` picks the HiDPI mode the same size as the current one, at the same refresh rate (or the highest it has) and variable refresh rate setting, and sets it with `SLSConfigureDisplayMode`; WindowServer remembers it per monitor.
- **Games.** `dusk tint` looks at the app in front every 2 seconds, for 5 minutes after an app starts and for a minute after another comes to the front, a full-screen space opens or the displays change, and not at all in between. It checks the windows on screen (`CGWindowListCopyWindowInfo`, about 0.1 ms) for one of that app's covering a display, and only then reads the app's GPU time, which the GPU driver keeps per process in the IORegistry (`accumulatedGPUTime` in the `AppUsage` of its `AGXDeviceUserClient`s, about 1 ms). The Info.plist comes from the app's bundle or the one built into a bare executable (`CFBundleCopyInfoDictionaryForURL`). An app found to be a game stays one until it quits. When it finds the first game, it sets the standard modes for the login session only (`CGCompleteDisplayConfiguration` with `.forSession`), so the HiDPI modes macOS saved stay as they are. It notes the games and the monitors it switched, with their HiDPI modes, in the settings file, so a restarted `dusk tint` still knows them, and 3 seconds after the last game quits sets each monitor back, unless it shows another size by then.
- **Keeping HiDPI.** WindowServer saves the display modes per set of connected monitors (`DisplayAnyUserSets` in `/Library/Preferences/com.apple.windowserver.displays.plist`). 3 seconds after display changes stop (`CGDisplayRegisterReconfigurationCallback`), `dusk tint` notes which monitors are in HiDPI. If a monitor attached, left or woke in the meantime, it first switches back the ones that were in HiDPI before and aren't now, if HiDPI is kept.
- **Scaling override.** `scaling on` writes a display override for each monitor model to `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vendor>/DisplayProductID-<product>` (where BetterDisplay's flexible scaling writes too), through the macOS administrator password dialog. On Apple Silicon, WindowServer (SkyLight's `GenerateModeListForDisplay`) makes each `scale-resolutions` entry of W x H pixels a HiDPI mode that looks like W/2 x H/2, if the display pipe can scale it down to the panel (to half its size at most) and has the bandwidth at that refresh rate. If macOS ships an override for the model, dusk's file starts from it, since macOS reads only the first one it finds. The file is marked with a `local.dusk` key; dusk never changes or removes one without it, such as BetterDisplay's.
- **Reconnecting.** WindowServer reads the override when it sets up a monitor. dusk has it set them up again by disconnecting and reconnecting them (`SLSConfigureDisplayEnabled`, a soft disconnect), with a temporary virtual display (`CGVirtualDisplay`) online meanwhile: it is the main display while they are off, since WindowServer won't disconnect the main display, and keeps the Mac from being without a display. When it goes, WindowServer restores the saved arrangement.

### Tint and dimming

- **Gamma.** Both are one gamma formula per display (`CGSetDisplayTransferByFormula`): each channel's encoded value is multiplied by the warmth colour times the brightness. macOS drops a gamma table when the process that set it exits, so `dusk tint` stays running.
- **Colour.** A blackbody approximation white-balanced to 6500 K, blending smoothly to pure red below 2000 K, so 0 K is pure red.
- **Schedule.** Sunrise and sunset use NOAA's equations (zenith 90.833°). `dusk tint` shows the look for now and sleeps on a wall-clock timer until the 8-bit output next changes, so time asleep counts and the screen is right on wake. Fades move each channel in a straight line between the two looks.
- **Resets.** macOS resets every display's gamma table during a mode switch and when another app that set its own table quits, and can on monitor attach or wake. After any display change or wake, `dusk tint` checks the tables every 20 ms for 3 seconds and sets them again as soon as they were reset; that takes about 25 ms, while the monitor is still blank from the switch. After an app switch or quit it checks three times over 3 seconds. Otherwise it has no timers and doesn't poll.

## Overhead

Measured on a Mac mini M4 with macOS 26.6:

- **Resident:** only `dusk tint`, 13 MB (as `top` shows it), about 8 MB more once the menu has been opened (macOS keeps its menu drawing code loaded), with no idle wakeups, except a look at the app in front every 2 seconds for a minute after you switch apps and 5 minutes after an app starts (about 0.1 ms each). The menu itself is built on each click and emptied when it closes.
- **CPU:** well under a second a day: about 0.07 s per fade (four a day, about 900 one-level steps in all) and 0.1 s at login.
- **Settings changes:** applied in about 30 ms.
- **Display mode switch:** the tint and dimming are back about 25 ms after macOS resets them.

## Notes

- Uses private Apple APIs, so a macOS update can break it. If one disappears, that step is skipped and the run exits 1; turning off GPU dithering only needs public IOKit, so it still happens.
- Tested on a Mac mini M4 with macOS 26.6 and two Dell monitors (one on HDMI, one on USB-C). No dithering was tested through a monitor power cycle and a system sleep/wake; the gamma reset handling through display mode switches and an app quitting. Standard in games was tested with a stand-in game (Metal, without the games category): filling a display at 42 to 94% GPU, borderless or as a full-screen space, it switched both monitors about 6 seconds after it started and back to their HiDPI modes 3 seconds after it quit. In a window at 65%, or filling the display at 1 to 6%, it switched nothing, and neither did VLC playing a 1080p video full screen. Marks and a restart of `dusk tint` while a game ran were tested too. With a real game, openmohaa (a Metal port that declares the games category, 30 to 38% GPU), both monitors switched as it filled the screen and back 3 seconds after it quit. Keeping HiDPI was tested by turning one of two monitors off and on. Wine programs and system sleep weren't part of these tests. Other chips and macOS versions are untested.
- SDR only. HDR needs a 10-bit link.
- `enableDither` resets on reboot; `local.dusk.display` sets it again at login.
- Display mode changes don't undo no dithering. WindowServer applies the saved 8-bit RGB link to whatever mode is active, so a game that switches resolution or refresh rate keeps it, and GPU dithering stays off across the link retrain (tested 4K60 → 4K30 and 240 → 120 Hz, during the switch and after the game quits).
- Night Shift, color profile switches, gamma changes and Color Filters don't reset the link or `enableDither` (tested).
- Don't run another app that tints or dims with gamma tables alongside dusk; they would overwrite each other's tables. If a command-line tool resets the gamma tables, `dusk apply` sets them again.
- While a tint or dimming is on, the display's calibration curve (`vcgt` in its color profile), if it has one, is replaced, like with other gamma-table apps.
- Changing the link (`dusk set dither on|off`, the No dithering menu item, `uninstall`) makes the monitors go black for a second or two while they retrain.
- The location is fixed to Montreal; the coordinates and schedule rules are constants at the top of `Sources/dusk/Tint.swift`.
- `uninstall` switches each external monitor back to the link WindowServer picks by default and turns GPU dithering back on.
- A HiDPI mode is drawn at 4x the pixels, which costs GPU time and memory. dusk switches to standard while a game runs (see [Games](#games)); games that switch to their own resolution are unaffected either way.
- Each switch between HiDPI and standard blanks the monitors for a moment, once when dusk finds the first game and once after the last one quits.
- The sizes `scaling` adds are per monitor model: every monitor of that model gets them. A monitor connected later gets them with `dusk set scaling on`. If the `scaling` line in `dusk status` says they aren't loaded, turning the monitor off and on loads them.
- While `scaling on|off` reconnects the monitors, windows move to the virtual display and back. Tested with two monitors on a Mac mini M4 with macOS 26.6; the windows came back where they were.

## License

MIT
