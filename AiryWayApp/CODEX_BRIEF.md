# Brief operativo da dare a Codex

## Obiettivo
Trasforma questo prototipo in una vera app iOS sideload/offline-first capace di:
- navigare sul web
- leggere e ripulire il testo delle pagine
- eseguire un LLM locale GGUF on-device
- rispondere in chat usando il contenuto della pagina aperta
- usare strumenti limitati tipo `open_url`, `search_web`, `fetch_page_text`, `summarize_page`

## Vincoli
- niente App Store richiesto
- priorità: funzionare su iPhone recenti
- codice SwiftUI nativo, niente React Native
- niente dipendenza da servizi cloud obbligatori
- conservare architettura semplice e leggibile

## Stato attuale
Il progetto ha già:
- browser con `WKWebView`
- fetch pagina via `URLSession`
- estrazione HTML basic
- orchestratore agentico minimale
- protocollo `LocalLLMEngine`
- `StubLocalLLMEngine` da sostituire

## Task 1 — integrare llama.cpp
1. aggiungi `llama.xcframework` al progetto
2. crea `LlamaCppEngine.swift`
3. implementa init con path modello GGUF
4. implementa generazione testo
5. aggiungi streaming token progressivo
6. aggiungi cancellazione generazione
7. esponi errori chiari in UI

## Task 2 — import modello da Files
1. aggiungi pulsante import in Settings
2. usa `fileImporter` SwiftUI
3. copia il modello nella sandbox `Application Support/Models`
4. salva path modello con `@AppStorage`
5. valida estensione `.gguf`
6. mostra dimensione file e nome modello caricato

## Task 3 — prompt orchestration serio
Sostituisci la logica keyword-based in `AgentOrchestrator` con una loop tool-based:
- il modello produce JSON tool calls
- il codice esegue gli strumenti consentiti
- il modello riceve l'output e continua
- limite massimo 4 tool calls per turno

Tool iniziali:
- `open_url(url)`
- `search_web(query)`
- `fetch_page_text(url)`
- `get_current_page()`
- `summarize_text(text)`

## Task 4 — reader migliore
1. migliora estrazione testo HTML
2. preferisci title/meta/paragraph/headings/list items
3. rimuovi nav/footer/cookie text quando possibile
4. tronca in chunk per context window
5. aggiungi cache locale delle ultime 20 pagine

## Task 5 — UX
1. stato modello: unloaded/loading/ready/error/generating
2. progress indicator in chat
3. pulsante Stop
4. action chips: Open / Search / Read / Summarize
5. cronologia siti recenti persistente
6. vista debug per prompt, tool call e tempi

## Task 6 — performance
1. carica modello una sola volta
2. riusa context/sessione se supportato
3. limita token output e context
4. esegui fetch/estrazione fuori dal main thread
5. profila memoria su iPhone reale

## Task 7 — sicurezza
1. togli `NSAllowsArbitraryLoads` globale
2. consenti HTTPS di default
3. aggiungi solo le eccezioni realmente necessarie
4. impedisci aperture non-HTTP(S)
5. metti allowlist per tool call browser se vuoi modalità sicura

## Deliverable richiesti a Codex
- codice completo buildabile
- commenti solo dove servono
- nessuna dipendenza inutile
- README aggiornato
- se serve, aggiungi unit test per URL normalization, HTML extraction e tool routing
