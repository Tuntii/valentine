# Puts Microsoft's current ConPTY (conpty.dll + OpenConsole.exe, the pair Windows Terminal and
# VS Code ship) next to valentine.exe. Windows 10's built-in ConPTY is years behind and garbles
# TUIs such as Claude Code; with these files present Valentine uses them instead.
#
# Usage: powershell -ExecutionPolicy Bypass -File tools\fetch-conpty.ps1 [-Dest <folder>]
param(
    [string]$Version = '1.25.260930003',
    [string]$Dest = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'

$arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } default { 'x64' } }
$work = Join-Path ([IO.Path]::GetTempPath()) "valentine-conpty-$Version"
$pkg = Join-Path $work 'conpty.zip'
New-Item -ItemType Directory -Force $work | Out-Null

$url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/$Version/microsoft.windows.console.conpty.$Version.nupkg"
Write-Host "Downloading Microsoft.Windows.Console.ConPTY $Version ..."
Invoke-WebRequest -Uri $url -OutFile $pkg -UseBasicParsing
Expand-Archive -Path $pkg -DestinationPath (Join-Path $work 'pkg') -Force

$files = @(
    (Join-Path $work "pkg\runtimes\win-$arch\native\conpty.dll"),
    (Join-Path $work "pkg\build\native\runtimes\$arch\OpenConsole.exe")
)
foreach ($f in $files) {
    $sig = Get-AuthenticodeSignature $f
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "Refusing $(Split-Path $f -Leaf): signature is $($sig.Status) ($($sig.SignerCertificate.Subject))"
    }
    Copy-Item $f $Dest -Force
    Write-Host "  $(Split-Path $f -Leaf) -> $Dest (signed by Microsoft)"
}
Remove-Item $work -Recurse -Force
Write-Host 'Done. Restart Valentine to use it.'
