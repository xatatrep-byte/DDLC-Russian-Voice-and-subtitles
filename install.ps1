param(
    [string]$GamePath = "",
    [switch]$ForceSubtitleReplace,
    [switch]$SkipDependencySetup
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$BundleVersion = "1.0.5"
$ExpectedSunTeamArchiveHash = "15f4ffe7bb5e91a81e21e2c30448c3070e1511278187347fd2d1b719a5c01837"
$ExpectedScriptsHash = "d13daa93ccaabc2cce15fc4293a20b3cd63fb0741e9ab3d5af9eb19009732dd4"
$ExpectedFontsHash = "b37ae2835d6d074d216453f03b365bdbed78255f47e41a2d890f2631806c3bce"
$ExpectedCommonHash = "0d08b92bebf77c874a7b7ffc5cbab169165bcb0a48cee6b956563b96bac6d418"
$ExpectedCommonCHash = "cdd459bea8c20bbd421dfdab48a2dd8ce482d07a17dfda0efcaf80b86ea8dd96"
$ExpectedSunTeamScriptVersion = "(6, 99, 13)"
$ExpectedRuntimeBootstrapHash = "db7b1d5ccac10ca583fe3e383122b0a688d16b3ab116a02b8f31de401a3e2f32"
$ExpectedRuntimePythonDllHash = "4bf70e90594a6d3fbc042747bb314f541e84c0d5f7ec1cf82beac0afd94b5348"
$ExpectedRuntimeExeHash = "559d5ca234a68bac5a9b1130f9ec73512c1a20178daf0ce04154cbe83dcd32fe"

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

# Windows PowerShell 5.1 can convert stderr from native programs into
# NativeCommandError records. With ErrorActionPreference="Stop", an expected
# probe failure (for example importing torch in a brand-new venv) can terminate
# the whole installer before we can inspect LASTEXITCODE.
#
# Run native tools with ErrorActionPreference temporarily relaxed, preserve
# their real process exit code, and restore the installer's strict mode after.
$script:NativeExitCode = 0

function Invoke-NativeSafe(
    [string]$FilePath,
    [string[]]$Arguments,
    [switch]$Quiet
) {
    $savedPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        if ($Quiet) {
            & $FilePath @Arguments 1>$null 2>$null
        }
        else {
            & $FilePath @Arguments 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    Write-Host $_.ToString()
                }
                else {
                    Write-Host $_
                }
            }
        }

        if ($null -eq $LASTEXITCODE) {
            $script:NativeExitCode = 0
        }
        else {
            $script:NativeExitCode = [int]$LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
}


function Find-7Zip {
    foreach ($p in @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe"
    )) {
        if (Test-Path -LiteralPath $p) {
            return $p
        }
    }

    try {
        $cmd = (Get-Command "7z.exe" -ErrorAction Stop).Source
        if ($cmd) {
            return $cmd
        }
    } catch {}

    return $null
}

function Ensure-7Zip {
    $seven = Find-7Zip
    if ($seven) {
        return $seven
    }

    Write-Warn "7-Zip was not found."
    Write-Info "Trying to install 7-Zip through winget..."

    try {
        $winget = (Get-Command "winget.exe" -ErrorAction Stop).Source
    }
    catch {
        throw "7-Zip is required to unpack the bundled DDLC_1.0_PC.rar. Install 7-Zip and rerun install.bat."
    }

    Invoke-NativeSafe -FilePath $winget -Arguments @(
        "install",
        "--exact",
        "--id", "7zip.7zip",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    if ($script:NativeExitCode -ne 0) {
        throw "winget could not install 7-Zip. Exit code: $($script:NativeExitCode)"
    }

    $seven = Find-7Zip
    if (!$seven) {
        throw "7-Zip installation completed but 7z.exe could not be located."
    }

    return $seven
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

function Test-ExactSunTeamRuntime([string]$Game) {
    $versionPath = Join-Path $Game "game\script_version.txt"
    $bootstrapPath = Join-Path $Game "renpy\bootstrap.py"
    $pythonDllPath = Join-Path $Game "lib\windows-i686\python27.dll"

    if (!(Test-Path -LiteralPath $versionPath)) { return $false }

    try {
        $version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    }
    catch {
        return $false
    }

    if ($version -ne $ExpectedSunTeamScriptVersion) { return $false }
    if ((Get-Sha256 $bootstrapPath) -ne $ExpectedRuntimeBootstrapHash) { return $false }
    if ((Get-Sha256 $pythonDllPath) -ne $ExpectedRuntimePythonDllHash) { return $false }
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

    $savedPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"
        $out = & $Exe -c "import sys,struct; print(sys.version_info.major,sys.version_info.minor,struct.calcsize('P')*8)" 2>$null
        $exitCode = $LASTEXITCODE
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    if ($exitCode -ne 0) { return $false }

    $parts = ($out -split "\s+")
    if ($parts.Count -lt 3) { return $false }

    try {
        $major = [int]$parts[0]
        $minor = [int]$parts[1]
        $bits = [int]$parts[2]
    }
    catch {
        return $false
    }

    return ($major -eq 3 -and $minor -ge 10 -and $minor -le 13 -and $bits -eq 64)
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
            $savedPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $resolved = & $py $ver -c "import sys; print(sys.executable)" 2>$null
                $pyExitCode = $LASTEXITCODE
            }
            catch {
                $pyExitCode = 1
            }
            finally {
                $ErrorActionPreference = $savedPreference
            }

            if ($pyExitCode -eq 0 -and $resolved -and (Test-Python $resolved.Trim())) {
                return $resolved.Trim()
            }
        }
    } catch {}

    return $null
}

