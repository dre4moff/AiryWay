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

## License
MIT. See [LICENSE](./LICENSE).

## Italiano
Documentazione tecnica originale: [README_IT](./AiryWayApp/README_IT.md)
