---
title: "Setting up"
description: "Every setting in GazeKeeper, with its default."
section: "getting-started"
order: 3
---

Open the menu bar item and choose **Settings**. The Settings window is one list of sections.

## Breaks

| Setting           | Default | Range            |
| ----------------- | ------- | ---------------- |
| Every             | 20 min  | 1 to 240 min     |
| Break length      | 20 sec  | 10 to 600 sec    |
| Snoozes per break | 2       | 0 to 10          |
| Long break every  | never   | 0 to 20 breaks   |
| Long break length | 5 min   | 30 sec to 60 min |

The long break length appears only when **Long break every** is not "never". A long break replaces every nth regular break.

Two timings are not in the Settings window. The heads-up pill appears 60 seconds before a break. A 30-second cooldown follows each break. See [scheduling](/docs/scheduling).

## Office hours

**Limit to office hours** is off by default. When you turn it on, GazeKeeper shows an active window (09:00 to 17:00 by default) and a toggle for each weekday (Monday to Friday by default). A window that crosses midnight works. With no day selected, every day is active. See [scheduling](/docs/scheduling) for what happens outside the window.

## Calendar

**Offer breaks before meetings** is off by default. See [scheduling](/docs/scheduling).

## Break overlay

- **Background**: blurred desktop (default), a solid colour, or an image you choose. If the image is missing, the overlay falls back to blur.
- **Allow Esc to skip**: off by default.
- **Chime when a break ends**: on by default.
- **Messages**: the text on the break screen. You can keep up to 12 messages of up to 200 characters each. GazeKeeper shows them in order, one per break. Long breaks use a separate built-in list that you cannot edit.
- **Take a break now** starts a break immediately.

## Appearance

**Accent** is GazeKeeper teal (default) or your system accent colour.

## Wellness

Nudges are on by default. They are small notes at the bottom of the screen that disappear after four seconds. They are not system notifications.

| Setting       | Default |
| ------------- | ------- |
| Posture nudge | 30 min  |
| Blink nudge   | 5 min   |
| Quiet hours   | off     |
| Weekly digest | off     |

Quiet hours, when on, silence nudges between two times. The window is 22:00 to 08:00 until you change it. Nudges also wait while a break or heads-up is on screen, while you are typing, and while a detector holds the schedule. You can write your own posture and blink text.

The weekly digest is a note on Monday at 09:00 that sums up the previous week. If that week had no breaks, or the app was not running on Monday, GazeKeeper shows nothing.

## Smart pause

Four toggles, all on by default: camera in use, microphone in use, screen being shared, and an app in fullscreen. **Away counts as a break after** is 1 minute by default. **App rules** lets you add a running app and mark it Pause or Ignore. See [detectors](/docs/detectors).

## Shortcuts

| Action           | Default shortcut |
| ---------------- | ---------------- |
| Start break now  | ⌘⌥B              |
| Pause / resume   | ⌘⌥P              |
| Snooze 5 minutes | none             |

Click a row to record a different shortcut.

## General

- **Launch at login**: off by default.
- **Show time in menu bar**: on by default. When off, the menu bar shows the ring only.

## The menu bar item

The menu shows the countdown and these actions:

- **Start Break Now**
- **Snooze**: 5, 10 or 15 minutes. It shows how many snoozes are left.
- **Pause**: 30 minutes, 1 hour, until tomorrow, or indefinitely.
- **Skip Next Break**: cancels the upcoming break and starts the interval again.
- **Settings**, **Dashboard**, **Show Welcome**, **Check for Updates** and **Quit**.

If a detector holds the schedule, the menu says why.

## Advanced

**Reveal stats & settings folder** opens the data folder in Finder. **Replay onboarding** shows the welcome window the next time GazeKeeper starts. To open it now, choose **Show Welcome** in the menu bar item.
