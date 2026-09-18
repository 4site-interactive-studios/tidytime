# 4Timer 2.0 MVP brief

**For:** Heming, Fernando  
**From:** Bryan  
**Date:** September 18, 2026  
**Status:** Replaces the scope in the August 28 plan. No code gets written until we agree on this.

## The goal

One of my main goals is to create software that helps me, and potentially others, track time more accurately and promptly. This brief is the smallest version of 4Timer (TidyTime in the repo) that I can hold up against that sentence with numbers.

## What the MVP is

Get the app's suggested Productive task to match the time it recorded. That's the whole MVP.

The app already watches my day and already proposes entries. What it doesn't do well yet is pick the right project and task, and until it does nothing else about it matters. I ran this against my own database today, covering the last 14 days:

1. Screen time: 10% gets matched to a project and 1% to a task
2. Meetings: 72% to a project, 22% to a task
3. Slack: 0 of 88 sessions matched to anything

Most of those misses aren't bad guesses. The matcher is being handed nothing to guess with. 8.7 of my 12.4 Chrome hours were recorded as a blank new tab, Slack sessions never pass along the channel name or the message text, and the app can remember a client or a project but has no way to remember a task.

## How we'll know it's working

I logged 105 entries in Productive over the last 30 days and every one has a task on it. So I can replay those days through the app and grade its suggestions against what I actually entered, without changing how I work. That replay is what I mean below by a backtest. It gives us three numbers:

1. **Match.** Of the minutes I logged, what percent the app would have put on the same project, and on the same task. This is the "accurately" half of the goal.
2. **Coverage.** Of the work minutes the app observed, what percent ended up in Productive. September 8, 9 and 10 have zero entries from me, and the app should be the thing that catches that the next morning.
3. **Lag.** Days between doing the work and the entry existing in Productive. This is the "promptly" half. It can't be measured today because the app doesn't store when an entry was created. That's a small read-only fix.

Provisional targets until I have a baseline: the right project on 80% of logged minutes, the right task as the first pick on 50%, and in the top three on 75%.

## The work, in order

1. **Install the build that merged September 9** (half a day). The version running on my Mac still counts the lock screen as work, so every observed-hours number is inflated until this is in.
2. **Build the backtest and the scoreboard** (3 to 4 days). Every step after this one gets judged by whether the three numbers move.
3. **Feed the matcher** (about a week). Fix the Chrome new tab capture, pass Slack channel names and message text through, and handle apps whose window titles say nothing. Claude desktop was 6.1 hours across 2 distinct titles.
4. **Rank tasks inside a project** (about a week). Once the project is known, score its open tasks against what was on screen, weighted toward tasks assigned to me and tasks I logged to recently. The card shows the top three.
5. **Learn from what I already log** (about a week). Each day's Productive entries become the answer key for that day's recorded time. No extra clicking.
6. **Show open days in the menu bar** (a couple of days). Something like "2 days open, about 9h unlogged," with the recap opening on the oldest open day.

That's roughly four weeks of focused time: [hours, capacity report line].

## What's out

- One click logging to Productive. The app stays read-only and the test that enforces it stays on. It can come later, once the match number has earned it.
- A second person, which means signing, onboarding, and the $99 Apple Developer Program. "Potentially others" is a build rule for now: nothing specific to me gets hardcoded, and the backtest runs for any Productive person.
- Cloud AI, unless the scoreboard shows local matching has plateaued. Cloud spend to date is $0.
- Nudges. Nudging me at 10% accuracy would teach me to ignore the app.

## What I need from you

1. **A yes on the narrower scope.** This replaces the write access decision I asked for on August 28. That one is off the table for now.
2. **Reserved time.** [hours] on the capacity report, starting [exact date].

Once I have the time, you get the baseline numbers from step 2 on [exact date].
