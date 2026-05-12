# =============================================================================
# PHASE Windows Installer - wizard end-to-end per il porting Windows di PHASE.
#
# Cosa fa, nell'ordine:
#   1. Welcome (logo + intro).
#   2. Verifica MATLAB (auto-detect + override).
#   3. Verifica SNAP   (auto-detect + override + lancio installer bundled).
#   4. Verifica/installa Python 3.11+ (silent install da python.org se assente).
#   5. Sceglie cartella destinazione (default: Desktop\PHASE).
#   6. Clona pyccino/PHASE, pyccino/StaMPS, Tiopio01/TRAIN.
#   7. Lancia StaMPS\install-windows.ps1 per Triangle/snaphu.
#   8. Configura tutto: MATLAB_EXE, %APPDATA%\PHASE\python.txt, savepath MATLAB.
#
# Usage (sorgente):
#   powershell -ExecutionPolicy Bypass -File install-phase.ps1
#
# Per compilare in .exe distribuibile vedere compile-to-exe.ps1.
# =============================================================================

[CmdletBinding()]
param(
    [string]$DefaultInstallDir = "$env:USERPROFILE\Desktop\PHASE",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
$Script:PhaseRepo  = 'https://github.com/pyccino/PHASE.git'
$Script:PhaseBranch = 'main'   # rinominato da windows-port/main -> main (commit dffa675)
$Script:StampsRepo = 'https://github.com/Tiopio01/StaMPS.git'   # fork con TS picker + GUI fixes
$Script:StampsBranch = 'main'
$Script:TrainRepo  = 'https://github.com/Tiopio01/TRAIN.git'
$Script:TrainBranch = 'main'
$Script:PythonUrl  = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe'
$Script:PythonMinMajor = 3
$Script:PythonMinMinor = 11
$Script:GitPortableUrl = 'https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/PortableGit-2.45.2-64-bit.7z.exe'
$Script:GmtZipUrl = 'https://github.com/GenericMappingTools/gmt/releases/download/6.6.0/gmt-6.6.0-win64.zip'

# Resolve script directory for finding bundled SNAP installer.
# Tre casi:
#   1. Sorgente .ps1 normale          -> $PSScriptRoot
#   2. Sorgente . sourced             -> $MyInvocation.MyCommand.Path
#   3. Compilato in .exe con PS2EXE   -> entrambi sopra sono null, fallback
#      al path del processo corrente.
$Script:ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
$Script:BundledSnapPath = Join-Path $Script:ScriptDir 'installers\esa-snap_sentinel_windows-13.0.0.exe'

# State accumulated across wizard pages
$Script:State = @{
    MatlabExe   = $null
    SnapGpt     = $null
    PythonExe   = $null
    PythonVersion = $null
    InstallDir  = $DefaultInstallDir
    GitExe      = $null
}

# -----------------------------------------------------------------------------
# Detection helpers
# -----------------------------------------------------------------------------

# MATLAB: glob Program Files, registry HKLM Mathworks, PATH lookup.
# Returns absolute path to matlab.exe or $null.
function Find-Matlab {
    if ($env:MATLAB_EXE -and (Test-Path $env:MATLAB_EXE)) {
        return $env:MATLAB_EXE
    }

    $glob = Get-ChildItem -Path 'C:\Program Files\MATLAB\R*\bin\matlab.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($glob) { return $glob.FullName }

    $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Mathworks\MATLAB\*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.MATLABROOT) { Join-Path $_.MATLABROOT 'bin\matlab.exe' }
        } |
        Where-Object { $_ -and (Test-Path $_) } |
        Sort-Object -Descending | Select-Object -First 1
    if ($reg) { return $reg }

    $cmd = Get-Command matlab.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

# Verifica quali toolbox MATLAB sono installate ispezionando le sub-directory
# di <MATLABROOT>\toolbox\. Molto piu' veloce di matlab -batch "v=ver" (<100ms
# vs 30s di startup MATLAB). Affidabile: ogni MathWorks toolbox crea sempre
# la sua sub-folder dedicata con quel nome canonico.
#
# Returns hashtable @{ 'Mapping Toolbox' = $true/$false; ... }.
function Find-MatlabToolboxes {
    param([Parameter(Mandatory)] [string]$MatlabExe)

    # <MATLABROOT> = parent di bin\ = parent di matlab.exe parent
    $matlabRoot = Split-Path -Parent (Split-Path -Parent $MatlabExe)
    $toolboxDir = Join-Path $matlabRoot 'toolbox'

    # Mapping (display name) -> (cartella sotto toolbox\)
    $toolboxFolders = [ordered]@{
        'Mapping Toolbox' = 'map'
        'Image Processing Toolbox' = 'images'
        'Signal Processing Toolbox' = 'signal'
        'Statistics and Machine Learning Toolbox' = 'stats'
        'Parallel Computing Toolbox' = 'parallel'
    }

    $result = [ordered]@{}
    foreach ($displayName in $toolboxFolders.Keys) {
        $folder = $toolboxFolders[$displayName]
        $result[$displayName] = Test-Path -LiteralPath (Join-Path $toolboxDir $folder)
    }
    return $result
}

# Toolbox bloccanti per PHASE - se mancano, non si può fare PSI.
$Script:RequiredToolboxes = @('Mapping Toolbox', 'Image Processing Toolbox')

# SNAP: cerca gpt.exe in tutte le install standard.
# Returns absolute path to gpt.exe or $null.
function Find-Snap {
    $globs = @(
        'C:\Program Files\esa-snap*\bin\gpt.exe',
        'C:\Program Files\snap*\bin\gpt.exe',
        'C:\Program Files (x86)\esa-snap*\bin\gpt.exe',
        "$env:USERPROFILE\esa-snap*\bin\gpt.exe",
        "$env:LOCALAPPDATA\Programs\esa-snap*\bin\gpt.exe"
    )
    foreach ($g in $globs) {
        $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command gpt.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Python 3.11+: prova `py -3.X` per X=20..11 poi `python` su PATH.
# Esclude esplicitamente lo stub Microsoft Store sotto \WindowsApps\.
# Returns @{ Exe = '...'; Version = '3.11.9' } or $null.
function Find-Python {
    $candidates = @()

    # Try py launcher with explicit version pins
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        for ($minor = 20; $minor -ge $Script:PythonMinMinor; $minor--) {
            $candidates += "py -3.$minor"
        }
        $candidates += 'py -3'
    }

    # Fallback to plain python and python3 on PATH
    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notlike '*\WindowsApps\*') {
            $candidates += "`"$($cmd.Source)`""
        }
    }

    foreach ($candidate in $candidates) {
        try {
            $resolved = & cmd /c "$candidate -c `"import sys; print(sys.executable + '|' + '%d.%d.%d' % sys.version_info[:3])`" 2>nul"
            if (-not $resolved) { continue }
            $parts = $resolved.Trim().Split('|')
            if ($parts.Count -ne 2) { continue }
            $exe = $parts[0]
            $ver = $parts[1]
            if ($exe -like '*\WindowsApps\*') { continue }
            $verParts = $ver.Split('.')
            $major = [int]$verParts[0]
            $minor = [int]$verParts[1]
            if ($major -lt $Script:PythonMinMajor) { continue }
            if ($major -eq $Script:PythonMinMajor -and $minor -lt $Script:PythonMinMinor) { continue }
            return @{ Exe = $exe; Version = $ver }
        } catch {
            continue
        }
    }
    return $null
}

