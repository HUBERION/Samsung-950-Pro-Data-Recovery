<#
.SYNOPSIS
    Report of a rescue made with Rescue-Disk.ps1: per folder, how many files the disk had (from the complete
    file lists in <Target>\_state) and how many are saved completely - and optionally whether a copy made from
    the rescue (for example the data copied back to a new disk) is complete and has no truncated files.
    Files changed after the copy back also show up as "smaller" or "larger" - compare with the date.

.DESCRIPTION
    Only folders that the rescue listed are known (the file lists are written area by area). Files that were
    interrupted keep a shorter copy in the target until they are finished; this report shows them as
    "incomplete". Reads only, changes nothing.

.PARAMETER Target
    The rescue target folder (the one that contains _state).

.PARAMETER RestoredTo
    Optional: the folder the rescued data was copied back to (same folder layout as the rescued partition).

.PARAMETER Depth
    Folder depth of the summary (default 2).

.PARAMETER List
    Also list every file that is missing or incomplete (on the target, or in -RestoredTo).

.EXAMPLE
    .\tools\Get-RescueReport.ps1 -Target E:\Rescue

.EXAMPLE
    .\tools\Get-RescueReport.ps1 -Target E:\Rescue -RestoredTo D:\ -List
#>
param(
    [Parameter(Mandatory)] [string]$Target,
    [string]$RestoredTo,
    [int]$Depth = 2,
    [switch]$List
)
$ErrorActionPreference = 'Stop'
$state = Join-Path $Target '_state'
if (-not (Test-Path -LiteralPath (Join-Path $state 'done.tsv'))) { throw "$state\done.tsv not found - is $Target a rescue target?" }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
public class ReportRow { public string Rel; public long Size; public long OnTarget = -1, OnRestore = -1; }
public static class RescueReport {
    public static List<ReportRow> Load(string stateDir) {
        Dictionary<string, ReportRow> rows = new Dictionary<string, ReportRow>(StringComparer.OrdinalIgnoreCase);
        foreach (string inv in Directory.GetFiles(stateDir, "inv_*.tsv"))
            foreach (string l in File.ReadLines(inv, Encoding.UTF8)) {
                string[] p = l.Split('\t');
                if (p.Length < 4 || p[0] != "F") continue;
                ReportRow r = new ReportRow(); r.Rel = p[1]; r.Size = long.Parse(p[2]);
                rows[r.Rel] = r;
            }
        return new List<ReportRow>(rows.Values);
    }
    static long Len(string path) { FileInfo f = new FileInfo(@"\\?\" + path); return f.Exists ? f.Length : -1; }
    public static void Stat(List<ReportRow> rows, string target, string restore) {
        foreach (ReportRow r in rows) {
            r.OnTarget = Len(Path.Combine(target, r.Rel));
            if (restore != null) r.OnRestore = Len(Path.Combine(restore, r.Rel));
        }
    }
}
'@
$rows = [RescueReport]::Load($state)
$restore = if ($RestoredTo) { (Resolve-Path -LiteralPath $RestoredTo).ProviderPath } else { $null }
[RescueReport]::Stat($rows, (Resolve-Path -LiteralPath $Target).ProviderPath, $restore)

function Get-Top([string]$rel) {
    $p = $rel.Split('\')
    if ($p.Count -le 1) { return '(root)' }
    ($p[0..([Math]::Min($Depth, $p.Count - 1) - 1)]) -join '\'
}

$saved = @($rows | Where-Object { $_.OnTarget -eq $_.Size }).Count
$partial = @($rows | Where-Object { $_.OnTarget -ge 0 -and $_.OnTarget -ne $_.Size })
Write-Host ("Files known from the file lists: {0:N0} ({1:N1} GB)" -f $rows.Count, (($rows | Measure-Object Size -Sum).Sum / 1GB))
Write-Host ("Saved completely on the target:  {0:N0}   incomplete: {1:N0}   missing: {2:N0}" -f $saved, $partial.Count, ($rows.Count - $saved - $partial.Count))
if ($restore) {
    $rs = @($rows | Where-Object { $_.OnRestore -eq $_.Size }).Count
    $smaller = @($rows | Where-Object { $_.OnRestore -ge 0 -and $_.OnRestore -lt $_.Size }).Count
    $larger = @($rows | Where-Object { $_.OnRestore -gt $_.Size }).Count
    $lost = @($rows | Where-Object { $_.OnTarget -eq $_.Size -and $_.OnRestore -lt 0 }).Count
    Write-Host ("In {0}: same size as on the disk {1:N0}, smaller {2:N0} (truncated - or changed since), larger {3:N0} (changed since)," -f $restore, $rs, $smaller, $larger)
    Write-Host ("  saved completely but not there {0:N0}" -f $lost)
}
Write-Host ''
$rows | Group-Object { Get-Top $_.Rel } | ForEach-Object {
    $all = $_.Count
    $ok = @($_.Group | Where-Object { $_.OnTarget -eq $_.Size }).Count
    $o = [ordered]@{ Folder = $_.Name; Files = $all; Saved = $ok; 'Saved %' = [Math]::Floor(100.0 * $ok / $all) }
    if ($restore) { $o['Restored'] = @($_.Group | Where-Object { $_.OnRestore -eq $_.Size }).Count }
    [pscustomobject]$o
} | Sort-Object Folder | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($List) {
    $rows | Where-Object { $_.OnTarget -ne $_.Size -or ($restore -and $_.OnRestore -ne $_.Size) } | Sort-Object Rel | ForEach-Object {
        $t = if ($_.OnTarget -lt 0) { 'missing' } elseif ($_.OnTarget -ne $_.Size) { "incomplete ($($_.OnTarget) of $($_.Size) bytes)" } else { 'saved' }
        $r = if (-not $restore) { '' } elseif ($_.OnRestore -lt 0) { ', not in restore' } elseif ($_.OnRestore -lt $_.Size) { ", SMALLER in restore ($($_.OnRestore) bytes - truncated or changed)" } elseif ($_.OnRestore -gt $_.Size) { ", larger in restore ($($_.OnRestore) bytes - changed)" } else { '' }
        '{0}  [{1}{2}]' -f $_.Rel, $t, $r
    }
}
