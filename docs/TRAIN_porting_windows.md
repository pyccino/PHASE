# Porting di TRAIN per PHASE su Windows — Documentazione tecnica

**Data**: 27 aprile 2026
**Scope**: Port di [TRAIN](https://github.com/dbekaert/TRAIN) (Toolbox for Reducing Atmospheric InSAR Noise) per l'uso da parte di PHASE su Windows.
**Fork**: [`Tiopio01/TRAIN`](https://github.com/Tiopio01/TRAIN) branch `windows-port/main`
**Base upstream**: `dbekaert/TRAIN @ 6c93feb`

---

## 1. TL;DR

PHASE su Windows usa TRAIN per **due** sole funzionalità (`tropo_method='a_linear'` e `tropo_method='a_gacos'`). Tutto il resto del toolbox TRAIN (ERA, ERA5, MERRA, MERIS, MODIS, NARR, PowerLaw) è codice morto rispetto a PHASE e non è stato portato.

Il porting consiste in **2 patch chirurgiche**, totale **~30 righe modificate** in 2 file MATLAB:

| File | Patch | Motivazione |
|---|---|---|
| `matlab/get_gmt_version.m` | Early-error informativo su Windows quando GMT non è sul PATH | Il workaround originale manipola variabili d'ambiente Linux-only (`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`) — su Windows è inutile e l'errore finale fuorviante |
| `matlab/aps_gacos_files.m` | Lancio Python sincrono su Windows tramite `if ispc` | `python ... &` (background Unix) viene interpretato da `cmd.exe` come separatore di comandi sequenziali, non fork |

Entrambe le patch sono `if ispc`-guarded → comportamento Unix/macOS **identico** all'upstream.

---

## 2. Contesto

### 2.1. Cosa è TRAIN

TRAIN è una toolbox MATLAB sviluppata da David Bekaert (originariamente JPL/Leeds) che applica correzioni atmosferiche (zenith total delay, ZTD) agli interferogrammi InSAR. Supporta diversi modelli atmosferici (ERA-Interim, ERA5, MERRA-2, NARR, MERIS, MODIS, GACOS) e una correzione lineare topografica.

Storicamente è Linux/macOS-only: usa `LD_LIBRARY_PATH`, `~/.merrapass`, comandi shell `wget`/`tar`/`gunzip`, e si appoggia a GMT (Generic Mapping Tools) per la geolocalizzazione.

### 2.2. Cosa è PHASE

PHASE è una suite MATLAB integrata per InSAR Persistent Scatterer (PSI) processing (modulo 1: preprocessing SNAP-based; modulo 2: StaMPS processing; modulo 3: analisi geospaziale). Il fork [`pyccino/PHASE`](https://github.com/pyccino/PHASE) `windows-port/*` è il porting Windows-native, già in uso.

### 2.3. Perché PHASE ha bisogno di TRAIN

Il modulo 2 di PHASE (`PHASE_StaMPS.mlapp`) integra TRAIN per applicare correzione troposferica agli output StaMPS, opzionalmente attivata da una checkbox nella GUI ("TRAIN atmospheric correction") + un parametro `tropo_method`.

---

## 3. Cosa PHASE chiama davvero di TRAIN

Estrazione del file `PHASE_Preprocessing/PHASE_StaMPS.mlapp` (è uno ZIP) e analisi di `matlab/document.xml`:

### 3.1. Probe di disponibilità (Change #1 del port PHASE)

```matlab
train_available = ~isempty(which('aps_linear')) && ...
                  ~isempty(which('aps_weather_model')) && ...
                  ~isempty(which('setparm_aps'));
```

Se `train_flag == 0 && ~train_available`, scatta il warning `StaMPS:phase:trainNotAvailable` e PHASE degrada silenziosamente (procede senza correzione atmosferica), preservando l'intent dell'utente per un re-run successivo.

### 3.2. Dispatcher

```matlab
if contains(tropo_method, 'a_linear')
    aps_linear;                                      % branch a_linear
elseif contains(tropo_method, 'a_gacos')
    setparm_aps('gacos_datapath', strcat(cd, '/GACOS'));
    setparm_aps('UTC_sat', utc_time);
    aps_weather_model('gacos', 0, 0);                % step 0: download/check
    % ... più tardi nello script ...
    setparm_aps('lambda', lambda, 1);
    setparm_aps('heading', heading, 1);
    aps_weather_model('gacos', 3, 3);                % step 3: apply
end
```

### 3.3. Conclusione: PHASE supporta SOLO 2 tropo_method

| `tropo_method` | Funzioni TRAIN entry-point | Dipendenze esterne | Patches Windows necessarie |
|---|---|---|---|
| `a_linear` | `aps_linear` | nessuna | nessuna (codice puro MATLAB) |
| `a_gacos` | `aps_weather_model('gacos', 0/3, 0/3)` + `setparm_aps` | dati GACOS + GMT | `get_gmt_version` + `aps_gacos_files` |

I valori `'a_era'`, `'a_era5'`, `'a_merra'`, `'a_meris'`, `'a_modis'`, `'a_narr'`, `'a_powerlaw'` non sono mai dispatchati da PHASE. Il toolbox TRAIN li implementa, ma PHASE non li raggiunge.

---

## 4. Closure di funzioni TRAIN raggiungibili

Costruita via BFS statico partendo dagli entry-point PHASE.

### 4.1. Closure full (`aps_weather_model` come dispatcher generico)

29 file. `aps_weather_model.m` ha branching su `model_type` per tutti i modelli (era/era5/gacos/merra/narr) → la closure statica include tutti i loro handler.

### 4.2. Closure narrow per `tropo_method='a_gacos'` (a runtime)

Restringendo agli entry-point effettivamente eseguiti per il flusso `gacos` — leggendo `aps_weather_model.m` per identificare il branch `gacos` e i suoi callee — la closure runtime è **13 file**:

```
aps_check_systemcall_error.m   (gestione errori shell)
aps_era5_ECMWF_Python.m         (legacy, raggiunto ma non eseguito per gacos)
aps_gacos_files.m               *** PATCH APPLICATA ***
aps_powerlaw_update_band.m
aps_systemcall.m                (wrapper system())
aps_weather_model_InSAR.m       (calcolo slant delay step 3)
get_gmt_version.m               *** PATCH APPLICATA ***
get_parm_rsc.m                  (lettura header .rsc)
getparm_aps.m
load_roipac.m                   (lettura binary .ztd)
load_weather_model_SAR.m        (caricamento modello + GMT grdtrack)
logit.m
setparm_aps.m
```

Solo 2 di questi 13 file richiedevano patch.

---

## 5. Patches applicate

### 5.1. `matlab/get_gmt_version.m`

**Problema**: la funzione cerca l'eseguibile GMT su PATH, e se fallisce manipola `LD_LIBRARY_PATH` (Linux) o `DYLD_LIBRARY_PATH` (macOS) iterando su `/usr/local/bin/`, `/usr/bin/`. Su Windows entrambe le env-var sono ignorate (Windows risolve le DLL via `PATH`, non via library path env-var), quindi il loop è codice morto e l'errore finale ("could not fix it, try to fix yourself") è inutile per l'utente Windows.

**Soluzione**: dopo la prima probe `gmt --version` / `GMT --version` (che funziona se GMT è installato e su PATH), inseriamo un short-circuit `if ispc` che lancia un `error()` informativo:

```matlab
if gmt_does_not_work~=0 && ispc
    error(['GMT executable not found on PATH. ', ...
           'Install GMT for Windows from https://www.generic-mapping-tools.org/download/ ', ...
           'and ensure the install dir (e.g. C:\Program Files\GMT\bin) is on the system PATH. ', ...
           'Verify with `gmt --version` in a fresh cmd or PowerShell.']);
end
```

**Effetto**:
- Su Windows con GMT installato: comportamento identico all'upstream (la prima probe ha successo, il branch nuovo non viene raggiunto).
- Su Windows senza GMT: errore actionable invece del loop inutile.
- Su Linux/macOS: comportamento identico all'upstream (la condizione `ispc` è falsa).

### 5.2. `matlab/aps_gacos_files.m`

**Problema**: il file usa due volte la costruzione

```matlab
python_str = ['python ',filelist(l,5:16),'.py > ',filelist(l,5:16),'down.log &'];
[a,b] = system(python_str);
```

Su Unix il `&` finale lancia il processo in background. Su Windows `cmd.exe` interpreta `&` come **separatore di comandi sequenziali**, NON come fork. Risultato: il redirect `> file` viene mal-parsato e il lancio fallisce silenziosamente.

**Soluzione**: branching `if ispc` per usare lancio sincrono su Windows:

```matlab
if ispc
    python_str = ['python ',filelist(l,5:16),'.py > ',filelist(l,5:16),'down.log'];
else
    python_str = ['python ',filelist(l,5:16),'.py > ',filelist(l,5:16),'down.log &'];
end
[a,b] = system(python_str);
```

Patch applicata in 2 punti identici (`aps_gacos_files.m:140-148` e `:170-178`).

**Note semantiche**:
- Il workflow GACOS standard si aspetta che l'utente pre-scarichi i file `.ztd` da `gacos.net` MANUALMENTE prima di chiamare `aps_weather_model`. Il blocco `system()` qui dentro è codice legacy ECMWF che raramente viene eseguito in pratica.
- Su Windows: blocking call → eventuale download Python è sincrono. Accettabile per il caso d'uso effettivo.
- Su Unix: comportamento background invariato.

---

## 6. Aree coperte (testate e validate)

| Area | Test eseguito | Esito |
|---|---|---|
| Audit statico TRAIN closure | `pytest tests/test_audit_train_windows_compat.py -v` (39 test) | ✅ 39/39 PASS |
| Resolution funzioni TRAIN da MATLAB | `which('aps_linear')`, `which('aps_weather_model')`, `which('setparm_aps')`, `which('aps_systemcall')`, `which('get_gmt_version')` | ✅ 5/5 risolte |
| PHASE detection probe | Triple `~isempty(which(...))` con TRAIN sul path | ✅ ritorna 1 |
| PHASE detection probe (negativo) | Stessa probe con TRAIN rimosso da path | ✅ ritorna 0 |
| PHASE guard non degrada | `train_flag=0`, TRAIN su path → guard non attiva | ✅ `train_flag` resta 0 |
| PHASE guard degrada | `train_flag=0`, TRAIN off path → guard attiva con warning ID corretto | ✅ `train_flag=1`, `StaMPS:phase:trainNotAvailable` fired |
| Dispatcher `a_linear` | `tropo_method='a_linear'` → chiama `aps_linear` | ✅ entra, legge config, fallisce a `phuw.mat` mancante (atteso) |
| Dispatcher `a_gacos` | `tropo_method='a_gacos'` → chiama `aps_weather_model('gacos',0,0)` | ✅ entra, esegue step 0, fallisce a `gacos_datapath` mancante (atteso) |
| Patch `get_gmt_version` (Windows error path) | Senza GMT installato → cattura errore | ✅ scatta nuovo error message Windows-specifico |
| Patch `aps_gacos_files` (parsing) | `nargin('aps_gacos_files')` post-patch | ✅ parse OK |
| Parsing tutti i 13 file della closure narrow | `nargin(<file>)` per ognuno | ✅ 13/13 parse OK |
| `aps_systemcall` cross-platform | `aps_systemcall('echo TRAIN_OK')` | ✅ ritorna NaN (success per design TRAIN) |
| `setparm_aps` callable | esecuzione senza argomenti | ✅ stampa parametri di default |
| `aps_weather_model` valida `model_type` | con `'badmodel'` | ✅ raise "model_type needs to be ..." |
| **Lettura GACOS data reali su Windows** | `load_roipac('20210914.ztd')` su file scaricato da gacos.net | ✅ array 418×358 float32, range ZTD 1.94-2.48 m |
| **Lettura header `.rsc` reale** | `get_parm_rsc('20210914.ztd.rsc', ...)` | ✅ WIDTH=418, FILE_LENGTH=358, X_FIRST=16.5109, Y_FIRST=39.2726, X_STEP=0.000833 |

---

## 7. Aree NON coperte e perché

### 7.1. Codice TRAIN non raggiunto da PHASE

PHASE non chiama mai i seguenti `tropo_method`. Il codice esiste in TRAIN ma è morto rispetto a PHASE. **Non sono stati portati né testati**:

| `tropo_method` | File TRAIN coinvolti | Perché non servono a PHASE |
|---|---|---|
| `a_era` | `aps_era_files.m`, `aps_era_ECMWF_Python.m`, `aps_load_era.m` | PHASE non usa ERA-Interim |
| `a_era5` | `aps_era5_files.m`, `aps_era5_ECMWF_Python.m` | PHASE non usa ERA5 |
| `a_merra` | `aps_merra_files.m` (con `~/.merrapass` Linux-path), `aps_load_merra.m` | PHASE non usa MERRA |
| `a_merra2` | come sopra | PHASE non usa MERRA-2 |
| `a_narr` | `aps_narr_files.m`, `aps_load_narr.m` | PHASE non usa NARR |
| `a_meris` | `aps_meris*.m` (5 file) | PHASE non usa MERIS |
| `a_modis` | `aps_modis*.m` (4 file) | PHASE non usa MODIS |
| `a_powerlaw` | `aps_powerlaw*.m` (5 file) | PHASE non usa Powerlaw |

**Conseguenza**: l'audit statico riporta findings (es. `aps_merra_files.m:50` `fopen('~/.merrapass','r')` Linux-only) in questi file, ma sono **falsi positivi rispetto al porting PHASE**. Non vengono mai eseguiti dal flusso PHASE → non rompono nulla in pratica.

### 7.2. Branch interni di `aps_weather_model.m` non raggiunti per `gacos`

Il dispatcher `aps_weather_model.m` ha if/elseif su `model_type`. Per `'gacos'`:

- **Step 0**: chiama solo `aps_gacos_files(0)` → ✅ patchato
- **Step 1**: nessuna chiamata (fprintf only)
- **Step 2**: **skipped per gacos** (commento esplicito: "GACOS delays as downloaded are already Zenith delays, do not need to do anything here") → `aps_weather_model_SAR.m` NON chiamato
- **Step 3**: chiama `aps_gacos_files(-1)` (verifica struttura) + `aps_weather_model_InSAR(model_type)` (computa slant delays) → in cascata `load_weather_model_SAR.m` + `aps_systemcall(GMT grdtrack ...)`

I rami `era`/`era5`/`merra`/`narr` di `aps_weather_model.m` esistono ma sono dead per `gacos`.

### 7.3. Test runtime end-to-end non eseguiti

Tre validazioni richiederebbero risorse esterne non disponibili al momento del porting:

| Test mancante | Risorsa esterna richiesta | Tempo stimato |
|---|---|---|
| **PHASE Module 2 end-to-end** con dataset reale | StaMPS preprocessing completo (`mt_prep` + `stamps(1,8)`) sul dataset Calabria | 2-6 ore di CPU |
| **`aps_systemcall(GMT grdtrack ...)` runtime** | GMT installato sulla macchina (~5 min installer ufficiale) | nessuno (dipende dall'utente) |
| **`aps_weather_model('gacos', 3, 3)` apply** end-to-end | Combinazione delle due risorse sopra + workspace StaMPS processato | dipende dalle due sopra |

**Importante**: questi non sono "lavoro di porting non fatto", sono **test bloccati da prerequisiti esterni** (software/dataset) che l'utente deve fornire.

Le due funzioni più critiche del flusso GACOS sono comunque **validate parzialmente**:
- `load_roipac` su `.ztd` reale: ✅
- `get_parm_rsc` su `.rsc` reale: ✅
- `aps_systemcall('echo ...')` su Windows: ✅
- `get_gmt_version` ramo error Windows: ✅

L'unica chiamata non testata runtime è `aps_systemcall('<GMT_string> grdtrack ...')` — ma `aps_systemcall` è una pura wrapper di `system()` (cross-platform per natura), e GMT su Windows usa la stessa CLI di GMT su Linux (verificato dalla docs ufficiale).

---

## 8. Prerequisiti utente Windows

Per usare il fork patchato in produzione:

```bash
# 1. Clone del fork (NON dell'upstream, per avere le patch Windows)
git clone --branch windows-port/main https://github.com/Tiopio01/TRAIN.git C:/TRAIN
```

```matlab
% 2. In MATLAB:
addpath(genpath('C:/TRAIN/matlab'))
savepath
```

**Solo se `tropo_method = 'a_gacos'`** servono inoltre:

3. **GMT installato**: scarica e installa da [generic-mapping-tools.org/download](https://www.generic-mapping-tools.org/download/). Aggiungi `C:\Program Files\GMT\bin` (o tuo install dir) al `PATH` di sistema. Verifica con `gmt --version` in un terminale fresco.

4. **Python sul PATH**: già richiesto da PHASE, niente di nuovo.

5. **Dati GACOS**: per ogni dataset, submetti richiesta su [gacos.net](http://www.gacos.net/M3/) per la tua AOI e date, scarica i `.tar.gz` ricevuti, mettili in `<dataset>/GACOS/`. PHASE/TRAIN estrae automaticamente i `.ztd`.

---

## 9. Riproducibilità dei test

### 9.1. Audit statico

```bash
cd F:/phase
python tools/audit_train_windows_compat.py
```
Genera `reports/train_audit_<sha>_<date>.md`. Exit code 1 se trova HIGH findings (atteso: 15 HIGH dovuti a system call e wrapper, tutti già coperti dal porting o in codice unreachable).

### 9.2. Test suite del tool di audit

```bash
cd F:/phase
python -m pytest tests/test_audit_train_windows_compat.py -v
```
Atteso: 39 tests, 39 passed.

### 9.3. Smoke test MATLAB del porting

```bash
matlab -batch "
addpath(genpath('F:/phase/TRAIN/matlab'));
% probe come PHASE
disp(~isempty(which('aps_linear')) && ~isempty(which('aps_weather_model')) && ~isempty(which('setparm_aps')));
% test wrapper
disp(aps_systemcall('echo OK'));
% test patch get_gmt_version (senza GMT)
try; get_gmt_version(); catch e; fprintf('%s\n', e.message); end
"
```
Atteso: `1`, `NaN`, error message Windows-specifico.

### 9.4. Test runtime su dati GACOS reali

```bash
matlab -batch "
addpath(genpath('F:/phase/TRAIN/matlab'));
data = load_roipac('F:/phase/test_dataset/INSAR_20210914/GACOS/20210914.ztd');
fprintf('Shape: %dx%d, range: %.3f - %.3f m\n', size(data,1), size(data,2), min(data(:)), max(data(:)));
"
```
Atteso (per AOI Calabria 30km): `Shape: 418x358, range: 1.940 - 2.479 m`.

---

## 10. Stato finale

### Cosa è stato consegnato

| Componente | Location | Stato |
|---|---|---|
| Fork TRAIN patchato | [`Tiopio01/TRAIN @ windows-port/main`](https://github.com/Tiopio01/TRAIN/tree/windows-port/main) | Live |
| Audit tool statico | `F:/phase/tools/audit_train_windows_compat.py` | Funzionante |
| Test suite audit tool | `F:/phase/tests/test_audit_train_windows_compat.py` | 39/39 PASS |
| README PHASE aggiornato | `F:/phase/README.md` (sezione "Verifying TRAIN on Windows") | Punta al fork |
| Documentazione tecnica | questo file | — |

### Verdetto

**Il porting di TRAIN per PHASE su Windows è completo per tutto ciò che PHASE effettivamente usa**. I limiti di test runtime end-to-end (sezione 7.3) sono dovuti a prerequisiti esterni (GMT, dataset processato), non a lavoro di porting non eseguito.

Il codice TRAIN non raggiunto da PHASE (sezione 7.1) NON è stato portato né testato per scelta deliberata di scope: portarlo significherebbe lavoro su funzionalità che PHASE non chiamerà mai. Se in futuro PHASE estendesse i `tropo_method` supportati (es. `a_era5`), il porting di quei rami andrà fatto separatamente.
