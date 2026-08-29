# TidyTime — alpha handoff and MVP scope

**Status: working alpha, one user, one machine.** Written 2026-08-28, after the QC pass that
preceded this document.

This is the document to read before touching the code or before deciding what the MVP is. It says
what the build actually does today (measured, not designed), what is written but dark, what it costs
a new person to get running, and what has to be true before anyone else installs it.

---

## 1. What it is

A macOS menu-bar app that watches what you work on and proposes time entries for Productive at the
end of the day. It never writes to Productive — that is guardrail
[G1](guardrails.md#g1--v1-never-writes-to-productive), enforced by test — so the worst thing a wrong
suggestion can do is waste one click.

The chain, in the order data moves:

```
capture → sessionize → classify → suggest → recap → decide → learn
```

- **capture** — frontmost app, window title, active browser tab, and (slowly, deduped) visible page
  text. Accessibility + Apple Events only. Never Screen Recording ([G3](guardrails.md#g3)).
- **sessionize** — collapses samples into contiguous blocks of work.
- **classify** — attributes a block to a client / project / task via a five-rung ladder. Rungs 3–5
  are cloud and currently dark.
- **suggest** — rounds to billing increments, pools micro-work, subtracts what you already logged.
- **recap** — a card stack at 17:00. Log it / toss it / reassign it.
- **learn** — your decision writes a `user_confirmed` signal that outranks everything, forever.

## 2. What actually runs today

Measured on the author's live install, 2026-08-28, after ~5 weeks of continuous capture.

| | Measured |
|---|---|
| Activity samples captured | 48,358 |
| Sessions built today | 91 |
| **Today's time attributed to a client** | **70.4%** |
| Attribution by rung today | 20 at rung 1 (exact / signal), 48 at rung 2 (lexical) |
| Productive mirror | 11,631 / 11,631 tasks carry their project |
| Client vocabulary | 1,379 bootstrapped signals |
| Suggestions today | 10 cards — 2 sessions, 1 meeting segment, 1 new task, 6 pools |
| Suggested vs observed | 420 min suggested for 395 min observed (**1.06×**) |
| Open ask-once questions | 1 |
| Decisions recorded | **0** |

That last row is the honest headline: **nobody has ever accepted a card.** Until this afternoon
"Log it ✓" silently failed on any card older than five minutes, so the number is a bug report, not a
usage statistic. It is the single most important thing to watch after this handoff — see §6.

## 3. What is written, tested, and dark

Every item below has passing unit tests and **no production call site**. This is the project's
signature defect: a correct component nothing calls, which no test can notice, because a job that is
never invoked cannot fail. Six were found and wired this week; these remain.

| Subsystem | Consequence today |
|---|---|
| `PowerObserver` (away/idle) | `away_gaps` is 0 rows; `AwayPrompt` never appears; the context-switch metric loses its idle-clipping input |
| `NudgeEngine` / `NudgePresenter` | `nudges` is 0 rows; no nudge is ever delivered |
| Answer-half of the learning loop (`AwayResolving`, `NudgeOutcomeRecording`) | those write paths never run |
| All of Phase 6 — `AIRouter`, `NoteDrafter`, the three providers, rungs 3–5 | `ai_calls` is 0 rows. **This is a Phase 5 acceptance criterion, not a defect.** |

`GuardrailEnforcementTests.testPipelineJobsHaveProductionCallSites` now pins the six jobs that *are*
wired, so deleting a call site is a test failure. It does not yet detect a *new* orphan. A Doctor
panel listing every pipeline job with its last-run time would — see §7.

## 4. Getting it running

Full detail in [RUNNING.md](RUNNING.md) and [permissions-setup.md](permissions-setup.md); the shape
of it:

```bash
make dmg
```

Then install, and grant **Accessibility** and **Automation** (Chrome + System Events). Two things
bite everyone:

- **Signing.** `Local.xcconfig` is gitignored and holds `DEVELOPMENT_TEAM`. Without a stable
  signature, macOS treats each rebuild as a new app and every TCC permission has to be re-granted —
  that is what [G7](guardrails.md#g7) is about. Copy the file from someone who has it, or set your
  own team. See [build/signing-and-tcc.md](build/signing-and-tcc.md).
- **Chrome page text** needs View → Developer → "Allow JavaScript from Apple Events" once. Without
  it the app still works, on URL and title alone, and Doctor says so rather than failing silently.

`make doctor` (or the Doctor pane) reports every permission and ingest source as a row, so "it isn't
working" resolves to a specific missing thing in about ten seconds.

Secrets live in the Keychain only ([G6](guardrails.md#g6)); `config.json` has no field that can hold
one, and a test enforces that.

## 5. What the MVP has to add

Ordered by what stops the next person from getting value, not by size.

**1. Someone other than the author has to be able to install it.**
Signing is the whole story. Today it needs a hand-copied gitignored file. Either check in a shared
team id, or document the "use your own" path so it is a five-minute step rather than a support
conversation.

**2. Editing a suggestion.**
The recap can accept, toss, and reassign. It cannot change the minutes or the note. Every real
timesheet has a "that was 45 minutes, not 60" moment, and today the only options are accept a wrong
number or throw the card away — which also throws away the correction the system would have learned
from.

**3. Actually logging to Productive.**
G1 makes v1 read-only deliberately, and that was right for an alpha. But the product's promise ends
one step short of the thing it promises: the user still retypes everything. This is the v2 line, and
it needs audit + undo designed properly before it is crossed — not bolted on.

**4. A second person's data.**
Every measurement in §2 comes from one workspace: 687 companies, 965 projects, 11,631 tasks, and a
strong bias toward web work in Chrome. The lexical rung's precision is tuned against that shape and
nothing else. The first genuinely different user — heavier meeting load, a different browser, a
workspace with 20 clients instead of 687 — is the real test, and some of the tuning will be wrong.

**5. Somewhere for a wrong rule to go and die.**
`user_confirmed` signals outrank everything forever and there is **no removal path in the UI**. One
mis-click writes a permanent rule. Guarded this afternoon against the specific case that made it
likely (tool hosts like `youtube.com` are no longer confirmable), but the general hole is open: the
system can be taught and cannot be un-taught.

**6. Onboarding that does not assume the author.**
First launch seeds a config and shows a menu-bar icon. It does not explain what the app is about to
watch, or offer the exclusion lists before it starts watching. For a tool whose entire value rests on
being trusted with your screen, that ordering is backwards.

## 6. Watch these first

The three things most likely to be wrong in a way the tests cannot see:

- **Does anyone accept a card?** `SELECT COUNT(*) FROM decisions;` If this stays 0 after a week of
  someone using it daily, the suggestions are not good enough and no amount of pipeline work will
  fix that.
- **Suggested vs observed minutes.** 1.06× today. If it climbs past ~1.3× the rounding is billing
  noise again, and the first thing to check is the pool count.
- **Rung mix.** 20 rung-1 / 48 rung-2 today. Rung 2 is lexical guessing; a healthy system moves work
  from 2 to 1 as it learns. If the ratio does not improve with use, the learning loop is not closing
  — which, given §2's last row, has never actually been observed working end to end.

## 7. Things known to be wrong

Not blockers, but do not rediscover them:

- **No orphan detection.** Nothing reports "job defined, never invoked." Five separate bugs this
  week were instances of it. A Doctor panel listing pipeline jobs with last-run times would surface
  the next one in seconds instead of weeks.
- **Confidence is calibrated by argument, not by data.** The numbers now discriminate (five distinct
  values across ten cards, where nine of fourteen used to read 0.82), but no one has ever checked
  whether an 0.80 card is right more often than an 0.76 one. Once `decisions` has rows, that becomes
  measurable — and it is the only way to know whether the ladder's thresholds are sane.
- **The exclusion lists are config-file only.** Private browsing is never recorded and needs no
  setup, but adding `chase.com` means hand-editing JSON. Settings shows the lists; it cannot edit
  them.
- **Coverage is 64% line / 69% region.** The gap is concentrated in the live AX / AppleScript /
  NSWorkspace wiring, which is deliberately untested and deliberately thin. Treat a number moving
  down as a signal; do not chase the number up.

---

## Appendix — where things live

| Looking for | Go to |
|---|---|
| Why a decision was made | [`DECISIONS.md`](../DECISIONS.md) — appended to, never rewritten |
| The rules that cannot be broken | [`guardrails.md`](guardrails.md) |
| How a layer is supposed to work | [`architecture/`](architecture/) — read the shipping-status callouts |
| Getting it running | [`RUNNING.md`](RUNNING.md), [`permissions-setup.md`](permissions-setup.md) |
| What is still open | [`open-items.md`](open-items.md) |
