import Foundation

/// Backend configuration for the Orivio account (self-hosted Supabase).
///
/// These are **public client** values — the same ones embedded in the shipped
/// Orivio apps. The `anonKey` is Supabase's `anon` role JWT: it is designed to
/// live in the client and only grants what any signed-in user is allowed to do
/// (enforced server-side by Row Level Security). It is NOT a `service_role`
/// key and confers no admin access. Account security comes from the user
/// logging in on the official web page during the QR flow — the app never sees
/// a password.
enum OrivioConfig {
    /// Primary Supabase base URL.
    static let supabaseURL = Secrets.supabaseURL

    /// Origin fallback used when the primary edge (Cloudflare) returns a 5xx /
    /// network error, mirroring the Android client's retry behavior.
    static let supabaseFallbackURL = Secrets.supabaseFallbackURL

    /// Public `anon` API key (role=anon, valid 2026-2031).
    static let anonKey = Secrets.supabaseAnonKey

    /// Web page the TV directs the user to (rendered as the QR target). The
    /// backend appends the login code to this base.
    static let tvLoginWebBaseURL = Secrets.tvLoginWebBaseURL

    /// Public storage base for profile avatar images. Image URL is this joined
    /// with an avatar catalog item's `storage_path`.
    static let avatarPublicBaseURL = Secrets.avatarPublicBaseURL

    static var isConfigured: Bool {
        !supabaseURL.isEmpty && !anonKey.isEmpty
    }
}
