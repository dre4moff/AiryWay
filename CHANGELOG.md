# Changelog

Tutte le modifiche rilevanti del progetto sono documentate qui.

## 0.0.3 - 2026-04-08

### Added
- Integrazione multimodale nativa `mtmd` nel runtime `llama.xcframework`: gli allegati immagine vengono passati come payload binario al modello, senza OCR/fallback testuale.
- Pipeline vision con sidecar `mmproj`: risoluzione automatica lato runtime e errore esplicito quando il companion manca.
- Download automatico del companion `mmproj` dalla schermata Models quando disponibile nel catalogo Hugging Face.
- Nuovo script `scripts/build_llama_multimodal_xcframework.sh` per ricostruire localmente lo `xcframework` con supporto multimodale.

### Changed
- Rimossa la toolbar di chiusura tastiera sopra il composer chat per eliminare la sovrapposizione con il tasto invio.
- Versione app aggiornata a `0.0.3`.
- I file `mmproj` non vengono più mostrati come “modelli installati” selezionabili in chat.
- Catalogo modelli esteso con metadati companion (`mmproj`) e badge dedicati nelle card.
- Tooling release aggiornato: script base `release_with_unsigned_ipa.sh` + wrapper versionato `release_0_0_3_with_unsigned_ipa.sh` per push/tag/release + upload IPA unsigned.

### Fixed
- Upload immagine ora bloccato quando il runtime `llama.xcframework` non espone API multimodali native: evita risposte fuorvianti o “inventate”.
- Aggiunto controllo lato orchestrator per impedire richieste con immagini su runtime non compatibile.
- Schermata Models aggiornata con warning esplicito sullo stato del vision runtime (capability modello vs supporto runtime reale).
- Capabilities in Models/Settings ora mostrano supporto immagini reale (`modello` + integrazione runtime effettiva), non solo inferenza da nome modello.
- Ripristinata visualizzazione capability immagini a livello modello nelle card; stato runtime mostrato separatamente con warning.
- Risolto il caso Gemma/LLaVA in cui il modello “fingeva” descrizioni: ora l’immagine arriva davvero al modello (con `mmproj` presente).

## 0.0.2 - 2026-04-08

### Added
- Hub modelli ridisegnato con layout a larghezza piena (`ScrollView` + card), sezione dispositivi dedicata e pull-to-refresh.
- Nuove card di stato per loading, errori e stati vuoti nella schermata Models.
- Progress strip download più chiara con percentuale e stato direttamente sulla card modello.
- Sezione `Installed models` ordinata per modifica recente e separata dalla lista online.
- `CHANGELOG.md` per gestire patch notes e release body.

### Changed
- UI refinement globale (Models, Chat, Settings, Tab Bar) con stile più coerente: materiali, bordi, shadow, spacing e animazioni più fluide.
- Card modello online e installato migliorate per leggibilità e allineamento su schermi iPhone.
- Composer chat riallineato (+, campo testo, invio), con keyboard dismiss e micro-interazioni più fluide.
- Bubble chat con larghezza controllata e rendering più pulito.
- Rilevamento capability immagini aggiornato per Gemma 4 (`gemma-4` / `gemma4`).
- `MARKETING_VERSION` aggiornato a `0.0.2`.

### Fixed
- Upload immagine in chat non più bloccato a runtime: ora crea attachment valido (dimensione + risoluzione) e lo passa al modello.
- Visual inconsistency delle card modelli che non riempivano correttamente la larghezza disponibile.

## 0.0.1 - 2026-04-08

### Added
- Prima release pubblica di AiryWay.
- Supporto a modelli locali GGUF con import, download, selezione e uso in chat.
- Integrazione `llama.xcframework` nell'app iOS.
