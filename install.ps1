param(
    [string]$GamePath = "",
    [switch]$ForceSubtitleReplace,
    [switch]$SkipDependencySetup
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$BundleVersion = "1.0.2"
$ExpectedScriptsHash = "d13daa93ccaabc2cce15fc4293a20b3cd63fb0741e9ab3d5af9eb19009732dd4"
$ExpectedFontsHash = "b37ae2835d6d074d216453f03b365bdbed78255f47e41a2d890f2631806c3bce"
$ExpectedCommonHash = "0d08b92bebf77c874a7b7ffc5cbab169165bcb0a48cee6b956563b96bac6d418"
$ExpectedCommonCHash = "cdd459bea8c20bbd421dfdab48a2dd8ce482d07a17dfda0efcaf80b86ea8dd96"

function Write-Title([string]$Text) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host ("[+] " + $Text) -ForegroundColor Green
}

function Write-Info([string]$Text) {
    Write-Host ("    " + $Text) -ForegroundColor Gray
}

function Write-Warn([string]$Text) {
    Write-Host ("[!] " + $Text) -ForegroundColor Yellow
}

function Get-Sha256([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-DDLCPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (
        (Test-Path -LiteralPath (Join-Path $Path "DDLC.exe")) -and
        (Test-Path -LiteralPath (Join-Path $Path "game\scripts.rpa")) -and
        (Test-Path -LiteralPath (Join-Path $Path "game\audio.rpa")) -and
        (Test-Path -LiteralPath (Join-Path $Path "game\images.rpa"))
    )
}

function Find-DDLC {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($p in @(
        "C:\Gaming Services\Steam\steamapps\common\Doki Doki Literature Club",
        "C:\Program Files (x86)\Steam\steamapps\common\Doki Doki Literature Club",
        "C:\Program Files\Steam\steamapps\common\Doki Doki Literature Club"
    )) {
        $candidates.Add($p)
    }

    $steamRoots = New-Object System.Collections.Generic.List[string]

    try {
        $s = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
        if ($s) { $steamRoots.Add($s) }
    } catch {}

    try {
        $s = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction Stop).InstallPath
        if ($s) { $steamRoots.Add($s) }
    } catch {}

    foreach ($steamRoot in ($steamRoots | Select-Object -Unique)) {
        $candidates.Add((Join-Path $steamRoot "steamapps\common\Doki Doki Literature Club"))

        $vdf = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            try {
                $text = Get-Content -LiteralPath $vdf -Raw
                $matches = [regex]::Matches($text, '"path"\s+"([^"]+)"')
                foreach ($m in $matches) {
                    $lib = $m.Groups[1].Value.Replace("\\", "\")
                    if ($lib) {
                        $candidates.Add((Join-Path $lib "steamapps\common\Doki Doki Literature Club"))
                    }
                }
            } catch {}
        }
    }

    # Normalize and deduplicate paths case-insensitively.
    # Windows paths C:\... and c:\... refer to the same installation.
    $validList = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($candidate in $candidates) {
        if (!(Test-DDLCPath $candidate)) { continue }

        try {
            $resolved = (Resolve-Path -LiteralPath $candidate).Path.TrimEnd("\")
        } catch {
            $resolved = $candidate.TrimEnd("\")
        }

        $key = $resolved.ToLowerInvariant()
        if (!$seen.ContainsKey($key)) {
            $seen[$key] = $true
            $validList.Add($resolved)
        }
    }

    $valid = @($validList.ToArray())

    if ($valid.Count -eq 0) {
        return $null
    }

    if ($valid.Count -eq 1) {
        return $valid[0]
    }

    Write-Warn "Multiple DDLC installations were found:"
    for ($i = 0; $i -lt $valid.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $valid[$i])
    }

    while ($true) {
        $choice = Read-Host "Choose installation number"
        $num = 0
        if ([int]::TryParse($choice, [ref]$num)) {
            if ($num -ge 1 -and $num -le $valid.Count) {
                return $valid[$num - 1]
            }
        }
    }
}

function Test-CyrillicInFile([string]$Path, [int]$MaxBytes = 262144) {
    if (!(Test-Path -LiteralPath $Path)) { return $false }

    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $count = [Math]::Min([int64]$MaxBytes, $fs.Length)
            $buffer = New-Object byte[] ([int]$count)
            $read = $fs.Read($buffer, 0, $buffer.Length)
        } finally {
            $fs.Dispose()
        }

        if ($read -le 0) { return $false }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $matches = [regex]::Matches($text, "[\u0400-\u04FF]")
        return ($matches.Count -ge 10)
    } catch {
        return $false
    }
}