function Find-Git {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Common install paths
    foreach ($p in @(
        'C:\Program Files\Git\bin\git.exe',
        'C:\Program Files (x86)\Git\bin\git.exe',
        "$env:LOCALAPPDATA\Programs\Git\bin\git.exe",
        # Portable Git installato dall'installer (se gia' eseguito una volta)
        "$env:LOCALAPPDATA\PHASE\portable-git\bin\git.exe"
    )) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# GMT (Generic Mapping Tools): cerca gmt.exe in Program Files glob + PATH
# + dir portable dell'installer.
# Returns absolute path a gmt.exe oppure $null.
function Find-Gmt {
    # Portable estratto dall'installer (preferito - controllato per primo)
    $portable = Join-Path $env:LOCALAPPDATA 'PHASE\gmt\bin\gmt.exe'
    if (Test-Path $portable) { return $portable }

    $globs = @(
        'C:\Program Files\GMT*\bin\gmt.exe',
        'C:\Program Files (x86)\GMT*\bin\gmt.exe',
        "$env:LOCALAPPDATA\Programs\GMT*\bin\gmt.exe"
    )
    foreach ($g in $globs) {
        $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command gmt.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Scarica e ESTRAE la versione portable di GMT (~182 MB zip, ~700 MB
# estratto). Necessario per TRAIN con tropo_method='a_gacos'.
#
# Strategia ZIP portable (no installer NSIS):
#   - Niente prompt UAC (estrazione in %LOCALAPPDATA%\PHASE\gmt)
#   - Niente dialog "Failed to add to PATH" (l'installer NSIS lo mostra
#     anche in silent mode quando manca admin per HKLM)
#   - Pattern identico a Portable Git
#   - Idempotente (skip se gmt.exe gia' presente)
function Install-GmtSilent {
    param(
        [Parameter(Mandatory)] [scriptblock]$StatusCallback,
        [Parameter(Mandatory)] [scriptblock]$ProgressCallback
    )
    $existing = Find-Gmt
    if ($existing) {
        & $StatusCallback "GMT gia' presente: $existing"
        # Anche se gia' presente, mi assicuro che <bin> sia su PATH user
        $existingBin = Split-Path -Parent $existing
        Add-DirToUserPath -Dir $existingBin -StatusCallback $StatusCallback
        return $existing
    }

    $destDir = Join-Path $env:LOCALAPPDATA 'PHASE\gmt'
    $gmtExe  = Join-Path $destDir 'bin\gmt.exe'

    & $StatusCallback 'Download GMT 6.6.0 portable (~182 MB, puo richiedere 2-5 minuti)...'
    $tmpZip = Join-Path $env:TEMP "gmt-portable_$(Get-Random).zip"
    try {
        Get-RemoteFile -Url $Script:GmtZipUrl -OutFile $tmpZip -ProgressCallback $ProgressCallback | Out-Null
        & $StatusCallback 'Estrazione GMT in corso (~700 MB su disco)...'

        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        # Lo zip GMT ha bin/, share/, lib/ al top-level (niente sub-cartella)
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $destDir)

        if (-not (Test-Path $gmtExe)) {
            throw "Estrazione GMT completata ma gmt.exe non trovato in $gmtExe"
        }

        $gmtBin = Split-Path -Parent $gmtExe
        Add-DirToUserPath -Dir $gmtBin -StatusCallback $StatusCallback
        # Aggiorno anche il PATH della sessione corrente
        $env:Path = "$env:Path;$gmtBin"

        & $StatusCallback "[OK] GMT portable installato: $gmtExe"
        return $gmtExe
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    }
}

# Helper: aggiunge una directory al PATH user-scope se non gia' presente.
# Usato per GMT bin e potenzialmente altre tool che devono essere su PATH.
function Add-DirToUserPath {
    param(
        [Parameter(Mandatory)] [string]$Dir,
        [Parameter(Mandatory)] [scriptblock]$StatusCallback
    )
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -and ($userPath -split ';' | Where-Object { $_ -ieq $Dir })) {
        & $StatusCallback "$Dir gia' su PATH user"
        return
    }
    $newPath = if ($userPath) { "$userPath;$Dir" } else { $Dir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    & $StatusCallback "[OK] $Dir aggiunto al PATH user"
}

# Scarica Portable Git da git-for-windows e lo estrae in una sotto-cartella
# %LOCALAPPDATA%\PHASE\portable-git. NON tocca l'installazione di sistema -
# resta una install isolata usata solo dall'installer e da PHASE.
#
# Il .7z.exe e' self-extracting: lanciato con `-o<dir> -y` estrae silent
# senza UAC ne' prompt (binari Inno Setup-style con flag standard 7-zip SFX).
#
# Non richiede credenziali git (i 3 repo sono pubblici, clone HTTPS anonimo).
function Install-PortableGit {
    param(
        [Parameter(Mandatory)] [scriptblock]$StatusCallback,
        [Parameter(Mandatory)] [scriptblock]$ProgressCallback
    )
    $destDir = Join-Path $env:LOCALAPPDATA 'PHASE\portable-git'
    $gitExe  = Join-Path $destDir 'bin\git.exe'

    if (Test-Path $gitExe) {
        & $StatusCallback "Portable Git gia' presente in $destDir"
        return $gitExe
    }

    & $StatusCallback 'Download Portable Git (~50 MB)...'
    $tmpExe = Join-Path $env:TEMP "PortableGit-installer_$(Get-Random).exe"
    try {
        Get-RemoteFile -Url $Script:GitPortableUrl -OutFile $tmpExe -ProgressCallback $ProgressCallback | Out-Null
        & $StatusCallback 'Estrazione Portable Git in corso...'

        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        # 7-zip SFX flags: -o<dir> directory output, -y assume yes
        # NB: il comando va passato senza spazio tra -o e il path.
        $proc = Start-Process -FilePath $tmpExe `
            -ArgumentList "-o`"$destDir`"", '-y' `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0 -and -not (Test-Path $gitExe)) {
            throw "Estrazione Portable Git fallita (exit $($proc.ExitCode))"
        }

        if (-not (Test-Path $gitExe)) {
            throw "Portable Git estratto ma git.exe non trovato in $gitExe"
        }
        & $StatusCallback "[OK] Portable Git installato in $destDir"
        return $gitExe
    } finally {
        Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------------
# Install / action helpers
# -----------------------------------------------------------------------------

# Download a file with progress to a target. Uses BITS when available (faster),
# falls back to Invoke-WebRequest. Returns the local path.
function Get-RemoteFile {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$OutFile,
        [scriptblock]$ProgressCallback
    )
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Invoke-WebRequest with manual progress (BITS requires admin for some URLs)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'PHASE-Installer/1.0'
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $stream = $resp.GetResponseStream()
    $fileStream = [System.IO.File]::Create($OutFile)
    $buffer = New-Object byte[] 81920
    $read = 0
    $totalRead = 0
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $totalRead += $read
            if ($ProgressCallback -and $total -gt 0) {
                $pct = [Math]::Min(100, [int](($totalRead / $total) * 100))
                & $ProgressCallback $pct
            }
        }
    } finally {
        $fileStream.Close()
        $stream.Close()
        $resp.Close()
    }
    return $OutFile
}

# Silent install of CPython from python.org. Returns the new python.exe path.
function Install-PythonSilent {
    param(
        [Parameter(Mandatory)] [scriptblock]$ProgressCallback,
        [Parameter(Mandatory)] [scriptblock]$StatusCallback
    )
    & $StatusCallback 'Download in corso...'
    $tmp = Join-Path $env:TEMP 'phase-python-installer.exe'
    Get-RemoteFile -Url $Script:PythonUrl -OutFile $tmp -ProgressCallback $ProgressCallback | Out-Null

    & $StatusCallback 'Installazione silenziosa Python 3.11.9...'
    # InstallAllUsers=1 -> sotto Program Files (richiede UAC)
    # InstallAllUsers=0 -> sotto AppData\Local\Programs\Python\Python311 (no UAC)
    # Scegliamo per-user per evitare il prompt UAC dentro al wizard.
    $args = @(
        '/quiet',
        'InstallAllUsers=0',
        'PrependPath=1',
        'Include_test=0',
        'Include_pip=1',
        'Include_launcher=1'
    )
    $proc = Start-Process -FilePath $tmp -ArgumentList $args -Wait -PassThru
    Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        throw "Python installer exited with code $($proc.ExitCode)"
    }

    # Aggiorna PATH della sessione corrente (l'installer lo setta nel registro
    # ma il processo corrente eredita il vecchio PATH)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $env:Path = "$machinePath;$userPath"

    & $StatusCallback 'Detection post-installazione...'
    Start-Sleep -Seconds 2
    $found = Find-Python
    if (-not $found) {
        throw "Python installato ma non rilevato sul PATH dopo l'install. Riavvia il wizard."
    }
    return $found
}

function Install-PythonPackages {
    param(
        [Parameter(Mandatory)] [string]$PythonExe,
        [Parameter(Mandatory)] [scriptblock]$StatusCallback
    )
    & $StatusCallback 'pip install openpyxl...'
    $proc = Start-Process -FilePath $PythonExe -ArgumentList '-m', 'pip', 'install', '--upgrade', 'openpyxl' -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "pip install openpyxl fallito con exit code $($proc.ExitCode)"
    }
}

# Lancia l'installer SNAP bundled. Prova prima la modalita' silent install4j
# (-q -overwrite, default install in C:\Program Files\snap, UAC prompt una
# volta sola). Se il silent fallisce (exit code != 0), fallback al wizard
# interattivo (~5 minuti, Avanti×3).
#
# install4j silent flags utilizzati:
#   -q          quiet/silent install, usa default per ogni var non specificata
#   -overwrite  sovrascrive file esistenti senza prompt
#   -dir        directory di install (omesso: usa il default dello script SNAP)
function Invoke-SnapInstaller {
    param(
        [string]$InstallerPath,
        [scriptblock]$StatusCallback
    )
    if (-not (Test-Path $InstallerPath)) {
        throw "Installer SNAP non trovato in: $InstallerPath"
    }

    $statusCb = if ($StatusCallback) { $StatusCallback } else { { param($m) Write-Host $m } }
    & $statusCb 'SNAP install in modalita silent (~3-5 minuti, UAC richiesto)...'

    # Tentativo 1: silent install
    $proc = Start-Process -FilePath $InstallerPath `
        -ArgumentList '-q', '-overwrite' `
        -Wait -PassThru
    if ($proc.ExitCode -eq 0) {
        & $statusCb 'SNAP install silent completato (exit 0)'
        return 0
    }

    & $statusCb "SNAP silent install ha ritornato exit code $($proc.ExitCode) - rilancio in modalita' interattiva"
    # Tentativo 2: fallback wizard interattivo (Avanti×3 dell'utente)
    $proc = Start-Process -FilePath $InstallerPath -Wait -PassThru
    return $proc.ExitCode
}

# git clone con progress callback (parse output di --progress).
function Invoke-GitClone {
    param(
        [Parameter(Mandatory)] [string]$GitExe,
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$Branch,
        [Parameter(Mandatory)] [string]$Destination,
        [Parameter(Mandatory)] [scriptblock]$StatusCallback
    )
    if (Test-Path (Join-Path $Destination '.git')) {
        # Repo gia' presente: forza l'allineamento al branch corretto del
        # remote configurato. Usato sia per riprese di install interrotte
        # sia per branch rinominati upstream (es. windows-port/main -> main).
        # Strategia:
        #   1. remote set-url origin <Repo>          (gestisce fork swap)
        #   2. reset --hard HEAD                     (scarta modifiche locali
        #                                             tracked - tipicamente
        #                                             le patch .mlapp precedenti)
        #   3. fetch origin <Branch>
        #   4. checkout -B <Branch> FETCH_HEAD       (anche su storia divergente
        #                                             - bypassa il ff-only)
        & $StatusCallback "Repo gia' presente in $Destination - aggiorno a origin/$Branch..."
        $null = Start-Process -FilePath $GitExe -ArgumentList @('-C', $Destination, 'remote', 'set-url', 'origin', $Repo) -Wait -PassThru -NoNewWindow
        $null = Start-Process -FilePath $GitExe -ArgumentList @('-C', $Destination, 'reset', '--hard', 'HEAD') -Wait -PassThru -NoNewWindow
        $pFetch = Start-Process -FilePath $GitExe -ArgumentList @('-C', $Destination, 'fetch', 'origin', $Branch) -Wait -PassThru -NoNewWindow
        if ($pFetch.ExitCode -ne 0) {
            & $StatusCallback "git fetch fallito (exit $($pFetch.ExitCode)) - mantengo lo stato attuale"
            return
        }
        $pCheckout = Start-Process -FilePath $GitExe -ArgumentList @('-C', $Destination, 'checkout', '-B', $Branch, 'FETCH_HEAD') -Wait -PassThru -NoNewWindow
        if ($pCheckout.ExitCode -eq 0) {
            & $StatusCallback "Repo allineato al branch $Branch (HEAD da remote)"
        } else {
            & $StatusCallback "git checkout fallito (exit $($pCheckout.ExitCode))"
        }
        return
    }
    if (Test-Path $Destination) {
        throw "Cartella $Destination esiste ma non e' un repo git. Spostala o cancellala manualmente."
    }

    & $StatusCallback "git clone $Repo (branch $Branch)..."
    $proc = Start-Process -FilePath $GitExe `
        -ArgumentList 'clone', '--branch', $Branch, '--single-branch', $Repo, $Destination `
        -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "git clone $Repo fallito con exit code $($proc.ExitCode)"
    }
}

# Scrive %APPDATA%\PHASE\python.txt con il path al Python interpreter.
# Letto da StaMPS\bin\mt_prep_snap.bat:27 per bypassare la ricerca di `py -3`.
function Set-PhasePythonConfig {
    param([Parameter(Mandatory)] [string]$PythonExe)
    $dir = Join-Path $env:APPDATA 'PHASE'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir 'python.txt'
    Set-Content -Path $file -Value $PythonExe -Encoding ASCII -NoNewline
}

# setx MATLAB_EXE (user scope, persistente).
function Set-MatlabEnvVar {
    param([Parameter(Mandatory)] [string]$MatlabExe)
    [Environment]::SetEnvironmentVariable('MATLAB_EXE', $MatlabExe, 'User')
}

