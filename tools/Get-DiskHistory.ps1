<#
.SYNOPSIS
    Shows when disks appeared and disappeared, from Windows' own records - the quickest way to see whether a
    disk has been dropping out for a while, and the exact model name to use with Rescue-Disk.ps1 -Model.

.DESCRIPTION
    Windows logs every disk arrival and removal in the Microsoft-Windows-Partition/Diagnostic log (event 1006),
    with manufacturer, model, serial number, bus type, size and the number of partitions it could read.
    A removal - or a disk that was detected but could not be read - shows up with 0 partitions.
    With -Errors, disk and storage controller warnings/errors from the System log are listed as well:
    retried and failed I/O, paging errors, surprise removals and controller resets.

    Needs no administrator rights. Changes nothing.

.PARAMETER Model
    Regular expression for "manufacturer model" (default: all disks).

.PARAMETER Days
    How many days back (default 365).

.PARAMETER Errors
    Also list disk/controller events from the System log.

.PARAMETER Max
    At most this many System log events (default 300, newest first).

.EXAMPLE
    .\tools\Get-DiskHistory.ps1
    All disk arrivals/removals of the last year.

.EXAMPLE
    .\tools\Get-DiskHistory.ps1 -Model '950' -Days 30 -Errors
#>
param([string]$Model = '.', [int]$Days = 365, [switch]$Errors, [int]$Max = 300)
$ErrorActionPreference = 'Stop'
$since = (Get-Date).AddDays(-$Days)
$busNames = @{ 1 = 'SCSI'; 3 = 'ATA'; 7 = 'USB'; 8 = 'RAID'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 17 = 'NVMe' }

$events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Partition/Diagnostic'; Id = 1006; StartTime = $since } -ErrorAction SilentlyContinue)
$rows = foreach ($ev in $events) {
    $x = [xml]$ev.ToXml()
    $d = @{}
    foreach ($e in $x.Event.EventData.Data) { $d[$e.Name] = $e.'#text' }
    $name = ('{0} {1}' -f $d['Manufacturer'], $d['Model']).Trim()
    if ($name -notmatch $Model) { continue }
    $bus = [int]$d['BusType']
    [pscustomobject]@{
        Time       = $ev.TimeCreated
        Disk       = $d['DiskNumber']
        Model      = $name
        Serial     = $d['SerialNumber']
        Bus        = $(if ($busNames.ContainsKey($bus)) { $busNames[$bus] } else { $bus })
        GB         = [Math]::Round([double]$d['Capacity'] / 1GB, 0)
        Partitions = $d['PartitionCount']
        State      = $(if ([int]$d['PartitionCount'] -gt 0) { 'present' } else { 'gone or unreadable' })
    }
}
if (-not $rows) { Write-Host "No disk events in the last $Days days$(if ($Model -ne '.') { " for '$Model'" })." }
else {
    Write-Host "Disk arrivals and removals (Partition/Diagnostic event 1006), last $Days days:"
    $rows | Sort-Object Time | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    $gone = @($rows | Where-Object State -ne 'present')
    Write-Host ("{0} events, {1} of them with 0 partitions (disk gone, or detected but not readable)." -f @($rows).Count, $gone.Count)
}

if ($Errors) {
    # Disk class driver, storage controllers (NVMe, AHCI, Intel RST, USB storage), file system and volume manager
    $providers = 'disk', 'stornvme', 'storahci', 'iaStorVD', 'iaStorAC', 'iaStorA', 'iaStorAVC', 'UASPStor', 'USBSTOR', 'Ntfs', 'volmgr', 'partmgr'
    $ms = [long]((Get-Date) - $since).TotalMilliseconds
    $xpath = "*[System[(" + (($providers | ForEach-Object { "Provider[@Name='$_']" }) -join ' or ') +
             ") and (Level=1 or Level=2 or Level=3) and TimeCreated[timediff(@SystemTime) <= $ms]]]"
    $sys = @(Get-WinEvent -LogName System -FilterXPath $xpath -MaxEvents $Max -ErrorAction SilentlyContinue)
    Write-Host "`nDisk/controller warnings and errors from the System log (newest $Max at most):"
    Write-Host "  disk 153 = I/O retried, 154 = I/O failed (hardware error), 51 = paging error, 157 = disk surprise-removed,"
    Write-Host "  129 (storage drivers) = reset to device after a timeout"
    $sys | Sort-Object TimeCreated | ForEach-Object {
        $m = ($_.Message -split "`r?`n")[0]
        '{0:yyyy-MM-dd HH:mm:ss} {1,-10} {2,5}  {3}' -f $_.TimeCreated, $_.ProviderName, $_.Id, $(if ($m.Length -gt 120) { $m.Substring(0, 120) } else { $m })
    }
    if (-not $sys) { Write-Host '  none' }
}
