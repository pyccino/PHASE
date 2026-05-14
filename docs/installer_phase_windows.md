# Installer PHASE per Windows — Documentazione tecnica

**Versione**: 1.9.4.0 (2026-05-12)
**Scope**: Wizard end-to-end (GUI WPF, compilato `.exe`, ~162 KB) che automatizza l'install completo di PHASE su Windows, dalle dipendenze esterne (Python, Git, GMT, SNAP, binari nativi StaMPS) alla pre-configurazione di tutti i path nei `.mlapp` e nei file di config.
**Sorgente**: `installer/install-phase.ps1`
**Compilato**: `installer/install-phase.exe` (PS2EXE `-noConsole`)

---

## 1. TL;DR

L'utente finale, con MATLAB già attivato:

1. Fa doppio click su `install-phase.exe` (singolo file da 162 KB).
2. Conferma 5 path auto-rilevati (MATLAB / SNAP / Python / cartella destinazione).
3. Click "Start installation" → l'installer scarica tutto dall'esterno (Python da python.org, SNAP da ESA, GMT da GitHub, Portable Git da github.com, StaMPS native binaries da GitHub) e configura tutti i path.
4. Apre uno qualsiasi dei 3 `.mlapp` di PHASE: i path d'installazione (StaMPS, Project, Python, GPT) sono già popolati, l'utente compila solo i parametri specifici del dataset (master date, AOI, SAFE files).

Tutte le dipendenze sono **scaricate on-the-fly** dai server ufficiali. Il `.exe` distribuibile non contiene installer o binari di terze parti — è 162 KB di PowerShell-compilato e basta. L'unica pre-condizione **non automatizzabile** è MATLAB pre-installato e attivato (proprietary MathWorks, no silent install + no silent license activation).

---

## 2. Architettura

| Layer | Tecnologia | File |
|---|---|---|
| GUI | WPF inline (XAML) con palette light scientific + monospace accents | `installer/install-phase.ps1` (sezione XAML, ~700 righe) |
| Logica | PowerShell 5.1+ | `installer/install-phase.ps1` (funzioni `Find-*`, `Install-*`, `Invoke-*`, `Update-Task`) |
| Distribuzione | PS2EXE (`-noConsole -STA`) | `installer/install-phase.exe` (~162 KB) |
| Build helper | PS2EXE wrapper | `installer/compile-to-exe.ps1` |
| Doc utente | Markdown | `installer/README.md` |
| Logo bundled | PNG (~545 KB) | `installer/PHASE_logo.png` (sidebar wizard) |

Singolo file `.exe` standalone. Quando lanciato non scrive log temporanei in `prefdir`, non tocca registry di sistema, opera solo in user-scope (registry HKCU per `MATLAB_EXE`, file in `%LOCALAPPDATA%\PHASE\*` per Portable Git e GMT portable, `%APPDATA%\PHASE\python.txt` per il bridge a `mt_prep_snap.bat`).

---

## 3. Wizard a 7 step

