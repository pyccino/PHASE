# Installer PHASE per Windows — Documentazione tecnica

**Data**: 12 maggio 2026
**Scope**: Wizard end-to-end (GUI WPF, compilato `.exe`) che automatizza l'install completo di PHASE su Windows, dalle dipendenze esterne (Python, Git, GMT, SNAP, binari nativi StaMPS) alla pre-configurazione di tutti i path nei `.mlapp` e nei file di config.
**Sorgente**: `installer/install-phase.ps1`
**Compilato**: `installer/install-phase.exe` (~115 KB, PS2EXE `-noConsole`)

---

## 1. TL;DR

L'utente finale dopo aver attivato MATLAB con la sua licenza:

1. Fa doppio click su `install-phase.exe`
2. Conferma 5 path auto-rilevati (MATLAB / SNAP / Python / cartella destinazione)
3. Click "Avvia installazione" → wizard scarica e configura tutto in 10-15 minuti
4. Aprire un qualsiasi dei 3 `.mlapp` di PHASE: i path d'installazione (StaMPS, Project, Python, GPT) sono già popolati, l'utente compila solo i parametri specifici del dataset (master date, AOI, SAFE files)

L'unica pre-condizione **non automatizzabile** è MATLAB pre-installato e attivato (proprietario MathWorks, no silent install + no silent license activation).

---

## 2. Architettura

| Layer | Tecnologia | File |
|---|---|---|
| GUI | WPF inline (XAML) | `installer/install-phase.ps1` (sezione XAML) |
| Logica | PowerShell 5.1+ | `installer/install-phase.ps1` (funzioni `Find-*`, `Install-*`, `Invoke-*`) |
| Distribuzione | PS2EXE (`-noConsole -STA`) | `installer/install-phase.exe` (~115 KB) |
| Build helper | PS2EXE wrapper | `installer/compile-to-exe.ps1` |
| Doc utente | Markdown | `installer/README.md` |

Singolo file `.exe` standalone. Quando lanciato non scrive log temporanei in `prefdir`, non tocca registry di sistema, opera solo in user-scope (registry HKCU per `MATLAB_EXE`, file in `%LOCALAPPDATA%\PHASE\*` per Portable Git e GMT portable).

---

## 3. Wizard a 7 step

