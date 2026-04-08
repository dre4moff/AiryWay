# AiryWay

Offline-first iOS chat app powered by local GGUF models via `llama.cpp`.

AiryWay focuses on on-device inference: load a local model, chat with it, and manage models directly from the app UI.

## Highlights
- Native iOS app in SwiftUI.
- Local model management (`.gguf` import/download/select/delete).
- On-device inference through embedded `llama.xcframework`.
- Chat UI with saved conversations and streaming output.
- Attachment entry points in chat UI (file/image/audio) with capability-aware controls.
- Light/Dark/System appearance support.

## Project Structure
- `AiryWayApp/AiryWayApp` – iOS app source.
- `AiryWayApp/AiryWayApp/Core` – engine and orchestration.
- `AiryWayApp/AiryWayApp/Features` – Chat, Models/Settings, Browser/Reader screens.
- `AiryWayApp/AiryWayApp/Vendor/llama` – bundled `llama.xcframework`.

## Build
1. Open `AiryWayApp/AiryWayApp.xcodeproj` in Xcode.
2. Select scheme `LocalWebPilot`.
3. Build and run on simulator or iPhone.

## Packaging (unsigned IPA)
Example command:

```bash
xcodebuild -project AiryWayApp/AiryWayApp.xcodeproj \
  -scheme LocalWebPilot \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
```

Then package `Payload/AiryWay.app` into `.ipa`.

Unsigned IPA output used for releases:
- `build_unsigned_ipa/AiryWay-v0.0.3-unsigned.ipa`
- `build_unsigned_ipa/AiryWay-unsigned.ipa` (legacy name)

## GitHub Release Script
After generating the unsigned IPA:

```bash
export GITHUB_TOKEN="YOUR_TOKEN"
./scripts/release_0_0_3_with_unsigned_ipa.sh
```

Lo script sincronizza `main`, aggiorna tag/release `0.0.3` e carica l’asset IPA unsigned.

Script base riutilizzabile (tag personalizzato):

```bash
export GITHUB_TOKEN="YOUR_TOKEN"
TAG=0.0.3 ./scripts/release_with_unsigned_ipa.sh
```

## Changelog
Patch notes are tracked in [CHANGELOG.md](./CHANGELOG.md).

## License
MIT. See [LICENSE](./LICENSE).

## Italiano
Documentazione tecnica originale: [README_IT](./AiryWayApp/README_IT.md)
