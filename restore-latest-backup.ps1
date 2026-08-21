param(
    [string]$GamePath = ""
)

$ErrorActionPreference = "Stop"

if (!$GamePath) {
    foreach ($p in @(
        "C:\Gaming Services\Steam\steamapps\common\Doki Doki Literature Club",
        "C:\Program Files (x86)\Steam\steamapps\common\Doki Doki Literature Club",
        "C:\Program Files\Steam\steamapps\common\Doki Doki Literature Club"
    )) {
        if (Test-Path -LiteralPath (Join-Path $p "_DDLC_RussianVoice_Backups")) {
            $GamePath = $p
            break
        }
    }
}

if (!$GamePath) {
    throw "Game path was not detected. Run restore-latest-backup.ps1 -GamePath <path>"
}

$backupBase = Join-Path $GamePath "_DDLC_RussianVoice_Backups"
if (!(Test-Path -LiteralPath $backupBase)) {
    throw "Backup directory not found: $backupBase"
}

$latest = Get-ChildItem -LiteralPath $backupBase -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1

if ($null -eq $latest) {
    throw "No backups found."
}

$manifestPath = Join-Path $latest.FullName "backup_manifest.json"
if (!(Test-Path -LiteralPath $manifestPath)) {
    throw "Backup manifest not found: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Write-Host ("Restoring backup: " + $latest.FullName)

foreach ($record in $manifest.records) {
    $target = Join-Path $GamePath $record.relative
    $source = Join-Path (Join-Path $latest.FullName "original") $record.relative

    if ($record.existed) {
        if (!(Test-Path -LiteralPath $source)) {
            throw "Backup file is missing: $source"
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        Write-Host ("RESTORED " + $record.relative)
    } else {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
            Write-Host ("REMOVED NEW FILE " + $record.relative)
        }
    }
}

Write-Host ""
Write-Host "Backup restore complete."
Write-Host "Steam file verification may still be used if you want a completely clean DDLC install."
