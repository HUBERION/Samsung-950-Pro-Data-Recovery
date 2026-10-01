<#
.SYNOPSIS
    Rescues files from a dying disk that only works for a short time after power-on - read-only,
    incremental and resumable, in an automatic wait - copy - resume loop.

.DESCRIPTION
    Made for drives that are still detected but read only for seconds to minutes after power-on, then hang
    or drop off the bus, and come back after a power cycle (for example unplugging a USB enclosure).
    A plain copy (Explorer, robocopy) wastes those short windows: it starts big files that never finish
    and starts over after every failure.

    This script:
      - waits for the disk, makes it read-only, mounts its data partition, and copies until the disk
        drops out; then waits for it to come back and continues exactly where it stopped;
      - remembers everything in <Target>\_state: the complete file list of every area it has listed,
        every finished file, and how far big files got (it resumes inside a file; the position is
        saved every 8 MB);
      - copies in a useful order: the configured "Front" files and folders first (in full), then the
        configured "Areas" in their order, then the rest of the partition; within an area small files
        first, media/disk images and "Late" folders last; files above -BigMB in a final pass;
      - never writes to the disk itself, and makes it read-only before mounting it (Windows remembers this
        for the disk), so that Windows does not write to it either; it reads with read-only handles and
        writes only below the target folder;
      - shows at once when the disk stops answering, instead of staying silent until Windows gives up,
        and asks you to unplug and replug the disk when that is needed (see README).

    Read the README (English: README.md, German: README.de.md) before the first run.

.PARAMETER Config
    PowerShell data file (.psd1) with the settings. Default: rescue-config.psd1 next to this script, if
    it exists. See rescue-config.example.psd1. Settings given on the command line override the file.

.PARAMETER Model
    Regular expression matched against "vendor product" of the disks, to find the disk to rescue
    (for example 'SSD 950'). Use -ListDisks to see the strings. The system disk and the disk holding the
    target are never used, and more than one match is refused.

.PARAMETER Target
    Folder on ANOTHER physical disk that receives the copies (same folder layout as on the rescued
    partition) and the state (_state) and log (rescue.log).

.PARAMETER Letter
    Drive letter used for the rescued partition if it has none. Default R.

.PARAMETER First
    Extra areas (folders relative to the partition root) to rescue before the configured areas.

.PARAMETER BigMB
    Files larger than this (MB) are copied in a final pass, after all smaller files. Default 500.

.PARAMETER HangSeconds
    After this many seconds without an answer from the disk, the script reacts (message, request to
    replug, or with -PortRestart a USB port restart). 0 = never. Default 5.

.PARAMETER WaitSeconds
    How long to wait for the disk to appear; 0 = forever (default). The autostart task uses 240.

.PARAMETER PortRestart
    Experimental: instead of asking to replug, first restart the disk's USB port, then switch the USB
    device off for -OffSeconds and on again. It did not revive the SSD this script was written for (the
    power stays on); see README.

.PARAMETER OffSeconds
    With -PortRestart: how long the USB device stays switched off. Default 5.

.PARAMETER TestSource
    Test mode: copy from this normal folder instead of a disk. Needs no administrator rights and runs
    one cycle.

.PARAMETER ListDisks
    Show the physical disks with the strings -Model is matched against, and exit.

.PARAMETER Prepare
    Once, before the dying disk is connected: switch automatic mounting of new volumes off (mountvol /N)
    and forget drive letters of volumes that are not present (mountvol /R), so that Windows does not
    mount (and write to) the disk before the script has made it read-only.

.PARAMETER InstallAutostart
    Register a scheduled task that runs this script as SYSTEM at every boot (for disks in an internal
    slot that must be read immediately after power-on). Needs a config file.

.PARAMETER RemoveAutostart
    Remove the scheduled task again.

.PARAMETER Finish
    At the very end: remove the scheduled task and switch automatic mounting on again (mountvol /E).

.EXAMPLE
    .\Rescue-Disk.ps1 -ListDisks
    Shows the disks and their model strings.

.EXAMPLE
    .\Rescue-Disk.ps1 -Prepare
    Once, in an administrator PowerShell, before connecting the dying disk.

.EXAMPLE
    .\Rescue-Disk.ps1 -Model 'SSD 950' -Target 'E:\Rescue'
    The rescue loop. Leave the window open; Ctrl+C stops it (best while it waits for the disk).

.EXAMPLE
    .\Rescue-Disk.ps1 -TestSource C:\SomeFolder -Target C:\Temp\RescueTest
    Test run without a disk and without administrator rights.

.NOTES
    Never confirm chkdsk, "Scan and repair", formatting or initializing of the dying disk.
    Windows PowerShell 5.1 on Windows 10/11. License: MIT (see LICENSE).
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$Model,
    [string]$Target,
    [char]$Letter,
    [string[]]$First,
    [int]$BigMB,
    [int]$HangSeconds,
    [int]$WaitSeconds,
    [switch]$PortRestart,
    [int]$OffSeconds,
    [string]$TestSource,
    [switch]$ListDisks,
    [switch]$Prepare,
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart,
    [switch]$Finish
)
$ErrorActionPreference = 'Stop'
$TaskName = 'DiskRescue'

