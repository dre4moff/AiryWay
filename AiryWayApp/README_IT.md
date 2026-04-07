# AiryWay - app iOS offline-first (SwiftUI)

AiryWay e una base iOS nativa per navigazione web, estrazione testo e assistente locale on-device.

## Funzionalita implementate
- Browser integrato con `WKWebView`.
- Reader con estrazione HTML migliorata (title/meta/heading/paragraph/list) e pulizia noise (script/style/nav/footer/cookie banners piu comuni).
- Cache locale reader LRU delle ultime 20 pagine.
- Chat agentica con loop tool-based (max 4 tool call per turno):
  - `open_url(url)`
  - `search_web(query)`
  - `fetch_page_text(url)`
  - `get_current_page()`
  - `summarize_text(text)`
- Debug view in chat con trace planner/tool/timing.
- Action chips in chat: Open / Search / Read / Summarize.
- Streaming progressivo della risposta + pulsante Stop.
- Stato modello: `unloaded / loading / ready / generating / error`.
- Import modello `.gguf` da Files (`fileImporter`).
- Download modello `.gguf` da URL HTTP(S) con progress e cancellazione.
- Gestione modelli in sandbox `Application Support/AiryWay/Models` (use/delete/list).
- Cleanup cache:
  - clear reader cache
  - clear URL/network cache
  - clear temp download
  - clear recent sites history
- History siti recenti persistente.
- ATS ristretto (rimosso `NSAllowsArbitraryLoads` globale) + blocco URL non HTTP(S).
- Safe mode opzionale per tool call con allowlist host.

## Motore locale
- Il progetto usa `LlamaCppEngine` come entrypoint del motore locale.
- Il codice e pronto per linkare `llama.xcframework` con `#if canImport(llama)`.
- Finche il framework non e linkato nel target, viene usato fallback locale per mantenere l'app funzionante.

## Dove vengono salvati i modelli
- Directory: `Application Support/AiryWay/Models`
- Estensione valida: solo `.gguf`
- Il modello selezionato viene persistito nelle impostazioni app.

## Build
1. Apri `AiryWayApp.xcodeproj`.
2. Seleziona schema app e un simulatore iPhone o device reale.
3. Build & Run.

## Note su llama.cpp
Per usare inferenza reale GGUF on-device:
1. Aggiungi `llama.xcframework` al target app in Xcode.
2. Verifica che il modulo sia importabile (`canImport(llama)`).
3. Completa il token loop nel punto segnato in `LlamaCppEngine`.

## File principali
- `AiryWayApp/Core/LocalLLMEngine.swift`
- `AiryWayApp/Core/AgentOrchestrator.swift`
- `AiryWayApp/Core/WebPageFetcher.swift`
- `AiryWayApp/Core/HTMLTextExtractor.swift`
- `AiryWayApp/Features/Settings/SettingsStore.swift`
- `AiryWayApp/Features/Settings/SettingsScreen.swift`
- `AiryWayApp/Features/Chat/ChatViewModel.swift`
- `AiryWayApp/Features/Chat/ChatScreen.swift`
