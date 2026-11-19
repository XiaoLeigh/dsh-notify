# dsh-notify.ps1 - show a Codex-style Windows toast and exit.
# ASCII-only on purpose: Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File dsh-notify.ps1 `
#     -Title "DSH" -Body "Task finished" -Sound default `
#     -IconPath "D:\DeepSeek Harness\DeepSeek Harness.exe" -Wav "C:\...\codex-notification.wav"
param(
  [string]$Title = 'DSH',
  [string]$Body  = 'Task finished',
  [string]$Sound = 'default',   # default | chime | none
  [string]$IconPath = '',
  [string]$Wav = ''
)

$ErrorActionPreference = 'SilentlyContinue'

# Registered AppUserModelID: an unpackaged process needs one before Windows
# accepts its toasts, otherwise the shell drops them silently.
$AppId = 'DeepSeek.Harness.Notify'
$Proto = 'dshnotify'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Esc([string]$s) {
  if ($null -eq $s) { return '' }
  $s = $s.Replace([string][char]38, '&amp;')
  $s = $s.Replace([string][char]60, '&lt;')
  $s = $s.Replace([string][char]62, '&gt;')
  $s = $s.Replace([string][char]34, '&quot;')
  $s = $s.Replace([string][char]39, '&apos;')
  return $s
}

function Get-ThemeIcon() {
  # The toast header shows the app icon over the toast background. Toasts follow
  # the *system* theme on Windows 11 (mixed mode is common: apps light, system
  # dark), so read SystemUsesLightTheme first and fall back to AppsUseLightTheme.
  $assets = Join-Path (Split-Path -Parent $Here) 'assets'
  $light = $null
  $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  foreach ($name in @('SystemUsesLightTheme', 'AppsUseLightTheme')) {
    try {
      $value = (Get-ItemProperty $personalize -Name $name -ErrorAction Stop).$name
      if ($null -ne $value) { $light = $value; break }
    } catch { }
  }
  $name = if ($light -eq 1) { 'whale-on-light.ico' } else { 'whale-on-dark.ico' }
  $candidate = Join-Path $assets $name
  if (Test-Path -LiteralPath $candidate) { return $candidate }
  return ''
}

function Ensure-AppId() {
  # Windows only *displays* toasts from an unpackaged process when a Start-menu
  # shortcut carries this AppUserModelID; the registry key alone is accepted but
  # never shown. ensure-appid.ps1 creates that shortcut once, and re-creates it
  # when the target/icon changes (tracked by a stamp file next to the shortcut).
  $programs = [Environment]::GetFolderPath('Programs')
  if (-not $programs) { $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
  $lnk = Join-Path $programs 'DeepSeek Harness.lnk'
  $stamp = Join-Path $programs '.dsh-notify.lnk.stamp'

  $icon = Get-ThemeIcon
  $target = if ($IconPath -and (Test-Path -LiteralPath $IconPath)) { $IconPath } else { $icon }
  if (-not $icon) { $icon = $target }

  $ticks = 0
  try { $ticks = (Get-Item -LiteralPath $icon -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { }
  $want = '{0}|{1}|{2}' -f $target, $icon, $ticks

  $have = ''
  try { if (Test-Path -LiteralPath $stamp) { $have = (Get-Content -LiteralPath $stamp -Raw).Trim() } } catch { }
  if ((Test-Path -LiteralPath $lnk) -and $have -eq $want) { return }

  $helper = Join-Path $Here 'ensure-appid.ps1'
  if (Test-Path -LiteralPath $helper) {
    & $helper -AppId $AppId -Target $target -Icon $icon -DisplayName 'DeepSeek Harness' -Force
    try { Set-Content -LiteralPath $stamp -Value $want -Encoding ASCII } catch { }
  }
  $script:ToastIcon = $icon
}

function Ensure-Protocol() {
  # Clicking the toast activates this URI, which restores the DSH window.
  $focus = Join-Path $Here 'focus-window.ps1'
  if (-not (Test-Path -LiteralPath $focus)) { return }
  $base = "HKCU:\Software\Classes\$Proto"
  if (-not (Test-Path $base)) { New-Item -Path $base -Force | Out-Null }
  Set-ItemProperty -Path $base -Name '(default)' -Value 'URL:DSH notify focus'
  Set-ItemProperty -Path $base -Name 'URL Protocol' -Value ''
  $cmdKey = "$base\shell\open\command"
  if (-not (Test-Path $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $cmd = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" "%1"' -f $ps, $focus
  Set-ItemProperty -Path $cmdKey -Name '(default)' -Value $cmd
}

function Audio-Xml() {
  if ($Sound -eq 'none') { return '<audio silent="true" />' }
  if ($Wav -and (Test-Path -LiteralPath $Wav)) {
    $uri = 'file:///' + ($Wav -replace '\\', '/')
    return ('<audio src="{0}" loop="false" />' -f (Esc $uri))
  }
  if ($Sound -eq 'chime') {
    return '<audio src="ms-winsoundevent:Notification.Looping.Alarm" loop="false" />'
  }
  return '<audio src="ms-winsoundevent:Notification.Default" loop="false" />'
}

$shown = $false
$setting = ''
$failure = ''
try {
  Ensure-AppId
  Ensure-Protocol
  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

  $xml = '<toast activationType="protocol" launch="{0}://focus"><visual><binding template="ToastGeneric"><text>{1}</text><text>{2}</text></binding></visual>{3}</toast>' -f `
    $Proto, (Esc $Title), (Esc $Body), (Audio-Xml)

  $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
  $doc.LoadXml($xml)
  $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
  $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)
  $setting = [string]$notifier.Setting
  $notifier.Show($toast)
  $shown = $true
} catch {
  $failure = $_.Exception.Message
}

# Compact breadcrumb so the host-side log can tell a suppressed toast from a
# failed one (integrity level matters: elevated vs medium changes behaviour).
try {
  $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
  $level = ($ident.Groups | Where-Object { $_.Value -like 'S-1-16-*' } | ForEach-Object { $_.Value }) -join ','
  $line = "diag: il={0} setting={1} shown={2} pid={3} temp={4} err={5}" -f $level, $setting, $shown, $PID, $env:TEMP, $failure
  $targets = @()
  if ($env:DSH_NOTIFY_LOG) { $targets += $env:DSH_NOTIFY_LOG }
  if ($env:TEMP) { $targets += (Join-Path $env:TEMP 'dsh-notify.log') }
  foreach ($t in $targets) {
    try { Add-Content -LiteralPath $t -Value $line -Encoding UTF8 } catch { }
  }
} catch { }

if (-not $shown) {
  # Fallback: tray balloon + system sound (works even where toasts are blocked).
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ($Sound -ne 'none') { [System.Media.SystemSounds]::Asterisk.Play() }
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $balloonIcon = $null
    if ($script:ToastIcon) {
      try { $balloonIcon = New-Object System.Drawing.Icon($script:ToastIcon) } catch { }
    }
    if ($balloonIcon) { $ni.Icon = $balloonIcon } else { $ni.Icon = [System.Drawing.SystemIcons]::Information }
    $ni.BalloonTipTitle = $Title
    $ni.BalloonTipText = $Body
    $ni.Visible = $true
    $ni.ShowBalloonTip(4000)
    Start-Sleep -Seconds 4
    $ni.Dispose()
  } catch {
    if ($Sound -ne 'none') { [System.Media.SystemSounds]::Exclamation.Play() }
  }
}