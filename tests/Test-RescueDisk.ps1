<#
.SYNOPSIS
    Self-test for Rescue-Disk.ps1 without a failing disk: runs it in test mode (-TestSource) against a generated
    folder tree and checks the copy order, Front/Areas/Late/Exclude/SkipDirs, resuming after "lost" files,
    already existing copies, a file name with invalid Unicode, a configuration with a non-ASCII path saved as
    UTF-8 without BOM, a junction (not followed), a folder that cannot be listed, a path with a drive letter in
    the configuration (refused), and a restart after an interrupted file list. Needs no administrator rights.

.PARAMETER BigFile
    Also copy a 3 GB file (created sparse, so it takes almost no space on the source side; the copy needs
    3 GB on the drive of the temp folder). Checks the > 2 GB code paths.

.PARAMETER Keep
    Keep the generated folders (printed at the end) instead of deleting them.

.EXAMPLE
    .\tests\Test-RescueDisk.ps1
#>
param([switch]$BigFile, [switch]$Keep)
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Rescue-Disk.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('DiskRescueTest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$src = Join-Path $work 'source'
$dst = Join-Path $work 'target'
$cfg = Join-Path $work 'test-config.psd1'
$script:failures = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $name $detail" -ForegroundColor Red; $script:failures++ }
}
function New-File([string]$rel, [long]$size, [byte]$fill = 0) {
    $f = Join-Path $src $rel
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($f))
    $b = New-Object byte[] $size
    if ($fill) { for ($i = 0; $i -lt $size; $i++) { $b[$i] = $fill } }
    [IO.File]::WriteAllBytes($f, $b)
}
function Invoke-Rescue([string[]]$extra) {
    $ErrorActionPreference = 'Continue'     # a crash of the rescue must show up as failed checks, not stop the test
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-TestSource', $src, '-Target', $dst, '-Config', $cfg, '-BigMB', '1') + $extra
    & powershell @a 2>&1 | ForEach-Object { "$_" }
}
function Get-DoneOrder { @(Get-Content -LiteralPath (Join-Path $dst '_state\done.tsv') -Encoding UTF8 | ForEach-Object { $_.Split("`t")[0] }) }
function Test-Copy([string]$rel) {
    $a = Get-Item -LiteralPath (Join-Path $src $rel); $b = Get-Item -LiteralPath (Join-Path $dst $rel) -ErrorAction SilentlyContinue
    return ($b -and $a.Length -eq $b.Length -and $a.LastWriteTimeUtc -eq $b.LastWriteTimeUtc)
}

Write-Host "Test folder: $work"
[void][IO.Directory]::CreateDirectory($src)

# --- The test disk --------------------------------------------------------------------------------------------
$key = 'Schl' + [char]0xFC + 'ssel.key'                 # Front 1 (partition root, not listed yet); non-ASCII name
New-File $key 10                                        # in a config saved as UTF-8 without BOM, as Notepad does
New-File 'Docs\Mail\old.pst' (2MB)                      # Front 2 (big, still copied in full, early)
New-File 'Docs\Letters\b.txt' 20                        # Front 3: folder Docs\Letters\ inside the area Docs
New-File 'Docs\Letters\a.txt' 10
New-File 'Photos\a.jpg' 30                              # Front 4: folder Photos\ (also an area)
New-File 'Photos\big.raw' (3MB)
New-File 'Docs\Important\contract.pdf' 100              # area 1
New-File 'Docs\Important\z.txt' 5
New-File 'Docs\readme.txt' 50                           # area 2
New-File 'Docs\video.mp4' 60                            # LateExtensions: after the other files of the area
New-File 'Docs\bigdoc.bin' (1536KB)                     # above -BigMB 1: final pass
New-File 'Docs\already.txt' 7 65                        # an identical copy exists on the target already
New-File 'notes.txt' 20                                 # rest of the partition
New-File 'Stuff\normal.txt' 40
New-File 'Stuff\Old\old.txt' 1                          # Late rank 1
New-File 'Stuff\Clones\clone.txt' 1                     # Late rank 2
New-File 'Stuff\Excluded\secret.txt' 1                  # Exclude
New-File 'Stuff\node_modules\x.js' 1                    # SkipDirs
New-File 'Stuff\Locked\inside.txt' 1                    # a folder that cannot be listed (access denied below)
$bad = Join-Path $src ('Docs\x' + [char]0xD800 + 'y.txt')   # unpaired surrogate in the name
[IO.File]::WriteAllBytes($bad, [byte[]](1, 2, 3))
cmd /c mklink /J (Join-Path $src 'Stuff\LinkToDocs') (Join-Path $src 'Docs') | Out-Null   # a junction: not followed
$locked = Join-Path $src 'Stuff\Locked'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls $locked /deny "*${sid}:(RD)" | Out-Null
if ($BigFile) {
    Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class SparseFile {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr i, int il, IntPtr o, int ol, out int r, IntPtr ov);
    public static void Create(string path, long size) {
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite)) {
            int got;
            if (!DeviceIoControl(fs.SafeFileHandle, 0x900C4, IntPtr.Zero, 0, IntPtr.Zero, 0, out got, IntPtr.Zero)) throw new IOException("FSCTL_SET_SPARSE failed");
            fs.SetLength(size); fs.Position = size - 4; fs.Write(new byte[] { 1, 2, 3, 4 }, 0, 4);
        }
    }
}
'@
    [SparseFile]::Create((Join-Path $src 'Docs\Mail\huge.pst'), 3GB + 12345)
}

