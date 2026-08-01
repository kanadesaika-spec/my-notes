# TRIARMS virtual office widget launcher
# Opens the office HTML in a small frameless browser window, moves it to a screen corner
# and pins it always-on-top. Run it again to re-pin the window that is already open.
#
# Usage: powershell -ExecutionPolicy Bypass -File office-widget.ps1 [-Width 420] [-Height 240] [-Corner BottomRight]
# (ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI when there is no BOM.)

param(
  [int]$Width  = 420,          # in browser DIP; the real window is larger on a scaled display
  [int]$Height = 240,
  [ValidateSet('BottomRight','BottomLeft','TopRight','TopLeft')]
  [string]$Corner = 'BottomRight',
  [int]$Margin = 20
)

$ErrorActionPreference = 'Stop'
$MARKER = 'TriarmsOfficeWidget'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TriarmsWin {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int  GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint c);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Get-WidgetProcess([string]$windowTitle) {
  if (-not $windowTitle) { return $null }
  # An --app window's caption is exactly the page <title>, so it is easy to tell apart
  # from a normal browser window (whose caption ends with " - Google Chrome" etc).
  return Get-Process -Name chrome,msedge -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -eq $windowTitle } |
         Select-Object -First 1
}

function Pin-Window([IntPtr]$hwnd, [int]$corner_x, [int]$corner_y, [int]$w, [int]$h) {
  $target = [TriarmsWin]::GetWindowThreadProcessId($hwnd, [IntPtr]::Zero)
  $mine   = [TriarmsWin]::GetCurrentThreadId()
  [void][TriarmsWin]::AttachThreadInput($mine, $target, $true)
  [void][TriarmsWin]::BringWindowToTop($hwnd)
  [void][TriarmsWin]::SetForegroundWindow($hwnd)
  $HWND_TOPMOST = [IntPtr](-1)
  [void][TriarmsWin]::SetWindowPos($hwnd, $HWND_TOPMOST, $corner_x, $corner_y, $w, $h, 0)
  [void][TriarmsWin]::AttachThreadInput($mine, $target, $false)
  Start-Sleep -Milliseconds 300
  $ex = [TriarmsWin]::GetWindowLong($hwnd, -20)
  return (($ex -band 0x8) -ne 0)
}

[void][TriarmsWin]::SetProcessDPIAware()

# --- locate the office html (the only .html file next to this script) and read its title ---
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$html = Get-ChildItem -LiteralPath $here -Filter '*.html' | Select-Object -First 1
if (-not $html) { Write-Host 'ERROR: no .html file found next to this script.' -ForegroundColor Red; exit 1 }
$pageTitle = ''
$raw = Get-Content -LiteralPath $html.FullName -Raw -Encoding UTF8
if ($raw -match '(?s)<title>(.*?)</title>') { $pageTitle = $Matches[1].Trim() }
if (-not $pageTitle) { Write-Host 'ERROR: could not read <title> from the html.' -ForegroundColor Red; exit 1 }

# --- reuse the window if the widget is already running ---
$existing = Get-WidgetProcess $pageTitle
if (-not $existing) {
  $uri = ([uri]$html.FullName).AbsoluteUri + '#widget'

  $candidates = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
  )
  $browser = $null
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $browser = $c; break } }
  if (-not $browser) { Write-Host 'ERROR: neither Chrome nor Edge was found.' -ForegroundColor Red; exit 1 }

  $profileDir = Join-Path $env:LOCALAPPDATA $MARKER
  $argList = @(
    "--app=$uri",
    "--user-data-dir=$profileDir",
    "--window-size=$Width,$Height",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-features=Translate,TranslateUI"
  )
  [void](Start-Process -FilePath $browser -ArgumentList $argList -PassThru)

  $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline -and -not $existing) {
    Start-Sleep -Milliseconds 600
    $existing = Get-WidgetProcess $pageTitle
  }
  if (-not $existing) { Write-Host 'NOTE: the window did not appear in time. Try running this again.' -ForegroundColor Yellow; exit 1 }
}

$hwnd = $existing.MainWindowHandle

# --- measure the real window size, then place it in the chosen corner of the work area ---
$rect = New-Object TriarmsWin+RECT
[void][TriarmsWin]::GetWindowRect($hwnd, [ref]$rect)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top

$work = New-Object TriarmsWin+RECT
[void][TriarmsWin]::SystemParametersInfo(0x0030, 0, [ref]$work, 0)   # SPI_GETWORKAREA

switch ($Corner) {
  'BottomRight' { $x = $work.Right - $w - $Margin; $y = $work.Bottom - $h - $Margin }
  'BottomLeft'  { $x = $work.Left  + $Margin;      $y = $work.Bottom - $h - $Margin }
  'TopRight'    { $x = $work.Right - $w - $Margin; $y = $work.Top    + $Margin }
  'TopLeft'     { $x = $work.Left  + $Margin;      $y = $work.Top    + $Margin }
}

# the very first attempt can fail while the window is still initialising, so retry a few times
$pinned = $false
for ($i = 0; $i -lt 6 -and -not $pinned; $i++) {
  if ($i -gt 0) { Start-Sleep -Milliseconds 700 }
  $pinned = Pin-Window $hwnd $x $y $w $h
}
if ($pinned) {
  Write-Host "OK: office widget pinned on top at ${x},${y} (${w}x${h})." -ForegroundColor Green
} else {
  Write-Host 'NOTE: the window is open but could not be pinned on top. Run this script again.' -ForegroundColor Yellow
}
