---
title: "Automations"
description: "Control GazeKeeper from Shortcuts and Siri with App Intents, and from global keyboard shortcuts."
section: "deep-dive"
order: 7
---

GazeKeeper offers its actions to macOS as App Intents. They appear in the Shortcuts app. They run inside the app, so GazeKeeper must be running. If it is not, the action fails with "GazeKeeper isn't running."

## The actions

| Action                | What it does                                                                                          |
| --------------------- | ----------------------------------------------------------------------------------------------------- |
| Start a break         | Starts a break now. It fails with "Breaks are paused — resume them first." if the schedule is paused. |
| Pause breaks          | Pauses for the number of minutes you enter. With the field empty, it pauses until you resume.         |
| Resume breaks         | Lifts a manual pause. A pause from a Focus filter lifts when the Focus ends.                          |
| Snooze the next break | Moves the next break out by 5 minutes. It uses one of the snoozes allowed for that break.             |
| Time to next break    | Says "Next break in N minutes", or "Breaks are paused."                                               |
| Today's stats         | Says the day's taken, skipped and worked-through counts and the score out of 100.                     |

## Siri phrases

Three actions come with ready-made phrases:

- "Start a break in GazeKeeper"
- "When is my next break in GazeKeeper"
- "How are my breaks in GazeKeeper"

The other three are available in the Shortcuts app. Build a shortcut from them, and Siri can run it by the shortcut's name.

## Keyboard shortcuts

**Settings → Shortcuts** binds global keyboard shortcuts. They work in any app.

| Action           | Default |
| ---------------- | ------- |
| Start break now  | ⌘⌥B     |
| Pause / resume   | ⌘⌥P     |
| Snooze 5 minutes | none    |

Click a row, then press the keys you want. If another app already uses the keys, the row says "Couldn't register — shortcut already taken".

## Privacy

Actions run on your Mac and talk to the running app. They make no network request.
