# ensure-appid.ps1 - make this app able to *display* Windows toasts.
#
# An unpackaged process needs a Start-menu shortcut whose System.AppUserModel.ID
# equals the AUMID it passes to CreateToastNotifier. Without that shortcut the
# shell accepts the toast (it shows up in the notification history) and then
# silently drops it, which is exactly the failure we hit.
#
# Creates the shortcut only when it is missing, so the cost is paid once.
# ASCII-only on purpose (PowerShell 5.1 reads BOM-less .ps1 as ANSI).
param(
  [string]$AppId = 'DeepSeek.Harness.Notify',
  [string]$Target = '',
  [string]$DisplayName = 'DeepSeek Harness',
  [string]$LinkName = 'DeepSeek Harness.lnk'
)

$ErrorActionPreference = 'Continue'

$src = @'
using System;
using System.Runtime.InteropServices;

namespace DshNotify
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class CShellLink { }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant
    {
        public ushort vt;
        public ushort r1;
        public ushort r2;
        public ushort r3;
        public IntPtr ptr;
        public IntPtr pad;
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    public interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    public interface IPropertyStore
    {
        uint GetCount();
        void GetAt(uint iProp, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, ref PropVariant pv);
        void SetValue(ref PROPERTYKEY key, ref PropVariant pv);
        void Commit();
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    public interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile(out IntPtr ppszFileName);
    }

    public static class Shortcut
    {
        const string PKEY_AppUserModel_ID = "9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3";

        public static void Create(string lnkPath, string target, string appId, string description)
        {
            var link = (IShellLinkW)new CShellLink();
            link.SetPath(target);
            link.SetDescription(description);
            link.SetIconLocation(target, 0);

            var store = (IPropertyStore)link;
            var key = new PROPERTYKEY();
            key.fmtid = new Guid(PKEY_AppUserModel_ID);
            key.pid = 5;

            var pv = new PropVariant();
            pv.vt = 31; // VT_LPWSTR
            pv.ptr = Marshal.StringToCoTaskMemUni(appId);
            try
            {
                store.SetValue(ref key, ref pv);
                store.Commit();
            }
            finally
            {
                Marshal.FreeCoTaskMem(pv.ptr);
            }

            ((IPersistFile)link).Save(lnkPath, true);
        }
    }
}
'@

$programs = [Environment]::GetFolderPath('Programs')
if (-not $programs) { $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
$lnk = Join-Path $programs $LinkName

# Display name / icon for the notification itself.
try {
  $key = "HKCU:\Software\Classes\AppUserModelId\$AppId"
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  Set-ItemProperty -Path $key -Name 'DisplayName' -Value $DisplayName
  if ($Target -and (Test-Path -LiteralPath $Target)) {
    Set-ItemProperty -Path $key -Name 'IconUri' -Value $Target
  }
} catch { }

if (Test-Path -LiteralPath $lnk) { exit 0 }

if (-not $Target) { $Target = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
try {
  Add-Type -TypeDefinition $src -Language CSharp | Out-Null
} catch {
  # Cannot compile: fall back to a plain shortcut without the AUMID property.
  try {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $Target
    $s.Description = $DisplayName
    $s.Save()
  } catch { }
  exit 0
}

try {
  [DshNotify.Shortcut]::Create($lnk, $Target, $AppId, "$DisplayName notifications")
} catch {
  # Never fail a notification because registration failed.
}