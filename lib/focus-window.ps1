# focus-window.ps1 - restore and focus the DeepSeek Harness window.
# Invoked by the dshnotify: URI that the toast carries as its click action.
$ErrorActionPreference = 'SilentlyContinue'

if (-not ('DshNotify.Window' -as [type])) {
  Add-Type -Namespace DshNotify -Name Window -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
'@
}

$target = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
  Select-Object -First 1

if ($null -eq $target) { exit 0 }

$handle = $target.MainWindowHandle
[void][DshNotify.Window]::ShowWindow($handle, 9)   # SW_RESTORE
[void][DshNotify.Window]::BringWindowToTop($handle)
[void][DshNotify.Window]::SetForegroundWindow($handle)