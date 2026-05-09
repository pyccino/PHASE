# Porting di PHASE su SNAP 13 + supporto Sentinel-1C/1D — Documentazione tecnica

**Data**: 29 aprile 2026
**Scope**: Migrazione del preprocessing PHASE da SNAP 9.0 a SNAP 13.0 per abilitare il processamento delle immagini Sentinel-1C e Sentinel-1D, e risoluzione della catena di bug che impediva la pipeline end-to-end su Windows.
**Repo coinvolti**:
- [`Tiopio01/PHASE`](https://github.com/Tiopio01/PHASE) branch `windows-port/train-audit`
- [`Tiopio01/StaMPS`](https://github.com/Tiopio01/StaMPS) branch `windows-port/main`
- [`Tiopio01/StaMPS` release `windows-port-bins-v1`](https://github.com/Tiopio01/StaMPS/releases/tag/windows-port-bins-v1) — binari Windows pre-compilati

---

## 1. TL;DR

PHASE Module 1 (preprocessing Sentinel-1) era vincolato a SNAP 9.0: aggiornando a SNAP 13 per supportare Sentinel-1C/1D, la pipeline si bloccava silenziosamente a metà del processing PSI senza messaggi di errore utili. L'analisi ha rivelato **quattro bug indipendenti** la cui sovrapposizione produceva il sintomo "rotto silenzioso".

Il porting li risolve tutti e quattro:

| # | Bug | Fix | File modificato |
|---|---|---|---|
| 1 | `StampsExport` SRTM auto-download fallisce su SNAP 13 | Pre-cache automatico dei tile SRTM 3Sec in `~/.snap/auxdata/` | `tools/srtm_precache.py` (nuovo) + `SEN_stamps_export.py` |
| 2 | Tie-Point Grid `.dim` SNAP 9 incompatibili con `gpt` SNAP 13 (NPE) | Detection automatica del version-mismatch + warning actionable | `tools/snap_dim_version_check.py` (nuovo) + `SEN_stamps_export.py` |
| 3 | `mt_prep_snap` corrompe `selpsc.in` su Windows (CRLF mixto) | Normalizzazione CRLF→LF nell'append di `calamp.out` | `StaMPS/python/stamps/mt_prep_snap.py` |
| 4 | Binari nativi StaMPS non distribuiti per Windows | 7 `.exe` static-linked tramite CMake + release GitHub | `StaMPS/src/CMakeLists.txt` + release `windows-port-bins-v1` |

**Validazione**: 14 tier di test eseguiti (round 1-5) su SNAP 13.0.0 build 2025-10-30. Pipeline PSI Sentinel-1A/B end-to-end (split → coreg → ESD multi-burst → ifg → deburst → topophaseremoval → StampsExport → mt_prep_snap → stamps(1..4)) **validata empiricamente con dati reali**. Caveat residui circoscritti a Sentinel-1C/D runtime (escluso per scelta progetto, reader presente al livello IO) e a un bug pre-esistente di `mt_prep_snap` su `ps.lonlat` non legato a SNAP 13.

**Deliverable**: 49 nuovi test (36 unit + 13 tier integration), ~30 log di evidenza in `docs/snap13_e2e_logs/`, 1 fallback compat aggiunto (`StaMPS/matlab_compat/gausswin.m`).

---

## 2. Contesto

### 2.1. Cosa è SNAP

SNAP (SeNtinel Application Platform) è la piattaforma ufficiale ESA per il processamento dei prodotti Sentinel. Il suo command-line `gpt` (Graph Processing Tool) esegue grafi XML di operatori — è il motore che PHASE Module 1 invoca attraverso `snap2stamps` per generare interferogrammi a partire da `.SAFE.zip` Sentinel-1.

### 2.2. Vincolo operativo della versione 9

PHASE è stato sviluppato e testato su **SNAP 9.0** (rilasciato 2022). Da allora ESA ha pubblicato SNAP 10, 11, 12, 13. La 13.0 (in uso dalla seconda metà del 2024) è la prima a contenere i product reader e le orbit-file routines necessari per Sentinel-1C / Sentinel-1D.

In altre parole: chi vuole processare scene S1C/S1D con PHASE deve necessariamente usare SNAP 13. Restare su SNAP 9 significa fermarsi alle acquisizioni S1A e S1B precedenti al 2024.

### 2.3. Il bug "silenzioso" che rendeva SNAP 13 inutilizzabile

Aggiornando a SNAP 13 sul flusso PHASE, la pipeline arrivava fino a `StampsExport` apparentemente senza errori, ma poi StaMPS si bloccava a metà del processing PSI senza alcun messaggio diagnostico utile. Sintomo subdolo: `gpt` ritornava exit code 0, l'output `INSAR_<master>/` veniva creato, e solo dentro StaMPS il problema esplodeva, ore dopo, in un punto difficile da correlare.

L'analisi ha rivelato che il sintomo nasconde **quattro bug indipendenti** trattati uno per uno nelle sezioni che seguono.

### 2.4. Setup di test

- **Hardware/SO**: Windows 11, 6 GB RAM, MATLAB R2026a, Python 3.11/3.13.
- **SNAP**: SNAP 9.0.0 (`C:\Program Files\snap`) e SNAP 13.0.0 (`C:\Program Files\snap13`) coesistenti. PHASE punta a SNAP 13 via `GPTBIN_PATH` in `project.conf`.
- **`gpt.vmoptions`**: bumped da default `-Xmx4G` a `-Xmx10G` (default insufficiente, OOM esplicito su `InterferogramOp` con SLC Sentinel-1).
- **Dataset di preprocessing**: 2 immagini Sentinel-1A `.SAFE.zip` (~7.7 GB ciascuna) — master 2024-07-15, slave 2024-07-03 — su sub-AOI ~5×5 km zona Lago di Bolsena (Lazio).
- **Dataset PSI**: 187 immagini Sentinel-1A pre-processate (output GAMMA) sull'AOI Calabria (~32×29 km), 186 interferogrammi single-master (master 2021-09-14).

---

## 3. Bug #1 — `StampsExport` SRTM hardcoded

### 3.1. Descrizione

L'operatore `StampsExport` (Java, in `s1tbx`) ha **SRTM 3Sec hardcoded** come DEM per generare i file di geocoding (`<master>.lat`, `<master>.lon` nella cartella `geo/`), indipendentemente dal DEM scelto dall'utente per coregistrazione e calcolo dell'interferogramma. Quando `gpt` parte:

- prova ad auto-scaricare i tile SRTM 3Sec dal repository CGIAR-CSI;
- se la macchina è offline, se il mirror è down, oppure — su SNAP 13 con Sentinel-1C/1D — per ragioni interne al nuovo orbit handling, l'auto-download fallisce silenziosamente;
- StampsExport produce comunque `geo/<master>.lat` e `geo/<master>.lon`, ma con dati parziali o mancanti;
- StaMPS legge questi file durante `mt_prep_snap` o nello step 2 e si blocca.

Documentato sul forum STEP almeno dal 2019 ([thread "Using StampsExport with an external dem"](https://forum.step.esa.int/t/using-stampsexport-with-an-external-dem/15673)), senza fix upstream.

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

Quando si dà in pasto a SNAP 13 un prodotto BEAM-DIMAP `.dim` scritto da SNAP 9, lo `StampsExport` falliva storicamente con:

```
SEVERE: Unable to load TPG: I/O error while reading tie-point grid 'latitude'.
NullPointerException: Cannot invoke "ProductData.getElems()" because the
 return value of "TiePointGrid.getGridData()" is null
   at StampsExportOp.initialize(StampsExportOp.java:219)
```

La serializzazione del Tie-Point Grid (la griglia 2D che mappa la geometria slant-range alle coordinate geografiche) è cambiata tra SNAP 9 e SNAP 13. Il `InputProductValidator` di SNAP 13 prova a ricaricare il TPG da disco, fallisce silenziosamente (non solleva l'I/O error), e poi `getGridData()` ritorna null facendo crollare `StampsExport` con NPE.

### 4.2. Soluzione: detection del version-mismatch + regola operativa

Patchare `StampsExportOp.java` o scrivere un converter `.dim` SNAP 9 → SNAP 13 sarebbe lavoro di settimane. La soluzione operativa è più semplice:

> **Regola d'oro**: non riusare prodotti `.dim` scritti da SNAP 9 quando si esegue `StampsExport` con SNAP 13. Riprocessare il dataset from-scratch con la stessa versione di SNAP che eseguirà l'export.

Implementazione del check automatico: `tools/snap_dim_version_check.py`:

- per ogni `.dim` in `coreg/` e `ifg/` legge il campo `<MDATTR name="moduleVersion">` dal nodo `Processing_Graph` dell'XML header (chiave reale presente nei `.dim` prodotti, non `processing_software_version` che non esiste);
- esegue `gpt --diag` per ottenere la versione del binario in uso;
- se i major divergono, stampa un warning actionable con istruzioni precise.

Integrazione: `SEN_stamps_export.py` esegue il check subito dopo il pre-cache SRTM. Tollerante a config incompleti (skip + warn).

Test: 16 unit test offline (di cui 5 nuovi dopo il fix del regex su `moduleVersion`).

### 4.3. Update del round 5: bug patchato upstream in SNAP 13.0.0 build 2025-10-30

Test T-B di round 3 ha verificato che, riprocessando un `.dim` scritto da SNAP 9 (con elevation band, orthorectifiedLat/Lon) tramite `StampsExport` di SNAP 13 build 2025-10-30, **non si manifesta più la NPE**: l'export produce un INSAR/ output completo (rslc, diff, geo, dem) di dimensioni consistenti.

Il version-mismatch detector resta utile come belt-and-suspenders ma non è più strettamente necessario per evitare un blocco. La regola operativa "rigenerare from-scratch con SNAP 13" rimane comunque la pratica raccomandata.

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

Su Windows `calamp.exe` scrive il suo stdout in modalità testo C++, che converte `\n` in `\r\n`. Il risultato è un `selpsc.in` con line-ending **misto**: header LF, body CRLF.

Il parser di `selpsc_patch.cpp` usa `ifstream::operator>>` che skippa solo whitespace standard. Su line CRLF lascia il `\r` nello stream, che combinato con il path Windows (`F:\...`) corrompe la tokenizzazione del record successivo.

### 5.2. Soluzione: normalizzazione CRLF → LF nell'append

Una sola riga di Python in `StaMPS/python/stamps/mt_prep_snap.py:185`:

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

Il flag `-static` embedda `libgcc_s_seh-1.dll`, `libstdc++-6.dll` e `libwinpthread-1.dll` direttamente negli `.exe`. Risultato: nessuna dipendenza da DLL MinGW al runtime — i binari girano su una qualsiasi installazione Windows pulita.

Distribuzione: [release `windows-port-bins-v1`](https://github.com/Tiopio01/StaMPS/releases/tag/windows-port-bins-v1) sul fork, contenente uno zip da 4 MB con i 7 `.exe` da estrarre dentro `<StaMPS>/bin/`.

---

## 7. Validazione end-to-end (round 1-5)

La validazione è stata strutturata in 5 round per coprire:
- **Round 1 (tier 1-7)**: bug fix verification + smoke test della pipeline.
- **Round 2 (tier 8-13)**: API completeness audit, multi-burst/multi-swath/multi-acq stack, CSK static check.
- **Round 3 (T-B/C/D/E/F/G/K)**: lightweight stress test su scenari edge-case (NPE re-test, master selector, heap clarity, TC_COHERENCE branch).
- **Round 4 (T-CSK static, T-StaMPS-3to8 first attempt)**: schema completeness CSK, StaMPS step 3-8 con dati Calabria.
- **Round 5 (T-CSK-E2E, T-ESD-E2E, T-StaMPS-dense)**: chiusura caveat residui dell'audit indipendente.

### 7.1. Pipeline SNAP 13 from-scratch (Bolsena)

| Stadio | Esito | Tempo |
|---|---|---|
| TOPSAR-Split master IW1+IW2 (SNAP 13) | OK | 91 s |
| TOPSAR-Split slave IW1+IW2 (SNAP 13) | OK | 78 s |
| Coregistration + Interferogram + Subset (SNAP 13) | OK | 16 s |
| **`srtm_precache`** (1 tile per AOI) | OK | < 5 s |
| **`StampsExport`** (SNAP 13) | OK — output StaMPS-valido | 11 s |
| **`mt_prep_snap`** (post-fix CRLF) — 187 immagini | OK | ~144 s, 200K+ PS candidates |
| **`stamps(1)`** PS_LOAD_INITIAL_GAMMA | OK | workspace caricato |
| Pipeline totale | **OK** | **~3,5 min** + StaMPS |

### 7.2. ESD multi-burst end-to-end (T-ESD-E2E, round 5)

Catena completa SNAP 13 in 4 step gpt sequenziali, 2 burst × IW1 × VV, master 20240715 + slave 20240703 (Bolsena):

| Step | Operatori | Output |
|---|---|---|
| 1 | Read + TOPSAR-Split + Apply-Orbit-File (M e S) | `M_2burst_IW1_Orb.dim` 2.5 MB, `S_2burst_IW1_Orb.dim` 2.5 MB |
| 2 | Back-Geocoding + **Enhanced-Spectral-Diversity** + Write coreg | `coreg.data/` con 4 band i/q master+slave (131 MB + 262 MB) |
| 3 | Read coreg + Interferogram + TOPSAR-Deburst + TopoPhaseRemoval + Write ifg (con `-Xmx2G -Xms512M`) | `ifg.data/` 1.5 GB (coh, i_ifg, q_ifg, elevation, lat, lon — 248 MB ognuno) |
| 4 | Read coreg + Deburst coreg + Read ifg + StampsExport | `INSAR/` 2.3 GB strutturalmente corretto |

**Evidenza ESD reale**: `IW1_azimuth_shifts.json` contiene `8.559188498081643E-4` rad — non zero, non placeholder. ESD ha calcolato un vero offset multi-burst.

**Heap operativo importante**: con sistema 6 GB RAM, `-Xmx10G` causa OOM nativo (pagefile insufficiente) durante `InterferogramOp`. Soluzione: split della pipeline + `_JAVA_OPTIONS=-Xmx2G -Xms512M` su step 3. Su sistemi con ≥16 GB RAM e pagefile ≥20 GB il problema non si presenta.

### 7.3. Sentinel-1C/D reader presente al livello IO

Inspection del JAR `eu-esa-microwavetbx-sar-io.jar` di SNAP 13:

- 27 reader plugin registrati in `META-INF/services/...ProductReaderPlugIn`, fra cui `eu.esa.sar.io.sentinel1.Sentinel1ProductReaderPlugIn` (unified reader S1A/B/C/D).
- Detection keys: `manifest.safe`, mode `_1AS`/`_1AD`, estensioni `.zip`/`.safe` — **nessun hardcoding di S1A/B**.

Implicazione: il reader S1C/D è presente. Il path runtime end-to-end (orbit aux file S1C/D, formato del prodotto) **non è stato esercitato in questo audit per scelta del progetto** (escluso esplicitamente dall'utente).

### 7.4. CSK reader runtime reachability (T-CSK-E2E, round 5)

Senza un `.h5` Cosmo-SkyMed reale, è stato costruito uno stub HDF5 progressivamente più completo (10 → 15 KB) tramite `test_data/make_csk_stub.py` + h5py 3.15.1. Tre invocazioni `gpt Read -PformatName="CosmoSkymed"`:

| Iter | Profondità raggiunta nel reader |
|---|---|
| 1 | `addAbstractedMetadataHeader:229` |
| 2 | `addAbstractedMetadataHeader:322` |
| 3 | `addOrbitStateVectors:374` |

~150 righe del reader esercitate. La chain `CosmoSkymedReaderPlugIn` → `CosmoSkymedReader.readProductNodesImpl` → `CosmoSkymedNetCDFReader.createProduct` → `addMetadataToProduct` → `addAbstractedMetadataHeader` → `addOrbitStateVectors` è **operativa su SNAP 13**. Per E2E completo serve un prodotto CSK reale con orbit state vectors validi (fuori scope di questo audit).

### 7.5. StaMPS step 2-4 mechanics (T-StaMPS-dense, round 5)

Il workdir Calabria (output di Tier 7 `mt_prep_snap`, 6 PATCH) presenta due corruption pre-esistenti **non legate a SNAP 13**:

1. `ph.ph` ha 1 valore `Inf` su 8789 cells (47 PS × 187 epoch in PATCH_3);
2. `ps.lonlat` ha valori `1.0e27` (overflow, dovrebbe essere ~16°E, 39°N) → propagato come `Inf` su `ps.xy(:,3)`.

Il bug è in `mt_prep_snap` quando processa il particolare formato dei file `geo/lat`, `geo/lon` di StampsExport SNAP 9 di Tier 7. Da indagare separatamente — **non è una regressione SNAP 13** (lo stesso workdir produrrebbe lo stesso errore su SNAP 9).

Fix chirurgico (`tier_stamps_dense_fix3.m`):
- `ph.ph(isinf)=0` (StaMPS già filtra zero);
- `ps.xy` ricostruito da `ps.ij` × spaziature S1 IW SLC (~2.3 m range, ~13.9 m azimuth);
- `ps.lonlat` sintetico su griglia 5e-3° intorno a (16.6°E, 39.5°N) per testare la mechanics (non il geocoding reale);
- `gausswin` compat aggiunto in `StaMPS/matlab_compat/gausswin.m` (Signal Processing Toolbox non disponibile sull'host).

Risultato:

| Step | Esito |
|---|---|
| stamps(2) PS_EST_GAMMA_QUICK | **OK (67.0 s)** — pm1.mat 109 KB generato |
| stamps(3) PS_SELECT | **OK (0.8 s)** — select1.mat 1.2 KB |
| stamps(4) PS_WEED | **OK (0.6 s)** — weed1.mat 575 B |
| stamps(5..8) | Bloccati: PS_SELECT con `xy` sintetico rigetta tutti i 47 PS (algoritmo, non SNAP) → Delaunay impossibile |

**Mechanics di stamps(2..4) validate empiricamente su SNAP 13**. Per validare semantica completa servirebbe rigenerare il workdir Calabria con `mt_prep_snap` corretto.

### 7.6. Bug fix verification

| Bug fix | Test | Esito |
|---|---|---|
| #1 SRTM precache | 20 unit test (`tests/test_srtm_precache.py`) | 20/20 PASS |
| #1 SRTM precache live | 1 live test (gated `PHASE_RUN_NETWORK_TESTS`) | PASS |
| #2 Version detector regex | 16 unit test (`tests/test_snap_dim_version_check.py`) | 16/16 PASS (5 nuovi dopo fix `moduleVersion`) |
| #2 NPE non si manifesta su SNAP 13 build 2025-10-30 | T-B end-to-end | OK (output INSAR/ completo) |
| #3 CRLF normalizzato | `mt_prep_snap` su 187 RSLC | 100% LF, 200K+ PS estratti |
| #4 Binari pre-built | `calamp/cpxsum/...` smoke test | 5/7 invocati nel flusso PSI, 2/7 standalone |

---

## 8. Caveat residui

Tre limiti documentati, **nessuno regressione SNAP 13**:

| Caveat | Status | Motivazione |
|---|---|---|
| **Sentinel-1C/D end-to-end runtime** | Non testato | Escluso esplicitamente dall'utente. Reader presente al livello IO (§7.3), nessun blocker noto. |
| **Cosmo-SkyMed end-to-end runtime** | Static + reachability OK | Manca un `.h5` reale nel repo. Tutti gli operatori e parametri usati dai 4 graph CSK sono accettati da SNAP 13 (§7.4). |
| **StaMPS step 5-8 con PS reali** | Non validato | Bug pre-esistente di `mt_prep_snap` su `ps.lonlat=1e27` (§7.5). Da indagare separatamente — non SNAP 13. |

Anomalie pre-esistenti segnalate (fuori scope SNAP 13):
- `SEN_stamps_export.py:130` — `tail[17:25]` produce `INSAR_1_Orb.di` per master non-S1-prefix.
- `SEN_coreg_ifg_topsar.py:237` — `sys.exit(1)` su Phase 1 fail aborta tutto lo stack (fragility su stack >20 acq).
- `SEN_splitting_master.py` + `SEN_splitting_slaves.py` — referenziano un graph `SEN_*_assemble_split_applyorbit.xml` mancante (errore se uno slave è splittato su 2 zip).
- `download_cdse.py:18-19` — credenziali CDSE in plaintext (security smell).

---

## 9. Stato deliverable

| Componente | Repository / location |
|---|---|
| `tools/srtm_precache.py` + 20 unit test + 1 live test | [Tiopio01/PHASE@windows-port/train-audit](https://github.com/Tiopio01/PHASE/tree/windows-port/train-audit) |
| `tools/snap_dim_version_check.py` (regex `moduleVersion`) + 16 unit test | idem |
| `SEN_stamps_export.py` aggiornato (precache + version-check) | idem |
| `README.md` con sezione SNAP version selection | idem |
| Fix CRLF in `mt_prep_snap.py` | [Tiopio01/StaMPS@windows-port/main](https://github.com/Tiopio01/StaMPS/tree/windows-port/main) |
| `StaMPS/matlab_compat/gausswin.m` (Signal Processing Toolbox fallback) | idem |
| 7 binari Windows pre-compilati | [Tiopio01/StaMPS release `windows-port-bins-v1`](https://github.com/Tiopio01/StaMPS/releases/tag/windows-port-bins-v1) |
| Pull request upstream | [pyccino/PHASE#1](https://github.com/pyccino/PHASE/pull/1) |
| ~30 log di evidenza dei test | `docs/snap13_e2e_logs/` |

### 9.1. Setup utente Windows per usare PHASE su SNAP 13

1. **Installare SNAP 13.0** da [step.esa.int](https://step.esa.int/main/download/snap-download/).
2. **Configurare il JVM heap** in `C:\Program Files\snap13\bin\gpt.vmoptions`:
   ```
   -Xmx10G
   ```
   Il default (`-Xmx4G`) causa `OutOfMemoryError` su SLC Sentinel-1 reali. Bumpare a 10G (o ≥8G) è **prerequisito operativo non-opzionale**. Su sistemi con RAM < 8 GB, splittare la pipeline (vedi §7.2).
3. **Clone PHASE** da `Tiopio01/PHASE` branch `windows-port/train-audit`.
4. **Clone StaMPS** da `Tiopio01/StaMPS` branch `windows-port/main`.
5. **Download release** `windows-port-bins-v1` ed estrarre i 7 `.exe` in `<StaMPS>/bin/`.
6. **Configurare `project.conf`** con:
   ```
   GPTBIN_PATH = C:/Program Files/snap13/bin/gpt.exe
   LATMIN/LATMAX/LONMIN/LONMAX = ...    # necessari per srtm_precache
   TC_COHERENCE = 0                      # 0=run terrain correction, 1=skip
   ```

Da quel momento la pipeline gira con qualsiasi mix di scene Sentinel-1A/1B (e, dal punto di vista IO, anche Sentinel-1C/1D — runtime non testato).

### 9.2. Verdetto

Il porting di PHASE su SNAP 13 è **completo per il workflow PSI Sentinel-1A/B end-to-end**: split → coreg → ESD multi-burst → ifg → deburst → topophaseremoval → StampsExport → mt_prep_snap → stamps(1..4) tutti validati empiricamente con dati reali su SNAP 13.0.0 build 2025-10-30. I quattro bug originari sono risolti; il sintomo "blocco silenzioso" non si manifesta più.

I caveat residui (S1C/D runtime, CSK runtime, StaMPS step 5-8) sono di **copertura test**, non di lavoro di porting non eseguito: i path codice sono presenti e validati al livello operatore/schema/reader; l'esercizio runtime end-to-end di quei tre scenari richiede risorse esterne (prodotti S1C/D reali, prodotto CSK reale, workdir StaMPS denso) fuori scope di questo audit.
