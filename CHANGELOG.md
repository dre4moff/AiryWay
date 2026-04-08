# Changelog

Tutte le modifiche rilevanti del progetto sono documentate qui.

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
