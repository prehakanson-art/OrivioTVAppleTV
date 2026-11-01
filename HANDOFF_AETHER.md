# Handoff — intégration AetherEngine dans OrivioTV (tvOS)

> Document de reprise pour un agent Claude qui tourne **sur le Mac de l'utilisateur**
> (Xcode disponible). Les sessions précédentes tournaient dans un conteneur Linux, sans
> Xcode : **rien de ce qui est décrit ici n'a encore été compilé**. Ta première mission
> est de compiler et de corriger.
>
> Réponds à l'utilisateur **en français**.

---

## 1. Contexte et objectif

- App : **Orivio TV**, client Stremio-like pour Apple TV (SwiftUI, tvOS).
- Fork de l'utilisateur : `docloulou/OrivioTVAppleTV`.
- Dépôt officiel (upstream) : `prehakanson-art/OrivioTVAppleTV`. Il est public et lisible
  en git ; son API GitHub n'est pas accessible depuis les sessions cloud.
- **Objectif de l'utilisateur** : utiliser [AetherEngine](https://github.com/superuser404notfound/AetherEngine)
  comme moteur de lecture.
  - Garder **la même UI de lecteur**.
  - Optimiser pour Apple TV.
  - Supporter tous les formats : MKV/MP4/HLS, Dolby Vision 5/7/8, HDR10+, HLG, TrueHD/DTS-HD MA,
    Atmos, DTS:X, PGS/ASS…
- Une **page de test** (Test streams) a été ajoutée pour valider chaque chemin de lecture
  sans add-on.

## 2. Git