| # | Step | Cosa fa |
|---|---|---|
| 1 | Welcome | Logo + descrizione, click Avanti |
| 2 | MATLAB | `Find-Matlab` = glob `C:\Program Files\MATLAB\R*\bin\matlab.exe` → registry `HKLM\SOFTWARE\Mathworks\MATLAB\*\MATLABROOT` → `Get-Command matlab.exe`. Path mostrato in TextBox + "Sfoglia". Validazione: file deve esistere e terminare in `matlab.exe` |
| 3 | SNAP | `Find-Snap` = glob `C:\Program Files\esa-snap*\bin\gpt.exe` + `C:\Program Files\snap*\bin\gpt.exe` + USERPROFILE + LOCALAPPDATA. Se assente: bottone "Installa SNAP ora" che lancia `installers/esa-snap_sentinel_windows-13.0.0.exe` bundled (semi-interattivo, l'utente clicca Avanti×3, ~5 min) |
| 4 | Python | `Find-Python` = `py -3.X` per X=20..11 → `python`/`python3` su PATH esclusi i path che contengono `\WindowsApps\` (stub Microsoft Store). Se assente: download silent di `python-3.11.9-amd64.exe` da `python.org/ftp/python/3.11.9/`, install per-user (`InstallAllUsers=0 PrependPath=1`, no UAC) + `pip install openpyxl` |
| 5 | Cartella | Default `%USERPROFILE%\Desktop\PHASE`, TextBox + "Sfoglia". Validazione: scrivibile, no caratteri non-ASCII, warning su path OneDrive |
| 6 | Setup | Console scrollabile live + progress bar. Click "Avvia installazione" lancia `Invoke-FullSetup` (vedi sezione 4) |
| 7 | Fine | Bottoni "Apri cartella PHASE" / "Apri log" + "Chiudi" |

Validazione dei campi disabilita il bottone "Avanti" finché il path corrente non è valido. Lo stato del wizard è in `$Script:State` (hashtable con `MatlabExe`, `SnapGpt`, `PythonExe`, `PythonVersion`, `InstallDir`, `GitExe`).

---

## 4. Step orchestrati da `Invoke-FullSetup`

Eseguiti in sequenza dopo il click "Avvia installazione":

1. **Verifica git**. `Find-Git` cerca `git.exe` su PATH + Program Files\Git + LOCALAPPDATA\Programs\Git + `%LOCALAPPDATA%\PHASE\portable-git\bin`. Se assente, `Install-PortableGit` scarica `PortableGit-2.45.2-64-bit.7z.exe` (~60 MB) da `git-for-windows/git` release v2.45.2.windows.1, estrae silent (`-o<dir> -y`, 7-Zip SFX flags) in `%LOCALAPPDATA%\PHASE\portable-git\`. Nessun UAC, nessuna install di sistema. I 3 repo PHASE/StaMPS/TRAIN sono pubblici quindi clone HTTPS è anonimo: l'utente può non aver mai usato git in vita sua.

2. **Clone PHASE**. `Invoke-GitClone` su `pyccino/PHASE @ main`. Se la cartella esiste già con `.git/`, applica `remote set-url origin <url>` + `reset --hard HEAD` (scarta modifiche locali tracked tipo patch precedenti dei `.mlapp`) + `fetch origin <branch>` + `checkout -B <branch> FETCH_HEAD`. Più robusto di `pull --ff-only` perché funziona anche su storie divergenti (es. dopo il rinome upstream `windows-port/main` → `main`).

3. **Clone StaMPS**. `Tiopio01/StaMPS @ main` (fork con i fix Windows + il TS picker headless `ts_export_batch.m` / `ts_export_picker.m`). `pyccino/StaMPS` branch corrispondente non ha i `ts_export_*`, quindi clonare il fork è obbligatorio.

4. **Clone TRAIN**. `Tiopio01/TRAIN @ main` (fork con le 2 patch Windows in `aps_gacos_files.m` e `get_gmt_version.m`).

5. **Build/install StaMPS auxiliary**. `Invoke-StampsInstall` lancia `<StaMPS>\install-windows.ps1` ereditato dall'upstream. Questo gestisce Triangle (build da source via CMake) e snaphu (no-op su MSVC, l'eseguibile va recuperato altrove). Non-bloccante: se fallisce, il workflow PSI standard funziona comunque perché i 7 `.exe` C++ vengono scaricati separatamente (step 6).

6. **Download 7 binari nativi StaMPS** (`Invoke-StampsBinariesDownload`). `install-windows.ps1` upstream cerca un asset `stamps-windows-x64-msvc.zip` che NON esiste sul fork `Tiopio01/StaMPS`. Workaround: download diretto di `stamps-win64-binaries.zip` (~4 MB) da `Tiopio01/StaMPS:windows-port-bins-v1` ed estrazione dei 7 `.exe` direttamente in `<StaMPS>\bin\`:
   - `calamp.exe` — calibrazione ampiezza inter-date
   - `cpxsum.exe` — somma coerente complessa (multi-look)
   - `pscphase.exe` — fase PSC da interferogrammi
   - `pscdem.exe` — DEM lookup per PSC
   - `psclonlat.exe` — lon/lat lookup per PSC
   - `selpsc_patch.exe` — selezione Persistent Scatterer Candidates su patch
   - `selsbc_patch.exe` — selezione Small Baseline Candidates

   Senza questi `mt_prep_snap` fallisce immediatamente. Idempotente: se i 7 sono già presenti, skip.

7. **GMT portable** (`Install-GmtSilent`). Necessario per TRAIN `tropo_method='a_gacos'`. Scarica `gmt-6.6.0-win64.zip` (~182 MB) da `GenericMappingTools/gmt:6.6.0` ed estrae in `%LOCALAPPDATA%\PHASE\gmt\`. Aggiunge `<gmt>\bin\` al PATH user-scope tramite `[Environment]::SetEnvironmentVariable('Path', $newPath, 'User')`. **Versione portable scelta** anziché installer NSIS perché:
   - L'installer NSIS richiede UAC per scrivere in Program Files
   - In silent mode mostra comunque dialog "Failed to add GMT to PATH" quando manca admin per `HKLM\PATH` (errore esplicito non sopprimibile da `/S`)
   - I flag silent Inno Setup (`/VERYSILENT /SUPPRESSMSGBOXES`) sono ignorati da NSIS (l'installer GMT è NSIS, non Inno Setup)

8. **Config environment** in 3 punti:
   - `setx MATLAB_EXE "<path>"` (user-scope env var)
   - `%APPDATA%\PHASE\python.txt` con il path al Python interpreter (letto da `StaMPS\bin\mt_prep_snap.bat:27` per bypassare il default `py -3` che fallisce con stub Microsoft Store)
   - `<dest>\PHASE\project.conf.template` con `GPTBIN_PATH` precompilato al `gpt.exe` rilevato

9. **MATLAB savepath + pre-popolamento .mat** (`Invoke-MatlabSavePath`). Singolo invocazione `matlab.exe -batch "run('<script.m>')"` che fa tutto in un colpo:
   - `addpath(genpath('<StaMPS>/matlab')) + matlab_compat + TRAIN/matlab; savepath` → `pathdef.m` permanente per tutte le future session MATLAB
   - Scrittura `input_StaMPS.mat` con le 63 variabili previste dal `SaveButton` del `.mlapp`, con `installation_folder` e `project_path` precompilati ai path dell'installer e gli altri 61 ai default UI del `.mlapp`
   - Scrittura `input_preprocessing.mat` con 24 variabili (SEN-flavor) tra cui `python` e `gptbin_path` precompilati

   Script MATLAB viene scritto come file `.m` temporaneo invece di passare statement inline a `-batch`. Inline su `-batch` produceva `try; ... catch e; ... end;` con `;` immediato dopo `try` → MATLAB lo parsa come "try senza corpo" e fallisce con `statement is incomplete`. Il file `.m` separa gli statement su newline e MATLAB li accetta. Process I/O via `System.Diagnostics.Process` invece di `Start-Process -Wait` (più affidabile su app GUI come `matlab.exe`).

10. **Patch dei `.mlapp` per auto-load** (`Invoke-MlappAutoLoadPatch`). Per ognuno dei 3 `.mlapp`:
    - Estrae il `.mlapp` (è uno zip OPC) in temp
    - Modifica `matlab/document.xml` iniettando un blocco MATLAB nell'`startupFcn`
    - Re-zippa **preservando l'ordine originale delle entry** (cruciale per il parser OPC di MATLAB) e usando `/` come separator interno (default `.NET ZipFile.CreateFromDirectory` usa `\` → MATLAB rifiuta)
    - Scrive `document.xml` in **UTF-8 senza BOM**. Il BOM all'inizio di document.xml fa parsare la classe da App Designer **lasciando tutte le method registrazioni a vuoto** (la classe carica ma `metaclass(app).MethodList` è incompleto, errore runtime "Method 'X' is not defined" su ogni callback). Bug debug-hostile: `clear classes` non lo risolve, serve riapertura completa di MATLAB

    Patch specifiche per ogni `.mlapp`:
    - **PHASE_StaMPS.mlapp**: insert dopo `cd(currentFolder);` di un blocco che fa `feval(app.LoadButton.ButtonPushedFcn, app.LoadButton, struct())` se `./input_StaMPS.mat` esiste. Il LoadButton popola correttamente tutti i 63 campi senza che l'utente clicchi nulla.
    - **PHASE_Preprocessing.mlapp**: insert dopo `app.CustomPythonEnvironmentEditField_2.Visible = 'off';` (linea 479) di un blocco che (a) attiva `Sentinel1Panel.Visible='on'` + `ConstellationSwitch.Value='Sentinel1'` (fix bug upstream: entrambi i pannelli sono nascosti by default e l'utente deve muovere lo switch per vedere il form), (b) fa load di `./PHASE_Preprocessing/input_preprocessing.mat` e setta direttamente `python_SEN`/`python_CSK`/`gptbin_path_SEN`/`gptbin_path_CSK` + i corrispondenti EditField visibili. Bypassa il `LoadButton` upstream perché questo fallisce silenziosamente su un dropdown set intermedio. Anchor diverso dal default `cd(...)` perché 4 righe dopo `cd` lo startupFcn fa `app.CustomPythonEnvironmentEditField.Visible='off';` che sovrascriverebbe il nostro `'on'`.
    - **PHASE_model.mlapp**: insert dopo `addpath('./MatlabFunctions/');` di un blocco che setta `app.pythonPath` se `input_model.mat` non esiste. Il `.mlapp` upstream ha già un auto-load completo nello `startupFcn` (legge `config` da `input_model.mat` se esiste); la nostra patch aggiunge solo il fallback per il path Python alla prima apertura, prima che l'utente abbia mai salvato.

11. **Kill MATLAB pre-patch**. Prima delle patch ai `.mlapp`, l'installer chiude qualunque `matlab.exe` aperto (`Get-Process matlab | Stop-Process -Force`). Necessario perché MATLAB cacha la definizione della classe quando un `.mlapp` viene aperto la prima volta; le successive modifiche al file su disco non vengono mai lette finché la session non si chiude.

---

## 5. Auto-detect / auto-install component matrix

| Component | Pre-condizione | Strategia |
|---|---|---|
| MATLAB R2023a+ | obbligatorio (proprietario) | Auto-detect 4 strategie + manual override |
| Python 3.11+ | auto-install | Silent download python.org + InstallAllUsers=0 + pip openpyxl + reject WindowsApps stub |
| SNAP 13 | auto-install (semi-interattivo) | Installer ESA bundled in distro, Avanti×3 |
| GMT 6.6.0 | auto-install (silent) | Zip portable in `%LOCALAPPDATA%\PHASE\gmt\` |
| Git | auto-install (silent) | PortableGit 2.45.2 in `%LOCALAPPDATA%\PHASE\portable-git\` |
| 7 .exe StaMPS | auto-download | Zip release `windows-port-bins-v1` da `Tiopio01/StaMPS` |
| openpyxl | auto-install | `pip install openpyxl` |
| ts_export_picker.m, ts_export_batch.m | via clone | `Tiopio01/StaMPS @ main` |

---

## 6. Distribuzione del pacchetto

Il `.exe` cerca l'installer SNAP in `.\installers\esa-snap_sentinel_windows-13.0.0.exe` accanto a sé. Pacchetto distribuibile:

```
phase-installer-v1.4.2/
├── install-phase.exe                                       # 115 KB
└── installers/
    └── esa-snap_sentinel_windows-13.0.0.exe               # ~500 MB
```

L'utente scarica lo zip, lo estrae, fa doppio click su `install-phase.exe`. Al primo avvio SmartScreen mostra *"Windows ha protetto il tuo PC"* (`.exe` non firmato): click su *Altre info → Esegui comunque*. Una volta sola per `.exe`-per-utente.

Per firmare digitalmente l'`.exe` ed eliminare il prompt SmartScreen serve un certificato code-signing (~€200/anno commerciale, oppure gratuito per OSS via SignPath — vedi `StaMPS/docs/SIGNPATH_STATUS.md` per il caso d'uso analogo di StaMPS).

---

## 7. Build dell'`.exe` dal sorgente

```powershell
# Una tantum:
Install-Module -Name ps2exe -Scope CurrentUser -Force

# Compila install-phase.ps1 -> install-phase.exe:
powershell -ExecutionPolicy Bypass -File installer\compile-to-exe.ps1
```

`compile-to-exe.ps1` invoca `Invoke-PS2EXE` con flag `-noConsole -STA -title 'PHASE Installer'`. Il sorgente PowerShell è scritto **UTF-8 con BOM** (richiesto da PS 5.1 per riconoscere i caratteri non-ASCII tipo apostrofi e accenti italiani — senza BOM PS 5.1 legge il file come Windows-1252 e l'XAML viene corrotto al parse).

---

## 8. Caveat operativi

1. **SmartScreen first-run**: `.exe` non firmato → utente clicca "Altre info → Esegui comunque" la prima volta.
2. **MATLAB activation richiesta**: se MATLAB non è ancora stato aperto/attivato, lo step 9 `MATLAB savepath` fallisce con `LICENSE_NOT_AVAILABLE`. L'installer scrive un warning nel log + istruzioni manuali per `addpath/savepath`, ma non blocca; l'utente attiva MATLAB poi rilancia l'installer.
3. **SNAP semi-interattivo**: l'installer ESA non ha vero silent mode senza response file pre-generato. ~3 click di Avanti.
4. **App Designer cache**: aprire il `.mlapp` con doppio click da Windows Explorer può lanciarlo in App Designer (editor) invece che come app runtime. Se la prima apertura è stata problematica (BOM-bug pre-fix, classe rotta cachata), l'errore "Method 'X' is not defined" persiste finché MATLAB non viene chiuso completamente. Suggerimento: aprire dal Command Window con `cd <path>; PHASE_StaMPS` (senza estensione).
5. **PATH user-scope vs current session**: `setx` aggiorna il registry user ma non `$env:Path` della sessione corrente. L'installer aggiorna ENTRAMBI così MATLAB lanciato dall'installer stesso vede i nuovi path (GMT bin), ma una shell esistente continuerà a usare il vecchio PATH finché non viene riavviata.
6. **OneDrive sync**: install in cartelle sotto OneDrive può causare file lock intermittenti durante i run lunghi (`PermissionError [WinError 32]` da Python, `fopen: Permission denied` dai `.exe` C++). L'installer warning su path che contengono `OneDrive` ma non blocca.

---

## 9. Riproducibilità

Versioni precise delle dipendenze fissate:

| Componente | Versione | URL |
|---|---|---|
| Python | 3.11.9 | `https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe` |
| Portable Git | 2.45.2.windows.1 | `https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/PortableGit-2.45.2-64-bit.7z.exe` |
| GMT | 6.6.0 | `https://github.com/GenericMappingTools/gmt/releases/download/6.6.0/gmt-6.6.0-win64.zip` |
| StaMPS binaries | windows-port-bins-v1 | `https://github.com/Tiopio01/StaMPS/releases/download/windows-port-bins-v1/stamps-win64-binaries.zip` |
| PHASE | pyccino/PHASE @ main | rinominato da `windows-port/main` |
| StaMPS | Tiopio01/StaMPS @ main | rinominato da `windows-port/main` |
| TRAIN | Tiopio01/TRAIN @ main | rinominato da `windows-port/main` |

Re-run dell'installer su una cartella esistente: idempotente. `Invoke-GitClone` aggiorna alla HEAD del branch corrente; `Invoke-StampsBinariesDownload` skip se i 7 `.exe` ci sono; `Install-PortableGit` / `Install-GmtSilent` / `Install-PythonSilent` skip se rispettivi `*.exe` rilevati; `Invoke-MlappAutoLoadPatch` skip se la stringa `AUTO-LOAD (PHASE installer)` o `AUTO-CONFIG (PHASE installer)` è già nel `document.xml`.

---

## 10. Stato di test verificato

| Verifica | Comando | Esito |
|---|---|---|
| Detection MATLAB | `Find-Matlab` su macchina con MATLAB R2026a installato | ✅ ritorna `C:\Program Files\MATLAB\R2026a\bin\matlab.exe` |
| Detection SNAP | `Find-Snap` con SNAP 13 installato | ✅ ritorna `C:\Program Files\snap13\bin\gpt.exe` |
| Detection Python | `Find-Python` con Python 3.13 from python.org installed | ✅ ritorna il path esatto + version `3.13.9`, esclude lo stub WindowsApps |
| Detection git | `Find-Git` con git su PATH | ✅ ritorna `C:\Program Files\Git\cmd\git.exe` |
| Portable Git install + clone HTTPS anonimo | Lanciato in dir pulita | ✅ 60.1 MB scaricati, estrazione `-y` exit 0, clone di `Tiopio01/TRAIN.git` 12 file senza credenziali |
| Download 7 .exe StaMPS | Su `F:\Games\PHASE\StaMPS` con `bin\` vuoto | ✅ 3.9 MB scaricati, 7/7 estratti |
| MATLAB savepath + scrittura `input_StaMPS.mat` | `Invoke-MatlabSavePath` end-to-end | ✅ exit code 0, output `PHASE_INSTALLER_SAVEPATH_OK`, `.mat` 3984 bytes leggibile |
| `.mat` loadabile dall'app | `LoadButtonPushed` simulato post-MATLAB-batch | ✅ 63 campi caricati senza errori |
| Patch auto-load su 3 .mlapp | Test apertura app post-patch senza click | ✅ tutti i path popolati al primo avvio: StaMPS path + Project + Python + GPT + Sentinel1 panel visibile |
| Install GMT portable | Su macchina senza GMT | ✅ ~182 MB scaricati, estratto in `%LOCALAPPDATA%\PHASE\gmt\`, `bin\gmt.exe` presente, PATH user aggiornato |

End-to-end fresh install non testato (richiede macchina vergine con solo MATLAB attivato). I singoli step sono tutti verificati su `F:\Games\PHASE` partendo da una install pre-esistente nel corso dell'iterazione.
