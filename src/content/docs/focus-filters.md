---
title: "Focus filters"
description: "Pause GazeKeeper while a macOS Focus is on."
section: "deep-dive"
order: 8
---

A Focus filter lets an app change its behaviour when a Focus turns on. GazeKeeper has one filter, **Pause breaks in this Focus**. It has one option, **Pause breaks**.

## What the filter does

When the Focus turns on, the schedule pauses. The countdown stops and no heads-up or break appears. If a break is on screen, it ends and is logged as interrupted. When the Focus turns off, the countdown continues from where it stopped.

The Focus pause is separate from a pause you start and from a detector hold. Ending the Focus does not lift a pause you started yourself.

## Set it up

1. Open **System Settings → Focus** and choose a Focus. You can create one first.
2. Under **Focus filters**, click **Add Filter** and choose **GazeKeeper**.
3. Leave **Pause breaks** on.
4. Repeat for every Focus where you want breaks to stop.

## Troubleshooting

The menu says "Paused" while the schedule is held. The schedule runs again only when all three pauses are lifted: yours, a [detector](/docs/detectors) hold, and the Focus filter. To end a pause you started, choose **Resume Scheduling** in the menu. To lift the Focus pause, turn the Focus off or remove the filter from it.