| Quoi | Valeur |
| --- | --- |
| Branche de travail | `claude/laughing-darwin-yc65hd` (sur `origin` = fork de l'utilisateur) |
| Base | tag upstream **v0.15** = commit `dc8e691` |
| Nos commits | `c76d30d` (code + projet) et `0bc313d` (docs), plus le commit de ce handoff |
| Ancienne version (base v0.12, abandonnée) | `4f945f1` |

La branche a été **reconstruite** sur v0.15 (force-push sur notre propre branche).
L'ancienne version n'est plus référencée par aucune branche ; le tag local
`backup/pre-v0.15-port` n'existait que dans le conteneur cloud.

Pour récupérer l'upstream :

```bash
git remote add upstream https://github.com/prehakanson-art/OrivioTVAppleTV.git
git fetch upstream --tags
git diff dc8e691..HEAD --stat   # = tout notre travail
```

Règles de l'utilisateur :
- Travailler et pousser sur `claude/laughing-darwin-yc65hd`.
- **Pas de PR** sauf demande explicite.
- Ne jamais réécrire une branche qui n'est pas la nôtre.

## 3. Architecture de la v0.15 (à comprendre avant de toucher au code)

### Deux lecteurs

Le routage est dans `PlayerPresenter.present(_:)`, fichier `OrivioTV/App/Navigation.swift`.

- **TV en direct** : live, `tv`, `channel` ou `recording`.
  - Va vers le **nouveau lecteur** `OrivioTV/Player/` (`PlayerViewModel`, `Player/Engine/*`).
  - Ses moteurs : `EngineKind { native, ffmpeg, vlc, dvDirect }`.
  - **Aether n'y est pas branché.**
- **Tout le reste** (films, épisodes, Plex/Jellyfin) : `classicRequest = ClassicPlaybackRequest(r)`.
  - Va vers le **lecteur Classic** `OrivioTV/ClassicPlayer/`.
  - C'est l'ancien gros lecteur, renommé avec un préfixe `Classic`.
  - **C'est là qu'AetherEngine est intégré.**

### Réglages

- Le modèle « nouveau » est `PlayerSettings` dans `Core/Stores/SettingsModels.swift`.
  - Moteur : `EnginePreference { auto, aether, native, ffmpeg, vlc, external }`.
  - Il est persistant, avec un décodage *lenient* : une valeur inconnue retombe sur le défaut.
- Le lecteur Classic a son propre `ClassicPlayerSettings`, avec `PlayerEngine { auto, aether, native, ffmpeg, vlc, external }`.
  - Il est synchronisé dans les deux sens avec `PlayerSettings` par `ClassicPlayerSettingsStore`.
  - Le mapping se fait par `rawValue` : **garder les rawValue identiques dans les deux enums.**
- L'UI des réglages est dans `Screens/Settings/` et utilise des composants maison :
  - `SettingsGroup`, `SettingsRow`, `PickerRow`, `ToggleRow`, `TextEntryRow` ;
  - la navigation interne passe par `SettingsNav.push(title) { View }`.

### Projet Xcode

- `OrivioTV.xcodeproj/project.pbxproj` est **commité et maintenu à la main** par l'upstream.
- Le tree upstream contient encore environ 120 **anciens fichiers Swift non compilés**, par exemple :
  - `OrivioTV/OrivioTVApp.swift`, `Core/*.swift` à la racine, `Screens/*.swift` à la racine ;
  - `Components/`, `Theme/` ;
  - 15 fichiers à la racine de `Player/`.
- On a ajouté des `excludes:` dans `project.yml` pour que `xcodegen generate` compile **le même
  ensemble** que le pbxproj. C'est vérifié par script contre le pbxproj, mais xcodegen lui-même
  n'a jamais tourné. `scripts/make-ipa.sh` lance xcodegen s'il est installé.
- **Un nouveau fichier Swift doit être ajouté à la main dans le pbxproj** (fileRef + buildFile +
  groupe + phase Sources), ou bien via xcodegen.

## 4. Ce qui a été fait (nos changements sur v0.15)

### 4.1 `Vendor/OrivioAether/` — package SwiftPM local (wrapper)

C'est une **bibliothèque dynamique** qui dépend d'AetherEngine `from: "7.53.1"`, résolu en 7.53.1
au moment de l'écriture.

Ce que fait `Package.swift` :
- `swift-tools-version: 6.1` : il faut **Xcode 16.3+** pour les traits.
- Il active les traits `TrueHDObjectAudio`, `DTSXObjectAudio`, `DualLayerDolbyVision` et
  `DolbyVisionStillReshaping`. XcodeGen ne sait pas passer les traits, d'où le wrapper.
- `.swiftLanguageMode(.v5)`.
- **`.unsafeFlags(["-enable-library-evolution"])`**, autorisé parce que le package est local.
- Plateforme tvOS 18.

Pourquoi un wrapper **dynamique** :
- KSPlayer (FFmpegKit) lie FFmpeg **en statique** dans l'exécutable, et VLCKit embarque le sien.
- Un `_avcodec_*` statique dans l'exécutable « gagnerait » sur celui d'AetherEngine.
- Dans un framework séparé, le namespace à deux niveaux garde les symboles d'Aether liés à
  `AetherLibavcodec`.

Pourquoi la **library evolution** :
- Sans elle, l'app charge quand même les `internal import` du module (SE-0409).
- Clang voit alors à la fois `AetherLibavcodec` et `Libavcodec` (KSPlayer), et plante avec :
  - *« 'AV_CODEC_ID_…' from module 'AetherLibavcodec' is not present in definition of 'enum AVCodecID' in module 'Libavcodec' »* ;
  - plus des erreurs `SwsContext` dans `ScrubThumbnailer`.

Le fichier `Sources/OrivioAether/AetherPlaybackEngine.swift` est la façade publique, environ 480 lignes.
- Types publics : `AetherPlaybackEngine`, `AetherPlaybackState` (**`@frozen`**, nécessaire avec
  la library evolution pour les `switch` exhaustifs côté app), `AetherTrack`, `AetherSubtitleCue`,
  `AetherChapter`, `AetherLoadConfiguration`.
- Il fait `internal import AetherEngine` : l'app n'importe **que** `OrivioAether`.
- API : `load(url:startPosition:configuration:)`, `play`, `pause`, `seek`, `stop(final:)`, `rate`,
  `setMuted`, `setAudioDelay`, pistes audio et sous-titres, `chapters`, `videoView`,
  `nativePlayerLayer` (PiP), et des labels de diagnostic (format, route, décodeur).
- Callbacks : `onState`, `onBuffering`, `onTime`, `onTracksChanged`, `onSubtitleCues`,
  `onVideoInfoChanged`.
- **Si AetherEngine change d'API** dans une version mineure, c'est ce fichier qu'il faut adapter.
  On peut aussi figer la dépendance avec `.upToNextMinor(from: "7.53.1")`.

### 4.2 libdovi

Les headers de `Vendor/libdovi.xcframework/*/Headers/` ont été déplacés dans
`Headers/libdovi/{dovi.h,module.modulemap}`.

Raison : la `LibDovi` d'AetherEngine (module `Dovi`) copie aussi un `dovi.h` et un
`module.modulemap` dans `include/`. Les deux à la fois donnaient l'erreur
*« Multiple commands produce …/include/dovi.h »*.

L'app fait toujours `import libdovi` (dossier = nom du module, donc clang le trouve).

### 4.3 Lecteur Classic — `OrivioTV/ClassicPlayer/ClassicPlayerViewModel.swift` (~13 000 lignes)

C'est le gros morceau, porté par merge 3-way depuis l'ancienne version. Les numéros de ligne
sont approximatifs.

- `import OrivioAether`.
- État Aether, vers la ligne 1287 :
  - `aetherEngine` et `usingAether` ;
  - `aetherDeclinedLinks`, l'ensemble des liens sur lesquels Aether a échoué : on ne le retente pas pour ce lien ;
  - `aetherSessionPrepared`, `aetherEmbeddedSubs`…
- Bloc **`AETHERENGINE FIRST`** dans le chargement, vers la ligne 4453.
  - Aether est essayé si `effectiveEngine == .aether` ou si on est en `.auto` hors mode Compatibility.
  - Il faut aussi que le lien ne soit pas « declined », qu'il n'y ait pas d'`overrideURL` et pas de
    `forceDemuxerForSession`.
  - Sinon, appel de `retireAetherEngine()` puis chemin historique : AVPlayer pour MP4/HLS, KSPlayer/FFmpeg pour le reste.
- Branches `usingAether` dans :
  - la vue vidéo active, le PiP, mute, play/pause/seek, vitesse, décalage audio ;
  - la sélection de pistes (`case aetherAudio(Int)`), le reconnect-by-seek ;
  - les sondes et le HUD de diagnostic.
- `switchEngine(_:)`, vers la ligne 8916 : changement de moteur en cours de lecture, avec réessai.
- Watchdog et échec de lien → `fallBackFromAether` : on recharge le même lien via les anciens moteurs.
  - Les erreurs du domaine `OrivioCache` et `Orivio.Player` -20 ne déclenchent pas ce fallback.
- `extension … // MARK: - AetherEngine path`, vers la ligne 12562 :
  - `loadViaAether`, `aetherLoadConfiguration` (headers, langues audio, match content / frame rate,
    pont LPCM lossless, lit objet 7.1.4, DV double couche…) ;
  - `aetherStateChanged`, `aetherTimeChanged`, `loadAetherTracks` ;
  - `applyPreferredAetherAudioIfNeeded`, `noteAetherDisplay`, `fallBackFromAether`, `retireAetherEngine`.
- `final class AetherEmbeddedSubtitleInfo: SubtitleInfo`, vers la ligne 12993 : sous-titres
  embarqués affichés par l'UI existante.
- Gardes `TestStreamCatalog.isTestMeta(meta.id)`, vers les lignes 8945 et 9314 : pas de balayage
  des add-ons ni de notices pour les flux de test.

### 4.4 Réglages et lecteur live

- `EnginePreference` (dans `SettingsModels.swift`) et `PlayerEngine` (dans `ClassicPlayerSettings.swift`)
  gagnent `case aether`, avec un label et une note de bas de page.
- Le texte du groupe « Player » dans `SettingsPages.swift` a été mis à jour.
- `Player/PlayerViewModel.swift` (lecteur live) : `.aether` est traité comme `.auto` dans
  `chooseEngine()`, `dvPreflightHint()` et la liste de fallback.

### 4.5 Test streams

- Fichier : `OrivioTV/Screens/Settings/TestStreamsPage.swift`, ajouté au pbxproj.
- Il définit `TestStreamCatalog`.
  - Les ids de meta sont préfixés `orivio-test:`, avec `isTestMeta(_:)`.
  - 5 catégories d'échantillons publics vérifiés : DV P5/8.1/8.4, HDR10/HLG/AV1, TrueHD Atmos /
    DTS-HD MA / E-AC-3, PGS/ASS, SDR/HLS.
  - Le tout s'accompagne d'une URL perso.
- Il définit aussi `TestStreamsPage`.
- Lancement : `PlayerPresenter.shared.present(PlaybackRequest(...))`, donc dans le lecteur Classic.
- Entrée dans l'app : **Réglages → Playback → Developer → Test streams**.
- Gardes pour que ces sessions ne polluent rien :
  - `ClassicModelBridge.swift` : `classicRecord` et `markFinished`, donc pas de Continue Watching ni de « vu » ;
  - `ClassicPlayerHost.swift` : `ClassicScrobbler.start`, donc pas de Trakt.

### 4.6 Projet

- Cible de déploiement : **tvOS 18.0**, dans `project.yml` et dans les 3 configs du pbxproj (Debug/Release/Profile).
- Entrées pbxproj ajoutées à la main (IDs `A1E7A0B1C2D3E4F5A6B7C801`…`806`) :
  - `XCLocalSwiftPackageReference "Vendor/OrivioAether"` ;
  - le produit `OrivioAether` dans la phase Frameworks et dans `packageProductDependencies` ;
  - le fichier `TestStreamsPage.swift`.
- README et SETTINGS_REFERENCE ont été mis à jour.

## 5. Compiler

Prérequis : Xcode **16.3 ou plus** (l'utilisateur a un SDK AppleTVOS 27). Le fichier
`OrivioTV/Secrets.swift` doit exister ; sinon, copier `Secrets.example.swift`.

```bash
rm -rf build
```

```bash
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV -destination 'generic/platform=tvOS' -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Simulateur (compile-check rapide) :

```bash
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV -destination 'generic/platform=tvOS Simulator' -derivedDataPath build/DD build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

IPA non signée (sideload) :

```bash
UNSIGNED=1 ./scripts/make-ipa.sh
```

Problèmes de simulateur déjà rencontrés :
- *« CoreSimulator is out of date »* → lancer `sudo xcodebuild -runFirstLaunch`.
- *« Unable to find application named 'Simulator' »* → lancer `open "$(xcode-select -p)/Applications/Simulator.app"`.

## 6. Historique des erreurs de build et de leurs correctifs

| Erreur | Cause | Correctif |
| --- | --- | --- |
| `Multiple commands produce …/include/dovi.h` (et `module.modulemap`) | libdovi de l'app et LibDovi d'Aether au même chemin | headers déplacés dans `Headers/libdovi/` (§4.2) |
| `'AV_CODEC_ID_…' from module 'AetherLibavcodec' is not present in definition of 'enum AVCodecID' in module 'Libavcodec'`, et `OpaquePointer` vs `UnsafeMutablePointer<SwsContext>` dans ScrubThumbnailer | les `internal import` d'OrivioAether chargés côté app | `-enable-library-evolution` + `@frozen AetherPlaybackState` (§4.1). **Correctif jamais confirmé par un build** |

## 7. Points non vérifiés / risques (par ordre de probabilité)

1. **Le correctif de library evolution** : si l'erreur AV_CODEC_ID revient, vérifier dans le
   build log que `-enable-library-evolution` est bien passé à OrivioAether.
   - Pistes si ça ne suffit pas :
     - exposer une interface `.swiftinterface` uniquement ;
     - passer `OrivioAether` en XCFramework binaire pré-buildé ;
     - isoler la dépendance KSPlayer côté app.
2. **Erreurs de compilation du merge 3-way** dans `ClassicPlayerViewModel.swift`. Tous les
   symboles ont été vérifiés par grep, mais pas compilés. Erreurs probables :
   - un `switch` non exhaustif sur `PlayerEngine` ou `EnginePreference` ailleurs (chercher
     `case .vlc`, `case .external`) ;
   - un nom de propriété qui diffère légèrement entre v0.12 et v0.15.
3. **L'API d'AetherEngine** : le wrapper a été écrit contre 7.51.0 et compile contre 7.53.1. Si SwiftPM résout une version
   plus récente et que ça casse, figer la version (§4.1).
4. **Isolation acteur et concurrence** : le wrapper est en mode Swift 5, l'app en `SWIFT_VERSION 5.9`.
   Des warnings `Sendable` sont possibles. Les callbacks d'Aether doivent arriver sur le main
   thread ; à vérifier si des mises à jour UI viennent d'un autre thread.
5. **xcodegen** : les `excludes` n'ont jamais été testés avec le vrai binaire. Les polices
   `Resources/Fonts/*.ttf` ne sont pas dans le pbxproj upstream, alors que xcodegen les ajoutera ;
   c'est sans gravité. En cas de doute, ne pas lancer xcodegen et utiliser le `.xcodeproj` commité.
6. **Test streams dans Classic** : le lecteur peut tenter d'enrichir ou de charger les métadonnées
   d'un id `orivio-test:*`. Les échecs devraient être silencieux ; à vérifier à l'exécution.

## 8. Prochaines étapes suggérées

1. **Compiler** (Release device + simulateur), corriger les erreurs et pousser.
2. Sur l'Apple TV, ouvrir Réglages → Playback → Developer → Test streams et valider chaque
   catégorie avec le moteur sur Auto. Vérifier dans le HUD de diagnostic que le moteur affiché
   est bien « AetherEngine ».
   - DV P5/8.1 : mode Dolby Vision de la TV.
   - TrueHD Atmos / DTS-HD MA : pont LPCM ou objets.
   - PGS/ASS : sous-titres.
   - Fallback : couper le réseau en cours de lecture.
3. Vérifier qu'une session de test n'apparaît **pas** dans Continue Watching, ni dans Trakt.
4. Optionnel, à proposer à l'utilisateur : **brancher Aether sur le lecteur live**.
   - Ajouter un `AetherEngine: PlaybackEngine` dans `Player/Engine/` et un `EngineKind.aether`.
   - Adapter `chooseEngine()` et le fallback.
5. Optionnel : ouvrir une issue ou une PR upstream pour signaler les fichiers legacy non compilés
   (le xcodegen d'upstream est cassé tel quel).

## 9. Références

- AetherEngine : https://github.com/superuser404notfound/AetherEngine. Voir `README` (traits,
  licences) et `docs/api.md` (« One FFmpeg, and it has to be the engine's »).
- Licences à embarquer dans un build distribué :
  - AetherEngine : LGPL-3.0 avec exception App Store ;
  - son FFmpeg : LGPL-2.1+ ;
  - libdovi : MIT ;
  - TrueHD (truehdd) : MIT + Apache-2.0.
- Les composants optionnels (traits) peuvent relever de brevets tiers : c'est la responsabilité
  du distributeur.
