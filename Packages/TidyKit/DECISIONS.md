
### 2. `task_deep_link_pattern` — wrong on both the org token and the path

Confirmed, and worse than reported: the shipped default was wrong **twice**, so no link it produced
could ever have resolved.

1. `{org}` substituted `organization.productive_organization_id` — the **numeric** id the
   `X-Organization-Id` header requires (`2650`). The web app routes on the **slug**
   (`2650-4site-interactive-studios-inc`). Different strings; neither substitutes for the other.
   The app's own Doctor tip already told users to *strip* the slug down to the number, guaranteeing
   `{org}` is numeric.
2. The path was `/task/{task_id}`. The real shape is `/tasks/task/{id}` — plural collection segment,
   then singular.

Confirmed against a live task on 2026-08-28:
`https://app.productive.io/2650-4site-interactive-studios-inc/tasks/task/18609405`.

**Resolution:** `organization.productive_org_slug` added; `{org_slug}` token added; default is now
`https://app.productive.io/{org_slug}/tasks/task/{task_id}`. `{org}` substitutes the numeric id
exactly as before, so an existing config is untouched — including the live machine's hand-written
workaround, which hardcodes the slug and uses no `{org}` token at all (pinned by test).

The slug lives in `organization`, not `productive`, because it identifies the org and is read off
the same address-bar string as the numeric id — one setup step teaches both.

**`url(...)` now returns `String?`, and an unfillable token suppresses the link.** Rejected
alternatives:
- *Substitute empty* → `https://app.productive.io//tasks/task/18609405`, a link that promises a task
  and delivers a 404. Worse than no link: it costs a context switch to discover, and it is not
  self-explaining. In an app whose whole posture is "we only show you things" (G1), one dead
  affordance discredits the suggestion carrying it.
- *Fall back to the numeric id* → assumes Productive's router redirects id → slug. Nobody has
  verified that. Shipping a guess as a silent fallback recreates the bug being fixed, and it fails
  invisibly.

**Correction to the report's framing, worth stating plainly:** "every deep link the suggestion cards
render would 404" overstates it — **no card renders one at all.** `ProductiveDeepLink` had exactly
one caller in the tree and it was a test; `suggestions.deep_link` is always `NULL`; the recap card
offers only Copy / Log it / Toss. The defect was real but entirely latent. It is now correct and
ready for the card that will use it; wiring that card is deliberately **not** in this change and is
recorded as still-open under A2.

The one existing test asserted the wrong shape as correct — replaced with nine that pin the real
URL, the back-compat path, the hand-hardcoded pattern, and every suppression case.