function Test-ExactSunTeam([string]$Game) {
    $gameDir = Join-Path $Game "game"
    $checks = @(
        @((Join-Path $gameDir "scripts.rpa"), $ExpectedScriptsHash),
        @((Join-Path $gameDir "fonts.rpa"), $ExpectedFontsHash),
        @((Join-Path $gameDir "tl\None\common.rpym"), $ExpectedCommonHash),
        @((Join-Path $gameDir "tl\None\common.rpymc"), $ExpectedCommonCHash)
    )

    foreach ($c in $checks) {
        if ((Get-Sha256 $c[0]) -ne $c[1]) { return $false }
    }
    return $true
}

function Test-CompatibleRussian([string]$Game) {
    $gameDir = Join-Path $Game "game"
    $common = Join-Path $gameDir "tl\None\common.rpym"
    $scripts = Join-Path $gameDir "scripts.rpa"

    return (
        (Test-CyrillicInFile $common 131072) -and
        (Test-CyrillicInFile $scripts 262144)
    )
}

function Test-ForeignModFiles([string]$Game) {
    $gameDir = Join-Path $Game "game"
    $files = Get-ChildItem -LiteralPath $gameDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Extension -eq ".rpy" -or $_.Extension -eq ".rpym") -and
            $_.Name -ne "zz_ddlc_russian_voice.rpy" -and
            $_.FullName -notmatch "\\tl\\None\\common\.rpym$" -and
            $_.FullName -notmatch "\\voice_mod\\"
        }

    return @($files)
}

function Test-Python([string]$Exe) {
    if (!(Test-Path -LiteralPath $Exe)) { return $false }
    try {
        $out = & $Exe -c "import sys,struct; print(sys.version_info.major,sys.version_info.minor,struct.calcsize('P')*8)" 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $parts = ($out -split "\s+")
        if ($parts.Count -lt 3) { return $false }
        $major = [int]$parts[0]
        $minor = [int]$parts[1]
        $bits = [int]$parts[2]
        return ($major -eq 3 -and $minor -ge 10 -and $minor -le 13 -and $bits -eq 64)
    } catch {
        return $false
    }
}

function Find-Python {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe")
    )
    foreach ($p in $candidates) {
        if (Test-Python $p) { return $p }
    }

    foreach ($cmd in @("python.exe", "python3.exe")) {
        try {
            $found = (Get-Command $cmd -ErrorAction Stop).Source
            if (Test-Python $found) { return $found }
        } catch {}
    }

    try {
        $py = (Get-Command "py.exe" -ErrorAction Stop).Source
        foreach ($ver in @("-3.11", "-3.12", "-3.13")) {
            try {
                $resolved = & $py $ver -c "import sys; print(sys.executable)" 2>$null
                if ($LASTEXITCODE -eq 0 -and (Test-Python $resolved.Trim())) {
                    return $resolved.Trim()
                }
            } catch {}
        }
    } catch {}

    return $null
}

Write-Title "DDLC Russian Voice v1.0.2 - Full Safe Installer"

# --------------------------------------------------------------------
# Locate / validate DDLC.
# --------------------------------------------------------------------
Write-Step "Locating original DDLC installation"

if ([string]::IsNullOrWhiteSpace($GamePath)) {
    $GamePath = Find-DDLC
}

if ($null -eq $GamePath -or !(Test-DDLCPath $GamePath)) {
    Write-Warn "Automatic detection failed."
    $GamePath = Read-Host "Enter the full path to Doki Doki Literature Club"
}

if (!(Test-DDLCPath $GamePath)) {
    throw "This does not look like original DDLC 2017. DDLC.exe + game/*.rpa were not found."
}

$GamePath = (Resolve-Path -LiteralPath $GamePath).Path
$game = Join-Path $GamePath "game"
$voiceDir = Join-Path $game "voice_mod"
$neuralDir = Join-Path $voiceDir "neural"

Write-Info ("Game: " + $GamePath)

if (Test-Path -LiteralPath (Join-Path $GamePath "Doki Doki Literature Club Plus.exe")) {
    throw "DDLC Plus is not supported. Install this mod into original DDLC 2017."
}

