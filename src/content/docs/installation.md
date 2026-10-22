---
title: "Installation"
description: "Install GazeKeeper on your Mac and what to expect on first launch."
section: "getting-started"
order: 2
---

## Download the DMG

Download `GazeKeeper.dmg` from the [download page](/download) and open it. Drag **GazeKeeper** into your Applications folder. Eject the disk image, then open the app from Applications.

## Requirements

macOS 14 (Sonoma) or later.

## First launch

GazeKeeper has no Dock icon or main window. It adds an icon to the menu bar. The first launch opens a welcome window with three steps:

1. **Rhythm.** Choose one of three presets: every 20 minutes for 20 seconds (the default), every 30 minutes for 1 minute, or every 50 minutes for 5 minutes. You can change both numbers later.
2. **Holds.** Switch on or off the four smart-pause signals: camera in use, microphone in use, screen sharing and fullscreen apps. This step also has an **Allow** button for notifications.
3. **Start.** Choose whether GazeKeeper opens at login. A **Try one** button runs a 5-second break so you can see the break screen.

Office hours are off by default, so breaks run whenever the app runs. To see the welcome again, choose **Show Welcome** in the menu bar item.

## Permissions

- **Notifications.** GazeKeeper uses notifications for one thing: a heads-up banner when a fullscreen app is in front and the fullscreen detector is off, so the pill cannot appear. If you decline, everything else works.
- **Calendar.** macOS asks when you turn on **Settings → Calendar → Offer breaks before meetings**. GazeKeeper reads meeting start times only.

There is no account and no sign-in.

## Updates

GazeKeeper checks for updates through Sparkle. You can also choose **Check for Updates** in the menu bar item.

## Where your data lives

Settings and stats are stored in `~/Library/Application Support/GazeKeeper`. Choose **Settings → Advanced → Reveal stats & settings folder** to open it. To remove the data, quit the app and delete that folder.

To change the rhythm, see [setting up](/docs/setting-up).