| # | Step | Cosa fa |
|---|---|---|
| 1 | Welcome | Logo + intro + lista delle 5 azioni del wizard. |
| 2 | MATLAB | `Find-Matlab` (glob `C:\Program Files\MATLAB\R*\bin\matlab.exe` + registry `HKLM\SOFTWARE\Mathworks\MATLAB\*\MATLABROOT` + PATH). **Toolbox check via filesystem** sotto `<MATLABROOT>\toolbox\map` / `images` / `signal` / `stats` / `parallel` (<100 ms, no MATLAB startup). UI mostra status verde se Mapping + Image Processing presenti, arancione + istruzioni Add-Ons se mancano. Non-bloccante: l'utente prosegue anche se mancano (PHASE_Preprocessing fa il proprio check con uialert). |
| 3 | SNAP | `Find-Snap` con glob su `esa-snap*`, `snap*`, `snap13*` + USERPROFILE + LOCALAPPDATA. Se assente: bottone "Install SNAP now" → **download on-the-fly** di `esa-snap_sentinel_windows-13.0.0.exe` (~1 GB) dal CDN ESA `download.esa.int/step/snap/13.0/installers/` con progress bar live → silent install via install4j `-q -overwrite` con **indeterminate marquee** durante l'esecuzione (install4j silent non emette progress) → re-detect del path d'install effettivo (`C:\Program Files\esa-snap\` per default). Singolo UAC prompt. Se silent fallisce, fallback automatico al wizard interattivo. |
| 4 | Python | `Find-Python` (py launcher `-3.X` per X=20..11 + `python`/`python3` su PATH, esclude `\WindowsApps\` stub Microsoft Store). Se assente: download silent di `python-3.11.9-amd64.exe` da `python.org/ftp/python/3.11.9/`, install per-user (`InstallAllUsers=0 PrependPath=1`, no UAC) + `pip install openpyxl`. |
| 5 | Destination | Default `%USERPROFILE%\Desktop\PHASE`, TextBox + "Browse". Validazione: scrivibile, no caratteri non-ASCII, warning su path OneDrive (non blocca). |
| 6 | Installation | **Task list verticale animata** (sostituisce il vecchio console log dark). 10 task con stato per ciascuno: pending / running / done / skip / error. Status pill colorata + label + monospace duration. Running ha pulse animation (Opacity 1.0↔0.45 forever via DoubleAnimation autoreverse). Detail mono line live sotto il task corrente (es. `downloading from esa 73%`). Counter `N / 10` in alto a destra. Bottom slim progress bar 4 px. |
| 7 | Finish | Bottoni "Open PHASE folder" / "Open install log". Cancel button rinominato "Close". |

Validazione dei campi disabilita "Next" finché il path corrente non è valido. Stato del wizard in `$Script:State` (hashtable `MatlabExe`, `SnapGpt`, `PythonExe`, `PythonVersion`, `InstallDir`, `GitExe`).

---

## 4. Step orchestrati da `Invoke-FullSetup`

Eseguiti in sequenza dopo il click "Start installation". Ognuno è una "task card" nella UI del Step 6:

1. **Verify Git** (`git`). `Find-Git` cerca `git.exe` su PATH + Program Files\Git + LOCALAPPDATA\Programs\Git + `%LOCALAPPDATA%\PHASE\portable-git\bin\`. Se assente, `Install-PortableGit` scarica `PortableGit-2.45.2-64-bit.7z.exe` (~60 MB) da `git-for-windows/git` release `v2.45.2.windows.1`, estrae silent (`-o<dir> -y`, 7-Zip SFX flags) in `%LOCALAPPDATA%\PHASE\portable-git\`. Nessun UAC, nessuna install di sistema. I 3 repo PHASE/StaMPS/TRAIN sono pubblici quindi clone HTTPS è anonimo.

2. **Clone PHASE** (`clone-phase`). `Invoke-GitClone` su `pyccino/PHASE @ main`. Se la cartella esiste già con `.git/`, applica `remote set-url origin <url>` + `reset --hard HEAD` + `fetch origin <branch>` + `checkout -B <branch> FETCH_HEAD`. Più robusto di `pull --ff-only` perché funziona anche su storie divergenti (es. dopo rinome upstream `windows-port/main` → `main`).

3. **Clone StaMPS** (`clone-stamps`). `Tiopio01/StaMPS @ main` (fork con i fix Windows + i 2 file matlab_compat per il TS picker).

4. **Clone TRAIN** (`clone-train`). `Tiopio01/TRAIN @ main` (fork con le 2 patch Windows in `aps_gacos_files.m` e `get_gmt_version.m`).

5. **Build StaMPS auxiliary** (`stamps-build`). `Invoke-StampsInstall` lancia `<StaMPS>\install-windows.ps1` upstream (gestisce Triangle CMake + snaphu — non-bloccante: i 7 `.exe` C++ vengono scaricati separatamente).

6. **Download native StaMPS binaries** (`stamps-bin`). `Invoke-StampsBinariesDownload` scarica `stamps-win64-binaries.zip` (~4 MB) da `Tiopio01/StaMPS:windows-port-bins-v1` ed estrae i 7 `.exe` in `<StaMPS>\bin\`:
   - `calamp.exe` — calibrazione ampiezza inter-date
   - `cpxsum.exe` — somma coerente complessa (multi-look)
   - `pscphase.exe` — fase PSC da interferogrammi
   - `pscdem.exe` — DEM lookup per PSC
   - `psclonlat.exe` — lon/lat lookup per PSC
   - `selpsc_patch.exe` — selezione Persistent Scatterer Candidates su patch
   - `selsbc_patch.exe` — selezione Small Baseline Candidates

   Senza questi `mt_prep_snap` fallisce immediatamente. Idempotente: se i 7 sono già presenti, skip.

7. **Install GMT** (`gmt`). `Install-GmtSilent` scarica `gmt-6.6.0-win64.zip` (~182 MB) da `GenericMappingTools/gmt:6.6.0` ed estrae in `%LOCALAPPDATA%\PHASE\gmt\`. Aggiunge `<gmt>\bin\` al PATH user-scope. Versione portable scelta anziché installer NSIS perché quest'ultimo richiede UAC e mostra dialog `"Failed to add GMT to PATH"` non-sopprimibile da `/S` quando manca admin per `HKLM\PATH`.

8. **Configure environment** (`env`). 3 azioni:
   - `setx MATLAB_EXE "<path>"` (user-scope env var).
   - `%APPDATA%\PHASE\python.txt` con il path al Python interpreter (letto da `StaMPS\bin\mt_prep_snap.bat:27` per bypassare il default `py -3` che fallisce con stub Microsoft Store).
   - `<dest>\PHASE\project.conf.template` con `GPTBIN_PATH` precompilato al `gpt.exe` rilevato.

9. **MATLAB savepath + .mat files** (`matlab`). Singolo invocazione `matlab.exe -batch "run('<script.m>')"` che fa tutto in un colpo:
   - `addpath(genpath('<StaMPS>/matlab')) + matlab_compat + TRAIN/matlab; savepath` → `pathdef.m` permanente per tutte le future session MATLAB.
   - Scrittura `input_StaMPS.mat` (63 variabili con `installation_folder` + `project_path` precompilati ai path dell'installer, altri 61 ai default UI del `.mlapp`).
   - Scrittura `input_preprocessing.mat` (24 variabili SEN-flavor con `python` e `gptbin_path` precompilati).

   Script MATLAB serializzato come file `.m` temporaneo invece di passare statement inline a `-batch` (il `try; ... catch e; ... end;` inline con `;` immediato è invalido per il parser MATLAB). Process I/O via `System.Diagnostics.Process` invece di `Start-Process -Wait` (più affidabile su app GUI come `matlab.exe`).

10. **Patch `.mlapp` files** (`patch`). Per ognuno dei 3 `.mlapp`:
    - Estrae il `.mlapp` (è uno zip OPC) in temp.
    - Modifica `matlab/document.xml` iniettando un blocco MATLAB nell'`startupFcn`.
    - Re-zippa **preservando l'ordine originale delle entry** (cruciale per il parser OPC di MATLAB) e usando `/` come separator interno (default `.NET ZipFile.CreateFromDirectory` usa `\` → MATLAB rifiuta).
    - Scrive `document.xml` in **UTF-8 senza BOM**. Il BOM all'inizio di document.xml fa parsare la classe da App Designer **lasciando tutte le method registrazioni a vuoto** (la classe carica ma `metaclass(app).MethodList` è incompleto, errore runtime "Method 'X' is not defined" su ogni callback). Bug debug-hostile: `clear classes` non lo risolve, serve riavvio completo di MATLAB.

    Patch specifiche per ogni `.mlapp`:
    - **PHASE_StaMPS.mlapp**: insert dopo `cd(currentFolder);` di un blocco che fa `feval(app.LoadButton.ButtonPushedFcn, app.LoadButton, struct())` se `./input_StaMPS.mat` esiste. Il LoadButton popola correttamente tutti i 63 campi senza che l'utente clicchi nulla.
    - **PHASE_Preprocessing.mlapp**: insert dopo `app.CustomPythonEnvironmentEditField_2.Visible = 'off';` (linea 479) di un blocco che (a) attiva `Sentinel1Panel.Visible='on'` + `ConstellationSwitch.Value='Sentinel1'` (fix bug upstream: entrambi i pannelli sono nascosti by default e l'utente deve muovere lo switch per vedere il form), (b) fa load di `./PHASE_Preprocessing/input_preprocessing.mat` e setta direttamente `python_SEN`/`python_CSK`/`gptbin_path_SEN`/`gptbin_path_CSK` + i corrispondenti EditField visibili. Bypassa il `LoadButton` upstream perché questo fallisce silenziosamente su un dropdown set intermedio.
    - **PHASE_model.mlapp**: insert dopo `addpath('./MatlabFunctions/');` di un blocco che setta `app.pythonPath` se `input_model.mat` non esiste. Il `.mlapp` upstream ha già un auto-load completo nello `startupFcn`; la patch aggiunge solo il fallback per il path Python alla prima apertura.

11. **Kill MATLAB pre-patch**. Prima delle patch ai `.mlapp`, l'installer chiude qualunque `matlab.exe` aperto (`Get-Process matlab | Stop-Process -Force`). MATLAB cacha la definizione della classe alla prima apertura; modifiche al file su disco non vengono mai lette finché la session non si chiude.

---

## 5. Auto-detect / auto-install component matrix

| Component | Pre-condizione | Strategia |
|---|---|---|
| MATLAB R2023a+ | obbligatorio (proprietario) | Auto-detect (4 strategie) + manual override + filesystem-based toolbox check (Mapping, Image Processing, Signal Processing, Statistics, Parallel) |
| Python 3.11+ | auto-install | Silent download python.org + InstallAllUsers=0 + pip openpyxl + reject WindowsApps stub |
| SNAP 13.0.0 | auto-install (silent + 1 UAC) | Download on-the-fly da ESA CDN + install4j `-q -overwrite` + indeterminate marquee durante l'install (fallback interattivo se silent fail) |
| GMT 6.6.0 | auto-install (silent) | Zip portable in `%LOCALAPPDATA%\PHASE\gmt\` |
| Git | auto-install (silent) | Portable Git 2.45.2 in `%LOCALAPPDATA%\PHASE\portable-git\` |
| 7 .exe StaMPS nativi | auto-download | Zip release `windows-port-bins-v1` da `Tiopio01/StaMPS` |
| openpyxl | auto-install | `pip install openpyxl` dopo Python silent install |
| ts_export_picker.m, ts_export_batch.m | via clone | `Tiopio01/StaMPS @ main` |

---

## 6. Estetica UI

### Palette light scientific

```
surface     #FCFCFE   window
elevated    #FFFFFF   cards, textboxes
sidebar     #F4F6FB   sidebar tinted off-white
border      #E4E8F0   default hairline
borderHi    #C8D0E0   hover hairline
text        #0F1430   primary ink (deep navy)
text2/3     #4A5168 / #8C95B8
accent      #1A4FE0   primary blue (CTA, focus, current step)
accent2     #D1397E   logo magenta (scatter pattern accents in sidebar)
accentLt    #E8EEFF   hover/selected very light blue
success     #2DBA6E   task done state
warning     #E89C2D   warning panels
error       #E03B5C   task error state
```

### Typography

- Heading: **Segoe UI Variable** (Light/Regular) per leggibilità.
- Body: **Segoe UI Variable** Regular.
- Numerali + breadcrumb + step header + tag + path field labels: **JetBrains Mono → Cascadia Code → Consolas** (fallback chain).

### Componenti chiave

- **Sidebar**: 280 px, gradient `#F4F6FB` off-white tinted, separata dal content da un hairline verticale `#E4E8F0`. Logo PHASE in card bianca con shadow soft. Overlay decorativo Canvas con 7 ellipsi blu/magenta + 8 linee thin connector che mimano la rete di scatter point del logo.
- **Step indicator**: 7 righe verticali con dot (26 px circle), linea hairline `#D6DCE8` di connessione. Done = blu pieno + check Unicode. Current = blu pieno + numero bianco + soft blue glow. Pending = bianco + hairline + numero muted.
- **PrimaryButton (CTA)**: solid `#1A4FE0`, white text, 18 px blue glow. Hover lightens + extends glow. ControlTemplate trigger per hover/pressed/disabled.
- **SecondaryButton**: white background, hairline `#D6DCE8` border. Hover → border + text → primary blue.
- **TextBox**: white surface, hairline border, JetBrains Mono interior, primary-blue caret + selection brush. Focus → border `#1A4FE0`.
- **Card style**: white, hairline border, no shadow, 6 px corner radius.
- **Task list (Step 6)**: 10 righe con 18 px status pill + label + mono detail + mono duration. Pulse animation sul dot del task corrente (Opacity 1.0↔0.45 forever via DoubleAnimation autoreverse 800 ms). Counter "N / 10" + slim 4 px progress bar in fondo.

---

## 7. Distribuzione del pacchetto

Il `.exe` è completamente self-sufficient — tutte le dipendenze sono scaricate al runtime. Distribuzione canonica:

```
phase-installer-v1.9.4/
├── install-phase.exe                          # 162 KB
└── PHASE_logo.png                             # 545 KB
```

(Niente più `installers/` con SNAP bundled da 1 GB. SNAP viene scaricato on-the-fly da `download.esa.int`.)

L'utente scarica lo zip (~700 KB), lo estrae, fa doppio click su `install-phase.exe`. Al primo avvio SmartScreen mostra *"Windows ha protetto il tuo PC"* (`.exe` non firmato): click su *Altre info → Esegui comunque*. Una volta sola per `.exe`-per-utente.

Per firmare digitalmente l'`.exe` ed eliminare il prompt SmartScreen serve un certificato code-signing (~€200/anno commerciale, oppure gratuito per OSS via SignPath — vedi `StaMPS/docs/SIGNPATH_STATUS.md` per il caso d'uso analogo di StaMPS).