# Lancia MATLAB in batch per:
#   1. addpath + savepath su StaMPS\matlab, StaMPS\matlab_compat e TRAIN\matlab
#   2. (PhaseRoot) generare input_StaMPS.mat precompilato con installation_folder
#      e project_path gia' settati, cosi' l'utente apre il .mlapp e clicca
#      Load senza dover sfogliare i due path manualmente.
# Fallback graceful: se MATLAB rifiuta -batch (vecchie versioni) o se la
# licenza non è ancora attivata, scrive un warning nel log ma non blocca.
function Invoke-MatlabSavePath {
    param(
        [Parameter(Mandatory)] [string]$MatlabExe,
        [Parameter(Mandatory)] [string]$StampsRoot,
        [string]$TrainRoot,
        [string]$PhaseRoot,
        [string]$PythonExe,
        [string]$SnapGpt,
        [Parameter(Mandatory)] [scriptblock]$StatusCallback
    )
    # Costruisco lo script MATLAB come file .m temporaneo. Più affidabile
    # che passare statement inline a -batch (evita escaping di virgolette
    # e apostrofi attraverso PowerShell -> cmd -> matlab.exe).
    $stampsM = $StampsRoot.Replace('\','/')
    $mLines = @(
        "try"
        "    addpath(genpath('$stampsM/matlab'));"
        "    addpath(genpath('$stampsM/matlab_compat'));"
    )
    if ($TrainRoot) {
        $trainM = $TrainRoot.Replace('\','/')
        $mLines += "    addpath(genpath('$trainM/matlab'));"
    }
    $mLines += @(
        "    savepath;"
    )

    # Step 2: scrittura input_StaMPS.mat precompilato (60+ var con i default
    # del .mlapp + i due path dell'installer). Le 60+ variabili sono
    # necessarie perche' StartButtonPushed (document.xml:623) fa load di
    # *tutte* le variabili - se ne manca una, il load esplode.
    if ($PhaseRoot) {
        $phaseM = $PhaseRoot.Replace('\','/')
        $matFile = "$phaseM/PHASE_Preprocessing/input_StaMPS.mat"
        $installFolder = "$phaseM/StaMPS"
        $projectPath = "$phaseM/PHASE_Preprocessing"
        $mLines += @(
            "    stamps_preparation = 0;"
            "    installation_folder = '$installFolder';"
            "    project_path = '$projectPath';"
            "    amplitude_threshold = 0.40;"
            "    master_date = '20200305';"
            "    export_name = 'filename';"
            "    time_span = 0;"
            "    year_0 = 2019;"
            "    month_0 = 7;"
            "    day_0 = 9;"
            "    utc_time = '10:30';"
            "    train_flag = 0;"
            "    stamps_first_step = '1';"
            "    stamps_last_step = '7';"
            "    n_cores = 4;"
            "    heading = 346.18;"
            "    lambda = 0.055465763;"
            "    max_topo_err = 16;"
            "    filter_grid_size = 40;"
            "    filter_weighting = 'P-square';"
            "    gamma_max_iterations = 7;"
            "    gamma_change_convergence = 0.0050;"
            "    gamma_stdev_reject = 0;"
            "    quick_est_gamma_flag = 'y';"
            "    small_baseline_flag = 'n';"
            "    clap_win = 16;"
            "    clap_alpha = 1;"
            "    clap_beta = 0.3000;"
            "    clap_low_pass_wavelength = 800;"
            "    select_method = 'PERCENT';"
            "    percent_rand = 1;"
            "    weed_standard_dev = 1;"
            "    weed_neighbours = 'y';"
            "    weed_zero_elevation = 'n';"
            "    weed_max_noise = Inf;"
            "    merge_resample_size = 0;"
            "    merge_standard_dev = Inf;"
            "    unwrap_grid_size = 20;"
            "    unwrap_gold_n_win = 16;"
            "    unwrap_method = '3D';"
            "    unwrap_gold_alpha = 0.8;"
            "    unwrap_alpha = 8;"
            "    unwrap_spatial_cost_func_flag = 'n';"
            "    unwrap_prefilter_flag = 'y';"
            "    unwrap_patch_phase = 'n';"
            "    unwrap_la_error_flag = 'y';"
            "    unwrap_hold_good_values = 'y';"
            "    subtr_tropo = 'y';"
            "    tropo_method = 'a_linear';"
            "    select_reest_gamma_flag = 'y';"
            "    drop_ifg_index = '[]';"
            "    scla_deramp = 'y';"
            "    scla_method = 'L2';"
            "    scla_drop_index = '[]';"
            "    scn_wavelength = 50;"
            "    scn_kriging_flag = 'n';"
            "    ref_centre_lonlat = [0.0 0.0];"
            "    ref_radius = 0;"
            "    ref_velocity = 0;"
            "    plot_s = 15;"
            "    ref_centre_lonlat_w = [0.0 0.0];"
            "    ref_radius_w = 0;"
            "    ph_output = 'unwrapped';"
            "    save('$matFile', 'stamps_preparation', 'installation_folder', 'project_path', 'amplitude_threshold', 'master_date', 'export_name', 'time_span', 'year_0', 'month_0', 'day_0', 'utc_time', 'train_flag', 'stamps_first_step', 'stamps_last_step', 'n_cores', 'heading', 'lambda', 'max_topo_err', 'filter_grid_size', 'filter_weighting', 'gamma_max_iterations', 'gamma_change_convergence', 'gamma_stdev_reject', 'quick_est_gamma_flag', 'small_baseline_flag', 'clap_win', 'clap_alpha', 'clap_beta', 'clap_low_pass_wavelength', 'select_method', 'percent_rand', 'weed_standard_dev', 'weed_neighbours', 'weed_zero_elevation', 'weed_max_noise', 'merge_resample_size', 'merge_standard_dev', 'unwrap_grid_size', 'unwrap_gold_n_win', 'unwrap_method', 'unwrap_gold_alpha', 'unwrap_alpha', 'unwrap_spatial_cost_func_flag', 'unwrap_prefilter_flag', 'unwrap_patch_phase', 'unwrap_la_error_flag', 'unwrap_hold_good_values', 'subtr_tropo', 'tropo_method', 'select_reest_gamma_flag', 'drop_ifg_index', 'scla_deramp', 'scla_method', 'scla_drop_index', 'scn_wavelength', 'scn_kriging_flag', 'ref_centre_lonlat', 'ref_radius', 'ref_velocity', 'plot_s', 'ref_centre_lonlat_w', 'ref_radius_w', 'ph_output', '-mat');"
        )
    }

    # Step 3: scrittura input_preprocessing.mat precompilato (24 var; configurazione
    # SEN di default - costellazione piu' usata. Le 2 var di installazione sono
    # python (=PythonExe dell'installer) e gptbin_path (=SnapGpt). Le altre 22
    # sono i default UI del .mlapp - l'utente le modifica per ogni dataset.
    # NB: il LoadButton di PHASE_Preprocessing.mlapp legge solo le var presenti,
    # quindi se l'utente cambia a CSK ricarica le 20 var CSK dal save successivo.
    if ($PhaseRoot -and $PythonExe -and $SnapGpt) {
        $phaseM = $PhaseRoot.Replace('\','/')
        $prepMatFile = "$phaseM/PHASE_Preprocessing/input_preprocessing.mat"
        $pyM = $PythonExe.Replace('\','/')
        $gptM = $SnapGpt.Replace('\','/')
        $mLines += @(
            "    constellation = 'SEN';"
            "    python = '$pyM';"
            "    gptbin_path = '$gptM';"
            "    images_download = 1;"
            "    master_date = '20200722';"
            "    auto_master = 1;"
            "    master_processing = 0;"
            "    polarisation = 'VV';"
            "    lon_min = -180.000;"
            "    lat_min = -90.000;"
            "    lon_max = 180.000;"
            "    lat_max = 90.000;"
            "    slaves_removal = 1;"
            "    dem_name = 'SRTM 1Sec HGT';"
            "    dem_file = '';"
            "    dem_name_coreg = 'SRTM 1Sec HGT';"
            "    dem_file_coreg = '';"
            "    dem_resampling = 'NEAREST_NEIGHBOUR';"
            "    first_step = 1;"
            "    coherence_tc = 0;"
            "    epsg_code = 32633;"
            "    cpu = 8;"
            "    cache = '26G';"
            "    save('$prepMatFile', 'constellation', 'python', 'images_download', 'master_date', 'auto_master', 'master_processing', 'polarisation', 'lon_min', 'lat_min', 'lon_max', 'lat_max', 'slaves_removal', 'dem_name', 'dem_file', 'dem_name_coreg', 'dem_file_coreg', 'dem_resampling', 'first_step', 'coherence_tc', 'epsg_code', 'gptbin_path', 'cpu', 'cache', '-mat');"
        )
    }

    $mLines += @(
        "    fprintf('PHASE_INSTALLER_SAVEPATH_OK\n');"
        "catch err"
        "    fprintf('PHASE_INSTALLER_SAVEPATH_ERR: %s\n', err.message);"
        "end"
        "exit;"
    )
    $tmpScript = Join-Path $env:TEMP "phase_savepath_$(Get-Random).m"
    Set-Content -Path $tmpScript -Value ($mLines -join "`r`n") -Encoding ASCII

    & $StatusCallback 'MATLAB savepath + setup input_StaMPS.mat (può richiedere 30-60s)...'

    # Uso System.Diagnostics.Process direttamente. Start-Process con
    # -NoNewWindow + -Wait + -RedirectStandardOutput non funziona affidabile
    # con app GUI come matlab.exe (il process parent puo' exit prima del
    # batch completion).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $MatlabExe
    $psi.Arguments = "-batch ""run('$($tmpScript.Replace('\','/'))')"""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode

    Remove-Item $tmpScript -ErrorAction SilentlyContinue

    $combined = $stdout + "`n" + $stderr
    $success = ($combined -match 'PHASE_INSTALLER_SAVEPATH_OK')
    return @{
        Success = $success
        Output  = $combined.Trim()
        ExitCode = $exitCode
    }
}

# Modifica un .mlapp clonato per aggiungere auto-load nello startupFcn.
# Quando l'utente apre il .mlapp con doppio click, se input_*.mat esiste
# l'app chiama in automatico il callback del LoadButton e tutti i campi
# si popolano (compresi installation_folder e project_path) senza che
# l'utente debba andare al tab Save/Load e cliccare Load.
#
# I .mlapp sono archivi zip con struttura OPC: i path interni usano '/'
# come separator (non '\') e l'ordine delle entry e' significativo. Quindi
# qui re-zippiamo manualmente preservando ordine + separator originale.
function Invoke-MlappAutoLoadPatch {
    param(
        [Parameter(Mandatory)] [string]$MlappPath,
        [string]$MatFileRelative,
        [string]$Anchor = 'cd(currentFolder);',
        [string]$InjectBlock,
        [Parameter(Mandatory)] [scriptblock]$StatusCallback
    )
    if (-not (Test-Path -LiteralPath $MlappPath)) {
        & $StatusCallback "Mlapp non trovato: $MlappPath (skip)"
        return $false
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $extractTmp = Join-Path $env:TEMP "phase_mlapp_patch_$(Get-Random)"
    New-Item -ItemType Directory -Path $extractTmp -Force | Out-Null

    try {
        # Salva ordine originale delle entry (cruciale per OPC/MATLAB)
        $orderedEntries = @()
        $zipRead = [System.IO.Compression.ZipFile]::OpenRead($MlappPath)
        $orderedEntries = $zipRead.Entries | ForEach-Object { $_.FullName }
        $zipRead.Dispose()

        # Estrai tutto in tmp
        [System.IO.Compression.ZipFile]::ExtractToDirectory($MlappPath, $extractTmp)

        # Modifica matlab/document.xml
        $docXml = Join-Path $extractTmp 'matlab\document.xml'
        $content = [System.IO.File]::ReadAllText($docXml, [System.Text.Encoding]::UTF8)

        # Verifica che la patch non sia gia' stata applicata (idempotenza)
        if ($content.Contains('AUTO-LOAD (PHASE installer)')) {
            & $StatusCallback "$([System.IO.Path]::GetFileName($MlappPath)): patch gia' presente, skip"
            return $true
        }

        # Anchor: prima occorrenza della stringa anchor
        $idx = $content.IndexOf($Anchor)
        if ($idx -lt 0) {
            throw "Anchor '$Anchor' non trovato in $docXml"
        }
        $insertPoint = $idx + $Anchor.Length

        # InjectBlock: o quello passato dal chiamante, o il default auto-load
        # standard che chiama LoadButton se il .mat esiste.
        if ($InjectBlock) {
            $blockToInsert = $InjectBlock
        } else {
            $blockToInsert = @"


            % AUTO-LOAD (PHASE installer): applica i default precompilati se il
            % .mat di default esiste. L'utente non deve cliccare manualmente Load.
            try
                if exist('$MatFileRelative', 'file') == 2 && isprop(app, 'LoadButton')
                    feval(app.LoadButton.ButtonPushedFcn, app.LoadButton, struct());
                end
            catch
                % non blocca lo startup se il load fallisce
            end
"@
        }

        $patched = $content.Substring(0, $insertPoint) + $blockToInsert + $content.Substring($insertPoint)
        # CRITICAL: scrivere UTF-8 SENZA BOM. App Designer di MATLAB rifiuta
        # i .mlapp con BOM nel document.xml (la classe viene parsata ma TUTTE
        # le callback risultano "non definite" - bug ostico da diagnosticare).
        # System.Text.Encoding.UTF8 default include BOM; usiamo new($false).
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($docXml, $patched, $utf8NoBom)

        # Re-zippa preservando ordine + separator '/'
        Remove-Item -LiteralPath $MlappPath -Force
        $zip = [System.IO.Compression.ZipFile]::Open($MlappPath, 'Create')
        try {
            foreach ($name in $orderedEntries) {
                $fsPath = Join-Path $extractTmp ($name -replace '/', '\')
                if (-not (Test-Path -LiteralPath $fsPath)) {
                    & $StatusCallback "Warning: entry '$name' missing during repack"
                    continue
                }
                $entry = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
                $stream = $entry.Open()
                $bytes = [System.IO.File]::ReadAllBytes($fsPath)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Close()
            }
        } finally {
            $zip.Dispose()
        }

        & $StatusCallback "$([System.IO.Path]::GetFileName($MlappPath)): auto-load aggiunto (anchor='$MatFileRelative')"
        return $true

    } finally {
        Remove-Item -Recurse -Force $extractTmp -ErrorAction SilentlyContinue
    }
}

# Genera un project.conf template con GPTBIN_PATH e GRAPHSFOLDER preconfigurati.
function Write-ProjectConfTemplate {
    param(
        [Parameter(Mandatory)] [string]$InstallDir,
        [Parameter(Mandatory)] [string]$SnapGpt
    )
    $template = @"
######### CONFIGURATION FILE per snap2stamps + PHASE - generato dall'installer ##########
# Aggiorna PROJECTFOLDER e MASTER per ogni nuovo dataset.

PROJECTFOLDER = $($InstallDir.Replace('\','/'))/PHASE_Preprocessing
GRAPHSFOLDER  = $($InstallDir.Replace('\','/'))/PHASE_Preprocessing/snap2stamps/graphs
GPTBIN_PATH   = $($SnapGpt.Replace('\','/'))

CACHE = 8G
CPU = 4

# Master: path al .dim splittato del master (compilato a runtime dall'app)
MASTER =

# AOI bounding box (richiesto dal pre-cache SRTM 3Sec)
LONMIN = 0.0
LATMIN = 0.0
LONMAX = 0.0
LATMAX = 0.0

SWATHS = IW1,IW2,IW3
POLARISATION = VV

DEMNAME = Copernicus 30m Global DEM
DEMFILE =
DEMRESAMPLING = BICUBIC_INTERPOLATION
"@
    $confPath = Join-Path $InstallDir 'project.conf.template'
    Set-Content -Path $confPath -Value $template -Encoding UTF8
}

# Esegue install-windows.ps1 di StaMPS (Triangle/snaphu build).
function Invoke-StampsInstall {
    param(
        [Parameter(Mandatory)] [string]$StampsRoot,
        [Parameter(Mandatory)] [scriptblock]$StatusCallback
    )
    $installScript = Join-Path $StampsRoot 'install-windows.ps1'
    if (-not (Test-Path $installScript)) {
        & $StatusCallback "install-windows.ps1 non trovato in $StampsRoot, skip."
        return $false
    }
    & $StatusCallback 'StaMPS install-windows.ps1 in corso (build Triangle/snaphu, può richiedere 5-10 minuti)...'
    $logFile = Join-Path $env:TEMP 'phase-stamps-install.log'
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installScript `
        -WorkingDirectory $StampsRoot `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $logFile
    return ($proc.ExitCode -eq 0)
}

# Scarica i 7 .exe di StaMPS dalla release "windows-port-bins-v1" di
# Tiopio01/StaMPS (asset stamps-win64-binaries.zip, ~4 MB compressed).
# Necessari per il workflow PSI (mt_prep_snap, ps_load_initial_gamma).
# Senza, StaMPS non puo' processare nulla (mt_prep fallisce al primo step).
#
# install-windows.ps1 upstream NON li scarica correttamente perche' cerca
# un asset diverso (stamps-windows-x64-msvc.zip) che non esiste su questo fork.
function Invoke-StampsBinariesDownload {
    param(
        [Parameter(Mandatory)] [string]$StampsRoot,
        [Parameter(Mandatory)] [scriptblock]$StatusCallback
    )
    $binDir = Join-Path $StampsRoot 'bin'
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    # Lista dei .exe richiesti per verificare se sono gia' presenti
    $required = @('calamp.exe', 'cpxsum.exe', 'pscphase.exe', 'pscdem.exe',
                  'psclonlat.exe', 'selpsc_patch.exe', 'selsbc_patch.exe')
    $missing = $required | Where-Object { -not (Test-Path (Join-Path $binDir $_)) }
    if ($missing.Count -eq 0) {
        & $StatusCallback "Tutti i 7 .exe StaMPS gia' presenti in $binDir, skip download"
        return $true
    }
    & $StatusCallback "Mancano $($missing.Count)/7 .exe StaMPS, scarico stamps-win64-binaries.zip..."

    $url = 'https://github.com/Tiopio01/StaMPS/releases/download/windows-port-bins-v1/stamps-win64-binaries.zip'
    $tmpZip = Join-Path $env:TEMP "stamps-win64-binaries_$(Get-Random).zip"

    try {
        # Download
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'PHASE-Installer/1.1'
        $resp = $req.GetResponse()
        $total = $resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($tmpZip)
        $buf = New-Object byte[] 81920
        $totalRead = 0
        while (($read = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $read)
            $totalRead += $read
        }
        $out.Close(); $in.Close(); $resp.Close()
        & $StatusCallback "Download completato ($([math]::Round($totalRead/1MB,1)) MB)"

        # Estrai i 7 .exe in $binDir
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.Name -in $required) {
                    $dest = Join-Path $binDir $entry.Name
                    # Sovrascrive (i .exe possono evolvere tra release)
                    if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Force }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest)
                }
            }
        } finally {
            $zip.Dispose()
        }

        # Verifica finale
        $stillMissing = $required | Where-Object { -not (Test-Path (Join-Path $binDir $_)) }
        if ($stillMissing.Count -eq 0) {
            & $StatusCallback "7/7 .exe StaMPS estratti in $binDir"
            return $true
        } else {
            & $StatusCallback "ERRORE: dopo l'estrazione mancano ancora: $($stillMissing -join ', ')"
            return $false
        }
    } catch {
        & $StatusCallback "ERRORE download/estrazione binari StaMPS: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------------
# WPF Wizard
# -----------------------------------------------------------------------------

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PHASE Installer"
        Width="720" Height="640"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#FFF7F7F8">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="MinWidth" Value="100"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="6,0"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Wizard pages: only one Visible at a time -->
        <Grid Grid.Row="0" Margin="32,28,32,12">

            <!-- Page 1: Welcome -->
            <StackPanel x:Name="Page1_Welcome" Visibility="Visible">
                <TextBlock Text="PHASE Windows Installer" FontSize="26" FontWeight="Light" Margin="0,0,0,8"/>
                <TextBlock Text="Installazione end-to-end della suite PHASE (Persistent scatterer Highly Automated Suite for Environmental monitoring) e di tutte le sue dipendenze su Windows."
                           TextWrapping="Wrap" FontSize="13" Foreground="#FF606060" Margin="0,0,0,20"/>
                <Border BorderBrush="#FFE0E0E0" BorderThickness="1" CornerRadius="4" Padding="16" Background="White">
                    <StackPanel>
                        <TextBlock Text="Questo wizard farà:" FontWeight="Semibold" Margin="0,0,0,10"/>
                        <TextBlock Text="1. Verifica MATLAB (deve essere già installato e attivato)" Margin="0,3"/>
                        <TextBlock Text="2. Verifica SNAP 13 (installa quello bundled se assente)" Margin="0,3"/>
                        <TextBlock Text="3. Installa Python 3.11+ silent se assente" Margin="0,3"/>
                        <TextBlock Text="4. Clona PHASE, StaMPS, TRAIN nella cartella scelta" Margin="0,3"/>
                        <TextBlock Text="5. Builda Triangle/snaphu e configura tutti i path" Margin="0,3"/>
                    </StackPanel>
                </Border>
                <TextBlock Text="Tempo stimato: 15-30 minuti (dipende dalla connessione e dall'installer SNAP)."
                           Margin="0,16,0,0" FontStyle="Italic" Foreground="#FF606060"/>
            </StackPanel>

            <!-- Page 2: MATLAB -->
            <StackPanel x:Name="Page2_Matlab" Visibility="Collapsed">
                <TextBlock Text="MATLAB" FontSize="24" FontWeight="Light" Margin="0,0,0,8"/>
                <TextBlock Text="MATLAB è richiesto da PHASE (R2023a o successivo). L'installer non può installarlo automaticamente perché è proprietario - deve essere già installato e attivato sul sistema."
                           TextWrapping="Wrap" FontSize="13" Foreground="#FF606060" Margin="0,0,0,20"/>

                <TextBlock x:Name="MatlabStatus" Text="" FontWeight="Semibold" Margin="0,0,0,8"/>

                <TextBlock Text="Path a matlab.exe:" Margin="0,0,0,4"/>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="MatlabPathBox" Grid.Column="0"/>
                    <Button x:Name="MatlabBrowseBtn" Grid.Column="1" Content="Sfoglia..." Margin="6,0,0,0"/>
                </Grid>

                <TextBlock x:Name="MatlabHint" Text="" TextWrapping="Wrap" Margin="0,12,0,0" Foreground="#FF606060" FontSize="12"/>

                <Border x:Name="MatlabDownloadHint" BorderBrush="#FFE08040" BorderThickness="1" CornerRadius="4"
                        Padding="12" Background="#FFFFF6E8" Margin="0,16,0,0" Visibility="Collapsed">
                    <StackPanel>
                        <TextBlock Text="MATLAB non trovato sul sistema." FontWeight="Semibold" Foreground="#FFA04000"/>
                        <TextBlock Text="Scaricalo e installalo da mathworks.com, poi torna qui e indica il path manualmente."
                                   TextWrapping="Wrap" Margin="0,4,0,8"/>
                        <Button x:Name="OpenMathworksBtn" Content="Apri mathworks.com" HorizontalAlignment="Left"/>
                    </StackPanel>
                </Border>

                <Border x:Name="MatlabToolboxStatus" BorderBrush="#FFE0E0E0" BorderThickness="1" CornerRadius="4"
                        Padding="12" Background="White" Margin="0,16,0,0" Visibility="Collapsed">
                    <StackPanel>
                        <TextBlock x:Name="MatlabToolboxHeader" Text="Toolbox MATLAB" FontWeight="Semibold" Margin="0,0,0,6"/>
                        <TextBlock x:Name="MatlabToolboxList" Text="" TextWrapping="Wrap" FontSize="12"/>
                        <TextBlock x:Name="MatlabToolboxHint" Text="" TextWrapping="Wrap" FontSize="11"
                                   Foreground="#FF606060" Margin="0,8,0,0" Visibility="Collapsed"/>
                    </StackPanel>
                </Border>
            </StackPanel>

            <!-- Page 3: SNAP -->
            <StackPanel x:Name="Page3_Snap" Visibility="Collapsed">
                <TextBlock Text="SNAP" FontSize="24" FontWeight="Light" Margin="0,0,0,8"/>
                <TextBlock Text="SNAP (Sentinel Application Platform di ESA) è richiesto per il preprocessing degli SLC. Versione 13.x raccomandata."
                           TextWrapping="Wrap" FontSize="13" Foreground="#FF606060" Margin="0,0,0,20"/>

                <TextBlock x:Name="SnapStatus" Text="" FontWeight="Semibold" Margin="0,0,0,8"/>

                <TextBlock Text="Path a gpt.exe:" Margin="0,0,0,4"/>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="SnapPathBox" Grid.Column="0"/>
                    <Button x:Name="SnapBrowseBtn" Grid.Column="1" Content="Sfoglia..." Margin="6,0,0,0"/>
                </Grid>

                <Border x:Name="SnapInstallHint" BorderBrush="#FFE08040" BorderThickness="1" CornerRadius="4"
                        Padding="12" Background="#FFFFF6E8" Margin="0,16,0,0" Visibility="Collapsed">
                    <StackPanel>
                        <TextBlock Text="SNAP non trovato sul sistema." FontWeight="Semibold" Foreground="#FFA04000"/>
                        <TextBlock x:Name="SnapInstallText" Text="" TextWrapping="Wrap" Margin="0,4,0,8"/>
                        <Button x:Name="InstallSnapBtn" Content="Installa SNAP ora" HorizontalAlignment="Left"/>
                    </StackPanel>
                </Border>

                <TextBlock x:Name="SnapHint" Text="" TextWrapping="Wrap" Margin="0,12,0,0" Foreground="#FF606060" FontSize="12"/>
            </StackPanel>

            <!-- Page 4: Python -->
            <StackPanel x:Name="Page4_Python" Visibility="Collapsed">
                <TextBlock Text="Python" FontSize="24" FontWeight="Light" Margin="0,0,0,8"/>
                <TextBlock Text="PHASE richiede Python 3.11 o successivo, con la libreria openpyxl. L'installer può scaricarlo e installarlo automaticamente."
                           TextWrapping="Wrap" FontSize="13" Foreground="#FF606060" Margin="0,0,0,20"/>

                <TextBlock x:Name="PythonStatus" Text="" FontWeight="Semibold" Margin="0,0,0,12"/>
                <TextBlock x:Name="PythonPath" Text="" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,12"/>

                <Border x:Name="PythonInstallPanel" BorderBrush="#FFE08040" BorderThickness="1" CornerRadius="4"
                        Padding="12" Background="#FFFFF6E8" Margin="0,8,0,0" Visibility="Collapsed">
                    <StackPanel>
                        <TextBlock Text="Python 3.11+ non rilevato (o trovato solo lo stub Microsoft Store)." FontWeight="Semibold" Foreground="#FFA04000"/>
                        <TextBlock Text="Verrà scaricato da python.org e installato silenziosamente per l'utente corrente (~28 MB)."
                                   TextWrapping="Wrap" Margin="0,4,0,8"/>
                        <Button x:Name="InstallPythonBtn" Content="Installa Python 3.11.9 ora" HorizontalAlignment="Left"/>
                        <ProgressBar x:Name="PythonProgress" Height="16" Margin="0,12,0,4" Visibility="Collapsed" Maximum="100"/>
                        <TextBlock x:Name="PythonProgressText" Text="" FontSize="11" Foreground="#FF606060" Visibility="Collapsed"/>
                    </StackPanel>
                </Border>
            </StackPanel>

            <!-- Page 5: Destination folder -->
            <StackPanel x:Name="Page5_Dest" Visibility="Collapsed">
                <TextBlock Text="Cartella di destinazione" FontSize="24" FontWeight="Light" Margin="0,0,0,8"/>
                <TextBlock Text="Scegli dove installare PHASE. Verranno create 3 sotto-cartelle: PHASE\, StaMPS\, TRAIN\."
                           TextWrapping="Wrap" FontSize="13" Foreground="#FF606060" Margin="0,0,0,20"/>

                <TextBlock Text="Cartella:" Margin="0,0,0,4"/>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="DestPathBox" Grid.Column="0"/>
                    <Button x:Name="DestBrowseBtn" Grid.Column="1" Content="Sfoglia..." Margin="6,0,0,0"/>
                </Grid>

                <TextBlock x:Name="DestHint" Text="" TextWrapping="Wrap" Margin="0,12,0,0" Foreground="#FF606060" FontSize="12"/>

                <Border BorderBrush="#FFE0E0E0" BorderThickness="1" CornerRadius="4"
                        Padding="12" Background="White" Margin="0,16,0,0">
                    <StackPanel>
                        <TextBlock Text="Suggerimenti:" FontWeight="Semibold" Margin="0,0,0,6"/>
                        <TextBlock Text="• Path corti (vicini al root del drive) evitano problemi con MAX_PATH=260 nei PATCH_N/ di StaMPS." Margin="0,2"/>
                        <TextBlock Text="• Evita cartelle sotto OneDrive (file lock intermittenti durante i run lunghi)." Margin="0,2"/>
                        <TextBlock Text="• Solo caratteri ASCII (no accenti, spazi OK)." Margin="0,2"/>
                    </StackPanel>
                </Border>
            </StackPanel>

            <!-- Page 6: Clone & Setup -->
            <StackPanel x:Name="Page6_Setup" Visibility="Collapsed">
                <Grid Margin="0,0,0,12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                        <TextBlock Text="Installazione" FontSize="24" FontWeight="Light" Margin="0,0,0,4"/>
                        <TextBlock x:Name="SetupSubtitle" Text="Pronto a procedere. Premi 'Avvia' per iniziare."
                                   TextWrapping="Wrap" FontSize="13" Foreground="#FF606060"/>
                    </StackPanel>
                    <Button x:Name="StartSetupBtn" Grid.Column="1" Content="Avvia installazione"
                            VerticalAlignment="Center" Padding="20,10" FontWeight="Semibold"/>
                </Grid>

                <ScrollViewer x:Name="SetupLogScroll" Height="320" BorderBrush="#FFE0E0E0" BorderThickness="1"
                              Background="#FF1E1E1E" VerticalScrollBarVisibility="Auto">
                    <TextBlock x:Name="SetupLog" FontFamily="Consolas" FontSize="11" Foreground="#FFE0E0E0"
                               Padding="10" TextWrapping="Wrap"/>
                </ScrollViewer>

                <ProgressBar x:Name="SetupProgress" Height="20" Margin="0,12,0,0" Maximum="100"/>
                <TextBlock x:Name="SetupProgressText" Text="" Margin="0,4,0,0" Foreground="#FF606060" FontSize="12"/>
            </StackPanel>

            <!-- Page 7: Finish -->
            <StackPanel x:Name="Page7_Finish" Visibility="Collapsed">
                <TextBlock Text="Installazione completata" FontSize="24" FontWeight="Light" Foreground="#FF008000" Margin="0,0,0,8"/>
                <TextBlock x:Name="FinishSubtitle" Text="PHASE è pronto. Apri la cartella e fai doppio click su uno dei tre .mlapp."
                           TextWrapping="Wrap" FontSize="13" Foreground="#FF606060" Margin="0,0,0,20"/>

                <Border BorderBrush="#FFE0E0E0" BorderThickness="1" CornerRadius="4"
                        Padding="16" Background="White">
                    <StackPanel>
                        <TextBlock Text="Cartella PHASE:" FontWeight="Semibold"/>
                        <TextBlock x:Name="FinishPath" Text="" FontFamily="Consolas" FontSize="12" Margin="0,4,0,12"/>
                        <TextBlock Text="App MATLAB disponibili:" FontWeight="Semibold" Margin="0,8,0,4"/>
                        <TextBlock Text="• PHASE_Preprocessing.mlapp - modulo 1 (preprocessing SNAP)" Margin="0,2"/>
                        <TextBlock Text="• PHASE_Preprocessing\PHASE_StaMPS.mlapp - modulo 2 (PSI StaMPS)" Margin="0,2"/>
                        <TextBlock Text="• PHASE_model.mlapp - modulo 3 (analisi geospaziale)" Margin="0,2"/>
                    </StackPanel>
                </Border>

                <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
                    <Button x:Name="OpenFolderBtn" Content="Apri cartella PHASE"/>
                    <Button x:Name="OpenLogBtn" Content="Apri log installazione"/>
                </StackPanel>
            </StackPanel>

        </Grid>

        <!-- Footer with Back/Next/Cancel -->
        <Grid Grid.Row="1" Background="#FFEDEDED">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="StepLabel" Grid.Column="0" Margin="32,16,0,16"
                       VerticalAlignment="Center" Foreground="#FF606060" FontSize="12"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,12,32,12">
                <Button x:Name="BackBtn" Content="Indietro"/>
                <Button x:Name="NextBtn" Content="Avanti"/>
                <Button x:Name="CancelBtn" Content="Annulla"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

# -----------------------------------------------------------------------------
# Parse XAML and wire up event handlers
# -----------------------------------------------------------------------------

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Helper: find named element
function Get-Element { param([string]$Name) $window.FindName($Name) }

# Element references
$pages = @{
    1 = Get-Element 'Page1_Welcome'
    2 = Get-Element 'Page2_Matlab'
    3 = Get-Element 'Page3_Snap'
    4 = Get-Element 'Page4_Python'
    5 = Get-Element 'Page5_Dest'
    6 = Get-Element 'Page6_Setup'
    7 = Get-Element 'Page7_Finish'
}
$labels = @{
    1 = 'Step 1 di 7 - Welcome'
    2 = 'Step 2 di 7 - MATLAB'
    3 = 'Step 3 di 7 - SNAP'
    4 = 'Step 4 di 7 - Python'
    5 = 'Step 5 di 7 - Cartella destinazione'
    6 = 'Step 6 di 7 - Installazione'
    7 = 'Step 7 di 7 - Fine'
}

$Script:CurrentPage = 1
$Script:SetupLogPath = Join-Path $env:TEMP "phase-installer-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Show-Page {
    param([int]$N)
    foreach ($k in $pages.Keys) {
        $pages[$k].Visibility = if ($k -eq $N) { 'Visible' } else { 'Collapsed' }
    }
    (Get-Element 'StepLabel').Text = $labels[$N]
    (Get-Element 'BackBtn').IsEnabled = ($N -gt 1 -and $N -lt 7)
    (Get-Element 'NextBtn').IsEnabled = ($N -lt 6)
    (Get-Element 'NextBtn').Content = if ($N -eq 5) { 'Procedi' } else { 'Avanti' }
    if ($N -eq 7) {
        (Get-Element 'NextBtn').Visibility = 'Collapsed'
        (Get-Element 'CancelBtn').Content = 'Chiudi'
    }
    $Script:CurrentPage = $N

    # Page-specific initialization
    switch ($N) {
        2 { Initialize-MatlabPage }
        3 { Initialize-SnapPage }
        4 { Initialize-PythonPage }
        5 { Initialize-DestPage }
        6 { Initialize-SetupPage }
        7 { Initialize-FinishPage }
    }
}

function Initialize-MatlabPage {
    $found = Find-Matlab
    if ($found) {
        (Get-Element 'MatlabStatus').Text = "[OK] MATLAB rilevato automaticamente."
        (Get-Element 'MatlabStatus').Foreground = '#FF008000'
        (Get-Element 'MatlabPathBox').Text = $found
        (Get-Element 'MatlabDownloadHint').Visibility = 'Collapsed'
        (Get-Element 'MatlabHint').Text = "Path rilevato automaticamente. Puoi modificarlo se vuoi puntare a una versione diversa."
        Update-MatlabToolboxStatus -MatlabExe $found
    } else {
        (Get-Element 'MatlabStatus').Text = "[X] MATLAB non trovato sul sistema."
        (Get-Element 'MatlabStatus').Foreground = '#FFA04000'
        (Get-Element 'MatlabPathBox').Text = ''
        (Get-Element 'MatlabDownloadHint').Visibility = 'Visible'
        (Get-Element 'MatlabHint').Text = "Inserisci il path completo a matlab.exe (es. C:\Program Files\MATLAB\R2025a\bin\matlab.exe)."
        (Get-Element 'MatlabToolboxStatus').Visibility = 'Collapsed'
    }
    Update-MatlabValidation
}

# Aggiorna il pannello "Toolbox MATLAB" della Page 2 con detection via
# filesystem (<MATLABROOT>\toolbox\<name>\). Non-bloccante: mostra solo
# lo stato, l'utente prosegue comunque.
function Update-MatlabToolboxStatus {
    param([string]$MatlabExe)
    if (-not $MatlabExe -or -not (Test-Path $MatlabExe)) {
        (Get-Element 'MatlabToolboxStatus').Visibility = 'Collapsed'
        return
    }
    try {
        $toolboxes = Find-MatlabToolboxes -MatlabExe $MatlabExe
    } catch {
        (Get-Element 'MatlabToolboxStatus').Visibility = 'Collapsed'
        return
    }

    # Costruisco la lista visibile + flag se qualcosa di richiesto manca
    $lines = @()
    $missingRequired = @()
    foreach ($name in $toolboxes.Keys) {
        $installed = $toolboxes[$name]
        $isRequired = $Script:RequiredToolboxes -contains $name
        $marker = if ($installed) { '[OK]' } else { if ($isRequired) { '[X]' } else { '[ ]' } }
        $tag = if ($isRequired) { ' (richiesta)' } else { ' (opzionale)' }
        $lines += "$marker $name$tag"
        if (-not $installed -and $isRequired) { $missingRequired += $name }
    }

    (Get-Element 'MatlabToolboxList').Text = ($lines -join "`n")

    if ($missingRequired.Count -eq 0) {
        (Get-Element 'MatlabToolboxHeader').Text = "Toolbox MATLAB - tutte le richieste presenti"
        (Get-Element 'MatlabToolboxHeader').Foreground = '#FF008000'
        (Get-Element 'MatlabToolboxHint').Visibility = 'Collapsed'
    } else {
        (Get-Element 'MatlabToolboxHeader').Text = "Toolbox MATLAB - $($missingRequired.Count) richiesta/e mancanti"
        (Get-Element 'MatlabToolboxHeader').Foreground = '#FFA04000'
        (Get-Element 'MatlabToolboxHint').Visibility = 'Visible'
        (Get-Element 'MatlabToolboxHint').Text = "Per installare le toolbox mancanti: apri MATLAB -> Home -> Add-Ons -> Get Add-Ons -> cerca il nome -> Install. Sei gia' loggato in MATLAB, nessuna credenziale extra richiesta. Puoi proseguire l'installer adesso e fare l'aggiunta toolbox in un secondo momento."
    }
    (Get-Element 'MatlabToolboxStatus').Visibility = 'Visible'
}

function Update-MatlabValidation {
    $path = (Get-Element 'MatlabPathBox').Text
    $valid = ($path -and (Test-Path $path) -and ($path -like '*matlab.exe'))
    (Get-Element 'NextBtn').IsEnabled = $valid
    if ($valid) {
        $Script:State.MatlabExe = $path
        Update-MatlabToolboxStatus -MatlabExe $path
    } else {
        (Get-Element 'MatlabToolboxStatus').Visibility = 'Collapsed'
    }
}

function Initialize-SnapPage {
    $found = Find-Snap
    if ($found) {
        (Get-Element 'SnapStatus').Text = "[OK] SNAP rilevato automaticamente."
        (Get-Element 'SnapStatus').Foreground = '#FF008000'
        (Get-Element 'SnapPathBox').Text = $found
        (Get-Element 'SnapInstallHint').Visibility = 'Collapsed'
        (Get-Element 'SnapHint').Text = "Path rilevato automaticamente. Modificalo per puntare a una install diversa."
    } else {
        (Get-Element 'SnapStatus').Text = "[X] SNAP non trovato sul sistema."
        (Get-Element 'SnapStatus').Foreground = '#FFA04000'
        (Get-Element 'SnapPathBox').Text = ''
        $hint = if (Test-Path $Script:BundledSnapPath) {
            "L'installer SNAP 13.0.0 e' bundled in questa distribuzione (~1 GB). Cliccando 'Installa SNAP ora' parte in modalita' silent (no Avanti×N): richiede solo il prompt UAC, ~3-5 minuti totali. Se il silent fallisce, fallback automatico al wizard interattivo."
        } else {
            "L'installer SNAP non e' bundled. Scaricalo da step.esa.int/main/download/snap-download/ e indicane il gpt.exe qui sopra."
        }
        (Get-Element 'SnapInstallText').Text = $hint
        (Get-Element 'SnapInstallHint').Visibility = 'Visible'
        (Get-Element 'InstallSnapBtn').IsEnabled = (Test-Path $Script:BundledSnapPath)
    }
    Update-SnapValidation
}

function Update-SnapValidation {
    $path = (Get-Element 'SnapPathBox').Text
    $valid = ($path -and (Test-Path $path) -and ($path -like '*gpt.exe'))
    (Get-Element 'NextBtn').IsEnabled = $valid
    if ($valid) { $Script:State.SnapGpt = $path }
}

function Initialize-PythonPage {
    $found = Find-Python
    if ($found) {
        (Get-Element 'PythonStatus').Text = "[OK] Python $($found.Version) rilevato."
        (Get-Element 'PythonStatus').Foreground = '#FF008000'
        (Get-Element 'PythonPath').Text = $found.Exe
        (Get-Element 'PythonInstallPanel').Visibility = 'Collapsed'
        $Script:State.PythonExe = $found.Exe
        $Script:State.PythonVersion = $found.Version
        (Get-Element 'NextBtn').IsEnabled = $true
    } else {
        (Get-Element 'PythonStatus').Text = "[X] Python 3.11+ non rilevato."
        (Get-Element 'PythonStatus').Foreground = '#FFA04000'
        (Get-Element 'PythonPath').Text = ''
        (Get-Element 'PythonInstallPanel').Visibility = 'Visible'
        (Get-Element 'NextBtn').IsEnabled = $false
    }
}

function Initialize-DestPage {
    if (-not (Get-Element 'DestPathBox').Text) {
        (Get-Element 'DestPathBox').Text = $Script:State.InstallDir
    }
    Update-DestValidation
}

function Update-DestValidation {
    $path = (Get-Element 'DestPathBox').Text
    $valid = $false
    $hint = ''
    if (-not $path) {
        $hint = 'Specifica una cartella di destinazione.'
    } elseif ($path -match '[^\x00-\x7F]') {
        $hint = 'Caratteri non-ASCII rilevati. Usa una cartella con solo caratteri ASCII.'
    } elseif ($path -like '*OneDrive*') {
        $hint = '[!] Path sotto OneDrive: rischio di file lock durante i run lunghi. Consigliato cambiare.'
        $valid = $true   # warning, non blocco
    } else {
        $parent = Split-Path -Parent $path
        if (-not $parent -or (Test-Path $parent)) {
            $valid = $true
            $hint = if (Test-Path $path) { "La cartella esiste già: se contiene già PHASE l'installer la riusa, altrimenti ci scriverà dentro." } else { "La cartella verrà creata." }
        } else {
            $hint = "La cartella padre $parent non esiste."
        }
    }
    (Get-Element 'DestHint').Text = $hint
    (Get-Element 'NextBtn').IsEnabled = $valid
    if ($valid) { $Script:State.InstallDir = $path }
}

function Initialize-SetupPage {
    (Get-Element 'SetupLog').Text = ''
    (Get-Element 'SetupProgress').Value = 0
    (Get-Element 'SetupProgressText').Text = ''
    (Get-Element 'BackBtn').IsEnabled = $false
    (Get-Element 'NextBtn').IsEnabled = $false
    (Get-Element 'StartSetupBtn').IsEnabled = $true
}

function Initialize-FinishPage {
    (Get-Element 'FinishPath').Text = $Script:State.InstallDir
    (Get-Element 'BackBtn').IsEnabled = $false
    # Riabilita Chiudi: era stato disabilitato dal click di StartSetupBtn
    # per evitare cancellazioni durante l'install. In pagina 7 di Fine
    # l'utente DEVE poter chiudere il wizard.
    (Get-Element 'CancelBtn').IsEnabled = $true
    (Get-Element 'CancelBtn').Content = 'Chiudi'
}

function Add-SetupLog {
    param([string]$Message, [string]$Color = '#FFE0E0E0')
    $log = Get-Element 'SetupLog'
    $stamp = (Get-Date -Format 'HH:mm:ss')
    $line = "[$stamp] $Message`n"
    $log.Text += $line
    Add-Content -Path $Script:SetupLogPath -Value "[$stamp] $Message"
    $scroll = Get-Element 'SetupLogScroll'
    $scroll.ScrollToEnd()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-SetupProgress {
    param([int]$Percent, [string]$Text)
    (Get-Element 'SetupProgress').Value = $Percent
    if ($Text) { (Get-Element 'SetupProgressText').Text = $Text }
    [System.Windows.Forms.Application]::DoEvents()
}

# Wire up events
(Get-Element 'NextBtn').Add_Click({
    Show-Page ($Script:CurrentPage + 1)
})

(Get-Element 'BackBtn').Add_Click({
    Show-Page ($Script:CurrentPage - 1)
})

(Get-Element 'CancelBtn').Add_Click({
    $window.Close()
})

(Get-Element 'MatlabBrowseBtn').Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'matlab.exe|matlab.exe'
    $dlg.Title = 'Seleziona matlab.exe'
    if ($dlg.ShowDialog() -eq 'OK') {
        (Get-Element 'MatlabPathBox').Text = $dlg.FileName
    }
})

(Get-Element 'MatlabPathBox').Add_TextChanged({ Update-MatlabValidation })

(Get-Element 'OpenMathworksBtn').Add_Click({
    Start-Process 'https://www.mathworks.com/downloads/'
})

(Get-Element 'SnapBrowseBtn').Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'gpt.exe|gpt.exe'
    $dlg.Title = 'Seleziona gpt.exe (in SNAP\bin\)'
    if ($dlg.ShowDialog() -eq 'OK') {
        (Get-Element 'SnapPathBox').Text = $dlg.FileName
    }
})

(Get-Element 'SnapPathBox').Add_TextChanged({ Update-SnapValidation })

(Get-Element 'InstallSnapBtn').Add_Click({
    (Get-Element 'InstallSnapBtn').IsEnabled = $false
    (Get-Element 'InstallSnapBtn').Content = 'Installazione silent in corso (~3-5 min)...'
    try {
        Invoke-SnapInstaller -InstallerPath $Script:BundledSnapPath `
            -StatusCallback { param($m) (Get-Element 'InstallSnapBtn').Content = $m } | Out-Null
        Start-Sleep -Seconds 2
        $found = Find-Snap
        if ($found) {
            (Get-Element 'SnapPathBox').Text = $found
            (Get-Element 'SnapStatus').Text = "[OK] SNAP installato correttamente."
            (Get-Element 'SnapStatus').Foreground = '#FF008000'
            (Get-Element 'SnapInstallHint').Visibility = 'Collapsed'
        } else {
            (Get-Element 'InstallSnapBtn').Content = 'Riprova rilevamento'
            (Get-Element 'InstallSnapBtn').IsEnabled = $true
            [System.Windows.MessageBox]::Show('SNAP installato ma gpt.exe non rilevato. Indica il path manualmente con Sfoglia.', 'Rilevamento SNAP', 'OK', 'Warning') | Out-Null
        }
    } catch {
        [System.Windows.MessageBox]::Show("Errore durante l'install di SNAP:`n$($_.Exception.Message)", 'Errore', 'OK', 'Error') | Out-Null
        (Get-Element 'InstallSnapBtn').Content = 'Installa SNAP ora'
        (Get-Element 'InstallSnapBtn').IsEnabled = $true
    }
})

(Get-Element 'InstallPythonBtn').Add_Click({
    (Get-Element 'InstallPythonBtn').IsEnabled = $false
    (Get-Element 'PythonProgress').Visibility = 'Visible'
    (Get-Element 'PythonProgressText').Visibility = 'Visible'
    try {
        $statusCb = {
            param($msg)
            (Get-Element 'PythonProgressText').Text = $msg
            [System.Windows.Forms.Application]::DoEvents()
        }
        $progressCb = {
            param($pct)
            (Get-Element 'PythonProgress').Value = $pct
            [System.Windows.Forms.Application]::DoEvents()
        }
        $result = Install-PythonSilent -ProgressCallback $progressCb -StatusCallback $statusCb
        Install-PythonPackages -PythonExe $result.Exe -StatusCallback $statusCb
        $Script:State.PythonExe = $result.Exe
        $Script:State.PythonVersion = $result.Version
        (Get-Element 'PythonStatus').Text = "[OK] Python $($result.Version) installato."
        (Get-Element 'PythonStatus').Foreground = '#FF008000'
        (Get-Element 'PythonPath').Text = $result.Exe
        (Get-Element 'PythonInstallPanel').Visibility = 'Collapsed'
        (Get-Element 'NextBtn').IsEnabled = $true
    } catch {
        [System.Windows.MessageBox]::Show("Errore durante l'install di Python:`n$($_.Exception.Message)", 'Errore', 'OK', 'Error') | Out-Null
        (Get-Element 'InstallPythonBtn').IsEnabled = $true
    }
})

(Get-Element 'DestBrowseBtn').Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Cartella di destinazione per PHASE'
    $dlg.SelectedPath = (Get-Element 'DestPathBox').Text
    if ($dlg.ShowDialog() -eq 'OK') {
        (Get-Element 'DestPathBox').Text = $dlg.SelectedPath
    }
})

(Get-Element 'DestPathBox').Add_TextChanged({ Update-DestValidation })

(Get-Element 'StartSetupBtn').Add_Click({
    (Get-Element 'StartSetupBtn').IsEnabled = $false
    (Get-Element 'CancelBtn').IsEnabled = $false
    try {
        Invoke-FullSetup
        Show-Page 7
    } catch {
        Add-SetupLog "ERRORE FATALE: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("Installazione fallita:`n$($_.Exception.Message)`n`nLog: $Script:SetupLogPath", 'Errore', 'OK', 'Error') | Out-Null
        (Get-Element 'CancelBtn').IsEnabled = $true
    }
})

(Get-Element 'OpenFolderBtn').Add_Click({
    Start-Process explorer.exe -ArgumentList $Script:State.InstallDir
})

(Get-Element 'OpenLogBtn').Add_Click({
    Start-Process notepad.exe -ArgumentList $Script:SetupLogPath
})

# -----------------------------------------------------------------------------
# Main setup orchestration (runs in Page 6 when StartSetupBtn is clicked)
# -----------------------------------------------------------------------------

function Invoke-FullSetup {
    Add-SetupLog "=== PHASE Installer ==="
    Add-SetupLog "Log file: $Script:SetupLogPath"
    Add-SetupLog "MATLAB:  $($Script:State.MatlabExe)"
    Add-SetupLog "SNAP:    $($Script:State.SnapGpt)"
    Add-SetupLog "Python:  $($Script:State.PythonExe) ($($Script:State.PythonVersion))"
    Add-SetupLog "Dest:    $($Script:State.InstallDir)"
    Add-SetupLog ""

    # Step 1: ensure git is available. Se assente, scarica Portable Git in
    # %LOCALAPPDATA%\PHASE\portable-git (no UAC, no install di sistema, no
    # credenziali richieste - i 3 repo sono pubblici, clone HTTPS anonimo).
    Set-SetupProgress 5 'Verifica git...'
    $git = Find-Git
    if (-not $git) {
        Add-SetupLog "git non trovato sul sistema. Scarico Portable Git..."
        try {
            $git = Install-PortableGit `
                -StatusCallback { param($m) Add-SetupLog $m } `
                -ProgressCallback { param($pct) Set-SetupProgress $pct "Download Portable Git $pct%" }
        } catch {
            throw "Impossibile installare Portable Git: $($_.Exception.Message). Installa manualmente da git-scm.com/download/win e rilancia l'installer."
        }
    }
    $Script:State.GitExe = $git
    Add-SetupLog "[OK] git: $git"

    # Step 2: ensure destination exists
    if (-not (Test-Path $Script:State.InstallDir)) {
        New-Item -ItemType Directory -Path $Script:State.InstallDir -Force | Out-Null
        Add-SetupLog "[OK] Creata $($Script:State.InstallDir)"
    }

    # Step 3: clone PHASE
    Set-SetupProgress 15 'Clone PHASE...'
    $phaseDir = Join-Path $Script:State.InstallDir 'PHASE'
    Invoke-GitClone -GitExe $git -Repo $Script:PhaseRepo -Branch $Script:PhaseBranch `
        -Destination $phaseDir -StatusCallback { param($m) Add-SetupLog $m }
    Add-SetupLog "[OK] PHASE clonato in $phaseDir"

    # Step 4: clone StaMPS
    Set-SetupProgress 35 'Clone StaMPS...'
    $stampsDir = Join-Path $phaseDir 'StaMPS'
    Invoke-GitClone -GitExe $git -Repo $Script:StampsRepo -Branch $Script:StampsBranch `
        -Destination $stampsDir -StatusCallback { param($m) Add-SetupLog $m }
    Add-SetupLog "[OK] StaMPS clonato in $stampsDir"

    # Step 5: clone TRAIN
    Set-SetupProgress 50 'Clone TRAIN...'
    $trainDir = Join-Path $phaseDir 'TRAIN'
    Invoke-GitClone -GitExe $git -Repo $Script:TrainRepo -Branch $Script:TrainBranch `
        -Destination $trainDir -StatusCallback { param($m) Add-SetupLog $m }
    Add-SetupLog "[OK] TRAIN clonato in $trainDir"

    # Step 6: StaMPS install (Triangle/snaphu)
    Set-SetupProgress 65 'Build StaMPS (Triangle/snaphu)...'
    $stampsOk = Invoke-StampsInstall -StampsRoot $stampsDir -StatusCallback { param($m) Add-SetupLog $m }
    if ($stampsOk) {
        Add-SetupLog "[OK] StaMPS install-windows.ps1 completato"
    } else {
        Add-SetupLog "[!] StaMPS install-windows.ps1 fallito o non disponibile (Triangle/snaphu da sorgente)."
    }

    # Download diretto dei 7 .exe StaMPS (necessari per il workflow PSI).
    # Indipendente da install-windows.ps1 perche' questo cerca un asset
    # con nome sbagliato per il fork Tiopio01.
    Set-SetupProgress 75 'Download binari nativi StaMPS (calamp, pscphase, ...)...'
    $binOk = Invoke-StampsBinariesDownload -StampsRoot $stampsDir -StatusCallback { param($m) Add-SetupLog $m }
    if ($binOk) {
        Add-SetupLog "[OK] 7 binari StaMPS pronti in $stampsDir\bin"
    } else {
        Add-SetupLog "[!] Download binari StaMPS fallito - mt_prep_snap non funzionera' senza di essi."
    }

    # GMT (Generic Mapping Tools): necessario per TRAIN tropo_method='a_gacos'.
    # Portable zip estratto in %LOCALAPPDATA%\PHASE\gmt - no UAC, no dialog.
    Set-SetupProgress 78 'Verifica/install GMT portable (Generic Mapping Tools)...'
    try {
        $gmtPath = Install-GmtSilent `
            -StatusCallback { param($m) Add-SetupLog $m } `
            -ProgressCallback { param($pct) Set-SetupProgress $pct "Download GMT $pct%" }
        Add-SetupLog "[OK] GMT pronto: $gmtPath"
    } catch {
        Add-SetupLog "[!] Install GMT fallito: $($_.Exception.Message). Necessario solo per tropo_method=a_gacos, gli altri workflow funzionano comunque."
    }

    # Step 7: configure environment
    Set-SetupProgress 80 'Configurazione ambiente...'
    Set-MatlabEnvVar -MatlabExe $Script:State.MatlabExe
    Add-SetupLog "[OK] MATLAB_EXE settato (user env var)"

    Set-PhasePythonConfig -PythonExe $Script:State.PythonExe
    Add-SetupLog "[OK] %APPDATA%\PHASE\python.txt scritto"

    Write-ProjectConfTemplate -InstallDir $phaseDir -SnapGpt $Script:State.SnapGpt
    Add-SetupLog "[OK] project.conf.template scritto in $phaseDir"

    # Step 8: MATLAB savepath + scrittura input_StaMPS.mat precompilato
    Set-SetupProgress 90 'MATLAB addpath/savepath + setup input_StaMPS.mat...'
    $savepathResult = Invoke-MatlabSavePath -MatlabExe $Script:State.MatlabExe `
        -StampsRoot $stampsDir -TrainRoot $trainDir -PhaseRoot $phaseDir `
        -PythonExe $Script:State.PythonExe -SnapGpt $Script:State.SnapGpt `
        -StatusCallback { param($m) Add-SetupLog $m }
    if ($savepathResult.Success) {
        Add-SetupLog "[OK] MATLAB savepath OK (StaMPS + TRAIN aggiunti permanentemente)"
        Add-SetupLog "[OK] input_StaMPS.mat precompilato (installation_folder + project_path)"
        Add-SetupLog "[OK] input_preprocessing.mat precompilato (python + gptbin_path)"
    } else {
        Add-SetupLog "[!] MATLAB savepath non confermato (exit code $($savepathResult.ExitCode))."
        if ($savepathResult.Output) {
            Add-SetupLog "Output MATLAB:"
            foreach ($line in ($savepathResult.Output -split "`n")) {
                if ($line.Trim()) { Add-SetupLog "    $line" }
            }
        }
        Add-SetupLog ""
        Add-SetupLog "Apri MATLAB e lancia manualmente questi comandi:"
        Add-SetupLog "    addpath(genpath('$($stampsDir.Replace('\','/'))/matlab')); savepath"
        if ($trainDir) {
            Add-SetupLog "    addpath(genpath('$($trainDir.Replace('\','/'))/matlab')); savepath"
        }
    }

    # Step 9: patch dei .mlapp per auto-load (cosi' l'utente apre il .mlapp
    # con doppio click e i campi sono gia' popolati senza dover cliccare Load).
    # Prima killa ogni MATLAB aperto: se una classe rotta era stata cachata
    # prima della patch, MATLAB la conserva fino al successivo riavvio.
    Set-SetupProgress 95 'Patch .mlapp per auto-load...'
    Get-Process matlab -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | Stop-Process -Force; Add-SetupLog "MATLAB chiuso (PID $($_.Id)) per evitare cache stale" } catch {}
    }
    Start-Sleep -Seconds 2
    $stampsMlapp = Join-Path $phaseDir 'PHASE_Preprocessing\PHASE_StaMPS.mlapp'
    [void](Invoke-MlappAutoLoadPatch -MlappPath $stampsMlapp `
        -MatFileRelative './input_StaMPS.mat' `
        -StatusCallback { param($m) Add-SetupLog $m })

    # PHASE_Preprocessing.mlapp: fixa 2 problemi all'avvio dell'app:
    #   1. Entrambi i pannelli (Sentinel1 + CosmoSkyMed) sono invisibili by
    #      default - l'utente deve muovere lo switch per vedere qualcosa.
    #      Fix: attiviamo Sentinel1 (default sensato).
    #   2. Solo i 2 path di INSTALLAZIONE (Python + GPT) vanno precompilati;
    #      gli altri 21 campi sono dataset-specifici. Anziche' chiamare il
    #      LoadButton (che fallisce silenziosamente su un campo intermedio),
    #      settiamo direttamente python_SEN/gptbin_path_SEN dal .mat se esiste.
    $prepInject = @"


            % AUTO-CONFIG (PHASE installer): default pannello SEN + path Python/GPT
            try
                % 1. Default Sentinel1 panel visibile
                if isprop(app, 'ConstellationSwitch') && isvalid(app.ConstellationSwitch)
                    app.ConstellationSwitch.Value = 'Sentinel1';
                end
                if isprop(app, 'Sentinel1Panel') && isvalid(app.Sentinel1Panel)
                    app.Sentinel1Panel.Visible = 'on';
                end
                if isprop(app, 'CosmoSkyMedPanel') && isvalid(app.CosmoSkyMedPanel)
                    app.CosmoSkyMedPanel.Visible = 'off';
                end
                app.constellation = 'SEN';
                drawnow;

                % 2. Set diretto dei 2 path da input_preprocessing.mat (Python+GPT)
                if exist('./PHASE_Preprocessing/input_preprocessing.mat', 'file') == 2
                    cfg = load('./PHASE_Preprocessing/input_preprocessing.mat');
                    if isfield(cfg, 'python')
                        % SEN side
                        if isprop(app, 'CustomPythonEnvironmentEditField') && isvalid(app.CustomPythonEnvironmentEditField)
                            app.CustomPythonEnvironmentEditField.Value = cfg.python;
                            app.CustomPythonEnvironmentEditField.Visible = 'on';
                        end
                        if isprop(app, 'PythonEnvironmentDropDown') && isvalid(app.PythonEnvironmentDropDown)
                            app.PythonEnvironmentDropDown.Value = 'Other';
                        end
                        if isprop(app, 'PythonEnvironmentLabel') && isvalid(app.PythonEnvironmentLabel)
                            app.PythonEnvironmentLabel.Visible = 'on';
                        end
                        app.python_SEN = cfg.python;
                        % CSK side (stesso python_exe)
                        if isprop(app, 'CustomPythonEnvironmentEditField_2') && isvalid(app.CustomPythonEnvironmentEditField_2)
                            app.CustomPythonEnvironmentEditField_2.Value = cfg.python;
                            app.CustomPythonEnvironmentEditField_2.Visible = 'on';
                        end
                        if isprop(app, 'PythonEnvironmentDropDown_2') && isvalid(app.PythonEnvironmentDropDown_2)
                            app.PythonEnvironmentDropDown_2.Value = 'Other';
                        end
                        app.python_CSK = cfg.python;
                    end
                    if isfield(cfg, 'gptbin_path')
                        if isprop(app, 'PathEditField') && isvalid(app.PathEditField)
                            app.PathEditField.Value = cfg.gptbin_path;
                        end
                        app.gptbin_path_SEN = cfg.gptbin_path;
                        if isprop(app, 'PathEditField_2') && isvalid(app.PathEditField_2)
                            app.PathEditField_2.Value = cfg.gptbin_path;
                        end
                        app.gptbin_path_CSK = cfg.gptbin_path;
                    end
                end
            catch
                % non blocca lo startup se qualcosa fallisce
            end
"@
    $prepMlapp = Join-Path $phaseDir 'PHASE_Preprocessing.mlapp'
    # Anchor specifico: l'ultima delle 4 righe di "Initially hide" (linea 479
    # del document.xml originale). Inserire qui assicura che la nostra
    # visibility='on' sui field Python non venga sovrascritta dalle 'off'
    # subito sotto la riga di anchor di default.
    [void](Invoke-MlappAutoLoadPatch -MlappPath $prepMlapp `
        -Anchor "app.CustomPythonEnvironmentEditField_2.Visible = 'off';" `
        -InjectBlock $prepInject `
        -StatusCallback { param($m) Add-SetupLog $m })

    # PHASE_model.mlapp ha gia' un auto-load nel suo startupFcn (legge config
    # da input_model.mat se esiste). Ma noi NON generiamo input_model.mat
    # perche' il config struct ha 60+ campi. Quindi patchiamo lo startupFcn
    # per settare SOLO app.pythonPath al python configurato, lasciando intatto
    # il resto del flusso (compreso il load esistente se il .mat sara' creato
    # poi dall'utente con Save).
    $pyForModel = $Script:State.PythonExe.Replace('\','/')
    $modelInject = @"


            % AUTO-CONFIG (PHASE installer): default pythonPath se input_model.mat
            % non esiste ancora. Sovrascritto dal config.pythonPath del load
            % successivo (linea ~341 dello startupFcn).
            try
                appDir_phaseinstaller = fileparts(mfilename('fullpath'));
                if exist(fullfile(appDir_phaseinstaller, 'input_model.mat'), 'file') ~= 2
                    app.pythonPath = '$pyForModel';
                    if isprop(app, 'pythoninstallationpathEditField') && isvalid(app.pythoninstallationpathEditField)
                        app.pythoninstallationpathEditField.Value = '$pyForModel';
                    end
                end
            catch
            end
"@
    $modelMlapp = Join-Path $phaseDir 'PHASE_model.mlapp'
    [void](Invoke-MlappAutoLoadPatch -MlappPath $modelMlapp `
        -Anchor "addpath('./MatlabFunctions/');" `
        -InjectBlock $modelInject `
        -StatusCallback { param($m) Add-SetupLog $m })

    Set-SetupProgress 100 'Completato!'
    Add-SetupLog ""
    Add-SetupLog "=== Installazione completata ==="
    Add-SetupLog "Apri uno di questi file in MATLAB:"
    Add-SetupLog "  $phaseDir\PHASE_Preprocessing.mlapp"
    Add-SetupLog "  $phaseDir\PHASE_Preprocessing\PHASE_StaMPS.mlapp"
    Add-SetupLog "  $phaseDir\PHASE_model.mlapp"
}

# -----------------------------------------------------------------------------
# Show wizard
# -----------------------------------------------------------------------------

if ($DryRun) {
    Write-Host "Dry run: XAML parsed OK, $($pages.Count) pages registered."
    Write-Host "Detection probes:"
    Write-Host "  MATLAB: $(Find-Matlab)"
    Write-Host "  SNAP:   $(Find-Snap)"
    Write-Host "  Python: $((Find-Python | ConvertTo-Json -Compress))"
    Write-Host "  git:    $(Find-Git)"
    exit 0
}

Show-Page 1
[void]$window.ShowDialog()
