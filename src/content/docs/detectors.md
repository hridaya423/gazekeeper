---
title: "Detectors"
description: "The signals that hold a break for you: camera, microphone, screen sharing, fullscreen and app rules. Also the pause in typing."
section: "deep-dive"
order: 5
---

Detectors hold your breaks during things that should not be interrupted.

## What a hold does

When a detector fires, the schedule pauses. The countdown stops where it is. When the signal clears, the countdown continues from the same point. There is no extra delay.

If a signal starts while a break is on screen, the break ends and is logged as interrupted. The menu bar item says why the schedule is paused, for example "camera in use".

You can turn each signal on or off under **Settings → Smart pause**. All four are on by default.

## The signals

### Camera in use

Any app that is capturing from a camera. GazeKeeper listens to the system's camera state. It does not poll.

### Microphone in use

An app that is capturing from the default audio input. An audio-only call counts.

### Screen sharing

GazeKeeper looks for the windows that macOS system sharing and recording services own, such as `screensharingd` and `replayd`. This needs no screen-recording permission.

### Fullscreen

The frontmost app has a window that covers at least 90% of one screen. GazeKeeper checks this only when a break is within two minutes, during the heads-up, or during a break. A window that does not fill the screen does not count.

### App rules

Under **Settings → Smart pause → App rules**, add a running app and choose a rule:

- **Pause.** While this app is frontmost, the schedule is paused.
- **Ignore.** The fullscreen check skips this app. Camera, microphone and screen sharing signals still apply.

An app rule is checked first. A **Pause** rule holds the schedule even if the other signals are off.

If several signals are active, the menu bar item shows the one with the highest priority: app rule, then camera, microphone, screen sharing, fullscreen.

## The pause in typing

This is not a detector. It has no toggle. When the heads-up ends, the break waits until you have not used the keyboard or pointer for 2 seconds. It waits at most 30 seconds past the end of the heads-up. Then the break starts. GazeKeeper reads only how long ago the last input happened. It does not read keystrokes. Posture and blink nudges use the same 2-second rule.

## What detectors never do

Detectors read system state: whether a camera or microphone is running, whether a sharing service has a window, which app is in front, and how large its window is. They do not record audio, video or keystrokes. They do not read window contents.

Every hold and release is written to the local event log.
