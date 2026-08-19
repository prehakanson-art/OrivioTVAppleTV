import Foundation

/// A row of the Supabase `addons` table (subset we sync).
struct SupabaseAddon: Decodable {
    let url: String
    let sortOrder: Int
    let enabled: Bool
    let name: String?

    private enum CodingKeys: String, CodingKey {
        case url
        case sortOrder = "sort_order"
        case enabled
        case name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        sortOrder = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 0
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        name = try? c.decode(String.self, forKey: .name)
    }
}

/// A row returned by `sync_pull_watch_progress`. Positions/durations are
/// milliseconds (matching the Android client's ExoPlayer values).
struct SupabaseWatchProgress: Decodable {
    let contentID: String
    let contentType: String
    let videoID: String
    let season: Int?
    let episode: Int?
    let position: Int
    let duration: Int
    let lastWatched: Int
    let progressKey: String

    private enum CodingKeys: String, CodingKey {
        case contentID = "content_id"
        case contentType = "content_type"
        case videoID = "video_id"
        case season, episode, position, duration
        case lastWatched = "last_watched"
        case progressKey = "progress_key"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentID = try c.decode(String.self, forKey: .contentID)
        contentType = (try? c.decode(String.self, forKey: .contentType)) ?? "movie"
        videoID = (try? c.decode(String.self, forKey: .videoID)) ?? contentID
        season = try? c.decode(Int.self, forKey: .season)
        episode = try? c.decode(Int.self, forKey: .episode)
        position = (try? c.decode(Int.self, forKey: .position)) ?? 0
        duration = (try? c.decode(Int.self, forKey: .duration)) ?? 0
        lastWatched = (try? c.decode(Int.self, forKey: .lastWatched)) ?? 0
        progressKey = (try? c.decode(String.self, forKey: .progressKey)) ?? videoID
    }
}

/// A row returned by `sync_pull_profiles`.
struct SupabaseProfile: Decodable {
    let profileIndex: Int
    let name: String
    let avatarColorHex: String
    let usesPrimaryAddons: Bool
    let usesPrimaryPlugins: Bool
    let avatarID: String?
    let avatarURL: String?

    private enum CodingKeys: String, CodingKey {
        case profileIndex = "profile_index"
        case name
        case avatarColorHex = "avatar_color_hex"
        case usesPrimaryAddons = "uses_primary_addons"
        case usesPrimaryPlugins = "uses_primary_plugins"
        case avatarID = "avatar_id"
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileIndex = try c.decode(Int.self, forKey: .profileIndex)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Profile"
        avatarColorHex = (try? c.decode(String.self, forKey: .avatarColorHex)) ?? "#1E88E5"
        usesPrimaryAddons = (try? c.decode(Bool.self, forKey: .usesPrimaryAddons)) ?? false
        usesPrimaryPlugins = (try? c.decode(Bool.self, forKey: .usesPrimaryPlugins)) ?? false
        avatarID = try? c.decode(String.self, forKey: .avatarID)
        avatarURL = try? c.decode(String.self, forKey: .avatarURL)
    }
}

/// A row returned by `verify_profile_pin`.
struct PinVerifyRow: Decodable {
    let unlocked: Bool
    let retryAfterSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case unlocked
        case retryAfterSeconds = "retry_after_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unlocked = (try? c.decode(Bool.self, forKey: .unlocked)) ?? false
        retryAfterSeconds = (try? c.decode(Int.self, forKey: .retryAfterSeconds)) ?? 0
    }
}

/// A row returned by `get_avatar_catalog`.
struct SupabaseAvatarCatalogItem: Decodable {
    let id: String
    let displayName: String
    let storagePath: String
    let category: String
    let sortOrder: Int
    let bgColor: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case storagePath = "storage_path"
        case category
        case sortOrder = "sort_order"
        case bgColor = "bg_color"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        storagePath = (try? c.decode(String.self, forKey: .storagePath)) ?? ""
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        sortOrder = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 0
        bgColor = try? c.decode(String.self, forKey: .bgColor)
    }
}

/// A row returned by `sync_pull_profile_locks`.
struct SupabaseProfileLockState: Decodable {
    let profileIndex: Int
    let pinEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case profileIndex = "profile_index"
        case pinEnabled = "pin_enabled"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileIndex = try c.decode(Int.self, forKey: .profileIndex)
        pinEnabled = (try? c.decode(Bool.self, forKey: .pinEnabled)) ?? false
    }
}

/// A row returned by `sync_pull_watched_items`.
struct SupabaseWatchedItem: Decodable {
    let contentID: String
    let contentType: String
    let title: String
    let season: Int?
    let episode: Int?
    let watchedAt: Int

    private enum CodingKeys: String, CodingKey {
        case contentID = "content_id"
        case contentType = "content_type"
        case title, season, episode
        case watchedAt = "watched_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentID = try c.decode(String.self, forKey: .contentID)
        contentType = (try? c.decode(String.self, forKey: .contentType)) ?? "movie"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        season = try? c.decode(Int.self, forKey: .season)
        episode = try? c.decode(Int.self, forKey: .episode)
        watchedAt = (try? c.decode(Int.self, forKey: .watchedAt)) ?? 0
    }
}