# --------------------------------------------------------------------
# Backup manager. Backups are deliberately OUTSIDE game/.
# --------------------------------------------------------------------
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupRoot = Join-Path $GamePath ("_DDLC_RussianVoice_Backups\" + $stamp)
$backupOriginal = Join-Path $backupRoot "original"
New-Item -ItemType Directory -Path $backupOriginal -Force | Out-Null

$backupRecords = New-Object System.Collections.ArrayList

function Register-Target([string]$AbsolutePath) {
    $relative = $AbsolutePath.Substring($GamePath.Length).TrimStart("\")
    $exists = Test-Path -LiteralPath $AbsolutePath

    if ($exists) {
        $backupPath = Join-Path $backupOriginal $relative
        $parent = Split-Path -Parent $backupPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item -LiteralPath $AbsolutePath -Destination $backupPath -Force
    }

    [void]$backupRecords.Add([pscustomobject]@{
        relative = $relative
        existed = [bool]$exists
    })
}

# --------------------------------------------------------------------
# Disable duplicate voice hooks before doing anything else.
# --------------------------------------------------------------------
Write-Step "Checking Ren'Py voice-hook safety"

$rootHook = Join-Path $game "zz_ddlc_russian_voice.rpy"

$dupHooks = Get-ChildItem -LiteralPath $game -Recurse -File -Filter "zz_ddlc_russian_voice.rpy" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $rootHook }

foreach ($hook in $dupHooks) {
    Register-Target $hook.FullName
    Remove-Item -LiteralPath $hook.FullName -Force
    Write-Warn ("Disabled duplicate hook: " + $hook.FullName)
}

# Compiled copies can also keep old wrappers alive.
$compiledHooks = Get-ChildItem -LiteralPath $game -Recurse -File -Filter "zz_ddlc_russian_voice.rpyc" -ErrorAction SilentlyContinue
foreach ($c in $compiledHooks) {
    Register-Target $c.FullName
    Remove-Item -LiteralPath $c.FullName -Force
}

# --------------------------------------------------------------------
# Russian subtitle detection / installation.
# --------------------------------------------------------------------
Write-Step "Checking Russian subtitles"

$subtitlePayload = Join-Path $PSScriptRoot "payload\russian_subtitles\game"
$payloadScripts = Join-Path $subtitlePayload "scripts.rpa"
$payloadFonts = Join-Path $subtitlePayload "fonts.rpa"
$payloadCommon = Join-Path $subtitlePayload "tl\None\common.rpym"
$payloadCommonC = Join-Path $subtitlePayload "tl\None\common.rpymc"

$payloadAvailable = (
    (Test-Path -LiteralPath $payloadScripts) -and
    (Test-Path -LiteralPath $payloadFonts) -and
    (Test-Path -LiteralPath $payloadCommon) -and
    (Test-Path -LiteralPath $payloadCommonC)
)

$exactSunTeam = Test-ExactSunTeam $GamePath
$compatibleRussian = Test-CompatibleRussian $GamePath

if ($exactSunTeam) {
    Write-Host "    SUN-TEAM Studio Russian translation v1.0 detected." -ForegroundColor Cyan
    Write-Host "    Subtitle files will NOT be overwritten." -ForegroundColor Green
}
elseif ($compatibleRussian) {
    Write-Host "    An existing Russian localization was detected." -ForegroundColor Cyan
    Write-Host "    It is not the exact bundled SUN-TEAM hash, so it will be preserved." -ForegroundColor Green
    Write-Host "    Voice will be installed on top of the existing Russian text." -ForegroundColor Green
}
else {
    if (!$payloadAvailable) {
        throw @"
No Russian localization was detected, and this package does not contain
a private Russian subtitle payload.

Install the SUN-TEAM Studio Russian translation first, then rerun this installer.
The public GitHub draft intentionally omits translated DDLC assets.
"@
    }

    $foreign = Test-ForeignModFiles $GamePath
    if ($foreign.Count -gt 0 -and !$ForceSubtitleReplace) {
        Write-Warn "Other Ren'Py mod files were detected:"
        $foreign | Select-Object -First 12 | ForEach-Object { Write-Host ("    " + $_.FullName) }
        throw @"
Safe mode stopped before replacing scripts.rpa.

The game appears to contain another mod. Replacing scripts.rpa could break it.
Use a clean original DDLC install, install this bundle there, or rerun with
-ForceSubtitleReplace if you knowingly want to replace the other mod.
"@
    }

    Write-Host "    Russian subtitles not detected. Installing SUN-TEAM Studio v1.0..." -ForegroundColor Cyan

    $targets = @(
        @((Join-Path $game "scripts.rpa"), $payloadScripts, $ExpectedScriptsHash),
        @((Join-Path $game "fonts.rpa"), $payloadFonts, $ExpectedFontsHash),
        @((Join-Path $game "tl\None\common.rpym"), $payloadCommon, $ExpectedCommonHash),
        @((Join-Path $game "tl\None\common.rpymc"), $payloadCommonC, $ExpectedCommonCHash)
    )

    foreach ($t in $targets) {
        $target = $t[0]
        $source = $t[1]
        $expected = $t[2]

        Register-Target $target
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force

        $actual = Get-Sha256 $target
        if ($actual -ne $expected) {
            throw "Russian subtitle verification failed for: $target"
        }
    }

    Write-Host "    SUN-TEAM Studio Russian translation installed and verified." -ForegroundColor Green
}

# --------------------------------------------------------------------
# Install stable voice runtime.
# --------------------------------------------------------------------
Write-Step "Installing DDLC Russian Voice stable runtime"

$voicePayload = Join-Path $PSScriptRoot "payload\voice\game"
$sourceHook = Join-Path $voicePayload "zz_ddlc_russian_voice.rpy"
$sourceEngine = Join-Path $voicePayload "voice_mod\neural\neural_tts.py"
$sourceVoices = Join-Path $voicePayload "voice_mod\neural\voices.json"
$sourceSapi = Join-Path $voicePayload "voice_mod\tts_helper.ps1"

foreach ($required in @($sourceHook,$sourceEngine,$sourceVoices,$sourceSapi)) {
    if (!(Test-Path -LiteralPath $required)) {
        throw "Voice payload is incomplete: $required"
    }
}

New-Item -ItemType Directory -Path $neuralDir -Force | Out-Null

$targetEngine = Join-Path $neuralDir "neural_tts.py"
$targetVoices = Join-Path $neuralDir "voices.json"
$targetSapi = Join-Path $voiceDir "tts_helper.ps1"

foreach ($target in @($rootHook,$targetEngine,$targetVoices,$targetSapi)) {
    Register-Target $target
}

Copy-Item -LiteralPath $sourceHook -Destination $rootHook -Force
Copy-Item -LiteralPath $sourceEngine -Destination $targetEngine -Force
Copy-Item -LiteralPath $sourceVoices -Destination $targetVoices -Force
Copy-Item -LiteralPath $sourceSapi -Destination $targetSapi -Force

# Clean stale compiled voice hooks again. Ren'Py will compile the fresh source.
Get-ChildItem -LiteralPath $game -Recurse -File -Filter "zz_ddlc_russian_voice.rpyc" -ErrorAction SilentlyContinue |
    Remove-Item -Force

# Clear generated voice cache because the stable engine version may differ.
$cache = Join-Path $neuralDir "cache"
if (Test-Path -LiteralPath $cache) {
    Remove-Item -LiteralPath $cache -Recurse -Force
}
New-Item -ItemType Directory -Path $cache -Force | Out-Null

# Verify exactly one active source hook.
$activeHooks = @(Get-ChildItem -LiteralPath $game -Recurse -File -Filter "zz_ddlc_russian_voice.rpy" -ErrorAction SilentlyContinue)
if ($activeHooks.Count -ne 1 -or $activeHooks[0].FullName -ne $rootHook) {
    throw "Voice-hook safety check failed. Expected exactly one active root hook."
}

Write-Host "    Exactly one Ren'Py voice hook is active." -ForegroundColor Green

# --------------------------------------------------------------------
# Python / Silero setup.
# --------------------------------------------------------------------
Write-Step "Checking Silero runtime"

$venv = Join-Path $neuralDir "venv"
$venvPython = Join-Path $venv "Scripts\python.exe"
$modelDir = Join-Path $neuralDir "models"
$modelPath = Join-Path $modelDir "v5_5_ru.pt"

if (!$SkipDependencySetup) {
    if (!(Test-Python $venvPython)) {
        $python = Find-Python

        if ($null -eq $python) {
            Write-Warn "Compatible 64-bit Python 3.10-3.13 was not found."
            Write-Info "Trying Python 3.11 installation through winget..."

            try {
                $winget = (Get-Command "winget.exe" -ErrorAction Stop).Source
            } catch {
                throw "Python is missing and winget is unavailable. Install 64-bit Python 3.11 and rerun."
            }

            & $winget install --exact --id Python.Python.3.11 --scope user --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                throw "winget could not install Python 3.11. Exit code: $LASTEXITCODE"
            }

            $python = Find-Python
            if ($null -eq $python) {
                throw "Python installation completed but python.exe could not be located."
            }
        }

        Write-Info ("Python: " + $python)
        Write-Info "Creating isolated virtual environment..."
        & $python -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw "Failed to create virtual environment." }
    }

    # Check whether the existing venv is already usable.
    & $venvPython -c "import torch,numpy; print('runtime-ok')" 2>$null | Out-Null
    $runtimeOk = ($LASTEXITCODE -eq 0)

    if (!$runtimeOk) {
        Write-Info "Installing Python dependencies..."
        & $venvPython -m pip install --upgrade pip setuptools wheel
        if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed." }

        $hasNvidia = $false
        try {
            $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop
            $hasNvidia = (@($gpus | Where-Object { $_.Name -match "NVIDIA" }).Count -gt 0)
        } catch {}

        if ($hasNvidia) {
            Write-Info "NVIDIA GPU detected: installing PyTorch 2.7.0 CUDA 12.8."
            & $venvPython -m pip install "torch==2.7.0" --index-url "https://download.pytorch.org/whl/cu128"
        } else {
            Write-Info "NVIDIA GPU not detected: installing PyTorch 2.7.0 CPU build."
            & $venvPython -m pip install "torch==2.7.0" --index-url "https://download.pytorch.org/whl/cpu"
        }
        if ($LASTEXITCODE -ne 0) { throw "PyTorch installation failed." }

        & $venvPython -m pip install "numpy>=1.26,<3"
        if ($LASTEXITCODE -ne 0) { throw "NumPy installation failed." }
    } else {
        Write-Info "Existing Python/Silero environment is reusable; heavy packages were not reinstalled."
    }

    New-Item -ItemType Directory -Path $modelDir -Force | Out-Null

    if (!(Test-Path -LiteralPath $modelPath) -or (Get-Item -LiteralPath $modelPath).Length -lt 1000000) {
        Write-Info "Downloading official Silero v5_5_ru model..."
        Invoke-WebRequest `
            -Uri "https://models.silero.ai/models/tts/ru/v5_5_ru.pt" `
            -OutFile $modelPath `
            -UseBasicParsing
    }

    if (!(Test-Path -LiteralPath $modelPath) -or (Get-Item -LiteralPath $modelPath).Length -lt 1000000) {
        throw "Silero model download failed or produced an invalid file."
    }
}

if (!(Test-Python $venvPython)) {
    throw "Silero venv is not ready. Rerun without -SkipDependencySetup."
}

if (!(Test-Path -LiteralPath $modelPath)) {
    throw "Silero model is missing. Rerun without -SkipDependencySetup."
}

$runtimeInfo = & $venvPython -c "import torch,numpy; print('torch='+torch.__version__); print('cuda='+str(torch.cuda.is_available())); print('gpu='+(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU')); print('numpy='+numpy.__version__)"
if ($LASTEXITCODE -ne 0) {
    throw "Python runtime verification failed."
}
$runtimeInfo | ForEach-Object { Write-Info $_ }

Write-Info "Running Silero generation self-test..."
& $venvPython $targetEngine --self-test --no-play
if ($LASTEXITCODE -ne 0) {
    throw "Silero self-test failed. Run diagnose.bat and send the output."
}

# --------------------------------------------------------------------
# Marker + backup manifest.
# --------------------------------------------------------------------
New-Item -ItemType Directory -Path $voiceDir -Force | Out-Null

$installState = [pscustomobject]@{
    bundle_version = $BundleVersion
    installed_at = (Get-Date -Format o)
    game_path = $GamePath
    exact_sunteam_detected_before_install = [bool]$exactSunTeam
    compatible_russian_detected_before_install = [bool]$compatibleRussian
    subtitle_payload_used = [bool](!$exactSunTeam -and !$compatibleRussian)
    voice_runtime = "v0.5.2.3 Natural Dashes / Acting Lite"
}

$installState | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $voiceDir "install_state.json") -Encoding UTF8

# Convert ArrayList to a plain object[] before JSON serialization.
# This avoids a Windows PowerShell 5.1 "Argument types do not match" failure.
$backupRecordArray = [object[]]$backupRecords.ToArray()

$manifestObject = [pscustomobject]@{
    game_path = $GamePath
    backup_created = (Get-Date -Format o)
    records = $backupRecordArray
}

$manifestObject | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $backupRoot "backup_manifest.json") -Encoding UTF8

Write-Title "INSTALLATION COMPLETE"
Write-Host "  Russian subtitles : READY" -ForegroundColor Green
Write-Host "  Voice runtime      : v0.5.2.3 Acting Lite" -ForegroundColor Green
Write-Host "  Silero self-test   : PASS" -ForegroundColor Green
Write-Host "  Ren'Py hook count  : 1" -ForegroundColor Green
Write-Host ""
Write-Host ("  Backup: " + $backupRoot) -ForegroundColor DarkGray
Write-Host ""
Write-Host "Launch Doki Doki Literature Club normally from Steam." -ForegroundColor Cyan
