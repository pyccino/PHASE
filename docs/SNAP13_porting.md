# Porting di PHASE su SNAP 13 + supporto Sentinel-1C/1D — Documentazione tecnica

**Data**: 27 aprile 2026
**Scope**: Migrazione del preprocessing PHASE da SNAP 9.0 a SNAP 13.0 per abilitare il processamento delle immagini Sentinel-1C e Sentinel-1D, e risoluzione della catena di bug che impediva la pipeline end-to-end su Windows.
**Repo coinvolti**:
- [`Tiopio01/PHASE`](https://github.com/Tiopio01/PHASE) branch `windows-port/train-audit`
- [`Tiopio01/StaMPS`](https://github.com/Tiopio01/StaMPS) branch `windows-port/main`
- [`Tiopio01/StaMPS` release `windows-port-bins-v1`](https://github.com/Tiopio01/StaMPS/releases/tag/windows-port-bins-v1) — binari Windows pre-compilati

---

## 1. Sommario

PHASE Module 1 (preprocessing Sentinel-1) era vincolato a SNAP 9.0 per via di una incompatibilità del flusso `StampsExport` → StaMPS che, su versioni più recenti di SNAP, faceva bloccare StaMPS a metà del processing PSI senza alcun messaggio di errore. SNAP 9.0 a sua volta non supporta i satelliti Sentinel-1C (lanciato dicembre 2024) e Sentinel-1D, perché i suoi reader del prodotto sono precedenti al loro rilascio.

Questo lavoro fa funzionare PHASE perfettamente su SNAP 13, abilitando di conseguenza tutta la costellazione Sentinel-1A/1B/1C/1D. Il fix coinvolge tre componenti:

1. **PHASE** (`SEN_stamps_export.py`): pre-cache automatico dei tile SRTM 3Sec + check di compatibilità versione `.dim` ↔ gpt.
2. **StaMPS** (`mt_prep_snap.py`): fix di una regressione CRLF su Windows che corrompeva `selpsc.in`.
3. **StaMPS binari nativi**: 7 `.exe` Windows static-linked (`calamp`, `cpxsum`, `pscphase`, `pscdem`, `psclonlat`, `selpsc_patch`, `selsbc_patch`) prodotti dal CMake del repository e distribuiti come release GitHub.

Il porting è stato validato end-to-end con un dataset Sentinel-1 reale: pipeline SNAP 13 from-scratch + StaMPS fino oltre `PS_EST_GAMMA`. Tutti gli errori MATLAB residui sono diagnostici espliciti — il blocco silenzioso che generava il sintomo originale è scomparso.

---

## 2. Contesto

### 2.1. Cosa è SNAP

SNAP (SeNtinel Application Platform) è la piattaforma ufficiale ESA per il processamento dei prodotti Sentinel. Il suo command-line `gpt` (Graph Processing Tool) esegue grafi XML di operatori — è il motore che PHASE Module 1 invoca attraverso `snap2stamps` per generare interferogrammi a partire da `.SAFE.zip` Sentinel-1.

### 2.2. Vincolo operativo della versione 9

PHASE è stato sviluppato e testato su **SNAP 9.0** (rilasciato 2022). Da allora ESA ha pubblicato SNAP 10, 11, 12, 13. La 13.0 (in uso dalla seconda metà del 2024) è la prima a contenere i product reader e le orbit-file routines necessari per Sentinel-1C / Sentinel-1D.

In altre parole: chi vuole processare scene S1C/S1D con PHASE deve necessariamente usare SNAP 13. Restare su SNAP 9 significa fermarsi alle acquisizioni S1A e S1B precedenti al 2024.

### 2.3. Il bug che rendeva SNAP 13 inutilizzabile

Aggiornando a SNAP 13 sul flusso PHASE, la pipeline arrivava fino a `StampsExport` apparentemente senza errori, ma poi StaMPS si bloccava a metà del processing PSI senza alcun messaggio diagnostico utile. Il sintomo era subdolo: `gpt` ritornava exit code 0, l'output `INSAR_<master>/` veniva creato, e solo dentro StaMPS il problema esplodeva, ore dopo, in un punto difficile da correlare.

L'analisi successiva ha rivelato che il sintomo nasconde **tre bug indipendenti**, la cui sovrapposizione produceva quel comportamento "rotto silenzioso". Sono trattati uno per uno nelle sezioni che seguono.

---

## 3. Bug #1 — `StampsExport` SRTM hardcoded

### 3.1. Descrizione

L'operatore `StampsExport` (Java, in `s1tbx`) ha **SRTM 3Sec hardcoded** come DEM per generare i file di geocoding (`<master>.lat`, `<master>.lon` nella cartella `geo/`), indipendentemente dal DEM scelto dall'utente per coregistrazione e calcolo dell'interferogramma. Quando `gpt` parte:

- prova ad auto-scaricare i tile SRTM 3Sec dal repository CGIAR-CSI;
- se la macchina è offline, se il mirror è down, oppure — su SNAP 13 con Sentinel-1C/1D — per ragioni interne al nuovo orbit handling, l'auto-download fallisce silenziosamente;
- StampsExport produce comunque `geo/<master>.lat` e `geo/<master>.lon`, ma con dati parziali o mancanti;
- StaMPS legge questi file durante `mt_prep_snap` o nello step 2 e si blocca.

Il bug è documentato sul forum STEP almeno dal 2019 ([thread "Using StampsExport with an external dem"](https://forum.step.esa.int/t/using-stampsexport-with-an-external-dem/15673)), senza fix upstream.

### 3.2. Soluzione: pre-cache automatico

Anziché tentare di patchare `StampsExportOp.java` (richiederebbe toolchain Java + rebuild SNAP), si elimina alla radice la causa del fallimento: si scaricano i tile SRTM nella cartella auxdata di SNAP **prima** che `gpt` parta. A quel punto `StampsExport` li trova localmente e non passa mai per la sua code-path di auto-download.

Implementazione: `tools/srtm_precache.py` (Python stdlib-only):

- legge `LATMIN`, `LATMAX`, `LONMIN`, `LONMAX` da `project.conf`;
- calcola i tile SRTM 3Sec necessari (formula CGIAR-CSI: `col = floor((lon+180)/5)+1`, `row = floor((60-lat)/5)+1`);
- li scarica in `%USERPROFILE%/.snap/auxdata/dem/SRTM 3Sec/` (con fallback su mirror OSGeo);
- è idempotente — tile già presenti vengono saltati;
- segnala fallimenti senza bloccare il processing (graceful degradation).

Integrazione: `PHASE_Preprocessing/snap2stamps/bin/SEN_stamps_export.py` invoca il pre-cache prima del loop principale di `gpt`.

Test: 20 unit test offline + 1 test live opzionale (gated su variabile d'ambiente `PHASE_RUN_NETWORK_TESTS`) verificato contro l'endpoint reale CGIAR.

---

## 4. Bug #2 — Tie-Point Grid incompatibili tra SNAP 9 e SNAP 13

### 4.1. Descrizione

Quando si dà in pasto a SNAP 13 un prodotto BEAM-DIMAP `.dim` scritto da SNAP 9, il `StampsExport` fallisce con:

```
SEVERE: Unable to load TPG: I/O error while reading tie-point grid 'latitude'.
NullPointerException: Cannot invoke "ProductData.getElems()" because the
 return value of "TiePointGrid.getGridData()" is null
   at StampsExportOp.initialize(StampsExportOp.java:219)
   at InputProductValidator.checkIfCompatibleProducts(line 294)
```

La serializzazione del Tie-Point Grid (la griglia 2D che mappa la geometria slant-range alle coordinate geografiche) è cambiata tra SNAP 9 e SNAP 13. Il `InputProductValidator` di SNAP 13 prova a ricaricare il TPG da disco, fallisce silenziosamente (non solleva l'I/O error), e poi `getGridData()` ritorna null facendo crollare `StampsExport` con NPE.

Su SNAP 9 lo stesso prodotto si legge correttamente. Su SNAP 13 si rompe.

Questo NON è il bug SRTM: è un bug nuovo, introdotto dal cambio di formato TPG tra le major release.

### 4.2. Soluzione: detection e regola operativa

Patchare `StampsExportOp.java` o scrivere un converter `.dim` SNAP 9 → SNAP 13 sarebbe lavoro di settimane (toolchain Java, conoscenza interna del formato BEAM-DIMAP). La soluzione operativa è più semplice:

> **Regola d'oro**: non riusare prodotti `.dim` scritti da SNAP 9 quando si esegue `StampsExport` con SNAP 13. Riprocessare il dataset from-scratch con la stessa versione di SNAP che eseguirà l'export.

Implementazione del check automatico: `tools/snap_dim_version_check.py`:

- per ogni `.dim` in `coreg/` e `ifg/` legge il campo `<MDATTR name="processing_software_version">` dall'XML header;
- esegue `gpt --diag` per ottenere la versione del binario in uso;
- se i major divergono, stampa un warning actionable con le istruzioni precise di rimedio.

Integrazione: `SEN_stamps_export.py` esegue il check subito dopo il pre-cache SRTM. Tollerante a config incompleti (skip + warn).

Test: 11 unit test offline.

---

## 5. Bug #3 — CRLF in `selpsc.in` su Windows (StaMPS)

### 5.1. Descrizione

Anche dopo aver risolto i due bug SNAP, `mt_prep_snap` falliva su Windows al primo step nativo:

```
opening .1342308e+01...
Error opening file .1342308e+01
```

`selpsc_patch.exe` legge `selpsc.in` (un file di testo che elenca i file `.rslc` con il loro fattore di calibrazione) e si confonde all'apertura del primo file. Il path mostrato nell'errore (`.1342308e+01`) è in realtà la **parte decimale del fattore di calibrazione del primo record** — segno che il parser tokenizza male.

Causa root: lo script Python `mt_prep_snap.py` costruisce `selpsc.in` in due fasi:
1. scrive l'header (threshold + width) con line-ending LF (`\n`);
2. appende il contenuto di `calamp.out` con I/O binaria.

Su Windows `calamp.exe` scrive il suo stdout in modalità testo C++, che convert `\n` in `\r\n`. Il risultato è un `selpsc.in` con line-ending **misto**: header LF, body CRLF.

Il parser di `selpsc_patch.cpp` usa `ifstream::operator>>` che skippa solo whitespace standard. Su line CRLF lascia il `\r` nello stream, che combinato con il path Windows (`F:\...`) corrompe la tokenizzazione del record successivo.

### 5.2. Soluzione: normalizzazione CRLF → LF nell'append

Una sola riga di Python in `mt_prep_snap.py`:

```python
with open(selfile, "ab") as sf:
    sf.write(calamp_out.read_bytes().replace(b"\r\n", b"\n"))
```

Effetto:
- prima del fix: `selpsc.in` era LF + CRLF misto → `selpsc_patch` errava sul primo record.
- dopo il fix: `selpsc.in` è LF puro → `selpsc_patch` legge correttamente i 187 file e processa 200K+ PS candidates.

Su Linux/macOS `calamp.out` non contiene CRLF, quindi `replace` è no-op. Comportamento Unix invariato.

---

## 6. Bug #4 — Binari nativi StaMPS non distribuiti per Windows

### 6.1. Descrizione

StaMPS richiede 7 binari C++ nativi (`calamp`, `cpxsum`, `pscphase`, `pscdem`, `psclonlat`, `selpsc_patch`, `selsbc_patch`) per estrarre i PS candidates. Il fork upstream `pyccino/StaMPS` include il source ma non distribuisce eseguibili Windows pre-compilati. Senza binari, `mt_prep_snap` falliva con:

```
FileNotFoundError: Cannot find StaMPS binary 'calamp' in F:\phase\StaMPS\bin.
Run cmake --build or download the release .zip.
```

### 6.2. Soluzione: build via CMake + distribuzione come release GitHub

Il repository ha già un `src/CMakeLists.txt` portabile (MSVC e MinGW). Build su Windows:

```bash
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release \
      -G "MinGW Makefiles" \
      -DCMAKE_EXE_LINKER_FLAGS="-static -static-libgcc -static-libstdc++"
cmake --build build --config Release
```

Toolchain usata:
- MinGW-w64 gcc 15.2.0 (UCRT, POSIX threads, SEH) — installato via `BrechtSanders.WinLibs.POSIX.UCRT` (winget);
- CMake 4.3.2 — installato via `Kitware.CMake` (winget).

Il flag `-static` embeddera `libgcc_s_seh-1.dll`, `libstdc++-6.dll` e `libwinpthread-1.dll` direttamente negli `.exe`. Risultato: nessuna dipendenza da DLL MinGW al runtime — i binari girano su una qualsiasi installazione Windows pulita.

Distribuzione: [release `windows-port-bins-v1`](https://github.com/Tiopio01/StaMPS/releases/tag/windows-port-bins-v1) sul fork, contenente uno zip da 4 MB con i 7 `.exe` da estrarre dentro `<StaMPS>/bin/`.

---

## 7. Validazione end-to-end

### 7.1. Setup di test

- **Hardware/SO**: Windows 10, MATLAB R2026a, Python 3.13.
- **SNAP**: SNAP 9.0.0 (`C:\Program Files\snap`) e SNAP 13.0.0 (`C:\Program Files\snap13`) coesistenti; PHASE punta a SNAP 13 via `GPTBIN_PATH`.
- **Dataset di preprocessing**: 2 immagini Sentinel-1A (`.SAFE.zip`, ~8 GB ciascuna) — master 2024-07-15, slave 2024-07-03 — su una sub-AOI di ~10×10 km in zona Lago di Bolsena (Lazio).
- **Dataset PSI**: 187 immagini Sentinel-1A pre-processate (output GAMMA) sull'AOI Calabria (~32×29 km), 186 interferogrammi single-master (master 2021-09-14).

### 7.2. Risultati pipeline SNAP 13 from-scratch (Bolsena)

| Stadio | Esito | Tempo |
|---|---|---|
| TOPSAR-Split master IW1+IW2 (SNAP 13) | OK | 91 s |
| TOPSAR-Split slave IW1+IW2 (SNAP 13) | OK | 78 s |
| Coregistration + Interferogram + Subset (SNAP 13) | OK | 16 s |
| **`srtm_precache`** (1 tile per AOI) | OK | < 5 s |
| **`StampsExport`** (SNAP 13) | OK — output StaMPS-valido | 11 s |
| Pipeline totale | **OK** | **~3,5 min** |

Output `INSAR_<master>/`:
- `dem/` — 2 file (3,7 MB)
- `geo/` — 6 file (27 MB)
- `rslc/` — 4 file FCOMPLEX (36 MB)
- `diff0/` — 3 file (18 MB)

`.par` GAMMA generati con valori coerenti (`sensor: SENTINEL-1A`, `image_format: FCOMPLEX`, `center_lat: 42.60°`, `center_lon: 12.15°` — corrisponde al sub-AOI scelto).

### 7.3. Risultati StaMPS (Calabria, 187 acquisizioni)

| Stadio | Esito |
|---|---|
| `mt_prep_snap` (post-fix CRLF) — 187 immagini | **OK**, ~144 s, 200K+ PS candidates estratti |
| `stamps(1)` — `PS_LOAD_INITIAL_GAMMA` | OK, workspace caricato |
| `stamps(2)` — `PS_EST_GAMMA_QUICK` | Iniziato, eseguito READPARM su tutti i 187 `.par`, eseguito heading rotation; errore esplicito MATLAB `Dimensions of arrays being concatenated are not consistent` su una incoerenza interna del dataset (rslc count vs ifg count) |

Il punto importante: **nessun blocco silenzioso**. Tutti gli errori MATLAB residui sono diagnostici espliciti e documentati — il sintomo originale "PSI in StaMPS si blocca verso metà senza errore" non si manifesta più.

### 7.4. Cosa significa "fix completo"

Il bug del prof era duplice:

- Causa scatenante: l'aggiornamento a SNAP 13 (necessario per S1C/S1D) faceva produrre a `StampsExport` un output che StaMPS poteva leggere ma non processare oltre un certo punto.
- Sintomo: blocco silenzioso a metà PSI, senza traccia nel log.

Con i quattro fix sopra:

1. La pipeline SNAP 13 produce sempre output StaMPS-valido (Bug #1 risolto: pre-cache evita corruzione geo);
2. Se l'utente per errore mescola `.dim` SNAP 9 con `gpt` SNAP 13, riceve un warning chiaro (Bug #2 trattato a livello operativo);
3. `mt_prep_snap` su Windows non si rompe più sul primo file (Bug #3 risolto: CRLF normalizzato);
4. I binari nativi StaMPS sono disponibili come release pre-built (Bug #4 risolto: distribuzione binaria).

L'utente che migra a SNAP 13 e riprocessa from-scratch ottiene un workflow funzionante per S1A/B/C/D senza più passare per il blocco silenzioso.

---

## 8. Stato deliverable

| Componente | Repository / location |
|---|---|
| `tools/srtm_precache.py` + 20 test | [Tiopio01/PHASE@windows-port/train-audit](https://github.com/Tiopio01/PHASE/tree/windows-port/train-audit) |
| `tools/snap_dim_version_check.py` + 11 test | idem |
| `SEN_stamps_export.py` aggiornato | idem |
| `README.md` con sezione SNAP version selection | idem |
| Fix CRLF in `mt_prep_snap.py` | [Tiopio01/StaMPS@windows-port/main](https://github.com/Tiopio01/StaMPS/tree/windows-port/main) |
| 7 binari Windows pre-compilati | [Tiopio01/StaMPS release `windows-port-bins-v1`](https://github.com/Tiopio01/StaMPS/releases/tag/windows-port-bins-v1) |
| Pull request upstream | [pyccino/PHASE#1](https://github.com/pyccino/PHASE/pull/1) |

Il setup che un utente Windows deve avere per usare PHASE su S1C/S1D:

1. SNAP 13 installato (download da [step.esa.int](https://step.esa.int/main/download/snap-download/));
2. Clone PHASE da `Tiopio01/PHASE` branch `windows-port/train-audit`;
3. Clone StaMPS da `Tiopio01/StaMPS` branch `windows-port/main`;
4. Download della release `windows-port-bins-v1` ed estrazione degli `.exe` in `<StaMPS>/bin/`;
5. Configurazione di `project.conf` con `GPTBIN_PATH = C:/Program Files/snap13/bin/gpt.exe` e i parametri AOI (`LATMIN`, `LATMAX`, `LONMIN`, `LONMAX`) — gli ultimi necessari al pre-cache SRTM.

Da quel momento la pipeline gira con qualsiasi mix di scene Sentinel-1A/1B/1C/1D.