Write-Title "DDLC Russian Voice v1.0.5 - Full SUN-TEAM Overlay Installer"

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
# Full SUN-TEAM overlay.
#
# v1.0.5 deliberately does NOT reconstruct the Russian translation from a
# selected subset of files. It uses the complete original DDLC_1.0_PC.rar
# supplied with this release, verifies it, removes the four game/runtime
# directories, then extracts the archive directly over the installed DDLC.
# The voice mod is installed only AFTER this exact SUN-TEAM baseline exists.
# --------------------------------------------------------------------
Write-Step "Installing complete SUN-TEAM DDLC_1.0_PC.rar baseline"

$sunTeamArchive = Join-Path $PSScriptRoot "payload\sunteam_full\DDLC_1.0_PC.rar"

if (!(Test-Path -LiteralPath $sunTeamArchive)) {
    throw "Bundled DDLC_1.0_PC.rar is missing. Download the Full v1.0.5 release again."
}

Write-Info "Verifying bundled DDLC_1.0_PC.rar..."
$archiveHash = Get-Sha256 $sunTeamArchive
if ($archiveHash -ne $ExpectedSunTeamArchiveHash) {
    throw ("DDLC_1.0_PC.rar SHA-256 mismatch. Expected " + $ExpectedSunTeamArchiveHash + ", got " + $archiveHash)
}

$runningDDLC = Get-Process -Name "DDLC" -ErrorAction SilentlyContinue
if ($runningDDLC) {
    throw "DDLC is currently running. Close the game completely and rerun install.bat."
}

$sevenZip = Ensure-7Zip
Write-Info ("7-Zip: " + $sevenZip)

# Test the RAR BEFORE deleting/replacing any game files.
Write-Info "Testing SUN-TEAM archive integrity..."
Invoke-NativeSafe -FilePath $sevenZip -Arguments @(
    "t",
    $sunTeamArchive
)
if ($script:NativeExitCode -ne 0) {
    throw "DDLC_1.0_PC.rar failed the 7-Zip integrity test."
}

Write-Warn "Replacing DDLC game/runtime files with the complete SUN-TEAM package."
Write-Info "Removing old game, renpy, lib and characters directories first..."

foreach ($dirName in @("game", "renpy", "lib", "characters")) {
    $targetDir = Join-Path $GamePath $dirName
    if (Test-Path -LiteralPath $targetDir) {
        Remove-Item -LiteralPath $targetDir -Recurse -Force
    }
}

Write-Info "Extracting the complete SUN-TEAM package with overwrite enabled..."
Invoke-NativeSafe -FilePath $sevenZip -Arguments @(
    "x",
    $sunTeamArchive,
    ("-o" + $GamePath),
    "-y",
    "-aoa"
)
if ($script:NativeExitCode -ne 0) {
    throw "SUN-TEAM archive extraction failed. Exit code: $($script:NativeExitCode)"
}

# Recompute paths because the game directory has just been recreated.
$game = Join-Path $GamePath "game"
$voiceDir = Join-Path $game "voice_mod"
$neuralDir = Join-Path $voiceDir "neural"

if (!(Test-DDLCPath $GamePath)) {
    throw "SUN-TEAM extraction completed, but the DDLC installation is incomplete."
}

if (!(Test-ExactSunTeam $GamePath)) {
    throw "Complete SUN-TEAM overlay verification failed: translated files do not match DDLC_1.0_PC.rar."
}

