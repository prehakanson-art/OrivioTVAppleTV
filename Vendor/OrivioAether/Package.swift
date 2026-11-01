// swift-tools-version: 6.1

import PackageDescription

// The AetherEngine playback engine, wrapped in a DYNAMIC framework.
//
// Why a wrapper at all, instead of linking the AetherEngine product into the
// app target directly:
//
// 1. ONE FFMPEG, AND IT HAS TO BE THE ENGINE'S. KSPlayer's FFmpegKit links
//    FFmpeg into the app executable as STATIC archives, and VLCKit carries its
//    own libavcodec as well. A static `_avcodec_open2` inside the executable
//    beats every dylib for every other object in the same link, so an engine
//    statically linked beside it would silently run against KSPlayer's FFmpeg
//    (wrong struct layouts, missing encoders — see AetherEngine docs/api.md,
//    "One FFmpeg, and it has to be the engine's"). Linked into this framework
//    instead, the engine's `_av*` references are resolved when the FRAMEWORK
//    links, against AetherLibavcodec.framework, and the two-level namespace
//    keeps them there at runtime. KSPlayer and VLC keep their own copies.
//
// 2. PACKAGE TRAITS. XcodeGen cannot express SwiftPM traits yet, so the
//    optional components are switched on here, in a manifest. All four are on:
//    TrueHD Atmos / DTS:X object rendering, Dolby Vision Profile 7 FEL
//    dual-layer composition and Dolby Vision Profile 5 stills. These may be
//    subject to third-party patent licensing — the integrator is responsible
//    for its own licensing (AetherEngine README, "Optional components").
//
// The app only ever imports `OrivioAether`; its public API is made of
// Orivio-defined types and the module is built with library evolution (see
// the target below), so nothing in the app sees AetherEngine, LibDovi or the
// Aether FFmpeg headers (the app has its own `libdovi` module).
let package = Package(
    name: "OrivioAether",
    platforms: [
        .tvOS(.v18),
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "OrivioAether", type: .dynamic, targets: ["OrivioAether"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine",
            from: "7.50.0",
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision", "DolbyVisionStillReshaping"]
        ),
    ],
    targets: [
        .target(
            name: "OrivioAether",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Library evolution is what keeps `internal import AetherEngine`
                // out of the app: a client of a NON-resilient module still
                // loads that module's internal imports (SE-0409), and
                // AetherEngine imports its FFmpeg as AetherLibavcodec & co.
                // Those headers declare the same C enums and structs as
                // KSPlayer's Libavcodec, which the app imports, and clang
                // rejects the two definitions ("'AV_CODEC_ID_…' from module
                // 'AetherLibavcodec' is not present in definition of 'enum
                // AVCodecID' in module 'Libavcodec'"). Allowed here because
                // this is a local package.
                .unsafeFlags(["-enable-library-evolution"]),
            ]
        ),
    ]
)