# An identical copy (same size and date) on the target already, but with other bytes: must not be read again.
$pre = Join-Path $dst 'Docs\already.txt'
[void][IO.Directory]::CreateDirectory((Split-Path $pre))
[IO.File]::WriteAllBytes($pre, [byte[]](66, 66, 66, 66, 66, 66, 66))
[IO.File]::SetLastWriteTimeUtc($pre, (Get-Item (Join-Path $src 'Docs\already.txt')).LastWriteTimeUtc)

$cfgText = @"
@{
    Areas   = @('Docs\Important', 'Docs', 'Photos')
    Front   = @('$key', 'Docs\Mail\old.pst', 'Docs\Letters\', 'Photos\')
    Late    = @{ 'Stuff\Old' = 1; 'Stuff\Clones' = 2 }
    Exclude = @('Stuff\Excluded')
}
"@
[IO.File]::WriteAllText($cfg, $cfgText, (New-Object Text.UTF8Encoding($false)))

# --- Run 1 --------------------------------------------------------------------------------------------------
Write-Host "`nRun 1"
$out = Invoke-Rescue @()
$out | Where-Object { $_ -match 'Front:|Area |Listed|Big files|Read error|not readable|Cycle:|DONE|Exception|error' } | ForEach-Object { "    $_" }
$expected = @($key, 'Docs\Mail\old.pst', 'Docs\Letters\a.txt', 'Docs\Letters\b.txt', 'Photos\a.jpg', 'Photos\big.raw',
              'Docs\Important\z.txt', 'Docs\Important\contract.pdf',
              'Docs\already.txt', 'Docs\readme.txt', 'Docs\video.mp4',
              'notes.txt', 'Stuff\normal.txt', 'Stuff\Old\old.txt', 'Stuff\Clones\clone.txt')
$order = Get-DoneOrder
$main = @($order | Where-Object { $_ -ne 'Docs\bigdoc.bin' -and $_ -ne 'Docs\Mail\huge.pst' })
Check 'copy order: Front, Areas, rest, Late ranks' (($main -join '|') -eq ($expected -join '|')) "`n        got:      $($main -join ', ')`n        expected: $($expected -join ', ')"
Check 'big file comes last' ($order[-1] -in 'Docs\bigdoc.bin', 'Docs\Mail\huge.pst')
foreach ($rel in $expected + 'Docs\bigdoc.bin') { if ($rel -ne 'Docs\already.txt') { Check "copied: $rel" (Test-Copy $rel) } }
Check 'existing identical copy is not read again' (([IO.File]::ReadAllBytes($pre) | Select-Object -First 1) -eq 66)
Check 'Exclude: Stuff\Excluded not copied' (-not (Test-Path (Join-Path $dst 'Stuff\Excluded')))
Check 'SkipDirs: node_modules not copied' (-not (Test-Path (Join-Path $dst 'Stuff\node_modules')))
Check 'junction: not followed' (-not (Test-Path -LiteralPath (Join-Path $dst 'Stuff\LinkToDocs')))
Check 'locked folder: recorded in failed.tsv' (@(Get-Content -LiteralPath (Join-Path $dst '_state\failed.tsv') -Encoding UTF8 | Where-Object { $_.StartsWith("Stuff\Locked\`t-1`t") }).Count -eq 1)
Check 'invalid Unicode name and locked folder: no crash, counted in DONE' (@($out | Where-Object { $_ -match 'DONE .* permanent read errors: 1, folders that could not be listed: 1 ' }).Count -eq 1)
Check 'every file only once in done.tsv' (@($order | Group-Object | Where-Object Count -gt 1).Count -eq 0)
if ($BigFile) {
    Check 'copied: 3 GB file (size and date)' (Test-Copy 'Docs\Mail\huge.pst')
    $fs = [IO.File]::OpenRead((Join-Path $dst 'Docs\Mail\huge.pst')); $fs.Position = $fs.Length - 4; $tail = New-Object byte[] 4; [void]$fs.Read($tail, 0, 4); $fs.Dispose()
    Check '3 GB file: last bytes correct' (($tail -join ',') -eq '1,2,3,4')
}

# --- Run 2: some files "lost" (as if they had never been finished) --------------------------------------------
Write-Host "`nRun 2 (resume)"
$lost = 'Docs\readme.txt', 'Photos\big.raw', 'Stuff\Old\old.txt'
$df = Join-Path $dst '_state\done.tsv'
$keepLines = @(Get-Content -LiteralPath $df -Encoding UTF8 | Where-Object { $lost -notcontains $_.Split("`t")[0] })
[IO.File]::WriteAllLines($df, [string[]]$keepLines, (New-Object Text.UTF8Encoding($false)))
foreach ($r in $lost) { Remove-Item -LiteralPath (Join-Path $dst $r) }
$out2 = Invoke-Rescue @()
$again = @(Get-DoneOrder | Select-Object -Skip $keepLines.Count)
Check 'resume: exactly the lost files are copied again' ((@($again | Sort-Object) -join '|') -eq (@($lost | Sort-Object) -join '|')) "got: $($again -join ', ')"
foreach ($r in $lost) { Check "copied again: $r" (Test-Copy $r) }
Check 'no file twice in done.tsv' (@(Get-DoneOrder | Group-Object | Where-Object Count -gt 1).Count -eq 0)

# --- Run 3: a path with a drive letter would make source and copy the same file - refused -------------------
Write-Host "`nRun 3 (path with drive letter)"
$victim = Join-Path $src 'notes.txt'
$badCfg = Join-Path $work 'bad-config.psd1'
[IO.File]::WriteAllText($badCfg, "@{ Front = @('$($victim.Replace("'", "''"))') }", (New-Object Text.UTF8Encoding($false)))
$out3 = & { $ErrorActionPreference = 'Continue'; & powershell -NoProfile -ExecutionPolicy Bypass -File $script -TestSource $src -Target $dst -Config $badCfg 2>&1 | ForEach-Object { "$_" } }
$exit3 = $LASTEXITCODE
Check 'a path with drive letter is refused' ($exit3 -ne 0 -and (($out3 -join '') -replace '\s', '') -match 'notapathrelativetotheroot')
Check '... and the file is untouched' ((Get-Item -LiteralPath $victim).Length -eq 20)

# --- Run 4: a file list that was interrupted (no end marker) is continued, not a crash ----------------------------
Write-Host "`nRun 4 (interrupted file list)"
$inv = Join-Path $dst '_state\inv_Docs.tsv'
$invLines = @(Get-Content -LiteralPath $inv -Encoding UTF8 | Where-Object { $_ -notmatch "^E`t" })
[IO.File]::WriteAllLines($inv, [string[]]$invLines, (New-Object Text.UTF8Encoding($false)))
$out4 = Invoke-Rescue @()
Check 'restart after an interrupted file list' (@($out4 | Where-Object { $_ -match 'DONE - ' }).Count -eq 1) ($out4 | Where-Object { $_ -match 'Exception|being used' } | Select-Object -First 2 | Out-String)
Check '... and the list is complete again' (@(Get-Content -LiteralPath $inv -Encoding UTF8 | Where-Object { $_ -match "^E`t" }).Count -eq 1)

Write-Host ''
icacls $locked /remove:d "*$sid" | Out-Null
if ($Keep) { Write-Host "Kept: $work" } else { Remove-Item -LiteralPath $work -Recurse -Force }
if ($script:failures) { Write-Host "$($script:failures) check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
