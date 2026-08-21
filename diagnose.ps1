param(
    [string]$GamePath = ""
)

$ErrorActionPreference = "Continue"

function Test-DDLCPath([string]$Path) {
    return (
        $Path -and
        (Test-Path -LiteralPath (Join-Path $Path "DDLC.exe")) -and
        (Test-Path -LiteralPath (Join-Path $Path "game\scripts.rpa"))
    )
}

if (!$GamePath) {
    foreach ($p in @(
        "C:\Gaming Services\Steam\steamapps\common\Doki Doki Literature Club",
        "C:\Program Files (x86)\Steam\steamapps\common\Doki Doki Literature Club",
        "C:\Program Files\Steam\steamapps\common\Doki Doki Literature Club"
    )) {
        if (Test-DDLCPath $p) { $GamePath = $p; break }
    }
}

Write-Host "DDLC Russian Voice v1.0.1 diagnostic"
Write-Host ("GamePath=" + $GamePath)

if (!(Test-DDLCPath $GamePath)) {
    Write-Host "Game path not detected. Run diagnose.ps1 -GamePath <path>"
    exit 2
}

$game = Join-Path $GamePath "game"
$neural = Join-Path $game "voice_mod\neural"
$python = Join-Path $neural "venv\Scripts\python.exe"

Write-Host ""
Write-Host "===== active hooks ====="
$hooks = @(Get-ChildItem -LiteralPath $game -Recurse -File -Filter "zz_ddlc_russian_voice.rpy" -ErrorAction SilentlyContinue)
Write-Host ("count=" + $hooks.Count)
$hooks | ForEach-Object { Write-Host $_.FullName }

Write-Host ""
Write-Host "===== subtitle hashes ====="
foreach ($rel in @(
    "scripts.rpa",
    "fonts.rpa",
    "tl\None\common.rpym",
    "tl\None\common.rpymc"
)) {
    $p = Join-Path $game $rel
    if (Test-Path -LiteralPath $p) {
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host ($rel + " " + $h)
    } else {
        Write-Host ($rel + " MISSING")
    }
}

if (Test-Path -LiteralPath $python) {
    Write-Host ""
    Write-Host "===== Python runtime ====="
    & $python -c "import torch,numpy; print('torch='+torch.__version__); print('cuda='+str(torch.cuda.is_available())); print('gpu='+(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU')); print('numpy='+numpy.__version__)"
}

foreach ($p in @(
    (Join-Path $game "voice_mod\mod.log"),
    (Join-Path $neural "neural.log"),
    (Join-Path $game "voice_mod\install_state.json")
)) {
    if (Test-Path -LiteralPath $p) {
        Write-Host ""
        Write-Host ("===== " + $p + " =====")
        Get-Content -LiteralPath $p -Tail 200
    }
}
