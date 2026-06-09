# Stáhne sidecar binárky (yt-dlp.exe + ffmpeg.exe) pro Windows build a
# pojmenuje je podle cílového triple, jak vyžaduje Tauri `externalBin`.
#
# Použití (z adresáře desktop/):
#   powershell -ExecutionPolicy Bypass -File scripts\fetch-binaries.ps1
#
# Cíl: x86_64-pc-windows-msvc

$ErrorActionPreference = "Stop"

$FfmpegRelease = "b6.1.1"          # eugeneware/ffmpeg-static
$Target = "x86_64-pc-windows-msvc"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinDir = Join-Path $ScriptDir "..\src-tauri\binaries"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

function Expand-Gzip($InPath, $OutPath) {
    $in = [System.IO.File]::OpenRead($InPath)
    $out = [System.IO.File]::Create($OutPath)
    $gz = New-Object System.IO.Compression.GzipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    try { $gz.CopyTo($out) } finally { $gz.Dispose(); $out.Dispose(); $in.Dispose() }
}

# --- yt-dlp.exe (oficiální release) ---
Write-Host "Stahuji yt-dlp.exe..."
$YtDlp = Join-Path $BinDir "yt-dlp-$Target.exe"
Invoke-WebRequest -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -OutFile $YtDlp

# --- ffmpeg.exe (statický build, .gz -> rozbalit) ---
Write-Host "Stahuji ffmpeg.exe (win32-x64)..."
$Gz = Join-Path $BinDir "ffmpeg.gz"
$Ffmpeg = Join-Path $BinDir "ffmpeg-$Target.exe"
Invoke-WebRequest -Uri "https://github.com/eugeneware/ffmpeg-static/releases/download/$FfmpegRelease/ffmpeg-win32-x64.gz" -OutFile $Gz
Expand-Gzip $Gz $Ffmpeg
Remove-Item $Gz

Write-Host "Hotovo:"
Get-ChildItem $YtDlp, $Ffmpeg | Format-Table Name, Length
