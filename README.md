# PhotoNuke 💥📷

Candy Crush for gallery purging. A high-velocity, highly addictive Android gallery cleanup app built with Flutter.

## Core Features
- **Tap-to-Nuke Mode:** Pop, shatter, or bubble-wrap individual photos instantly.
- **AC-130 Paint & Release Mode:** Drag your finger across a grid/timeline to paint target reticles, then lift to vaporize the batch.
- **Temporal Burst Clustering:** Smart-cluster rapid-fire photo sequences to select and nuke entire bursts in one gesture.
- **Arcade Feedback Loop:** Real-time score counter, items nuked, storage space freed (`-1.4 GB cleared!`), and combo multipliers.
- **Modular Theme Packs (In-App Purchases):**
  - **Bubble Wrap** (Default)
  - **Gunship** (AC-130 crosshairs & missile strikes)
  - **Nuclear** (Geiger counters & mushroom clouds)
  - **Demolition** (Concrete cracking & wrecking balls)

## Architecture
- **Framework:** Flutter (Dart) for 60fps gesture handling and custom canvas effects.
- **Storage & Privacy:** 100% offline and local-first via Android MediaStore.

## Android release builds
CI builds and publishes release-mode APKs for development. When no Android signing secrets are configured, Gradle signs them with an automatically generated debug keystore. No secrets are required for this mode, but installing a later build may require uninstalling the previous app, which removes its app data.

For consistent signing so builds can be installed as updates, configure all four GitHub Actions repository secrets:

- `ANDROID_KEYSTORE_BASE64`: the keystore file encoded as base64
- `ANDROID_KEYSTORE_PASSWORD`: the keystore password
- `ANDROID_KEY_ALIAS`: the signing key alias
- `ANDROID_KEY_PASSWORD`: the signing key password

If only some signing secrets are configured, CI fails rather than silently switching keys. Keep the release keystore and its passwords safe and reuse them for every release. The workflow increases the Android version code for each release build.