if (!(Test-ExactSunTeamRuntime $GamePath)) {
    throw "Complete SUN-TEAM overlay verification failed: matching Ren'Py 6.99.13 runtime was not installed."
}

Write-Host "    Complete SUN-TEAM package installed and verified." -ForegroundColor Green
Write-Host "    Russian subtitles baseline: READY" -ForegroundColor Green
Write-Host "    Ren'Py 6.99.13 baseline: READY" -ForegroundColor Green

# --------------------------------------------------------------------
# Backup manager. Backups are deliberately OUTSIDE game/.
# In v1.0.5 this backup covers our voice overlay. The complete SUN-TEAM
# baseline itself can be reverted by Steam's Verify integrity feature.
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
        kind = "file"
    })
}

function Register-TreeTarget([string]$AbsolutePath) {
    $relative = $AbsolutePath.Substring($GamePath.Length).TrimStart("\")
    $exists = Test-Path -LiteralPath $AbsolutePath

    if ($exists) {
        $backupPath = Join-Path $backupOriginal $relative
        $parent = Split-Path -Parent $backupPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item -LiteralPath $AbsolutePath -Destination $backupPath -Recurse -Force
    }

    [void]$backupRecords.Add([pscustomobject]@{
        relative = $relative
        existed = [bool]$exists
        kind = "directory"
    })
}

function Install-TreeFromPayload([string]$SourceDir, [string]$TargetDir) {
    if (!(Test-Path -LiteralPath $SourceDir)) {
        throw "Runtime payload directory is missing: $SourceDir"
    }

    Register-TreeTarget $TargetDir

    if (Test-Path -LiteralPath $TargetDir) {
        Remove-Item -LiteralPath $TargetDir -Recurse -Force
    }

    Copy-Item -LiteralPath $SourceDir -Destination $TargetDir -Recurse -Force
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
# Verify the complete SUN-TEAM baseline installed above.
# No partial/smart subtitle installation exists in v1.0.5.
# --------------------------------------------------------------------
Write-Step "Verifying Russian subtitles and matching Ren'Py runtime"

$exactSunTeam = Test-ExactSunTeam $GamePath
$compatibleRussian = $exactSunTeam
$exactSunTeamRuntime = Test-ExactSunTeamRuntime $GamePath
$subtitlePayloadUsed = $true
$runtimePayloadUsed = $true

if (!$exactSunTeam) {
    throw "SUN-TEAM Russian subtitle verification failed after full archive extraction."
}

if (!$exactSunTeamRuntime) {
    throw "SUN-TEAM Ren'Py 6.99.13 runtime verification failed after full archive extraction."
}

Write-Host "    SUN-TEAM Studio Russian translation v1.0: VERIFIED" -ForegroundColor Green
Write-Host "    Matching Ren'Py 6.99.13 runtime: VERIFIED" -ForegroundColor Green


# --------------------------------------------------------------------
# Install stable voice runtime.
# --------------------------------------------------------------------
Write-Step "Installing DDLC Russian Voice v1.0.5 runtime"

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

            Invoke-NativeSafe -FilePath $winget -Arguments @(
                "install",
                "--exact",
                "--id", "Python.Python.3.11",
                "--scope", "user",
                "--silent",
                "--accept-package-agreements",
                "--accept-source-agreements"
            )
            if ($script:NativeExitCode -ne 0) {
                throw "winget could not install Python 3.11. Exit code: $($script:NativeExitCode)"
            }

            $python = Find-Python
            if ($null -eq $python) {
                throw "Python installation completed but python.exe could not be located."
            }
        }

        Write-Info ("Python: " + $python)
        Write-Info "Creating isolated virtual environment..."
        Invoke-NativeSafe -FilePath $python -Arguments @("-m", "venv", $venv)
        if ($script:NativeExitCode -ne 0) {
            throw "Failed to create virtual environment. Exit code: $($script:NativeExitCode)"
        }
    }

    # Check whether the existing venv is already usable.
    # Missing torch/numpy is EXPECTED on a brand-new PC and must not abort
    # Windows PowerShell 5.1 with NativeCommandError.
    Invoke-NativeSafe -FilePath $venvPython -Arguments @(
        "-c",
        "import torch,numpy; print('runtime-ok')"
    ) -Quiet
    $runtimeOk = ($script:NativeExitCode -eq 0)

    if (!$runtimeOk) {
        Write-Info "Installing Python dependencies..."
        Invoke-NativeSafe -FilePath $venvPython -Arguments @(
            "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"
        )
        if ($script:NativeExitCode -ne 0) {
            throw "pip upgrade failed. Exit code: $($script:NativeExitCode)"
        }

        $hasNvidia = $false
        try {
            $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop
            $hasNvidia = (@($gpus | Where-Object { $_.Name -match "NVIDIA" }).Count -gt 0)
        } catch {}

        if ($hasNvidia) {
            Write-Info "NVIDIA GPU detected: installing PyTorch 2.7.0 CUDA 12.8."
            Invoke-NativeSafe -FilePath $venvPython -Arguments @(
                "-m", "pip", "install",
                "torch==2.7.0",
                "--index-url", "https://download.pytorch.org/whl/cu128"
            )
        } else {
            Write-Info "NVIDIA GPU not detected: installing PyTorch 2.7.0 CPU build."
            Invoke-NativeSafe -FilePath $venvPython -Arguments @(
                "-m", "pip", "install",
                "torch==2.7.0",
                "--index-url", "https://download.pytorch.org/whl/cpu"
            )
        }
        if ($script:NativeExitCode -ne 0) {
            throw "PyTorch installation failed. Exit code: $($script:NativeExitCode)"
        }

        Invoke-NativeSafe -FilePath $venvPython -Arguments @(
            "-m", "pip", "install", "numpy>=1.26,<3"
        )
        if ($script:NativeExitCode -ne 0) {
            throw "NumPy installation failed. Exit code: $($script:NativeExitCode)"
        }
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

Write-Info "Runtime details:"
Invoke-NativeSafe -FilePath $venvPython -Arguments @(
    "-c",
    "import torch,numpy; print('torch='+torch.__version__); print('cuda='+str(torch.cuda.is_available())); print('gpu='+(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU')); print('numpy='+numpy.__version__)"
)
if ($script:NativeExitCode -ne 0) {
    throw "Python runtime verification failed. Exit code: $($script:NativeExitCode)"
}

Write-Info "Running Silero generation self-test..."
Invoke-NativeSafe -FilePath $venvPython -Arguments @(
    $targetEngine,
    "--self-test",
    "--no-play"
)
if ($script:NativeExitCode -ne 0) {
    throw "Silero self-test failed. Run diagnose.bat and send the output."
}

$runtimeReadyFlag = Join-Path $neuralDir "runtime-ready.flag"
$failedFlag = Join-Path $neuralDir "failed.flag"
$legacyReadyFlag = Join-Path $neuralDir "ready.flag"

if (!(Test-Path -LiteralPath $runtimeReadyFlag)) {
    throw "Silero self-test completed but runtime-ready.flag was not created."
}
if (Test-Path -LiteralPath $failedFlag) {
    throw "Silero failed.flag exists after self-test. Run diagnose.bat."
}
if (Test-Path -LiteralPath $legacyReadyFlag) {
    Remove-Item -LiteralPath $legacyReadyFlag -Force -ErrorAction SilentlyContinue
}

Write-Host "    Silero backend readiness verified (runtime-ready.flag)." -ForegroundColor Green
Write-Info "Automatic Windows SAPI fallback is disabled."

# --------------------------------------------------------------------
# Marker + backup manifest.
# --------------------------------------------------------------------
New-Item -ItemType Directory -Path $voiceDir -Force | Out-Null

$installState = [pscustomobject]@{
    bundle_version = $BundleVersion
    installed_at = (Get-Date -Format o)
    game_path = $GamePath
    full_sunteam_archive_overlay = $true
    sunteam_archive_sha256 = "15f4ffe7bb5e91a81e21e2c30448c3070e1511278187347fd2d1b719a5c01837"
    exact_sunteam_verified = [bool](Test-ExactSunTeam $GamePath)
    sunteam_runtime_verified = [bool](Test-ExactSunTeamRuntime $GamePath)
    voice_runtime = "v1.0.5 Acting Lite / Natural Dashes"
    silero_backend = "silero-v5_5"
    sapi_fallback = "disabled"
    latin_nickname_tts_normalization = $true
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
Write-Host "  Voice runtime      : v1.0.5 Acting Lite" -ForegroundColor Green
Write-Host "  Silero self-test   : PASS" -ForegroundColor Green
Write-Host "  Silero backend     : silero-v5_5 (SAPI fallback disabled)" -ForegroundColor Green
Write-Host "  Ren'Py hook count  : 1" -ForegroundColor Green
Write-Host ""
Write-Host ("  Backup: " + $backupRoot) -ForegroundColor DarkGray
Write-Host ""
Write-Host "Launch Doki Doki Literature Club normally from Steam." -ForegroundColor Cyan
