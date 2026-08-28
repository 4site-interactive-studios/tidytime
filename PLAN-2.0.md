# 4Timer 2.0 plan

**For:** Heming, Fernando  
**From:** Bryan  
**Date:** August 28, 2026  
**Status:** Draft for discussion. No code gets written until we agree on this.

## The short version

I built a Mac app called TidyTime and have been running it since late July. It watches what I actually do all day, reconstructs the day into blocks, matches each block to a Productive client, project and task, and hands me a ready-to-enter time entry with a note and a link straight to the task.

I built it because the hours I lose are the ones that never got captured: the client minutes buried inside an internal call, the drive-by Slack messages, the block I would have misremembered by Friday. Tracking hours was never the hard part. Deciding what each block was for is.

What it does not do is write to Productive. That was a deliberate line in v1. 2.0 is where we cross it, and that is the decision I need from you two.

Three asks today: agreement this is worth continuing, a yes or no on write access, and reserved time to do step 1, which I have blocked as [hours, item 1] on the capacity report.

## Where it stands today

### What it does

It lives in the menu bar and shows two numbers all day: hours observed and hours logged. Underneath that, four things are happening.

**It watches.** Foreground app and window title, Chrome URL and title and visible page text, idle and away time, and whether you are in a meeting. Window titles come from the Accessibility permission, so it never asks for Screen Recording and never sees your screen.

**It pulls context, read-only.** Your Productive clients, projects, tasks and the entries you have already logged. Fathom meetings, where the recording start and stop is the real duration and the transcript is speaker-stamped. Google Calendar events and attendees. Slack direct messages and channels.

**It reconstructs the day.** Raw activity becomes sessions, short detours get absorbed into the block they interrupted, and each session gets matched to a client, then a project, then a task. Where it is unsure it asks a one-line question and remembers your answer for next time.

**It hands you entries.** At a set time, 5pm by default, the recap opens. Left side is the day as a timeline, colored by client, with meetings, away gaps and your already-logged entries drawn in so the holes are obvious. Right side is a stack of cards. Each card is client, project and task, a duration rounded to 15 minutes, a confidence indicator, a plain line explaining why it thinks so, and an editable one or two sentence note. Buttons copy the note, copy the duration and note together, open that task in Productive, or mark it handled.

Four behaviors in there are the ones that matter:

- a one-hour internal call gets split by client off the transcript, so the 20 client minutes buried inside it show up as their own entry
- a dozen four-minute drive-bys on the same project pool into one rolled-up entry with an itemized note, instead of a dozen entries nobody would ever make
- it compares against what you already logged, stays quiet about what is reconciled, and only surfaces the delta
- when there is a clear client and project but no task that fits, it proposes the new task rather than dropping the time

It also nudges during the day when a block gets big enough, rate-limited and quiet during meetings, and it learns from what you dismiss. It asks what a 40-minute gap was: break, call, or something else. The dashboard tracks observed against logged, billable against internal, weekly totals per client, capture health, and what the AI cost.

### How it was built

A native Mac app in Swift and SwiftUI. One process, no background daemons. The app target itself is a thin shell: all the logic sits in eight SwiftPM library modules, which is what makes 279 unit tests possible without launching the app at all. Storage is SQLite through GRDB in the user's Application Support folder, secrets are in the Keychain and nowhere else, and XcodeGen generates the Xcode project so the build is reproducible.

The interesting part is the classification ladder. Attribution runs local first, then cheap, then smart: deterministic rules, then fuzzy matching against a client registry, then Apple's on-device model, then an economy cloud model, and Claude only when a case escalates past all of that. Most of a day never leaves the machine.

I built it driving Claude Code, on the same spec-first pattern we use in 4Site Labs: a locked plan, phase docs, an append-only decisions log, and three rounds of adversarial review against the code that got written.

### What is proven and what is not

