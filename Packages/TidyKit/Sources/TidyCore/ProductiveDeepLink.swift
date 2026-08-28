import Foundation

// Moved here from TidyIngest: this is pure string substitution with no I/O, and its only inputs are
// `Config` values that already live in TidyCore. Keeping it in the ingest layer meant TidySuggest
// could not populate `suggestions.deep_link` without taking a dependency the module map forbids —
// so the column stayed NULL and the "Open in Productive" button was never built.

/// Builds the web deep-link for a task from the configured pattern.
///
/// Two different org identifiers exist and they are **not** interchangeable:
/// - `{org}` → the numeric id (`2650`), which is what `X-Organization-Id` requires.
/// - `{org_slug}` → the web URL segment (`2650-4site-interactive-studios-inc`), which is what
///   `app.productive.io` actually routes on.
///
/// The original implementation substituted the numeric id into the web URL and used the path
/// `/task/{id}`. The real shape, confirmed against a live task on 2026-08-28, is
/// `https://app.productive.io/{slug}/tasks/task/{id}` — wrong on both counts, so every link it
/// produced would have 404'd. `{org}` still substitutes exactly as before, so a config that
/// already uses it keeps working.
public enum ProductiveDeepLink {
    /// `nil` when the pattern needs a value the config does not supply — callers **must** hide the
    /// affordance rather than open a URL that cannot resolve.
    ///
    /// Returning `nil` rather than substituting an empty string is deliberate. An empty slug
    /// yields `https://app.productive.io//tasks/task/18609405`: a link that promises a task and
    /// delivers a 404. In an app whose entire posture is "we only show you things, we never write"
    /// (guardrail G1), one dead affordance discredits the suggestion carrying it — and it costs a
    /// context switch to discover. Falling back to the numeric id was also rejected: whether
    /// Productive's router redirects id → slug is an unverified guess, and shipping a guess as a
    /// silent fallback recreates exactly the bug being fixed, failing invisibly.
    public static func url(taskId: String, organizationId: String,
                           organizationSlug: String = "", pattern: String) -> String? {
        let slug = organizationSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskId.isEmpty else { return nil }
        if pattern.contains("{org_slug}"), slug.isEmpty { return nil }
        if pattern.contains("{org}"), id.isEmpty || id == "REPLACE_WITH_ORG_ID" { return nil }
        // Slug first: `{org}` cannot match inside `{org_slug}` (the `}` intervenes), so the order
        // is not load-bearing today — but it is pinned by test so a future token rename can't
        // silently turn `{org_slug}` into `<numeric>_slug`.
        return pattern
            .replacingOccurrences(of: "{org_slug}", with: slug)
            .replacingOccurrences(of: "{org}", with: id)
            .replacingOccurrences(of: "{task_id}", with: taskId)
    }
}