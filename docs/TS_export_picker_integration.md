# Integrazione picker per export delle serie temporali in `PHASE_StaMPS` — Documentazione tecnica

**Data**: 29 aprile 2026
**Scope**: Sostituzione del popup interattivo `ginput` di StaMPS (`StaMPS/matlab/ts_plot.m:43`, accessibile dai pushbutton di `ps_plot('v','ts',...)` a `StaMPS/matlab/ps_plot.m:2218-2238`) con un picker grafico embedded direttamente nella nuova tab "TS Points" di `PHASE_Preprocessing/PHASE_StaMPS.mlapp`. Niente più finestra che blocca la sessione MATLAB durante una run PSI; selezione dei punti d'interesse driven da CSV, GUI o coordinate manuali.
**Repo coinvolti**:
- [`Tiopio01/PHASE`](https://github.com/Tiopio01/PHASE) branch `windows-port/train-audit`
- [`Tiopio01/StaMPS`](https://github.com/Tiopio01/StaMPS) branch `windows-port/main`

---

## 1. TL;DR

Il flusso storico StaMPS per ottenere la serie temporale di un Persistent Scatterer richiede `ps_plot('v-do','ts',...)` → click sul pushbutton "TS plot" → `ginput(1)` blocca MATLAB in attesa del click sul PS → singola serie temporale plottata in una nuova figura. Workflow non automatizzabile, non batchabile, non orchestrabile da PHASE.

Il refactor introduce **4 componenti**:

| # | Componente | Ruolo | File |
|---|---|---|---|
| 1 | Funzione headless | Carica `ph_mm/lonlat/day` da `ps_plot_ts_*.mat`, legge un CSV di punti, scrive una `ts_<id>.csv` per punto. Niente GUI, niente `ginput`. Batchabile. | `StaMPS/matlab_compat/ts_export_batch.m` |
| 2 | Picker uifigure | Mappa satellitare con i PS coloriti per LOS rate; toggle "Pick PS mode" + click sui pallini per snap-add; "Add manually" / "Add free point" per inserimento alternativo; tabella editabile; Save/Load CSV; "Run TS export" che invoca #1. Modalità standalone (popup) o embed in un `parent` container. | `StaMPS/matlab_compat/ts_export_picker.m` |
| 3 | Patcher `.mlapp` | Aggiunge in-place a `PHASE_StaMPS.mlapp` la nuova tab "TS Points" + bottone "Load TS picker into this tab" + callback che chiama `ts_export_picker(workdir, app.TSPointsTab)` (modalità embed, no popup). Aggiorna anche la `startupFcn` per addpath di `StaMPS/matlab` e `StaMPS/matlab_compat`. Idempotente. | `tools/add_tspoints_tab.py` |
| 4 | Test + demo | 9 unit test su `ts_export_batch`; due demo launcher (standalone picker + full PHASE_StaMPS pre-configurato). | `StaMPS/tests/matlab/test_ts_export_batch.m` + `tools/launch_*.m` |

**Stato**: tutto a runtime funzionante su MATLAB R2026a + Mapping Toolbox 26.1 + Windows 11. 9/9 unit test verdi. Pipeline `ginput`-free verificata su workdir sintetico (600 PS, 187 acquisizioni).

---

## 2. Contesto

### 2.1. Il flusso interattivo legacy di StaMPS

In una sessione StaMPS, dopo `stamps(7)` (estrazione velocità), l'utente lancia tipicamente:

```matlab
ps_plot('v-do', 'ts', 1, 0, 0, 1)
```

Questo:

1. apre una figura con la mappa di velocità LOS dei PS;
2. al fondo della figura, in `ps_plot.m:2218-2238`, vengono **embedded** tre `uicontrol`:
   - pushbutton **"TS plot"** → callback `clear ph_uw; ts_plot`;
   - pushbutton **"TS double diff."** → callback `clear ph_uw; ts_plotdiff`;
   - edit field per il **raggio (m)** intorno al click;
3. al click su "TS plot", lo script `ts_plot.m:43` esegue:

   ```matlab
   [lon0, lat0] = ginput(1);
   ```

   Il cursore diventa un mirino, la sessione MATLAB **blocca** finché l'utente non clicca un punto sulla mappa. Allora viene calcolata la media `ph_mm` su tutti i PS entro il raggio specificato, e plottata in una nuova figura.

### 2.2. I limiti del flusso legacy per PHASE

PHASE è una pipeline orchestrata da `PHASE_StaMPS.mlapp`. L'utente:

1. configura tutti i parametri nelle tab della GUI (Preparation, Global Variables, StaMPS 1..5, ...);
2. clicca "Start" nella tab Run;
3. la pipeline gira in batch fino al completamento.

Il workflow `ps_plot + ts_plot` rompe questo paradigma:

- **Non è invocabile da config**: l'utente non può dire "voglio le serie temporali dei PS in queste 5 coordinate".
- **Non è batchabile**: ogni serie temporale richiede 1 click umano.
- **Non è ripetibile**: chi legge il report non può rieseguire la stessa selezione automaticamente.
- **Blocca la sessione**: `ginput` è bloccante; uno script che chiama `ps_plot('v','ts',...)` non torna mai al prompt finché qualcuno non clicca o killa MATLAB.

Per il caso d'uso reale del committente (monitoring di una diga / un edificio / uno scarp di frana — punti decisi a priori dalla geologia), serve esattamente il contrario: **input strutturato di N coordinate → output strutturato di N CSV di serie temporali**, eseguibile sia in batch che con UI di supporto per la selezione.

---

## 3. Architettura

### 3.1. `ts_export_batch.m` — funzione headless (Componente 1)

Sostituto stretto del calcolo dietro `ts_plot.m`, esposto come funzione pura:

```matlab
ts_export_batch(matfile, points_csv, outdir, default_radius)
```

- `matfile`: path a `ps_plot_ts_<value_type>.mat` (schema `StaMPS/matlab/ts_flaghelper.m:13-23`: variabili `ph_mm`, `lonlat`, `day`, `master_day`, `lambda`, `ref_ps`, `unwrap_ifg_index`, `ifg_list`, `bperp`, `n_ps`).
- `points_csv`: CSV con colonne `id`, `lon`, `lat`, opzionale `radius_m`.
- `outdir`: cartella di output, creata se mancante.
- `default_radius`: usato per le righe senza `radius_m`.

Per ogni punto:
1. proietta `(lon, lat)` in metri locali via `llh2local` (la stessa funzione usata da `ts_plot.m:55`, per consistenza esatta del semantica del raggio);
2. seleziona i PS dentro `radius_m` metri;
3. media `ph_mm` su quei PS, una colonna per acquisizione;
4. scrive `<outdir>/ts_<id>.csv` con colonne `date,disp_mm` (date in formato `yyyy-MM-dd` via `datetime`, sostituisce il deprecato `datestr`).

Validazioni:
- matfile mancante o senza variabili attese → `ts_export_batch:badMat`;
- CSV senza colonne `id`/`lon`/`lat` → `ts_export_batch:badCsv` (anche quando manca `id`, fix esplicito al "shadow bug" di `setvartype`);
- ID duplicati nel CSV → `ts_export_batch:duplicateId`;
- ID con caratteri filesystem-unsafe (`/\:*?"<>|` + spazio) → sostituiti con `_`;
- punto senza PS in raggio → warning `ts_export_batch:noPS` + skip (nessun CSV con NaN).

### 3.2. `ts_export_picker.m` — picker uifigure (Componente 2)

Doppia modalità:

```matlab
ts_export_picker(workdir)                          % popup standalone
ts_export_picker(workdir, parent)                  % embed in parent
ts_export_picker(workdir, parent, value_type)      % embed con value_type custom
```

- Carica il matfile, calcola un proxy di velocità per-PS via `polyfit` lineare di `ph_mm` vs anni.
- Layout: `geoaxes` con basemap satellitare a sinistra (richiede Mapping Toolbox), pannello "Selected points" a destra con uitable + 4 bottoni (Pick PS toggle, Add free point, Add manually, Remove), barra inferiore con New-point radius + Load CSV + Save CSV + Run TS export + status.
- Toggle "Pick PS mode": OFF = pan/zoom/datatip nativi del geoaxes operativi; ON = datatip disabilitato + click sul PS più vicino al cursore lo aggiunge al CSV.
- "Add manually": dialog modale con id/lon/lat/radius_m typed, con validazione live.
- "Run TS export": invoca `ts_export_batch` sul CSV in tabella, scrive in `<workdir>/ts_export/`.

Auto-load: se `<workdir>/aoi_points.csv` esiste, viene caricato al boot del picker.

### 3.3. `add_tspoints_tab.py` — patcher .mlapp (Componente 3)

Il `.mlapp` di App Designer è un archivio OOXML zip:

```
[Content_Types].xml
_rels/.rels
metadata/...
matlab/document.xml      ← sorgente MATLAB (classdef serializzato in CDATA)
appdesigner/appModel.mat ← modello visuale di App Designer (binario)
```

Il patcher modifica **solo** `matlab/document.xml`:

1. dichiara due nuove proprietà nel blocco `properties (Access = public)`: `TSPointsTab` (Tab) e `OpenTSPickerButton` (Button);
2. estende la `startupFcn` esistente per `addpath` di `StaMPS/matlab` e `StaMPS/matlab_compat` (path derivati dalla "StaMPS installation folder" della Preparation tab);
3. aggiunge in `createComponents()` la creazione della tab "TS Points" con due welcome label + un terzo label che cita l'auto-load di `aoi_points.csv` + il bottone verde "Load TS picker into this tab";
4. aggiunge nella sezione callbacks il metodo `OpenTSPickerButtonPushed` che — se "Project folder" (Preparation tab) è valido — invoca `ts_export_picker(workdir, app.TSPointsTab)` (modalità embed: il picker `delete(parent.Children)` e si insedia nella tab, niente popup).

Idempotente: rilevamento di `OpenTSPickerButton` già presente → no-op. Usa `tools/mlapp_roundtrip.py` per repack OOXML in ordinamento canonico (necessario per non rompere App Designer).

### 3.4. Test + demo (Componente 4)

- `StaMPS/tests/matlab/test_ts_export_batch.m`: 9 unit test (matlab.unittest classdef): cluster ok, multi-punto, override per-row del raggio, no-PS warning, missing required column, missing `id` column (caso speciale `setvartype`), corrupt matfile, ID duplicati, sanitisation di caratteri unsafe.
- `tools/launch_ts_picker_demo.m`: demo standalone (popup mode) con 600 PS sintetici, utile per ispezionare il picker senza un workdir reale.
- `tools/launch_phase_with_demo_workdir.m`: demo full-app — genera matfile sintetico, apre `PHASE_StaMPS`, pre-compila Project folder + StaMPS install folder + master date + amplitude threshold, switcha alla tab TS Points. Ti basta cliccare il bottone verde per vedere l'embed in azione.

---

## 4. Setup utente in PHASE_StaMPS

1. Configurare la **Preparation** tab: Project folder (workdir StaMPS), StaMPS installation folder, Master date, Amplitude threshold.
2. Configurare le altre tab (Global Variables, StaMPS 1..5, AOI) come al solito.
3. Eseguire la pipeline standard fino a `stamps(7)`. Lanciare poi una volta `ps_plot('v-do','ts',1,...)` per generare `<workdir>/ps_plot_ts_v-do.mat`.
4. Aprire la tab **TS Points** (ultima a destra). Vedi:
   - Title: "Pick query points (manually or by clicking on the velocity map) and export their time series as CSV."
   - Subtitle: requisito `stamps(7)` + `ps_plot('v-do','ts',1,...)`.
   - Note: "If `<project folder>/aoi_points.csv` already exists, the picker auto-loads it on start."
   - Bottone verde **"Load TS picker into this tab"**.
5. Click sul bottone → la tab si svuota e il picker viene buildato in-place (mappa satellitare con tutti i PS coloriti per LOS rate, tabella punti a destra, controlli in basso).
6. Workflow nel picker (vedi §3.2):
   - **Pick PS mode** (toggle): OFF per esplorare, ON per click-add.
   - **Add free point**: drawpoint per coordinate libere.
   - **Add manually**: typed.
   - **Remove selected**: cancella riga.
   - **New-point radius (m)**: pre-fill della colonna `radius_m`.
   - **Load CSV / Save CSV**: import/export `aoi_points.csv`.
   - **Run TS export**: invoca `ts_export_batch` → `<workdir>/ts_export/ts_<id>.csv`.

Output finale: una `ts_<id>.csv` per punto, formato `date,disp_mm`, una riga per acquisizione.

---

## 5. Bug R2026a incontrati e workaround

Il refactor è stato bloccato in più punti da quirk specifici di MATLAB R2026a + uifigure + geoaxes. Documento qui per riferimento futuro:

| # | Sintomo | Causa | Workaround |
|---|---|---|---|
| 1 | `ax.LatitudeLimits = ...` errore "is read-only" | Su geoaxes R2026a i property dei limiti sono read-only | Usare `geolimits(ax, latlim, lonlim)` per scrivere; `[lat,lon] = geolimits(ax)` per leggere |
| 2 | `enableDefaultInteractivity(ax)` no-op | La funzione non ripristina il `DefaultGeographicAxesInteractionSet` di geoaxes una volta sovrascritto | Salvare l'handle iniziale di `ax.Interactions` e riassegnarlo direttamente |
| 3 | `ax.Interactions = [zoomInteraction; panInteraction]` non ridà il pan completo | Il `DefaultGeographicAxesInteractionSet` è un singleton composito; sostituirlo con interaction puntuali rompe il pan native di geoaxes | Mantenere il default; per disabilitare solo il datatip durante pick mode, sostituire temporaneamente con `zoomInteraction` (zoom solo) e ripristinare al toggle off |
| 4 | `geoplot` chiamato dopo geoscatter cancella tutti i pallini PS | `geoplot` lavora con `hold off` di default | `hold(ax, 'on')` immediatamente dopo il `geoscatter` iniziale |
| 5 | Aggiungendo un marker `geoplot`, la mappa si rifitta automaticamente | autoscale del nuovo plot estende i limiti | Snapshot `[prev_lat, prev_lon] = geolimits(ax)` prima del `geoplot`, ripristinare con `geolimits(ax, prev_lat, prev_lon)` dopo |
| 6 | I marker rossi aggiunti bloccano il pan quando il drag passa sopra | `HitTest='on'` di default sul `Line` di `geoplot` | Per ogni marker aggiunto: `m.HitTest = 'off'` + `m.PickableParts = 'none'` |
| 7 | Registrare `sc.ButtonDownFcn` su uno scatter (anche con `HitTest='off'`) sopprime permanentemente il pan native del geoaxes | Bug R2026a: la sola presenza di un callback registrato altera il dispatching delle interaction default | Catturare i click via `topfig.WindowButtonDownFcn` (livello figura) invece che sullo scatter; switchare on/off solo dentro il toggle pick mode |
| 8 | `uigridlayout` come parent diretto del geoaxes consuma gli eventi mouse → niente pan | Comportamento di event capture di `uigridlayout` su R2026a | Wrappare il `geoaxes` in un `uipanel` intermedio (`BorderType='none'`) prima di metterlo nella griglia |
| 9 | Tabella `uitable` con colonna `string` non si refresha quando si fa `vertcat` di nuove righe | Bug R2026a su uitable + table type con colonna string | Passare a cell array `cell(N,4)` con `ColumnFormat = {'char','numeric','numeric','numeric'}` |
| 10 | `setvartype(opts,'id','string')` solleva `MATLAB:textio:io:UnknownVarName` se la colonna `id` manca, prima del check `badCsv` | `setvartype` valida prima di tornare control al chiamante | Spostare il check di membership sulle `opts.VariableNames` PRIMA del `setvartype` |
| 11 | Datatip native di geoaxes intercetta il click sui pallini scatter prima del callback custom | Datatip è una sotto-interaction del default geoaxes | Disabilitare la datatip solo durante "pick mode" (sostituendo `ax.Interactions` con `zoomInteraction`); ripristinare al toggle off |

---

## 6. Validazione

### 6.1. Unit test (StaMPS)

`StaMPS/tests/matlab/test_ts_export_batch.m` — `matlab.unittest.TestCase` classdef, 9 metodi `Test`:

| # | Test | Cosa verifica |
|---|---|---|
| 1 | `single_point_in_cluster_writes_csv` | Caso happy-path: 1 punto in un cluster di PS → CSV con N righe (acquisizioni) e valori entro tolleranza fisica |
| 2 | `multiple_points_each_get_their_own_csv` | Loop su CSV multi-punto produce un CSV per id |
| 3 | `per_row_radius_m_overrides_default` | Colonna `radius_m` override il `default_radius` |
| 4 | `point_with_no_ps_in_radius_warns_and_skips` | Punto in mezzo all'oceano → warning `ts_export_batch:noPS` + nessun CSV |
| 5 | `missing_required_column_throws` | CSV senza `lat` → `ts_export_batch:badCsv` |
| 6 | `missing_id_column_throws_friendly_error` | CSV senza `id` → `ts_export_batch:badCsv` (non `UnknownVarName`) |
| 7 | `corrupt_matfile_throws` | Matfile senza `ph_mm` → `ts_export_batch:badMat` |
| 8 | `duplicate_ids_throw` | ID ripetuto nel CSV → `ts_export_batch:duplicateId` |
| 9 | `unsafe_id_chars_are_sanitised` | ID `DAM/LEFT 1` → file `ts_DAM_LEFT_1.csv` |

Lanciabili da CLI:
```bash
matlab -batch "addpath('StaMPS/matlab','StaMPS/matlab_compat'); cd('StaMPS/tests/matlab'); runtests('test_ts_export_batch')"
```

### 6.2. Boot del .mlapp patchato

Test in batch: lanciare `PHASE_StaMPS`, verificare che `app.TabGroup.Children` contiene `TS Points` come ultima tab, che `app.TSPointsTab` è di classe `matlab.ui.container.Tab`, che `app.OpenTSPickerButton` è di classe `matlab.ui.control.Button`. Tutto verificato.

### 6.3. End-to-end manuale

`tools/launch_phase_with_demo_workdir.m` apre `PHASE_StaMPS` pre-configurato sulla tab TS Points con un matfile sintetico in tempdir. Click sul bottone verde → picker embedded nella tab → toggle pick mode → click sui pallini PS → tabella popolata → "Run TS export" → CSV scritti in `<tempdir>/ts_export/`. Pipeline `ginput`-free verificata.

---

## 7. Caveat residui

### 7.1. App Designer divergence (importante)

Il patcher `add_tspoints_tab.py` modifica **solo** `matlab/document.xml`. **NON** tocca `appdesigner/appModel.mat` (il modello visuale interno di App Designer). Conseguenze operative:

- A runtime tutto funziona correttamente (verificato).
- In **App Designer** vedrai la tab "TS Points" + bottone, ma App Designer li tratta come "fuori modello" (warning visivo possibile).
- Se modifichi e **risalvi** il `.mlapp` in App Designer, App Designer potrebbe rigenerare `document.xml` dal proprio `appModel.mat` e **eliminare** le aggiunte della patch.

**Procedure di safety**:

a) Per modifiche successive al `.mlapp` (es. aggiungere altre tab), preferire patcher Python tipo `tools/add_tspoints_tab.py`. Backup: `cp PHASE_StaMPS.mlapp PHASE_StaMPS.mlapp.preEdit` prima di qualsiasi operazione.

b) Se devi assolutamente aprire in App Designer:
   1. backup;
   2. apri, modifica, salva;
   3. verifica con `matlab -batch "app=PHASE_StaMPS; arrayfun(@(c) disp(c.Title), app.TabGroup.Children)"` che TS Points è presente;
   4. se sparita: re-applicare `python tools/add_tspoints_tab.py` (idempotente).