# --- Settings: built-in defaults < config file < command line --------------------------------------------
$settings = [ordered]@{
    Model          = $null       # regex against "vendor product" of the disk (see -ListDisks)
    Target         = $null       # folder on another disk for the copies, the state and the log
    Letter         = 'R'         # drive letter for the rescued partition if it has none
    Areas          = @()         # folders (relative to the partition root) to rescue first, in this order
    Front          = @()         # files, or folders ending in "\", copied first in every cycle, in full
    Late           = @{}         # folder -> rank 1..9: copied after everything else of its area
    Exclude        = @()         # folders that are not rescued at all
    SkipDirs       = @('node_modules', '.venv', 'venv', '__pycache__', 'obj', '.next', '.pytest_cache', '.mypy_cache')
    SkipRootDirs   = @()         # more folders in the partition root that are not rescued
    LateExtensions = '\.(wmv|mp4|avi|mkv|mov|mpg|iso|vhdx?|vmdk|ova)$'   # copied after the other files of an area
    BigMB          = 500         # files above this size come in a final pass
    HangSeconds    = 5           # react after this many seconds without an answer (0 = never)
    WaitSeconds    = 0           # how long to wait for the disk (0 = forever)
    PortRestart    = $false      # experimental USB port restart / device off-on instead of asking to replug
    OffSeconds     = 5           # with PortRestart: how long the USB device stays off
    BitLockerKeyFile = $null     # text file with the 48-digit BitLocker recovery password, if needed (keep it private)
}
if (-not $Config) {
    $defaultConfig = Join-Path $PSScriptRoot 'rescue-config.psd1'
    if (Test-Path -LiteralPath $defaultConfig) { $Config = $defaultConfig }
}
# Windows PowerShell reads a file without BOM in the ANSI code page, but Notepad saves UTF-8 without BOM: umlauts in
# paths would come out garbled. Such a file is therefore read as UTF-8 (through a temporary copy with BOM).
function Import-Config([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    $read = $path
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) -or
           ($b.Length -ge 2 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF)))
    $nonAscii = $false
    foreach ($x in $b) { if ($x -ge 0x80) { $nonAscii = $true; break } }
    if (-not $bom -and $nonAscii) {
        $text = $null
        try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($b) } catch { }   # not UTF-8: ANSI after all
        if ($null -ne $text) {
            $read = Join-Path ([IO.Path]::GetTempPath()) ('rescue-config-' + [Guid]::NewGuid().ToString('N') + '.psd1')
            [IO.File]::WriteAllText($read, $text, (New-Object Text.UTF8Encoding($true)))
        }
    }
    try { return Import-PowerShellDataFile -LiteralPath $read }
    catch { throw "Cannot read the configuration file $path : $($_.Exception.Message)" }
    finally { if ($read -ne $path) { Remove-Item -LiteralPath $read -ErrorAction SilentlyContinue } }
}
if ($Config) {
    $Config = (Resolve-Path -LiteralPath $Config).ProviderPath
    $cfg = Import-Config $Config
    foreach ($k in $cfg.Keys) {
        if (-not $settings.Contains($k)) { throw "Unknown setting '$k' in $Config." }
        $settings[$k] = $cfg[$k]
    }
}
foreach ($k in @($PSBoundParameters.Keys)) { if ($settings.Contains($k)) { $settings[$k] = $PSBoundParameters[$k] } }
$Model = $settings.Model
$Target = $settings.Target
$Letter = [char]([string]$settings.Letter).ToUpperInvariant()
$BigMB = [int]$settings.BigMB
$HangSeconds = [int]$settings.HangSeconds
$WaitSeconds = [int]$settings.WaitSeconds
$PortRestart = [bool]$settings.PortRestart
$OffSeconds = [int]$settings.OffSeconds
if ($Letter -lt [char]'D' -or $Letter -gt [char]'Z') { throw "Letter must be a drive letter from D to Z, not '$Letter'." }
# Paths in the settings are relative to the root of the rescued partition. With a drive letter, the source and the copy
# would be the same file, and the copy would overwrite it - so refuse such paths before anything happens.
foreach ($p in @($settings.Areas) + @($First) + @($settings.Front) + @($settings.Exclude) + @($settings.SkipRootDirs) + @($settings.Late.Keys)) {
    if ($null -eq $p) { continue }
    $r = ([string]$p).Trim().Trim('\', '/')
    if ($r -eq '' -or $r.Contains(':') -or $r -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "'$p' in the settings is not a path relative to the root of the rescued partition (without drive letter, for example 'Users\anna\Documents')."
    }
}

# --- Helpers in C#: detection, attributes, sign of life, copying with resume, watchdog, work lists ---------
# Add-Type works once per PowerShell session. If an older version of these classes is still loaded, the old
# code would run silently - so stop right away.
if ('RescueDisk' -as [type]) {
    if ([RescueDisk]::Version -ne 1) {
        throw 'An older version of this script is still loaded in this PowerShell window: type "exit", start "powershell" again and rerun the script.'
    }
} else { Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class RescueDisk {
    public const int Version = 2;           // raise whenever the C# code changes (see the check above Add-Type)

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr overlapped);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint mode);

    // QuickEdit off for this console: otherwise a click into the window starts a selection, and the next
    // console output blocks the whole script (wasting the disk's short uptime) until Esc is pressed.
    static uint savedMode;
    static bool modeChanged;
    public static bool QuickEditOff() {
        IntPtr h = GetStdHandle(-10);                               // STD_INPUT_HANDLE
        uint mode;
        if (!GetConsoleMode(h, out mode) || (mode & 0x40) == 0) return false;   // no console, or already off
        if (!SetConsoleMode(h, (mode | 0x80) & ~0x40u)) return false;           // EXTENDED_FLAGS on, QUICK_EDIT off
        savedMode = mode;
        modeChanged = true;
        return true;
    }
    public static void RestoreConsole() {
        if (modeChanged) { SetConsoleMode(GetStdHandle(-10), savedMode); modeChanged = false; }
    }

    // Handle with access mask 0: allows queries only, no reading or writing of data.
    static SafeFileHandle Open(string path) { return CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero); }

    // Vendor + product (IOCTL_STORAGE_QUERY_PROPERTY); null if the disk does not exist.
    public static string Product(int n) {
        using (SafeFileHandle h = Open(@"\\.\PhysicalDrive" + n)) {
            if (h.IsInvalid) return null;
            byte[] query = new byte[12];            // StorageDeviceProperty, PropertyStandardQuery
            byte[] buf = new byte[1024];
            int got;
            if (!DeviceIoControl(h, 0x002D1400, query, query.Length, buf, buf.Length, out got, IntPtr.Zero)) return "";
            return (Str(buf, BitConverter.ToInt32(buf, 12)) + " " + Str(buf, BitConverter.ToInt32(buf, 16))).Trim();
        }
    }

    // Disk attributes (IOCTL_DISK_GET_DISK_ATTRIBUTES): bit 0 offline, bit 1 read-only; negative on error.
    public static long Attributes(int n) {
        using (SafeFileHandle h = Open(@"\\.\PhysicalDrive" + n)) {
            if (h.IsInvalid) return -1;
            byte[] buf = new byte[16];
            int got;
            if (!DeviceIoControl(h, 0x000700F0, null, 0, buf, buf.Length, out got, IntPtr.Zero)) return -2;
            return BitConverter.ToInt64(buf, 8);
        }
    }

    // Physical disk numbers a drive letter lives on (IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS); empty if unknown.
    public static int[] DisksOfVolume(char letter) {
        using (SafeFileHandle h = Open(@"\\.\" + letter + ":")) {
            if (h.IsInvalid) return new int[0];
            byte[] buf = new byte[8 + 24 * 32];     // NumberOfDiskExtents, then DISK_EXTENT { DiskNumber, StartingOffset, ExtentLength }
            int got;
            if (!DeviceIoControl(h, 0x00560000, null, 0, buf, buf.Length, out got, IntPtr.Zero)) return new int[0];
            List<int> disks = new List<int>();
            int n = BitConverter.ToInt32(buf, 0);
            for (int i = 0; i < n && 8 + 24 * i + 4 <= got; i++) {
                int d = BitConverter.ToInt32(buf, 8 + 24 * i);
                if (!disks.Contains(d)) disks.Add(d);
            }
            return disks.ToArray();
        }
    }

    // Can the first 4 KiB be read within timeoutMs? 1 = yes, 0 = error, -1 = no answer (hangs).
    // Read-only handle. Reads synchronously on a worker thread: an asynchronous FileStream takes the "file
    // length" of a raw disk as 0 and reads nothing. A hanging read (and its thread) is left behind.
    public static int Check(int n, int timeoutMs) {
        FileStream fs;
        try { fs = new FileStream(@"\\.\PhysicalDrive" + n, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1); }
        catch { return 0; }
        byte[] buf = new byte[4096];
        System.Threading.Tasks.Task<int> t = System.Threading.Tasks.Task.Run(() => fs.Read(buf, 0, buf.Length));
        bool finished;
        try { finished = t.Wait(timeoutMs); }
        catch { fs.Dispose(); return 0; }                      // the read failed
        if (!finished) return -1;
        fs.Dispose();
        return t.Result == buf.Length ? 1 : 0;
    }
    public static bool Probe(int n, int timeoutMs) { return Check(n, timeoutMs) > 0; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FindData {
        public uint Attributes, Created1, Created2, Accessed1, Accessed2, Written1, Written2, SizeHigh, SizeLow, Reserved0, Reserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string ShortName;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstFileW(string name, out FindData data);
    [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr h);

    // Reparse tag of a file or folder (WIN32_FIND_DATA.dwReserved0); 0 = none, 0xFFFFFFFF = could not be read.
    // Tags with bit 29 are name surrogates: symbolic links, junctions, mount points.
    public static uint ReparseTag(string path) {
        FindData d;
        IntPtr h = FindFirstFileW(path, out d);
        if (h == new IntPtr(-1)) return 0xFFFFFFFF;
        FindClose(h);
        return (d.Attributes & 0x400) != 0 ? d.Reserved0 : 0;
    }

    static string Str(byte[] b, int off) {
        if (off <= 0 || off >= b.Length) return "";
        int end = off;
        while (end < b.Length && b[end] != 0) end++;
        return System.Text.Encoding.ASCII.GetString(b, off, end - off).Trim();
    }
}

public class CopyFailed : Exception {
    public long Offset;
    public CopyFailed(long offset, Exception inner) : base(inner.Message, inner) { Offset = offset; }
}

// Where the disk hangs on the USB, and restarting that port: IOCTL_USB_HUB_CYCLE_PORT makes the hub drop the
// device and enumerate it again, as if it had been unplugged and plugged in (only the USB side; the port power
// stays on). Before that, the port is checked to still carry the same device (vendor/product ID).
public static class UsbPort {
    public class Info {
        public string Hub;      // device path of the hub (GUID_DEVINTERFACE_USB_HUB)
        public int Port;        // port number on that hub (1-based)
        public int Vid, Pid;    // USB IDs of the enclosure
        public string Device;   // instance ID of the enclosure
        public bool SuperSpeed; // runs at USB 3 speed (then the bridge tends not to restart the disk by itself)
    }

    static Guid DiskClass = new Guid("53f56307-b6bf-11d0-94f2-00a0c91efb8b");
    static Guid HubClass = new Guid("f18a0e88-c30c-11d0-8815-00a0c906bed8");

    [StructLayout(LayoutKind.Sequential)]
    struct DevPropKey { public Guid Fmtid; public int Pid; }
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TokenPrivilege { public int Count; public long Luid; public int Attributes; }

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_Interface_List_SizeW(out int len, ref Guid cls, string devId, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_Interface_ListW(ref Guid cls, string devId, char[] buf, int len, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_Interface_PropertyW(string iface, ref DevPropKey key, out int type, byte[] buf, ref int size, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out int devInst, string devId, int flags);
    [DllImport("cfgmgr32.dll")]
    static extern int CM_Get_Parent(out int parent, int devInst, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_IDW(int devInst, char[] buf, int len, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_DevNode_Registry_PropertyW(int devInst, int prop, out int type, byte[] buf, ref int size, int flags);
    [DllImport("cfgmgr32.dll")]
    static extern int CM_Disable_DevNode(int devInst, int flags);
    [DllImport("cfgmgr32.dll")]
    static extern int CM_Enable_DevNode(int devInst, int flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr overlapped);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivilege state, int len, IntPtr prev, IntPtr prevLen);

    static string[] Interfaces(Guid cls, string devId) {
        int len;
        if (CM_Get_Device_Interface_List_SizeW(out len, ref cls, devId, 0) != 0 || len <= 1) return new string[0];
        char[] buf = new char[len];
        if (CM_Get_Device_Interface_ListW(ref cls, devId, buf, len, 0) != 0) return new string[0];
        return new string(buf).Split(new char[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
    }

    static string DeviceId(int devInst) {
        char[] buf = new char[400];
        if (CM_Get_Device_IDW(devInst, buf, buf.Length, 0) != 0) return null;
        int end = Array.IndexOf(buf, '\0');
        return new string(buf, 0, end < 0 ? buf.Length : end);
    }

    // Instance ID of \\.\PhysicalDriveN: the disk interface whose device number is N (query-only handles).
    static string DiskInstance(int disk) {
        foreach (string path in Interfaces(DiskClass, null)) {
            using (SafeFileHandle h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                if (h.IsInvalid) continue;
                byte[] num = new byte[12];
                int got;
                // IOCTL_STORAGE_GET_DEVICE_NUMBER: DeviceType, DeviceNumber, PartitionNumber
                if (!DeviceIoControl(h, 0x2D1080, null, 0, num, num.Length, out got, IntPtr.Zero)) continue;
                if (BitConverter.ToInt32(num, 4) != disk) continue;
            }
            DevPropKey key = new DevPropKey();
            key.Fmtid = new Guid("78c34fc8-104a-4aca-9ea4-524d52996e57");   // DEVPKEY_Device_InstanceId
            key.Pid = 256;
            byte[] buf = new byte[1024];
            int size = buf.Length, type;
            if (CM_Get_Device_Interface_PropertyW(path, ref key, out type, buf, ref size, 0) != 0) return null;
            return Encoding.Unicode.GetString(buf, 0, size).TrimEnd('\0');
        }
        return null;
    }

    // The USB port the disk hangs on; null if it is not connected via USB.
    public static Info Find(int disk) {
        string id = DiskInstance(disk);
        int node;
        if (id == null || CM_Locate_DevNodeW(out node, id, 0) != 0) return null;
        for (int depth = 0; depth < 8; depth++) {
            int parent;
            if (CM_Get_Parent(out parent, node, 0) != 0) return null;
            string parentId = DeviceId(parent);
            string[] hub = parentId == null ? new string[0] : Interfaces(HubClass, parentId);
            if (hub.Length > 0) {
                // 'node' sits directly on this hub; for USB devices the address is the port number
                string dev = DeviceId(node);
                Match m = Regex.Match(dev ?? "", @"^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase);
                byte[] buf = new byte[4];
                int size = 4, type;
                if (!m.Success || CM_Get_DevNode_Registry_PropertyW(node, 0x1D, out type, buf, ref size, 0) != 0) return null;   // CM_DRP_ADDRESS
                Info i = new Info();
                i.Hub = hub[0];
                i.Port = BitConverter.ToInt32(buf, 0);
                i.Vid = Convert.ToInt32(m.Groups[1].Value, 16);
                i.Pid = Convert.ToInt32(m.Groups[2].Value, 16);
                i.Device = dev;
                i.SuperSpeed = IsSuperSpeed(i.Hub, i.Port);
                return i.Port > 0 ? i : null;
            }
            node = parent;
        }
        return null;
    }

    // IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX_V2: does the device on the port run at USB 3 speed?
    static bool IsSuperSpeed(string hub, int port) {
        using (SafeFileHandle h = CreateFile(hub, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return false;
            byte[] v = new byte[16];                        // ConnectionIndex, Length, SupportedUsbProtocols, Flags
            BitConverter.GetBytes(port).CopyTo(v, 0);
            BitConverter.GetBytes(16).CopyTo(v, 4);
            BitConverter.GetBytes(7).CopyTo(v, 8);
            int got;
            if (!DeviceIoControl(h, 0x22045C, v, v.Length, v, v.Length, out got, IntPtr.Zero)) return false;
            return (BitConverter.ToInt32(v, 12) & 5) != 0;  // operating at SuperSpeed or SuperSpeedPlus
        }
    }

    // Switches the USB device off for 'seconds' and on again. While it is disabled the hub suspends it; a
    // bus-powered USB bridge might then switch the disk off (suspend current) - unlike a port restart, where the
    // disk keeps its power. Not persistent: replugging brings the device back enabled in any case.
    // null = done, otherwise the reason.
    public static string OffOn(Info p, int seconds) {
        int node;
        int cr = CM_Locate_DevNodeW(out node, p.Device, 0);
        if (cr != 0) return "USB device not found (CONFIGRET " + cr + ")";
        cr = CM_Disable_DevNode(node, 4);                   // CM_DISABLE_UI_NOT_OK
        if (cr == 0x17) return "Windows does not allow switching it off, the device is in use (CR_REMOVE_VETOED)";
        if (cr != 0) return "switching off failed (CONFIGRET " + cr + ")";
        System.Threading.Thread.Sleep(seconds * 1000);
        for (int i = 0; i < 5; i++) {
            cr = CM_Enable_DevNode(node, 0);
            if (cr == 0) return null;
            System.Threading.Thread.Sleep(1000);
        }
        return "SWITCHING ON AGAIN FAILED (CONFIGRET " + cr + ") - please unplug the USB cable and plug it in again";
    }

    static SafeFileHandle OpenHub(string path) {
        SafeFileHandle h = CreateFile(path, 0x40000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);     // GENERIC_WRITE
        if (!h.IsInvalid) return h;
        h.Dispose();
        return CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    }

    static bool EnablePrivilege(string name) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return false;   // TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY
        try {
            TokenPrivilege tp = new TokenPrivilege();
            tp.Count = 1;
            tp.Attributes = 2;                                                     // SE_PRIVILEGE_ENABLED
            if (!LookupPrivilegeValue(null, name, out tp.Luid)) return false;
            return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero) && Marshal.GetLastWin32Error() == 0;
        } finally {
            CloseHandle(token);
        }
    }

    // Restarts the port like unplugging and plugging in, but only if the same device is still on it.
    // 0 = restarted; 1 = is being set up again anyway; 2 = not now (reason); 3 = refused by Windows (reason).
    public static int Cycle(Info p, out string reason) {
        reason = null;
        using (SafeFileHandle h = OpenHub(p.Hub)) {
            if (h.IsInvalid) { reason = "cannot open the USB hub (error " + Marshal.GetLastWin32Error() + ")"; return 2; }
            byte[] b = new byte[512];
            BitConverter.GetBytes(p.Port).CopyTo(b, 0);
            int got;
            // IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX: device descriptor (IDs at 12/14), status at 31
            if (!DeviceIoControl(h, 0x220448, b, b.Length, b, b.Length, out got, IntPtr.Zero)) {
                reason = "cannot query USB port " + p.Port + " (error " + Marshal.GetLastWin32Error() + ")";
                return 2;
            }
            int vid = BitConverter.ToUInt16(b, 12), pid = BitConverter.ToUInt16(b, 14), status = BitConverter.ToInt32(b, 31);
            if (status == 0) { reason = "nothing is plugged into USB port " + p.Port + " any more"; return 2; }
            if (status == 9 || status == 10) return 1;                   // enumerating / resetting right now
            if (status == 1 && (vid != p.Vid || pid != p.Pid)) {
                reason = string.Format("another device is on USB port {0} now (VID_{1:X4}&PID_{2:X4})", p.Port, vid, pid);
                return 2;
            }
            byte[] c = new byte[8];                                       // USB_CYCLE_PORT_PARAMS: ConnectionIndex, StatusReturned
            BitConverter.GetBytes(p.Port).CopyTo(c, 0);
            if (DeviceIoControl(h, 0x220444, c, c.Length, c, c.Length, out got, IntPtr.Zero)) return 0;   // IOCTL_USB_HUB_CYCLE_PORT
            int err = Marshal.GetLastWin32Error();
            if (err == 5 && EnablePrivilege("SeLoadDriverPrivilege")) {  // access denied: try once more with this privilege on
                BitConverter.GetBytes(p.Port).CopyTo(c, 0);
                if (DeviceIoControl(h, 0x220444, c, c.Length, c, c.Length, out got, IntPtr.Zero)) return 0;
                err = Marshal.GetLastWin32Error();
            }
            reason = string.Format("Windows refuses, error {0}: {1}", err, new System.ComponentModel.Win32Exception(err).Message);
            return err == 433 ? 2 : 3;                                    // 433: no device there at the moment
        }
    }
}

// Watchdog: when the disk stops answering in the middle of a read or a directory listing, say so on the console
// at once instead of staying silent until Windows gives up (about 40 s in our case). What happens after
// 'hang' seconds depends on the connection (see Tick). The recovery steps Restart and PowerCycle (only with
// -PortRestart) are each done once, until the disk delivers data again. Messages go to the console at once;
// TakeLog() hands them over for rescue.log.
public static class DiskWatch {
    public static DateTime Boot = DateTime.Now;     // for "since boot" in log lines
    public static bool AutoRestart = false;

    static readonly object gate = new object(), con = new object();
    static readonly ConcurrentQueue<string> notes = new ConcurrentQueue<string>();
    static System.Threading.Timer timer;
    static string what;                             // current disk operation; null = none, watchdog quiet
    static long since = DateTime.UtcNow.Ticks;      // start of the current wait (UTC ticks)
    static long data = DateTime.UtcNow.Ticks;       // last time the disk delivered something
    static long action;                             // UTC ticks of the last recovery step; 0 = none pending
    static int reported, hangSeconds;
    static bool acted, cycled, powered;
    static UsbPort.Info port;                       // USB port of the disk, found when it appeared

    public static void Start(int hang) {
        hangSeconds = hang;
        if (timer == null) timer = new System.Threading.Timer(Tick, null, 1000, 1000);
    }
    public static void Busy(string label) { lock (gate) { what = label; since = DateTime.UtcNow.Ticks; reported = 0; acted = false; } }
    public static void Alive() { lock (gate) { since = data = DateTime.UtcNow.Ticks; reported = 0; acted = cycled = powered = false; action = 0; } }
    public static void Idle() { lock (gate) { what = null; } }
    public static DateTime LastData { get { lock (gate) { return new DateTime(data, DateTimeKind.Utc).ToLocalTime(); } } }
    // The disk reads again: the recovery steps may be used again the next time it hangs.
    public static void Recovered() { lock (gate) { cycled = powered = false; action = 0; } }
    // Seconds since the last recovery step that has not led to a readable disk yet; -1 = none.
    public static double SecondsSinceAction { get { lock (gate) { return action == 0 ? -1 : (DateTime.UtcNow.Ticks - action) / 1e7; } } }
    // Connected via USB at USB 2 speed (then the bridge often restarts the disk by itself).
    public static bool Usb2 { get { lock (gate) { return port != null && !port.SuperSpeed; } } }

    // The disk is (back) at PhysicalDrive<disk>: remember its USB port. Returns a description, null if not USB.
    public static string Attach(int disk) {
        UsbPort.Info p = null;
        try { p = UsbPort.Find(disk); } catch { }
        lock (gate) { port = p; }
        return p == null ? null : string.Format("USB port {0}, {1}, VID_{2:X4}&PID_{3:X4}", p.Port, p.SuperSpeed ? "USB 3" : "USB 2", p.Vid, p.Pid);
    }

    // Step 1: restart the disk's USB port. Ends hanging reads at once; the disk itself keeps its power, though.
    public static bool Restart(string why) {
        UsbPort.Info p;
        lock (gate) {
            if (!AutoRestart || port == null || cycled) return false;
            cycled = true;
            action = DateTime.UtcNow.Ticks;
            p = port;
        }
        string reason;
        int r;
        try { r = UsbPort.Cycle(p, out reason); } catch (Exception e) { r = 2; reason = e.Message; }
        if (r == 0) Note(string.Format("The disk {0}: restarted its USB port (port {1}).", why, p.Port), ConsoleColor.Yellow);
        else if (r == 2) Note("No USB port restart: " + reason, ConsoleColor.Yellow);
        else if (r == 3) {
            AutoRestart = false;
            Note("Automatic USB port restart is not possible (" + reason + ") - from now on manual only.", ConsoleColor.Yellow);
        }
        return r <= 1;
    }

    // Step 2: switch the USB device off for some seconds and on again, in the hope that the disk loses power.
    public static bool PowerCycle(string why, int seconds) {
        UsbPort.Info p;
        lock (gate) {
            if (!AutoRestart || port == null || powered) return false;
            powered = true;
            action = DateTime.UtcNow.Ticks;
            p = port;
        }
        Note(string.Format("The disk {0}: switching the USB device off for {1} s ...", why, seconds), ConsoleColor.Yellow);
        string reason;
        try { reason = UsbPort.OffOn(p, seconds); } catch (Exception e) { reason = e.Message; }
        lock (gate) { action = DateTime.UtcNow.Ticks; }
        Note(reason == null ? "... and on again." : "Switching off and on failed: " + reason, ConsoleColor.Yellow);
        return reason == null;
    }

    static void Tick(object state) {
        string label;
        int secs;
        bool act = false;
        lock (gate) {
            if (what == null) return;
            secs = (int)((DateTime.UtcNow.Ticks - since) / TimeSpan.TicksPerSecond);
            if (hangSeconds > 0 && secs >= hangSeconds && !acted) { acted = true; act = true; }
            if (!act && secs < reported + 3) return;    // one line every 3 s, and one when it is time to react
            reported = secs;
            label = what.Length <= 70 ? what : "..." + what.Substring(what.Length - 67);
        }
        lock (con) Console.WriteLine(string.Format("    {0:HH:mm:ss}  disk has not answered for {1} s ({2})", DateTime.Now, secs, label));
        if (!act) return;
        if (Usb2) Note("The disk hangs - over USB 2 the USB bridge usually restarts it by itself, please wait a moment.", ConsoleColor.Yellow);
        else if (!(AutoRestart && Restart("has been hanging for " + secs + " s")))
            Note("The disk hangs: please unplug it and plug it in again - the rescue continues exactly where it stopped.", ConsoleColor.Yellow);
    }

    // A message for the console (now) and for rescue.log (written by the script's Log function).
    static void Note(string msg, ConsoleColor color) {
        string line = string.Format("{0:HH:mm:ss} (+{1,4:N0}s since boot) {2}", DateTime.Now, (DateTime.Now - Boot).TotalSeconds, msg);
        notes.Enqueue(line);
        lock (con) {
            ConsoleColor old = Console.ForegroundColor;
            Console.ForegroundColor = color;
            Console.WriteLine(line);
            Console.ForegroundColor = old;
        }
    }
    public static string[] TakeLog() {
        List<string> l = new List<string>();
        string s;
        while (notes.TryDequeue(out s)) l.Add(s);
        return l.ToArray();
    }
}

public class QueueEntry {
    public string Rel;
    public long Size, Mtime;
    public int Group;       // copy order: rank of the folder (see RescueQueue.SetLate) * 2, +1 for LateExtensions
}

// Work list of one area: the files of its inventory that are not done yet and do not belong to a deeper area of
// the plan, in copy order (Group, then size, then path). Files already on the target with the same size and date
// (for example from an earlier robocopy) go to 'present' instead, for the script to mark them done without
// reading them again.
public static class RescueQueue {
    static string[] latePrefixes = new string[0];
    static int[] lateRanks = new int[0];

    // Folders to copy late: 'prefixes[i]' (relative path of a folder) gets rank 'ranks[i]' (0 = normal).
    // The first matching prefix wins, so pass the most specific (longest) ones first.
    public static void SetLate(string[] prefixes, int[] ranks) { latePrefixes = prefixes; lateRanks = ranks; }

    public static int Rank(string rel) {
        for (int i = 0; i < latePrefixes.Length; i++)
            if (rel.StartsWith(latePrefixes[i] + "\\", StringComparison.OrdinalIgnoreCase)) return lateRanks[i];
        return 0;
    }

    // Has the listing of this area been finished (end marker "E" in the inventory)?
    public static bool IsComplete(string invFile) {
        if (!File.Exists(invFile)) return false;
        foreach (string l in File.ReadLines(invFile, Encoding.UTF8))
            if (l.Length > 0 && l[0] == 'E' && (l.Length == 1 || l[1] == '\t')) return true;
        return false;
    }

    // How many entries of a work list are not done yet, and their size.
    public static int Open(QueueEntry[] q, HashSet<string> done, out long bytes) {
        int n = 0;
        bytes = 0;
        foreach (QueueEntry e in q) if (!done.Contains(e.Rel)) { n++; bytes += e.Size; }
        return n;
    }

    public static QueueEntry[] Build(string invFile, string rootRel, HashSet<string> done, HashSet<string> plan,
                                     string target, string lateExt, List<QueueEntry> present) {
        // Later lines win (a folder listed twice counts with its latest listing).
        Dictionary<string, QueueEntry> files = new Dictionary<string, QueueEntry>(StringComparer.OrdinalIgnoreCase);
        foreach (string line in File.ReadLines(invFile, Encoding.UTF8)) {
            string[] p = line.Split('\t');
            if (p.Length < 4 || p[0] != "F") continue;
            QueueEntry e = new QueueEntry();
            e.Rel = p[1];
            e.Size = long.Parse(p[2]);
            e.Mtime = long.Parse(p[3]);
            files[e.Rel] = e;
        }
        Regex late = new Regex(lateExt, RegexOptions.IgnoreCase);
        int from = rootRel == "." ? 0 : rootRel.Length + 1;
        List<QueueEntry> todo = new List<QueueEntry>();
        foreach (QueueEntry e in files.Values) {
            if (done.Contains(e.Rel)) continue;
            // Belongs to a deeper area of its own (e.g. Documents\Important inside Documents)? Check every folder prefix.
            bool other = false;
            for (int i = from < e.Rel.Length ? e.Rel.IndexOf('\\', from) : -1; i >= 0; i = e.Rel.IndexOf('\\', i + 1))
                if (plan.Contains(e.Rel.Substring(0, i))) { other = true; break; }
            if (other) continue;
            string dst = @"\\?\" + Path.Combine(target, e.Rel);
            if (File.Exists(dst)) {
                FileInfo fi = new FileInfo(dst);
                if (fi.Length == e.Size && fi.LastWriteTimeUtc.ToFileTimeUtc() == e.Mtime) { present.Add(e); continue; }
            }
            e.Group = Rank(e.Rel) * 2 + (late.IsMatch(e.Rel) ? 1 : 0);
            todo.Add(e);
        }
        todo.Sort(delegate(QueueEntry a, QueueEntry b) {
            if (a.Group != b.Group) return a.Group.CompareTo(b.Group);
            if (a.Size != b.Size) return a.Size.CompareTo(b.Size);
            return string.Compare(a.Rel, b.Rel, StringComparison.OrdinalIgnoreCase);
        });
        return todo.ToArray();
    }
}

public static class RescueCopy {
    // UTF-8 without BOM that never throws: a file name with an unpaired surrogate must not stop the rescue.
    static readonly Encoding Utf8 = new UTF8Encoding(false, false);

    // Copies src to dst from byte 'offset' on, in blocks of 'block' bytes; the source is only read.
    // Every 'markEvery' bytes the reached offset is appended to progressFile ("rel<TAB>offset"), so the next run
    // continues there. Files of 20 MB and more report progress on the console every 3 s.
    // Every block read counts as a sign of life for the watchdog.
    // Returns the length of dst once the source is exhausted.
    public static long Copy(string src, string dst, long offset, int block, string progressFile, string rel, long markEvery) {
        DiskWatch.Busy(rel);
        try {
            using (FileStream s = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, block, FileOptions.SequentialScan))
            using (FileStream d = new FileStream(dst, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read, block)) {
                if (offset > d.Length) offset = d.Length;
                if (offset > s.Length) offset = 0;
                d.SetLength(offset);
                s.Position = offset;
                d.Position = offset;
                byte[] buf = new byte[block];
                long mark = 0;
                long total = s.Length, start = offset;
                DateTime t0 = DateTime.Now, shown = DateTime.Now;
                while (true) {
                    if (total >= 20L << 20 && (DateTime.Now - shown).TotalSeconds >= 3) {
                        shown = DateTime.Now;
                        double secs = Math.Max(0.1, (shown - t0).TotalSeconds);
                        Console.WriteLine(string.Format("    {0:HH:mm:ss}  {1}: {2:N2} / {3:N2} GB ({4:N0} %), {5:N1} MB/s",
                            shown, Path.GetFileName(rel), offset / 1073741824.0, total / 1073741824.0,
                            100.0 * offset / total, (offset - start) / 1048576.0 / secs));
                    }
                    int n;
                    try { n = s.Read(buf, 0, buf.Length); }
                    catch (Exception e) {
                        d.Flush(true);
                        File.AppendAllText(progressFile, rel + "\t" + offset + "\r\n", Utf8);
                        throw new CopyFailed(offset, e);
                    }
                    DiskWatch.Alive();
                    if (n <= 0) break;
                    d.Write(buf, 0, n);
                    offset += n;
                    mark += n;
                    if (mark >= markEvery) {
                        d.Flush(true);
                        File.AppendAllText(progressFile, rel + "\t" + offset + "\r\n", Utf8);
                        mark = 0;
                    }
                }
                d.Flush(true);
                return offset;
            }
        } finally {
            DiskWatch.Idle();
        }
    }
}
'@ }

# Disks that are never touched: the one with Windows on it and the one holding the target.
function Get-ProtectedDisks {
    $letters = @($env:SystemDrive.Substring(0, 1))
    if ($Target -match '^[A-Za-z]:') { $letters += $Target.Substring(0, 1) }
    $disks = foreach ($l in $letters) { [RescueDisk]::DisksOfVolume([char]$l.ToUpperInvariant()) }
    return @($disks | Sort-Object -Unique)
}

# --- -ListDisks: show the disks and the strings -Model is matched against -----------------------------------
if ($ListDisks) {
    $protected = Get-ProtectedDisks
    [DiskWatch]::Boot = Get-Date
    '{0,-15} {1,-40} {2}' -f 'Disk', 'Vendor and product (-Model)', 'Notes'
    foreach ($n in 0..31) {
        $p = [RescueDisk]::Product($n)
        if ($null -eq $p) { continue }
        $notes = @()
        if ($protected -contains $n) { $notes += 'system or target disk - never used' }
        $usb = [DiskWatch]::Attach($n)
        if ($usb) { $notes += $usb }
        if ($Model -and $p -match $Model -and $protected -notcontains $n) { $notes += '<- matches -Model' }
        '{0,-15} {1,-40} {2}' -f "PhysicalDrive$n", $p, ($notes -join '; ')
    }
    return
}

if (-not $TestSource) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Please run this in a PowerShell started "As administrator".' }
    if (-not $Model -and -not ($RemoveAutostart -or $Finish -or $Prepare)) { throw 'Set -Model (or Model in the config file); see -ListDisks.' }
}
if (-not $Target -and -not ($RemoveAutostart -or $Finish -or $Prepare)) { throw 'Set -Target (or Target in the config file): a folder on another disk.' }

$log = $null
if ($Target) {
    New-Item -ItemType Directory -Force $Target | Out-Null
    $Target = (Resolve-Path -LiteralPath $Target).ProviderPath
    $log = Join-Path $Target 'rescue.log'
}
# Boot time without WMI (WMI can be slow right after boot)
$ms = [long][Environment]::TickCount; if ($ms -lt 0) { $ms += 4294967296 }
$boot = (Get-Date).AddMilliseconds(-$ms)
function Log([string]$msg, [string]$color = 'Gray') {
    $line = '{0} (+{1,4:N0}s since boot) {2}' -f (Get-Date -Format 'HH:mm:ss'), ((Get-Date) - $boot).TotalSeconds, $msg
    if ($log) { Add-Content -LiteralPath $log -Value (@(Get-Notes) + $line) }
    Write-Host $line -ForegroundColor $color
}
# Messages of the watchdog (C#, own thread; already on the console) that are not in rescue.log yet
$script:watchReady = $true
function Get-Notes { if ($script:watchReady) { [DiskWatch]::TakeLog() } }

# --- One-time settings --------------------------------------------------------------------------------------
if ($Prepare) {
    if ($Model) {
        $protected = Get-ProtectedDisks
        foreach ($n in 0..31) {
            $p = [RescueDisk]::Product($n)
            if ($p -and $p -match $Model -and $protected -notcontains $n) {
                throw "The disk is connected right now (PhysicalDrive$n, $p) - run -Prepare only while it is NOT connected."
            }
        }
    }
    mountvol /N | Out-Null          # do not mount new volumes automatically any more
    mountvol /R | Out-Null          # forget drive letters of volumes that are not present
    Log 'Prepared: automatic mounting is off, drive letters of absent volumes are forgotten.' Green
    return
}

if (-not $env:ProgramData) { throw 'ProgramData is not set - stopping.' }
$TaskDir = Join-Path $env:ProgramData 'DiskRescue'
if ($InstallAutostart) {
    if (-not $Config) { throw '-InstallAutostart needs a config file (-Config or rescue-config.psd1 next to the script).' }
    if (-not $Target) { throw '-InstallAutostart needs a target (-Target or Target in the config file).' }
    # The SYSTEM task starts a copy in a folder that only SYSTEM and administrators can change
    New-Item -ItemType Directory -Force $TaskDir | Out-Null
    icacls $TaskDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    $copy = Join-Path $TaskDir 'Rescue-Disk.ps1'
    $cfgCopy = Join-Path $TaskDir 'rescue-config.psd1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $copy -Force
    Copy-Item -LiteralPath $Config -Destination $cfgCopy -Force
    # Quoted arguments: a trailing backslash (a target like E:\) must be doubled, or it escapes the closing quote
    $q = { param($s) '"' + ($s -replace '(\\+)$', '$1$1') + '"' }
    $arg = "-NoProfile -ExecutionPolicy Bypass -File $(& $q $copy) -Config $(& $q $cfgCopy) -WaitSeconds 240 -Target $(& $q $Target) -Model $(& $q $Model)"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Force | Out-Null
    Log "Autostart task '$TaskName' installed: runs at every boot as SYSTEM." Green
    return
}

if ($RemoveAutostart -or $Finish) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    if (Test-Path $TaskDir) { Remove-Item -LiteralPath $TaskDir -Recurse -Force }
    if ($Finish) { mountvol /E | Out-Null; Log 'Autostart removed, automatic mounting is on again.' Green }
    else { Log 'Autostart removed (automatic mounting stays off).' Green }
    return
}

# --- State (survives dropouts and restarts) -----------------------------------------------------------------
$stateDir = Join-Path $Target '_state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$doneFile = Join-Path $stateDir 'done.tsv'          # rel <TAB> bytes
$partFile = Join-Path $stateDir 'partial.tsv'       # rel <TAB> offset (the last entry counts)
$failFile = Join-Path $stateDir 'failed.tsv'        # rel <TAB> offset <TAB> message (a folder: rel ends in "\", offset -1)
$stuckFile = Join-Path $stateDir 'stuck.tsv'        # rel <TAB> offset <TAB> how often the disk hung there (the last entry counts)
$rootsFile = Join-Path $stateDir 'roots_done.txt'   # areas that are completely done
function Read-Lines([string]$p) { if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllLines($p) } else { @() } }
# State files: UTF-8 without BOM that never throws (a file name with invalid Unicode would otherwise raise an
# exception while appending and stop the rescue at the same place on every start)
$utf8 = New-Object Text.UTF8Encoding($false, $false)

$done = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($l in Read-Lines $doneFile) { $p = $l.Split("`t"); if ($p[0]) { [void]$done.Add($p[0]) } }
$partial = @{}
foreach ($l in Read-Lines $partFile) { $p = $l.Split("`t"); if ($p.Count -ge 2) { $partial[$p[0]] = [long]$p[1] } }
$failed = @{}
$gaveUp = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)   # not tried again
foreach ($l in Read-Lines $failFile) {
    $p = $l.Split("`t")
    if ($p.Count -ge 2) { $failed[$p[0]] = [long]$p[1] }
    if ($p.Count -ge 3 -and $p[2].StartsWith('gave up')) { [void]$gaveUp.Add($p[0]) }
}
# "file<TAB>position" -> how often the disk stopped answering there without any progress (also across restarts,
# e.g. with the autostart task: one cycle per boot)
$stuck = @{}
foreach ($l in Read-Lines $stuckFile) { $p = $l.Split("`t"); if ($p.Count -ge 3) { $stuck["$($p[0])`t$($p[1])"] = [int]$p[2] } }
$rootsDone = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($l in Read-Lines $rootsFile) { if ($l) { [void]$rootsDone.Add($l) } }

# --- Plan: which areas in which order ------------------------------------------------------------------------
# Each area only once (a duplicate would make Copy-BigFiles copy the same file twice). Plus areas of earlier runs
# (done or listed, e.g. with other settings), so that their big files and read errors are not left behind; their
# area is in the first X line of their inventory. The rest of the partition ('.') always comes last.
function ConvertTo-Rel([string]$p) { $p.Trim().Trim('\').Replace('/', '\') }
# Area name for messages ('.' is the rest of the partition)
function Show-Area([string]$r) { if ($r -eq '.') { '(rest of the partition)' } else { $r } }
# Area of an inventory: its first X line. (Read with a reader that is closed right away: a PowerShell foreach that
# stops early keeps the file open, and appending to a list that is not finished yet would then fail.)
function Get-InvArea([string]$path) {
    $rd = New-Object IO.StreamReader($path, [Text.Encoding]::UTF8)
    try { while ($null -ne ($l = $rd.ReadLine())) { if ($l.StartsWith("X`t")) { return $l.Substring(2) } } }
    finally { $rd.Dispose() }
}
$earlier = @($rootsDone) + @(Get-ChildItem -LiteralPath $stateDir -Filter 'inv_*.tsv' | ForEach-Object { Get-InvArea $_.FullName })
# Front: at the start of every cycle these files and folders (folders end in "\") first, in this order and in
# full, even above -BigMB. Every Front folder is an area of its own, listed before all others.
$front = @($settings.Front | ForEach-Object { if ($_.TrimEnd().EndsWith('\') -or $_.TrimEnd().EndsWith('/')) { (ConvertTo-Rel $_) + '\' } else { ConvertTo-Rel $_ } })
$frontAreas = @($front | Where-Object { $_.EndsWith('\') } | ForEach-Object { $_.TrimEnd('\') })
$planSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$plan = New-Object 'Collections.Generic.List[string]'
foreach ($r in $frontAreas + @($First | Where-Object { $_ } | ForEach-Object { ConvertTo-Rel $_ }) + @($settings.Areas | ForEach-Object { ConvertTo-Rel $_ }) + $earlier + @('.')) {
    if ($r -and $planSet.Add($r)) { $plan.Add($r) }
}
# Late folders: copied after everything else of their area, higher rank = later. Longest prefixes first, so that a
# deeper folder can have its own rank.
$lateKeys = @($settings.Late.Keys | Sort-Object { $_.Length } -Descending)
[RescueQueue]::SetLate([string[]]@($lateKeys | ForEach-Object { ConvertTo-Rel $_ }), [int[]]@($lateKeys | ForEach-Object { $settings.Late[$_] }))
# Not rescued at all (folders relative to the partition root). Copies made before stay in the target.
$exclude = @($settings.Exclude | ForEach-Object { ConvertTo-Rel $_ } | Where-Object { $_ })
$excludeSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($x in $exclude) { [void]$excludeSet.Add($x) }
function Test-Excluded([string]$rel) {
    foreach ($x in $exclude) { if ($rel.StartsWith($x + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
# Folder names skipped everywhere (package caches, build intermediates); .git, bin, dist are copied.
$skipDirs = @($settings.SkipDirs)
# In the partition root: system folders and the configured ones
$skipTop = @('System Volume Information', '$RECYCLE.BIN', 'Config.Msi') + @($settings.SkipRootDirs)
$lateExt = [string]$settings.LateExtensions

# Storage service calls (Get-Disk etc.) often do not know a freshly appeared disk yet: refresh the cache and
# retry up to 5 times.
function Invoke-Storage([scriptblock]$call) {
    for ($i = 1; $i -le 5; $i++) {
        try { return & $call }
        catch {
            if ($i -eq 5) { throw }
            Update-HostStorageCache -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }
}

# Is this drive letter a volume on the disk being rescued?
function Test-LetterOnDisk([char]$l) { return ([RescueDisk]::DisksOfVolume($l) -contains $script:diskNo) }

# Make the disk read-only and provide its data partition (the largest one); returns its root.
function Connect-Disk {
    $attr = [RescueDisk]::Attributes($script:diskNo)
    if ($attr -lt 0 -or ($attr -band 2) -eq 0) {
        $disk = Invoke-Storage { Get-Disk -Number $script:diskNo }
        if ($disk.FriendlyName -notmatch $Model -and [RescueDisk]::Product($script:diskNo) -notmatch $Model) {
            throw "Disk $($script:diskNo) is '$($disk.FriendlyName)', not the disk to rescue."
        }
        if (-not $disk.IsReadOnly) { Invoke-Storage { Set-Disk -Number $script:diskNo -IsReadOnly $true } }
        $disk = Invoke-Storage { Get-Disk -Number $script:diskNo }
        if (-not $disk.IsReadOnly) { throw 'Could not make the disk read-only - nothing is read.' }
    }
    Log 'Disk is read-only.' Green
    # Wait for the drive letter: after the first connection the partition gets its letter back by itself. Wait for
    # the letter that was used last time (or -Letter); never build paths on the disk with Join-Path: it throws as
    # long as the drive does not exist (yet).
    $l = if ($script:rootLetter) { $script:rootLetter } else { $Letter }
    $t = Get-Date
    while (-not (Test-LetterOnDisk $l) -and ((Get-Date) - $t).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 300 }
    if (Test-LetterOnDisk $l) {
        $r = "$($l):\"
    } else {
        # Data partitions: "basic data" on GPT disks; FAT, NTFS or exFAT on MBR disks (not hidden, extended or recovery ones)
        $part = Invoke-Storage { Get-Partition -DiskNumber $script:diskNo } |
            Where-Object { $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -or $_.MbrType -in 6, 7, 11, 12, 14 } |
            Sort-Object Size -Descending | Select-Object -First 1
        if (-not $part) { throw 'No data partition found (partition table not readable?).' }
        if ($part.DriveLetter -and $part.DriveLetter -ne [char]0) {
            $r = "$($part.DriveLetter):\"
        } else {
            $r = "$($Letter):\"
            if ([IO.Directory]::Exists($r) -or (Test-Path -LiteralPath $r)) { throw "Drive letter $Letter is used by another drive - choose a free one with -Letter." }
            Invoke-Storage { Add-PartitionAccessPath -DiskNumber $script:diskNo -PartitionNumber $part.PartitionNumber -AccessPath $r }
            Start-Sleep -Seconds 1
        }
    }
    $script:rootLetter = $r[0]
    if ([RescueDisk]::DisksOfVolume($Target[0]) -contains $script:diskNo) { throw "Target $Target is on the disk being rescued." }
    if (-not (Test-Path -LiteralPath $r)) { Unlock-IfLocked $r }
    if (-not (Test-Path -LiteralPath $r)) { throw "$r is not readable (RAW?). Do NOT format it." }
    return $r
}

# BitLocker: an encrypted partition must be unlocked before it can be read. On the PC the disk was used in, Windows
# usually does that by itself (auto-unlock: the key is stored on that PC). Elsewhere the 48-digit recovery password
# is needed: from BitLockerKeyFile, otherwise asked for once; it is kept in memory for all further cycles.
# Unlocking only reads the disk.
$script:bitLockerKey = $null
function Unlock-IfLocked([string]$root) {
    $mp = $root.Substring(0, 2)
    try { $bv = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop } catch { return }   # no BitLocker here
    if ("$($bv.LockStatus)" -ne 'Locked') { return }
    Log "The partition ($mp) is encrypted with BitLocker and locked - auto-unlock is not active for it on this PC." Yellow
    if (-not $script:bitLockerKey -and $settings.BitLockerKeyFile) {
        $script:bitLockerKey = (Get-Content -LiteralPath $settings.BitLockerKeyFile -TotalCount 1).Trim()
    }
    if (-not $script:bitLockerKey) {
        # The autostart task (SYSTEM, no window) cannot ask - it would wait forever
        if (-not [Environment]::UserInteractive) { throw 'The partition is locked by BitLocker and nobody can be asked for the key here - set BitLockerKeyFile.' }
        $s = Read-Host -AsSecureString 'BitLocker recovery password (48 digits)'
        $script:bitLockerKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)).Trim()
    }
    $digits = $script:bitLockerKey -replace '\D', ''
    if ($digits.Length -ne 48) { $script:bitLockerKey = $null; throw 'A BitLocker recovery password has 48 digits.' }
    $key = (0..7 | ForEach-Object { $digits.Substring($_ * 6, 6) }) -join '-'
    try { Unlock-BitLocker -MountPoint $mp -RecoveryPassword $key -ErrorAction Stop | Out-Null }
    catch {
        if (Test-Alive) { $script:bitLockerKey = $null }        # disk still there: the password was probably wrong
        throw "BitLocker unlock failed: $($_.Exception.Message)"
    }
    Log "BitLocker: $mp unlocked." Green
}

# Wait until the disk disappears from the system, at most $max s (0 = no limit). $true = it is gone.
function Wait-Gone([int]$max) {
    $t = Get-Date
    while ($null -ne [RescueDisk]::Product($script:diskNo) -and ($max -le 0 -or ((Get-Date) - $t).TotalSeconds -lt $max)) {
        Start-Sleep -Milliseconds 250
    }
    return ($null -eq [RescueDisk]::Product($script:diskNo))
}

# Only with -PortRestart. Steps, each once until the disk delivers data again: 1. restart the USB port,
# 2. switch the USB device off for -OffSeconds and on again. Step 1 only with -Hanging (a read may hang or the old
# drive letter may still be in use, which would prevent switching off). $true = a step was taken.
function Recover-Disk([string]$why, [switch]$Hanging) {
    if ($Hanging -and [DiskWatch]::Restart($why)) { [void](Wait-Gone 20); return $true }
    return [DiskWatch]::PowerCycle($why, $OffSeconds)
}

# The disk hangs or does not read and is still in the system. Over USB 2 the USB bridge often restarts it by
# itself: wait up to $selfSeconds for that. Otherwise (with -PortRestart first Recover-Disk) ask for a replug.
function Resolve-Hang([string]$why, [int]$selfSeconds, [switch]$Hanging) {
    if ([DiskWatch]::Usb2 -and $selfSeconds -gt 0 -and (Wait-Gone $selfSeconds)) { return }
    if ($PortRestart -and (Recover-Disk $why -Hanging:$Hanging)) { return }
    if ($null -eq [RescueDisk]::Product($script:diskNo)) { return }
    Log 'Please unplug the disk and plug it in again - the rescue continues exactly where it stopped.' Yellow
    [void](Wait-Gone 0)
}

# After a failure while copying: usually the disk is gone already (USB 2: the bridge restarts it; USB 3: mostly
# unplugged already). Otherwise Resolve-Hang.
function Wait-Removal {
    if ($null -eq [RescueDisk]::Product($script:diskNo)) { return }
    Log 'Waiting for the disk to restart ...' Yellow
    Resolve-Hang 'still hangs in the system' 30 -Hanging
}

function Test-Alive {
    if ($TestSource) { return (Test-Path -LiteralPath $TestSource) }
    if ($null -eq [RescueDisk]::Product($script:diskNo)) { return $false }
    return [RescueDisk]::Probe($script:diskNo, 5000)
}

function Mark-Done([string]$rel, [long]$bytes) {
    [IO.File]::AppendAllText($doneFile, "$rel`t$bytes`r`n", $utf8)
    [void]$done.Add($rel)
}

function Get-InvPath([string]$rootRel) { Join-Path $stateDir ('inv_' + ($rootRel -replace '[\\/:*?"<>|. ]', '_') + '.tsv') }

# List the folders of an area; every folder that is listed completely is saved at once.
function Get-Inventory([string]$rootRel, [string]$base) {
    $inv = Get-InvPath $rootRel
    $files = @{}
    $known = New-Object 'Collections.Generic.List[string]'
    $listed = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $complete = $false
    foreach ($l in Read-Lines $inv) {
        $p = $l.Split("`t")
        switch ($p[0]) {
            'F' { $files[$p[1]] = [pscustomobject]@{ Rel = $p[1]; Size = [long]$p[2]; Mtime = [long]$p[3] } }
            'D' { $known.Add($p[1]) }
            'X' { [void]$listed.Add($p[1]) }
            'E' { $complete = $true }
        }
    }
    if ($complete) { return $files }
    $queue = New-Object 'Collections.Generic.Queue[string]'
    $queue.Enqueue($rootRel)
    foreach ($d in $known) { $queue.Enqueue($d) }
    $links = 0; $cloud = 0
    while ($queue.Count -gt 0) {
        $d = $queue.Dequeue()
        if ($listed.Contains($d)) { continue }
        $full = if ($d -eq '.') { $base } else { [IO.Path]::Combine($base, $d) }
        $lines = New-Object 'Collections.Generic.List[string]'
        $err = $null
        try {
            [DiskWatch]::Busy("folder $d")
            $di = New-Object IO.DirectoryInfo ('\\?\' + $full)
            foreach ($e in $di.EnumerateFileSystemInfos()) {
                [DiskWatch]::Alive()
                # Symbolic links and junctions point elsewhere (maybe off this disk, or in a circle): skipped. Other
                # reparse points (e.g. cloud or deduplicated files) are ordinary files and folders of this disk.
                if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                    ([RescueDisk]::ReparseTag($e.FullName) -band 0x20000000) -ne 0) { $links++; continue }
                $rel = if ($d -eq '.') { $e.Name } else { "$d\$($e.Name)" }
                if ($e -is [IO.DirectoryInfo]) {
                    if ($skipDirs -contains $e.Name) { continue }
                    if ($d -eq '.' -and $skipTop -contains $e.Name) { continue }
                    if ($planSet.Contains($rel) -and $rel -ne $rootRel) { continue }   # an area of its own
                    if ($excludeSet.Contains($rel)) { continue }                       # not to be rescued
                    $lines.Add("D`t$rel")
                    $queue.Enqueue($rel)
                } elseif (([int]$e.Attributes -band 0x400000) -ne 0) {
                    $cloud++                    # only in the cloud (e.g. OneDrive "online-only"): no content on this disk
                } else {
                    $mt = $e.LastWriteTimeUtc.ToFileTimeUtc()
                    $lines.Add("F`t$rel`t$($e.Length)`t$mt")
                    $files[$rel] = [pscustomobject]@{ Rel = $rel; Size = $e.Length; Mtime = $mt }
                }
            }
        } catch {
            if (-not (Test-Alive)) { throw }
            $err = $_.Exception.Message -replace '\s+', ' '
        } finally {
            [DiskWatch]::Idle()
        }
        if ($err) {
            # A read error while the disk answers: try the folder once more at the end of the list; if it fails again,
            # keep what could be read and record the folder in failed.tsv, so that it is not silently lost.
            $script:folderTries[$d] = 1 + [int]$script:folderTries[$d]
            if ($script:folderTries[$d] -lt 2) {
                Log "  Folder not readable, will be tried again at the end of the list: $d ($err)" Yellow
                $queue.Enqueue($d)
                continue
            }
            Log "  Folder not readable, skipped: $d ($err)" Yellow
            [IO.File]::AppendAllText($failFile, "$d\`t-1`tfolder not readable: $err`r`n", $utf8)
            $failed["$d\"] = -1
        }
        $lines.Add("X`t$d")
        [IO.File]::AppendAllLines($inv, [string[]]$lines, $utf8)
        [void]$listed.Add($d)
    }
    [IO.File]::AppendAllText($inv, "E`t`r`n", $utf8)
    $skipped = @()
    if ($links) { $skipped += "$links link$(if ($links -ne 1) { 's' })" }
    if ($cloud) { $skipped += "$cloud cloud-only file$(if ($cloud -ne 1) { 's' })" }
    Log ("Listed {0}: {1} files, {2:N1} MB{3}" -f (Show-Area $rootRel), $files.Count, (($files.Values | Measure-Object Size -Sum).Sum / 1MB),
        $(if ($skipped.Count) { ' (skipped: ' + ($skipped -join ', ') + ')' }))
    return $files
}

function Copy-One($f, [string]$base) {
    if ($done.Contains($f.Rel)) { return }              # saved already: never start again (it would shorten the copy)
    $src = '\\?\' + [IO.Path]::Combine($base, $f.Rel)
    $dst = '\\?\' + [IO.Path]::Combine($Target, $f.Rel)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
    $off = 0L
    if ($partial.ContainsKey($f.Rel)) { $off = [long]$partial[$f.Rel] }
    $have = New-Object IO.FileInfo $dst                 # the copy can be shorter than the remembered position
    $off = if ($have.Exists) { [Math]::Min([long]$off, [long]$have.Length) } else { 0L }
    if ($f.Size -ge 50MB) {
        Log ("Copying {0} ({1:N2} GB), from {2:N2} GB ({3:N0} %)" -f $f.Rel, ($f.Size / 1GB), ($off / 1GB), (100.0 * $off / [Math]::Max(1L, [long]$f.Size))) Cyan
    }
    try {
        $n = [RescueCopy]::Copy($src, $dst, $off, 1MB, $partFile, $f.Rel, 8MB)
    } catch {
        $ex = $_.Exception
        while ($ex.InnerException -and -not ($ex -is [CopyFailed])) { $ex = $ex.InnerException }
        $at = if ($ex -is [CopyFailed]) { $ex.Offset } else { $off }
        $partial[$f.Rel] = $at
        $script:cycleBytes += [Math]::Max(0L, [long]($at - $off))
        if (-not (Test-Alive)) {
            if ($f.Size -ge 50MB) {
                Log ("Interrupted at {0}: {1:N2} of {2:N2} GB ({3:N0} %) saved" -f $f.Rel, ($at / 1GB), ($f.Size / 1GB), (100.0 * $at / [Math]::Max(1L, [long]$f.Size))) Yellow
            } else {
                Log "Interrupted at $($f.Rel)" Yellow
            }
            # Interrupted three times at the same position without any progress: maybe the disk hangs exactly
            # here. Then defer it to the second pass at the end, so that this spot does not block everything else;
            # after three more times at that position, give up on the file, so that the rescue can finish.
            $key = "$($f.Rel)`t$at"
            $n = 1 + [int]$stuck[$key]
            $stuck[$key] = $n
            [IO.File]::AppendAllText($stuckFile, "$key`t$n`r`n", $utf8)
            if ($n -ge 3 -and -not $failed.ContainsKey($f.Rel)) {
                [IO.File]::AppendAllText($failFile, "$($f.Rel)`t$at`tinterrupted three times at the same position`r`n", $utf8)
                $failed[$f.Rel] = $at
                Log "  $($f.Rel) was interrupted three times at the same position - deferred to the second pass at the end." Yellow
            } elseif ($n -ge 6 -and $gaveUp.Add($f.Rel)) {
                [IO.File]::AppendAllText($failFile, "$($f.Rel)`t$at`tgave up: interrupted six times at the same position`r`n", $utf8)
                Log "  $($f.Rel) was interrupted six times at the same position - given up (see _state\failed.tsv)." Yellow
            }
            throw 'DISK_GONE'
        }
        [IO.File]::AppendAllText($failFile, "$($f.Rel)`t$at`t$($ex.Message -replace '\s+', ' ')`r`n", $utf8)
        $failed[$f.Rel] = $at
        Log ("  Read error in {0} at {1:N1} MB, will be retried later: {2}" -f $f.Rel, ($at / 1MB), $ex.Message) Yellow
        return
    }
    [IO.File]::SetLastWriteTimeUtc($dst, [DateTime]::FromFileTimeUtc($f.Mtime))
    Mark-Done $f.Rel $n
    $script:cycleBytes += ($n - $off)
    $script:cycleFiles++
    if ($f.Size -ge 50MB) { Log ("  done: {0} ({1:N0} MB)" -f $f.Rel, ($f.Size / 1MB)) Green }
    if (((Get-Date) - $script:lastShow).TotalSeconds -ge 3) {
        $script:lastShow = Get-Date
        Write-Host ("  {0} files / {1:N1} MB in this cycle - last {2}" -f $script:cycleFiles, ($script:cycleBytes / 1MB), $f.Rel)
    }
}

# Sorted work list of an area ([RescueQueue]::Build, see above); built once per script run and then reused in all
# cycles. Areas that are listed completely are built at start already (needs only the target disk), so that
# copying starts right after the disk appears.
$script:queues = @{}
$script:qpos = @{}          # continue searching here: everything before is done, too big, or has a read error
$script:folderTries = @{}   # folder -> failed attempts to list it in this run
function Get-Queue([string]$rootRel, [string]$base) {
    if ($script:queues.ContainsKey($rootRel)) { return , $script:queues[$rootRel] }
    $inv = Get-InvPath $rootRel
    if (-not [RescueQueue]::IsComplete($inv)) { [void](Get-Inventory $rootRel $base) }
    $t = Get-Date
    $present = New-Object 'Collections.Generic.List[QueueEntry]'
    $q = [RescueQueue]::Build($inv, $rootRel, $done, $planSet, $Target, $lateExt, $present)
    foreach ($f in $present) { Mark-Done $f.Rel $f.Size }      # e.g. copied by robocopy before - do not read again
    if ($exclude.Count) {                                      # leave out the excluded folders
        $keep = New-Object 'Collections.Generic.List[QueueEntry]'
        foreach ($e in $q) {
            $skip = $false
            foreach ($x in $exclude) { if ($e.Rel.StartsWith($x + '\', [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break } }
            if (-not $skip) { $keep.Add($e) }
        }
        $q = $keep.ToArray()
    }
    if ($q.Count -ge 10000) { Log ("Work list {0}: {1:N0} files open ({2:N0} s)" -f (Show-Area $rootRel), $q.Count, ((Get-Date) - $t).TotalSeconds) }
    $script:queues[$rootRel] = $q
    return , $q
}

# Work through an area: small files first. Files above -BigMB come at the very end (Copy-BigFiles), files with
# read errors in the second pass.
$bigBytes = [long]$BigMB * 1MB
function Copy-Root([string]$rootRel, [string]$base, [switch]$Retry) {
    $queue = Get-Queue $rootRel $base
    $k = if ($Retry -or -not $script:qpos.ContainsKey($rootRel)) { 0 } else { $script:qpos[$rootRel] }
    for (; $k -lt $queue.Count; $k++) {
        $f = $queue[$k]
        if (-not $Retry) { $script:qpos[$rootRel] = $k }
        if ($done.Contains($f.Rel)) { continue }
        if ($failed.ContainsKey($f.Rel) -and -not $Retry) { continue }
        if ($Retry -and $gaveUp.Contains($f.Rel)) { continue }
        if ($f.Size -gt $bigBytes -and -not $Retry) { continue }
        Copy-One $f $base
    }
    if (-not $Retry) {
        $open = @($queue | Where-Object { -not $done.Contains($_.Rel) -and -not $failed.ContainsKey($_.Rel) -and $_.Size -le $bigBytes }).Count
        if ($open -eq 0) { [IO.File]::AppendAllText($rootsFile, "$rootRel`r`n", $utf8); [void]$rootsDone.Add($rootRel) }
    }
}

# At the end everything that is still open in the work lists (without read errors): normally exactly the files
# above -BigMB; this way nothing is left behind either if -BigMB was raised between two runs. Order: rank of the
# folder, then by the amount left (started files usually have less left).
function Copy-BigFiles([string]$base) {
    $big = New-Object 'Collections.Generic.List[object]'
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $plan) {
        if (-not (Test-Path -LiteralPath (Get-InvPath $r))) { continue }
        foreach ($f in (Get-Queue $r $base)) {
            if (-not $done.Contains($f.Rel) -and -not $failed.ContainsKey($f.Rel) -and $seen.Add($f.Rel)) { $big.Add($f) }
        }
    }
    if ($big.Count -eq 0) { return }
    $left = { param($f) $f.Size - $(if ($partial.ContainsKey($f.Rel)) { [long]$partial[$f.Rel] } else { 0L }) }
    $ordered = @($big | Sort-Object @{ e = { [RescueQueue]::Rank($_.Rel) } }, @{ e = { & $left $_ } })
    Log ("Big files: {0} open, {1:N1} GB left" -f $ordered.Count, (($ordered | ForEach-Object { & $left $_ } | Measure-Object -Sum).Sum / 1GB)) Cyan
    foreach ($f in $ordered) { Copy-One $f $base }
}

# The deepest area of the plan that $rel belongs to ('.' = rest of the partition).
function Get-AreaOf([string]$rel) {
    if ($planSet.Contains($rel)) { return $rel }
    $area = '.'
    for ($i = $rel.IndexOf('\'); $i -ge 0; $i = $rel.IndexOf('\', $i + 1)) {
        if ($planSet.Contains($rel.Substring(0, $i))) { $area = $rel.Substring(0, $i) }
    }
    return $area
}

# Entry for a single Front file: from the work list of its area if that is listed already, otherwise directly
# from the disk (e.g. a file in the partition root, whose rest is listed only at the very end).
# $null = does not exist (or is done already).
function Get-FrontFile([string]$rel, [string]$base) {
    $area = Get-AreaOf $rel
    if ([RescueQueue]::IsComplete((Get-InvPath $area))) {
        foreach ($f in (Get-Queue $area $base)) { if ($f.Rel -eq $rel) { return $f } }
        return $null
    }
    [DiskWatch]::Busy($rel)
    try { $fi = New-Object IO.FileInfo ('\\?\' + [IO.Path]::Combine($base, $rel)); $there = $fi.Exists }
    finally { [DiskWatch]::Idle() }
    if (-not $there) {
        if (-not (Test-Alive)) { throw 'DISK_GONE' }    # believe "does not exist" only while the disk answers
        return $null
    }
    $e = New-Object QueueEntry
    $e.Rel = $rel; $e.Size = $fi.Length; $e.Mtime = $fi.LastWriteTimeUtc.ToFileTimeUtc()
    return $e
}

# Copy the Front files and folders in full, small ones first. What is done (or does not exist) is not looked at
# again in the same script run.
$script:frontDone = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:frontLists = @{}
function Copy-Front([string]$base) {
    foreach ($spec in $front) {
        if ($script:frontDone.Contains($spec)) { continue }
        if (-not $spec.EndsWith('\')) {
            if (-not $done.Contains($spec) -and -not $failed.ContainsKey($spec)) {
                $f = Get-FrontFile $spec $base
                if ($f) { Copy-One $f $base } else { Log "  Front: $spec does not exist (or is done already)." }
            }
            [void]$script:frontDone.Add($spec)
            continue
        }
        if (-not $script:frontLists.ContainsKey($spec)) {
            # A Front folder is an area of its own (see the plan): list it now, unless that was done before
            $folder = $spec.TrimEnd('\')
            if (-not [RescueQueue]::IsComplete((Get-InvPath $folder))) {
                [DiskWatch]::Busy("folder $folder")
                try { $there = [IO.Directory]::Exists('\\?\' + [IO.Path]::Combine($base, $folder)) } finally { [DiskWatch]::Idle() }
                if (-not $there) {
                    if (-not (Test-Alive)) { throw 'DISK_GONE' }    # believe "does not exist" only while the disk answers
                    Log "  Front: $spec does not exist."
                    [void]$script:frontDone.Add($spec); continue
                }
            }
            $script:frontLists[$spec] = @((Get-Queue $folder $base) | Sort-Object Size)
            Log ("Front: {0} with {1} files" -f $spec, $script:frontLists[$spec].Count) Cyan
        }
        foreach ($f in $script:frontLists[$spec]) {
            if ($done.Contains($f.Rel) -or $failed.ContainsKey($f.Rel)) { continue }
            Copy-One $f $base
        }
        [void]$script:frontDone.Add($spec)
    }
}

# What is still open (from all work lists built so far) and which areas are not listed yet.
function Get-OpenText {
    $n = 0; $b = 0L
    foreach ($q in $script:queues.Values) { $x = 0L; $n += [RescueQueue]::Open($q, $done, [ref]$x); $b += $x }
    $t = '{0:N0} files ({1:N1} GB) still open' -f $n, ($b / 1GB)
    $unlisted = @($plan | Where-Object { -not $rootsDone.Contains($_) -and -not $script:queues.ContainsKey($_) })
    if ($unlisted.Count) { $t += ', not listed yet: ' + (($unlisted | ForEach-Object { Show-Area $_ }) -join ', ') }
    return $t
}

# --- Main loop ----------------------------------------------------------------------------------------------
$mutexName = if ($TestSource) { 'Global\DiskRescueTest' } else { 'Global\DiskRescue' }
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Log 'A rescue is already running - this instance exits.' Yellow; $mutex.Dispose(); return }

Log "Rescue loop started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name), target $Target$(if ($Config) { ", config $Config" })."
$protected = if ($TestSource) { @() } else { Get-ProtectedDisks }
$script:diskNo = $null
$script:rootLetter = $null
$script:connectFails = 0
$allDone = $false
[DiskWatch]::Boot = $boot
[DiskWatch]::AutoRestart = $PortRestart
[DiskWatch]::Start($HangSeconds)
try {
    if ([RescueDisk]::QuickEditOff()) { Log 'QuickEdit is off in this window while the rescue runs (a click into the window would otherwise pause it).' }
    # Build the work lists of completely listed areas now, not when the disk runs (also of done areas: big files
    # may still be open there, and "still open" should count everything)
    foreach ($r in $plan) {
        if ([RescueQueue]::IsComplete((Get-InvPath $r))) { [void](Get-Queue $r '') }
    }
    Log ('Status: {0} files saved, {1}.' -f $done.Count, (Get-OpenText))
    while (-not $allDone) {
        # 1. Wait for the disk (direct device query every 300 ms)
        if ($TestSource) {
            $root = $TestSource
        } else {
            Log 'Waiting for the disk ...'
            $deadline = if ($WaitSeconds -gt 0) { (Get-Date).AddSeconds($WaitSeconds) } else { [DateTime]::MaxValue }
            $script:diskNo = $null
            $asked = $false
            do {
                $found = @(foreach ($n in 0..31) {
                    if ($protected -contains $n) { continue }
                    $p = [RescueDisk]::Product($n)
                    if ($p -and $p -match $Model) { [pscustomobject]@{ N = $n; Product = $p } }
                })
                if ($found.Count -gt 1) {
                    throw ("More than one disk matches -Model '{0}': {1}. Make -Model more specific (see -ListDisks)." -f $Model, (($found | ForEach-Object { "PhysicalDrive$($_.N) $($_.Product)" }) -join ', '))
                }
                if ($found.Count -eq 1) { $script:diskNo = $found[0].N; $prod = $found[0].Product }
                if ($null -eq $script:diskNo) {
                    # After an automatic restart not back within 60 s: ask for help (once)
                    if (-not $asked -and [DiskWatch]::SecondsSinceAction -ge 60) {
                        Log 'The disk has not come back: please unplug it and plug it in again.' Yellow
                        $asked = $true
                    }
                    Start-Sleep -Milliseconds 300
                }
            } while ($null -eq $script:diskNo -and (Get-Date) -lt $deadline)
            if ($null -eq $script:diskNo) { Log 'The disk did not show up - end.' Yellow; break }
            $where = [DiskWatch]::Attach($script:diskNo)
            Log ("Found the disk: PhysicalDrive{0} ({1}{2})." -f $script:diskNo, $prod, $(if ($where) { ", $where" } else { ', not on USB' })) Green

            # Does it read? After a USB port restart it often returns only read errors. Right after appearing it
            # may still be "not ready": up to 3 tries. If a try hangs, no further ones.
            $state = 0
            for ($i = 0; $i -lt 3 -and $state -eq 0; $i++) {
                if ($i) { Start-Sleep -Seconds 1 }
                $state = [RescueDisk]::Check($script:diskNo, 3000)
            }
            if ($state -le 0) {
                Log $(if ($state -lt 0) { 'It does not answer.' } else { 'It does not read (even sector 0 fails).' }) Yellow
                Resolve-Hang 'does not read' 30 -Hanging:($state -lt 0)
                continue
            }
            [DiskWatch]::Recovered()

            # 2.+3. Read-only (registry attribute) and the data partition as a drive (the letter is registry only)
            try {
                $root = Connect-Disk
                $script:connectFails = 0
            } catch {
                Log "Preparation failed, nothing is read: $($_.Exception.Message)" Red
                # If it keeps failing while the disk still answers, the cause is not the disk - better stop.
                if ((Test-Alive) -and ++$script:connectFails -ge 3) { throw 'Preparation failed three times in a row - stopping. Please check the message above.' }
                Resolve-Hang 'cannot be prepared' 30 -Hanging
                continue
            }
            Log "Reading from $root (read-only)." Green
        }

        # 4. Work through the plan until the disk drops out
        $script:cycleStart = Get-Date; $script:cycleBytes = 0L; $script:cycleFiles = 0; $script:lastShow = Get-Date
        try {
            Copy-Front $root
            foreach ($r in $plan) {
                if ($rootsDone.Contains($r)) { continue }
                if ($r -ne '.') {
                    [DiskWatch]::Busy("folder $r")
                    $exists = Test-Path -LiteralPath ([IO.Path]::Combine($root, $r))
                    [DiskWatch]::Idle()
                    if (-not $exists) {
                        # Believe "does not exist" only while the disk demonstrably answers - otherwise the area
                        # would be skipped for good.
                        if (-not (Test-Alive)) { throw 'DISK_GONE' }
                        [IO.File]::AppendAllText($rootsFile, "$r`r`n", $utf8); [void]$rootsDone.Add($r); continue
                    }
                }
                Log "Area $(Show-Area $r) ..." Cyan
                Copy-Root $r $root
            }
            Copy-BigFiles $root
            $retry = @($failed.Keys | Where-Object { -not $_.EndsWith('\') -and -not $done.Contains($_) -and -not $gaveUp.Contains($_) -and -not (Test-Excluded $_) })
            if ($retry.Count -gt 0) {
                Log "Second pass for $($retry.Count) file(s) with read errors ..." Cyan
                foreach ($r in $plan) { if (Test-Path -LiteralPath (Get-InvPath $r)) { Copy-Root $r $root -Retry } }
            }
            $allDone = $true
        } catch {
            if ($_.Exception.Message -ne 'DISK_GONE' -and (Test-Alive)) { throw }
        }
        # Reading time until the last sign of life of the disk, then the time it did not answer
        [DiskWatch]::Idle()
        $last = [DiskWatch]::LastData
        if ($last -lt $script:cycleStart) { $last = $script:cycleStart }
        $sec = [Math]::Max(1.0, ($last - $script:cycleStart).TotalSeconds)
        $hang = ((Get-Date) - $last).TotalSeconds
        $msg = 'Cycle: {0} files, {1:N1} MB in {2:N0} s ({3:N2} MB/s)' -f $script:cycleFiles, ($script:cycleBytes / 1MB), $sec, ($script:cycleBytes / 1MB / $sec)
        if ($hang -ge 3) { $msg += ', then {0:N0} s without an answer' -f $hang }
        Log ('{0} - {1} files saved in total, {2}.' -f $msg, $done.Count, (Get-OpenText)) Green
        if ($allDone -or $TestSource) { break }

        # 5. Dropped out: wait for the disk to restart, then continue above
        Log 'The disk dropped out.' Yellow
        Wait-Removal
    }
    if ($allDone) {
        $left = @($failed.Keys | Where-Object { -not $done.Contains($_) -and -not (Test-Excluded $_) })
        $nd = @($left | Where-Object { $_.EndsWith('\') }).Count
        $msg = 'DONE - everything readable has been read. Files with permanent read errors: {0}' -f ($left.Count - $nd)
        if ($nd) { $msg += ", folders that could not be listed: $nd" }
        Log "$msg (see _state\failed.tsv)." Green
    }
}
finally {
    [DiskWatch]::Idle()
    [RescueDisk]::RestoreConsole()
    $notes = @(Get-Notes)
    if ($notes.Count -and $log) { Add-Content -LiteralPath $log -Value $notes }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
