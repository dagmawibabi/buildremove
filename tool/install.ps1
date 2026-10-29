# Compiles buildremove to a native exe and puts it in the Pub bin folder
# (%LOCALAPPDATA%\Pub\Cache\bin), adding that folder to the user PATH if needed.
# Re-run after changing the code.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bin = Join-Path $env:LOCALAPPDATA 'Pub\Cache\bin'
New-Item -ItemType Directory -Force $bin | Out-Null

# Drop the slower `dart pub global` shim if it was used before.
Remove-Item (Join-Path $bin 'buildremove.bat') -ErrorAction SilentlyContinue

# A running exe can't be overwritten, but it can be renamed out of the way.
$exe = Join-Path $bin 'buildremove.exe'
$old = Join-Path $bin 'buildremove.old.exe'
Remove-Item $old -ErrorAction SilentlyContinue
if (Test-Path $exe) { Move-Item $exe $old -Force }

Push-Location $root
try {
    dart pub get | Out-Null
    dart compile exe bin\buildremove.dart -o $exe
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Compile failed. If buildremove is running in another terminal, close it and retry.'
        exit 1
    }
} finally {
    Pop-Location
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
    Write-Host "Added $bin to your PATH. Open a new terminal to use it."
}
Write-Host 'Installed. Run: buildremove'
