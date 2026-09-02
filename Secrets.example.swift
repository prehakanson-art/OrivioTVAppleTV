import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  TEMPLATE — copy this file to `NuvioTV/Secrets.swift` and fill in your keys.
//
//      cp Secrets.example.swift NuvioTV/Secrets.swift
//
//  `NuvioTV/Secrets.swift` is gitignored, so your keys never enter the repo
//  (same pattern as the official Orivio app's `local.properties`). This template
//  lives at the repo root so it is NOT compiled into the app.
//
//  Every value is optional — the app still browses and plays via addons with
//  them blank. What each unlocks:
//    • supabase*        → the Orivio account: QR login + cross-device sync
//    • trakt*           → Trakt sign-in + scrobbling
//    • tmdbAPIKey       → TMDB enrichment (cast, trailers, ratings, stills)
//                         Get a free key at https://www.themoviedb.org/settings/api
// ─────────────────────────────────────────────────────────────────────────────

enum Secrets {
    // Orivio account backend (self-hosted Supabase). Leave blank to disable the
    // Orivio account; these point at Orivio's own server and aren't reusable.
    static let supabaseURL = ""
    static let supabaseFallbackURL = ""
    static let supabaseAnonKey = ""
    static let tvLoginWebBaseURL = "https://nuvio.tv/tv-login"
    static let avatarPublicBaseURL = ""

    // Trakt OAuth app credentials (create one at https://trakt.tv/oauth/applications).
    static let traktClientID = ""
    static let traktClientSecret = ""

    // TMDB API key (https://www.themoviedb.org/settings/api).
    static let tmdbAPIKey = ""
}
