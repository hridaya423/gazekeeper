---
title: "Stats"
description: "What the Dashboard counts, how the 0 to 100 Screen Score is worked out, and how to export your history."
section: "deep-dive"
order: 6
---

GazeKeeper keeps a local log of what happened. The Dashboard and the Screen Score are worked out from that log on your Mac. Choose **Dashboard** in the menu bar item to open it.

## The Dashboard

- **Next break.** A countdown, and whether the schedule is paused.
- **Today's score.** The score ring with its two parts. Until your first break of the day, it shows "No breaks yet today".
- **Four counts for today.**
  - **Taken**: breaks you sat through. A rest that GazeKeeper saw while you were away from the Mac also counts.
  - **Postponed**: breaks you snoozed.
  - **Skipped**: breaks you skipped.
  - **Worked through**: breaks where you used the keyboard or pointer during the break. These are not counted as taken.
- **Cadence check.** A suggestion card. It appears only in the case described below.
- **Breaks.** A bar chart of taken, snoozed and skipped breaks for each day. Switch between the last week and the last month.
- **Summary.** Your streak in days, the breaks you took this week, and your average score for the week.

## Screen Score

The score runs from 0 to 100. It is the sum of two parts. The **i** button next to the headline explains them. The headline is "Strong day" from 70, "Holding up" from 40, and "Room to rest" below that.

- **Discipline: up to 60.** It starts at 60 once a break has come due. A break you take or start costs nothing. A break you skip or snooze costs 2 points for each minute between when it came due and when you skipped or snoozed it. A break left unanswered costs the same until the session ends.
- **Adherence: up to 40.** The share of due breaks you took, times 40, rounded down. Each skip takes off 4 points and each snooze takes off 2. A worked-through break counts as due but not as taken.

Some things never affect the score. Postponements that GazeKeeper makes itself, because you were idle or outside office hours, are ignored. So is **Skip Next Break** before a break is due. A detector hold only pauses the schedule, so it creates no due break.

A day with no due breaks has no score. It does not get a zero, and it does not pull your weekly average down.

## Streak

The streak counts consecutive days, back from today, with at least one taken break. A day with no due breaks, such as a day off, does not break the streak and does not add to it. A past day with due breaks and no taken break ends it. Today does not end it before the day is over.

## Cadence check

If at least 10 breaks came due in the last 7 days and more than 40% of them were skipped, snoozed or worked through, the Dashboard offers a change. It suggests the smallest interval from 10, 15, 20, 25, 30, 45 and 60 minutes that is at least 1.5 times your current one. If you are already at the top of that list, it suggests turning on long breaks. You can apply the change or dismiss it. A dismissed suggestion is not offered again.

## Weekly digest

The weekly digest is optional and off by default (**Settings → Wellness**). On Monday at 09:00 it shows a short note: "Last week: N taken, N skipped, N worked through — avg score N." If last week had no due breaks, or the app was not running that Monday morning, nothing is shown.

## Export

Use the export button at the top right of the Dashboard and choose **CSV** or **JSON**. A save panel asks where to write the file. The name is `gazekeeper-stats` plus the extension.

Both files hold the whole event log. The CSV columns are `timestamp`, `kind` and `reason`. The JSON file is a list of events with `at`, `kind` and `reason`, plus `durationSeconds` when it is not zero. The kinds are:

`session_started`, `session_ended`, `break_due`, `break_started`, `break_taken`, `break_worked`, `break_skipped`, `break_postponed`, `break_interrupted`, `natural_break`, `snooze_exhausted`, `detector_paused`, `detector_resumed`, `nudge_sent` and `menu_revealed`.

The log lives in `stats.jsonl` in the data folder. See [installation](/docs/installation#where-your-data-lives).

## What stats never do

The data leaves your Mac only if you export it.