**Proven live on one Mac,** July 25 to 27. Signed app installed, macOS permission grants surviving rebuilds, capture banking real sessions with window titles, credentials in the Keychain, and live Slack and Fathom syncs including their first-run failures, which the app's own diagnostics caught and I fixed.

**Not proven yet.** The Google sign-in click, Productive sync against live data (it is waiting on our organization id in config), the cloud AI tiers, and the recap and dashboard under real daily use. Tests cover the logic at 64.3% line coverage, but they cover no SwiftUI view. Last commit was July 27. It has sat for a month while the Trust for Public Land launch went out the door.

So the accurate summary is a tested library and a working capture layer, not a finished product. Anyone who tells you it is done, me on a call included, is rounding up.

One piece is already earning its keep. The context-switching number I quoted on our goals call comes out of this app: switches per hour, dwell time, brief-switch fragmentation, longest focus block, persisted daily.

## What 2.0 is

Three steps, in order, each ending in something we can judge.

**Step 1. Finish v1 and use it for two weeks.** Productive sync live, Google sign-in done, cloud tiers on, and me reconciling every day from the recap. The output is one number: what percentage of suggestions I accept without editing. That number decides everything after it. At 40% this is a toy. At 80% it is a product.

**Step 2. The approve button.** Today the app recommends and I type. 2.0 is a tap that writes the entry into Productive. That means write scope on the token, an audit log of every entry the app created, and an undo. This is the entire reason to build 2.0, and it is also the part that has to be designed rather than bolted on, which is why v1 refuses to write at all.

**Step 3. A second person on it.** Config profiles so the 4Site-specific parts are not hardcoded to me, a setup doc, and a signing path so it installs on someone else's Mac without a fight. Fernando is the obvious first pilot. Second best is whoever complains loudest about time entry.

Everything past that is real but it is not 2.0: Safari and Firefox support, recap timing learned from when I actually wind down, a weekly digest, Fathom webhooks instead of polling, and eventually a surface living inside Productive itself.

## What it would run on

Fernando, this section is for you.

There is no hosting. It is one Mac app writing to one local database, and every API it touches today is read-only. Nothing to deploy, nothing to monitor, no shared state between people. The stack is in the section above.

The only shared infrastructure 2.0 adds is a cloud AI account, and that is an API key with a budget cap, not a service we operate.

Rules already enforced in the code that I want to keep:

- a sensitivity gate that fails closed, so personnel, comp and legal content never reaches a cloud model
- every cloud call metered, with provider, model, tokens, cost and outcome landing in a local ledger, so AI spend is a number we can report as overhead
- no Screen Recording permission ever requested
- raw activity and page text purged after 90 days, distilled summaries kept

The thing I want you to push hardest on is the write path in step 2. That is where this stops being a personal tool and starts being something that can put wrong data into our system of record.

## Decisions I need from you

1. **Write access to Productive.** Yes or no. Everything in step 2 depends on it, and it is a real risk call, not a formality.
2. **The name.** The app is TidyTime, which sits next to TidyContact. 4Timer came out of our call and I like it, but the name is baked into the bundle identifier, and macOS ties permission grants to that identifier. Renaming now costs an afternoon. Renaming after other people have installed it means everyone re-grants their permissions. My vote is keep TidyTime as the product and let 4Timer be what we call it in conversation.
3. **Whose cloud AI account bills.** Mine or 4Site's. The ledger produces the overhead number either way, so this is purely an accounting decision.
4. **$99 a year for the Apple Developer Program.** My free personal signing covers my Mac. Putting the app on anyone else's Mac needs a Developer ID certificate and Apple notarization, and both require the paid program. I confirmed that against Apple's developer documentation today.
5. **Who pilots it second, and when.**

## What I am not doing

I am not writing code on this until we have agreed on the above. This is the planning deliverable, not the start of the build. The reason is the one you already named on Friday: I have a habit of going off and building the thing first, and the capacity report is the example we both point at.
