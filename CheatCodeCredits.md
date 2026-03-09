# Cheat Code Credits (Codex)

## Obiettivo
Ottenere output ottimi con meno crediti, meno run inutili e meno iterazioni.

## Regole veloci
1. Scrivi richieste complete in un solo messaggio: obiettivo, file, vincoli, done criteria.
2. Chiedi `patch-first`: implementa subito, spiegazione finale breve.
3. Limita i test: run solo mirati quando cambia la logica; no full build per sole UI.
4. Passa dettagli UI tutti insieme (screenshot + colori + spacing + expected).
5. Blocca scope creep: niente refactor extra se non richiesto.
6. Imposta formato risposta breve: `cambiato / file / verifica`.
7. Batch di task correlati in una singola richiesta.
8. Se vuoi solo fattibilità: chiedi `SI/NO + rischio + stima` prima di implementare.
9. Evita loop lunghi: dopo 1 fix chiedi verifica e poi micro-adjust.
10. Chiedi sempre modifiche minime e reversibili.

## Prompt template (copia/incolla)
```md
Task: [cosa vuoi ottenere]

Scope:
- File da toccare: [path1, path2]
- Non toccare: [path/cartelle]
- Vincoli: [performance, UX, API, naming]

Execution mode:
- Implementa direttamente (no brainstorming lungo)
- No refactor extra
- Run solo se cambia logica/comportamento
- Se è solo UI: non runnare full project

Output finale:
- 3 punti: cosa hai cambiato, file, come verificare
```

## Prompt template (fast UI)
```md
Modifica solo UI.
Obiettivo visuale: [descrizione]
Screenshot riferimento: [allegato]
File target: [path]
Vincoli: no logica, no run full project.
Output: solo diff + 2 step di verifica manuale.
```