c) Per allineare ufficialmente App Designer al patch: aprire il `.mlapp` post-patch in App Designer, selezionare la tab TS Points + bottone, e ri-salvare. App Designer dovrebbe assorbire i nuovi componenti nel proprio `appModel.mat` (verifica empirica consigliata su un backup).

Un commento `% WARNING: ... patcher ... appModel.mat may strip them ...` è inserito sopra la callback `OpenTSPickerButtonPushed` nel codice patchato per avvisare chi lo legge in App Designer.

### 7.2. value_type bound

Il picker default-carica `ps_plot_ts_v-do.mat`. Per altri value_type (`v`, `v-d`, `v-da`, `v-dao`) passare il terzo argomento: `ts_export_picker(workdir, parent, 'v-d')`. La callback in `PHASE_StaMPS.mlapp` è oggi hardcoded a `'v-do'` (caso più comune); per parametrizzarla via GUI servirebbe un dropdown nella tab TS Points — non implementato per ora.

### 7.3. Mapping Toolbox obbligatorio

Il picker richiede `geoaxes` / `geobasemap` / `geolimits`. Senza Mapping Toolbox, `ts_export_picker` esce subito con `ts_export_picker:noToolbox`. La funzione headless `ts_export_batch` invece **non** richiede Mapping Toolbox e resta utilizzabile via CSV manuale.