/// A row returned by `sync_pull_library`.
struct SupabaseLibraryItem: Decodable {
    let contentID: String
    let contentType: String
    let name: String
    let poster: String?
    let posterShape: String
    let background: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: Double?
    let genres: [String]
    let addonBaseURL: String?
    let addedAt: Int

    private enum CodingKeys: String, CodingKey {
        case contentID = "content_id"
        case contentType = "content_type"
        case name, title, poster
        case posterShape = "poster_shape"
        case background, description
        case releaseInfo = "release_info"
        case imdbRating = "imdb_rating"
        case genres
        case addonBaseURL = "addon_base_url"
        case addedAt = "added_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentID = try c.decode(String.self, forKey: .contentID)
        contentType = (try? c.decode(String.self, forKey: .contentType)) ?? "movie"
        name = (try? c.decode(String.self, forKey: .name))
            ?? (try? c.decode(String.self, forKey: .title))
            ?? ""
        poster = try? c.decode(String.self, forKey: .poster)
        posterShape = (try? c.decode(String.self, forKey: .posterShape)) ?? "POSTER"
        background = try? c.decode(String.self, forKey: .background)
        description = try? c.decode(String.self, forKey: .description)
        releaseInfo = try? c.decode(String.self, forKey: .releaseInfo)
        imdbRating = try? c.decode(Double.self, forKey: .imdbRating)
        genres = (try? c.decode([String].self, forKey: .genres)) ?? []
        addonBaseURL = try? c.decode(String.self, forKey: .addonBaseURL)
        addedAt = (try? c.decode(Int.self, forKey: .addedAt)) ?? 0
    }
}

/// Row shape returned by `sync_pull_collections` — the whole profile's
/// collections as one JSON blob (arbitrary nested JSON, decoded downstream
/// by CollectionsStore).
/// A `collections` table row read directly (PostgREST select), used to gather
/// EVERY profile's collections into the shared library. `collections_json` can
/// come back as a JSON string or as already-parsed JSON depending on the column
/// type, so decode both shapes.
struct SupabaseCollectionsRow: Decodable {
    let profileID: Int
    let collectionsJSON: String

    private enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case collectionsJSON = "collections_json"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = (try? c.decode(Int.self, forKey: .profileID)) ?? 1
        if let s = try? c.decode(String.self, forKey: .collectionsJSON) {
            collectionsJSON = s
        } else if let raw = try? c.decode(AnyDecodableJSON.self, forKey: .collectionsJSON),
                  let data = try? JSONSerialization.data(withJSONObject: raw.value),
                  let s = String(data: data, encoding: .utf8) {
            collectionsJSON = s
        } else {
            collectionsJSON = "[]"
        }
    }
}

/// Minimal passthrough for a column that may be `jsonb` rather than `text`.
struct AnyDecodableJSON: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            if let a = try? c.decode([AnyDecodableJSON].self) { value = a.map(\.value); return }
            if let d = try? c.decode([String: AnyDecodableJSON].self) {
                value = d.mapValues(\.value); return
            }
            if let s = try? c.decode(String.self) { value = s; return }
            if let n = try? c.decode(Double.self) { value = n; return }
            if let b = try? c.decode(Bool.self) { value = b; return }
        }
        value = NSNull()
    }
}

struct SupabaseCollectionsBlob: Decodable {
    let profileID: Int
    let collectionsJSON: String
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case collectionsJSON = "collections_json"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = (try? c.decode(Int.self, forKey: .profileID)) ?? 1
        updatedAt = try? c.decode(String.self, forKey: .updatedAt)
        // collections_json arrives as a JSON value, not a string; re-serialize
        // it so CollectionsStore can decode with its own tolerant models.
        if let raw = try? c.decode(AnyJSON.self, forKey: .collectionsJSON) {
            collectionsJSON = raw.rawString
        } else {
            collectionsJSON = "[]"
        }
    }
}

/// Row shape returned by `sync_pull_home_catalog_settings`.
struct SupabaseHomeCatalogSettingsBlob: Decodable {
    let profileID: Int
    let settingsJSON: String
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case settingsJSON = "settings_json"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = (try? c.decode(Int.self, forKey: .profileID)) ?? 1
        updatedAt = try? c.decode(String.self, forKey: .updatedAt)
        if let raw = try? c.decode(AnyJSON.self, forKey: .settingsJSON) {
            settingsJSON = raw.rawString
        } else {
            settingsJSON = "{}"
        }
    }
}

/// Minimal JSON passthrough: decodes any JSON value and can re-serialize it,
/// used for jsonb blob columns whose shape other stores own.
enum AnyJSON: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AnyJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: AnyJSON].self) { self = .object(o) }
        else { self = .null }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    var rawString: String {
        let value = anyValue
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            // Top-level scalars/strings (or a pre-encoded blob stored as a
            // string column) fall through here.
            if case .string(let s) = self { return s }
            return "null"
        }
        return string
    }
}