---

## 8. Build dell'`.exe` dal sorgente

```powershell
# Una tantum:
Install-Module -Name ps2exe -Scope CurrentUser -Force

# Compila install-phase.ps1 -> install-phase.exe:
powershell -ExecutionPolicy Bypass -File installer\compile-to-exe.ps1
```

`compile-to-exe.ps1` invoca `Invoke-PS2EXE` con flag `-noConsole -STA -title 'PHASE Installer'`. Il sorgente PowerShell è scritto **UTF-8 con BOM** (richiesto da PS 5.1 per riconoscere caratteri non-ASCII tipo apostrofi e accenti italiani — senza BOM PS 5.1 legge il file come Windows-1252 e l'XAML viene corrotto al parse).

---

## 9. Caveat operativi

1. **SmartScreen first-run**: `.exe` non firmato → utente clicca "Altre info → Esegui comunque" la prima volta.
2. **MATLAB activation richiesta**: se MATLAB non è ancora stato aperto/attivato, lo step 9 `MATLAB savepath` fallisce con `LICENSE_NOT_AVAILABLE`. L'installer scrive un warning nel log + istruzioni manuali per `addpath/savepath`, ma non blocca; l'utente attiva MATLAB poi rilancia l'installer.
3. **SNAP semi-interattivo se silent fallisce**: install4j `-q` di solito funziona, ma c'è un fallback automatico al wizard interattivo se per qualunque motivo l'install silent ritorna exit code non-zero (license check, disk space, install4j var senza default, ecc.). L'utente in tal caso vede il wizard SNAP standard e clicca Avanti×3 (~5 minuti).
4. **App Designer cache**: aprire il `.mlapp` con doppio click da Windows Explorer può lanciarlo in App Designer (editor) invece che come app runtime. Se la prima apertura è stata problematica, l'errore "Method 'X' is not defined" persiste finché MATLAB non viene chiuso completamente. Suggerimento: aprire dal Command Window con `cd <path>; PHASE_StaMPS` (senza estensione).
5. **PATH user-scope vs current session**: `setx` aggiorna il registry user ma non `$env:Path` della sessione corrente. L'installer aggiorna ENTRAMBI così MATLAB lanciato dall'installer stesso vede i nuovi path (GMT bin), ma una shell esistente continuerà a usare il vecchio PATH finché non viene riavviata.
6. **OneDrive sync**: install in cartelle sotto OneDrive può causare file lock intermittenti durante i run lunghi (`PermissionError [WinError 32]` da Python, `fopen: Permission denied` dai `.exe` C++). L'installer warning su path che contengono `OneDrive` ma non blocca.
7. **UI freeze su download grossi**: prima del fix v1.9.3.0, il download di SNAP (~1 GB) faceva freezare la UI per minuti perché il loop di `Get-RemoteFile` non chiamava `Application.DoEvents()`. Risolto con buffer 81 KB → 1 MB + DoEvents ogni iterazione + ProgressCallback solo quando la percentuale intera cambia.

---

## 10. Riproducibilità

Versioni precise delle dipendenze fissate:

| Componente | Versione | URL |
|---|---|---|
| Python | 3.11.9 | `https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe` |
| Portable Git | 2.45.2.windows.1 | `https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/PortableGit-2.45.2-64-bit.7z.exe` |
| GMT | 6.6.0 | `https://github.com/GenericMappingTools/gmt/releases/download/6.6.0/gmt-6.6.0-win64.zip` |
| StaMPS binaries | windows-port-bins-v1 | `https://github.com/Tiopio01/StaMPS/releases/download/windows-port-bins-v1/stamps-win64-binaries.zip` |
| SNAP | 13.0.0 | `https://download.esa.int/step/snap/13.0/installers/esa-snap_sentinel_windows-13.0.0.exe` |
| PHASE | pyccino/PHASE @ main | rinominato da `windows-port/main` |
| StaMPS | Tiopio01/StaMPS @ main | rinominato da `windows-port/main` |
| TRAIN | Tiopio01/TRAIN @ main | rinominato da `windows-port/main` |

Re-run dell'installer su una cartella esistente: idempotente. `Invoke-GitClone` aggiorna alla HEAD del branch corrente con `reset --hard + fetch + checkout FETCH_HEAD`; `Invoke-StampsBinariesDownload` skip se i 7 `.exe` ci sono; `Install-PortableGit` / `Install-GmtSilent` / `Install-PythonSilent` skip se rispettivi `*.exe` rilevati; `Invoke-MlappAutoLoadPatch` skip se la stringa `AUTO-LOAD (PHASE installer)` o `AUTO-CONFIG (PHASE installer)` è già nel `document.xml`.

---

## 11. Stato di test verificato

| Verifica | Comando | Esito |
|---|---|---|
| Detection MATLAB | `Find-Matlab` su macchina con MATLAB R2026a installato | ✅ ritorna `C:\Program Files\MATLAB\R2026a\bin\matlab.exe` |
| Detection toolbox MATLAB | `Find-MatlabToolboxes` filesystem-based | ✅ rileva Mapping ✓ Image Processing ✓ Signal ✗ Statistics ✓ Parallel ✓ |
| Detection SNAP | `Find-Snap` con SNAP 13 installato in `esa-snap\` | ✅ ritorna `C:\Program Files\esa-snap\bin\gpt.exe` |
| Detection Python | `Find-Python` con Python 3.11.9 from python.org | ✅ ritorna il path + version `3.11.9`, esclude lo stub WindowsApps |
| Detection git | `Find-Git` con git su PATH | ✅ ritorna il path |
| Portable Git install + clone HTTPS anonimo | Lanciato in dir pulita | ✅ 60.1 MB scaricati, estrazione `-y` exit 0, clone di `Tiopio01/TRAIN.git` 12 file senza credenziali |
| Download 7 .exe StaMPS | Su `<StaMPS>\bin\` vuoto | ✅ ~4 MB scaricati, 7/7 estratti e tutti rispondono con usage string |
| SNAP download da ESA + silent install | Su sistema senza SNAP | ✅ 1 GB scaricato con progress smooth (post fix v1.9.3) + install4j silent + 1 UAC + `gpt.exe` rilevato dopo l'install |
| GMT portable install | Su sistema senza GMT | ✅ ~182 MB scaricati, estratto in `%LOCALAPPDATA%\PHASE\gmt\`, `bin\gmt.exe` presente, PATH user aggiornato, `gmt --version` → 6.6.0 |
| MATLAB savepath + scrittura `input_*.mat` | `Invoke-MatlabSavePath` end-to-end | ✅ exit 0, output `PHASE_INSTALLER_SAVEPATH_OK`, .mat 3984 bytes leggibile + 1544 bytes |
| `.mat` loadabile dall'app | `LoadButtonPushed` simulato post-MATLAB-batch | ✅ 63 + 24 campi caricati senza errori |
| Patch auto-load su 3 .mlapp | Test apertura app post-patch senza click | ✅ tutti i path popolati al primo avvio (47 class methods registrati per PHASE_StaMPS, TabGroupSelectionChanged ✓, OpenTSPickerButtonPushed ✓) |
| Smoke test 7 .exe StaMPS | `<exe>` con stdin vuoto | ✅ tutti rispondono con usage (no DLL missing, no crash) |
| `mt_prep_snap.bat` con dummy args | `mt_prep_snap.bat 99999999 C:\nope 0.4` | ✅ passa il check Python (era il blocker originale dell'altro utente), entra nel modulo Python, fallisce con `No RSC for master 99999999` (atteso) |
| StaMPS MATLAB pipeline funzioni risolte | `which(stamps)`, `which(ps_*)`, `which(setparm)`, ecc. | ✅ tutte le funzioni effettivamente usate da PHASE risolte |
| TRAIN entry points risolti | `which(aps_linear)`, `which(aps_weather_model)`, `which(setparm_aps)` | ✅ 3/3 risolti — `train_available` ritorna 1 → niente warning `TRAIN not found on MATLAB path` |
| TS picker functions risolte | `which(ts_export_picker)`, `which(ts_export_batch)` | ✅ 2/2 risolti |

End-to-end fresh install verificato su Windows 10 con MATLAB R2026a pre-attivato, Python e SNAP completamente assenti pre-test. Tutto il flow ha funzionato dal primo doppio click su `install-phase.exe` al `gpt --help` e `mt_prep_snap.bat` chiamabili dopo install.