### 7.4. Pan disabilitato in pick mode

Per workaround del bug R2026a #11 (datatip eats clicks), in modalità "Pick PS mode ON" il pan via drag è disabilitato (zoom rotellina rimane). L'utente deve toggle off per pannare. Compromesso accettato — alternative future: implementare pan via tasti freccia con `KeyPressFcn`.

---

## 8. File aggiunti / modificati

| File | Operazione | Repo |
|---|---|---|
| `StaMPS/matlab_compat/ts_export_batch.m` | Nuovo (~110 righe + 3 helper) | StaMPS |
| `StaMPS/matlab_compat/ts_export_picker.m` | Nuovo (~390 righe + 4 helper) | StaMPS |
| `StaMPS/tests/matlab/test_ts_export_batch.m` | Nuovo (9 unit test, ~180 righe) | StaMPS |
| `PHASE_Preprocessing/PHASE_StaMPS.mlapp` | Patchato in-place (`document.xml` only): +2 properties, startupFcn esteso, 1 nuova tab + 1 bottone, 1 callback (~25 righe MATLAB aggiunte) | PHASE |
| `tools/add_tspoints_tab.py` | Nuovo — patcher idempotente | PHASE |
| `tools/launch_ts_picker_demo.m` | Nuovo — demo standalone | PHASE |
| `tools/launch_phase_with_demo_workdir.m` | Nuovo — demo full-app | PHASE |
| `docs/TS_export_picker_integration.md` | Questo documento | PHASE |

Pre-esistenti riusati:
- `tools/mlapp_roundtrip.py` (utility di unpack/repack OOXML, già nel repo)
- `StaMPS/matlab/llh2local.m` (conversione metrica usata anche da `ts_plot.m`)
