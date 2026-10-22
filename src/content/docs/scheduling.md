---
title: "Scheduling"
description: "How GazeKeeper decides when a break is due, when it lands, and what moves it."
section: "deep-dive"
order: 4
---

## The cycle

The countdown runs for one interval (20 minutes by default). Then:

1. **Heads-up.** A small pill appears: "Break in 1:00". It has **Start now** and **Snooze 5m** buttons. The default heads-up is 60 seconds.
2. **Wait for a pause in typing.** When the heads-up ends, the break starts only if you have not used the keyboard or pointer for 2 seconds. If you are still typing, the pill reads "As soon as you pause…" and the break waits. It waits at most 30 seconds past the end of the heads-up. After that the break starts anyway.
3. **The break.** A full-screen overlay covers every display for the break length (20 seconds by default).
4. **Cooldown.** After the break ends or is skipped, a 30-second cooldown runs. Nothing becomes due during it. The next break is due one interval after the break ended.

## Long breaks

**Long break every** is set to "never" by default. If you set it to _n_, every _n_th break uses the long break length (5 minutes by default) and the long break messages.

## Office hours

**Limit to office hours** is off by default. When it is on, a break that comes due outside the active days and hours is postponed. The countdown restarts for a full interval, and the postponement does not count against your score.

## Time away from the Mac

- **Idle.** If you give no input for the time set in **Away counts as a break after** (1 minute by default), GazeKeeper counts it as a break and restarts the countdown. It records one such break per rest.
- **Sleep, screen sleep and screen lock.** The schedule stops while the Mac is away. If you were away for at least the break length, that counts as a break and the countdown restarts. If you were away for less, you get 60 seconds in which no break can become due.

## Calendar awareness

**Settings → Calendar → Offer breaks before meetings** is off by default. Turning it on asks for calendar access. GazeKeeper reads meeting start times for the next four hours. It treats an event as a meeting if it is not an all-day event and has more than one attendee, a location, or a URL.

The rule is narrow: a break that would be due in the last two minutes before a meeting is moved to three minutes before the meeting starts. A break due earlier, or during a meeting, is not changed. During a call the [detectors](/docs/detectors) hold the break.

If you add or move a meeting, GazeKeeper reapplies the rule to the pending break. If you cancel one, the earlier time stays. If calendar access is off, the setting has no effect and Settings says so.

## Postpone and skip

- **Snooze** moves the break out by 5, 10 or 15 minutes from the menu, or by 5 minutes from the pill, the break screen, a shortcut or Shortcuts. Each due break allows 2 snoozes by default. The count resets when the break starts. When none are left, the snooze controls are disabled.
- **Skip** ends a break that is on screen. The Skip button appears after the first 3 seconds of a break. Esc also skips, if **Allow Esc to skip** is on.
- **Skip Next Break** in the menu cancels the upcoming break and restarts the countdown. During the heads-up it counts as an ordinary skip.

Detector holds do not use up snoozes.

## Pause

The menu pauses for 30 minutes, 1 hour, until tomorrow, or indefinitely. A paused countdown stops and continues from the same point when the pause ends. If you pause during a break, the break ends and is logged as interrupted.

Three things can pause the schedule: you, a [detector](/docs/detectors), and a [Focus filter](/docs/focus-filters). They are separate. The countdown continues only when none of them is active.
