# Configuration for Rescue-Disk.ps1
#
# Copy this file to "rescue-config.psd1" next to Rescue-Disk.ps1 and adapt it; the script loads that file
# automatically (or pass another one with -Config). rescue-config.psd1 is in .gitignore: it names your folders
# and files and should stay private. Everything here can also be given on the command line (-Model, -Target, ...).
#
# Only Model and Target are needed. The other settings below are examples: remove the "#" in front of the ones you
# want and adapt them. All paths are relative to the root of the rescued partition, without drive letter, for
# example 'Users\anna\Documents' for R:\Users\anna\Documents.
@{
    # Which disk: a regular expression matched against "vendor product" as shown by .\Rescue-Disk.ps1 -ListDisks
    # (or tools\Get-DiskHistory.ps1). The disk with Windows and the disk holding the target are never used, and if
    # more than one disk matches, the script stops.
    Model = 'SSD 950 PRO'

    # Where the copies go: a folder on ANOTHER physical disk with enough free space. The folder structure of the
    # rescued partition is recreated below it, plus _state (progress, file lists) and rescue.log.
    Target = 'E:\Rescue'

    # Drive letter for the rescued partition, if it has none yet. Must be free.
    # Letter = 'R'

    # The most important folders first, in this order. Each area is listed (its complete file list is saved) and
    # then copied, small files first. Everything that is not in an area comes at the end ("rest of the partition").
    # A deeper folder can be an area of its own before its parent, e.g. 'Users\anna\Documents\Company' before
    # 'Users\anna\Documents'. Without areas, the whole partition is listed before the first file is copied.
    # Areas = @(
    #     'Users\anna\Documents\Company'
    #     'Users\anna\Documents'
    #     'Users\anna\Desktop'
    #     'Projects'
    # )

    # Copied first in every cycle and in full, even if bigger than BigMB: single irreplaceable files, or whole
    # folders (ending in "\"). A folder here is listed on its own, before all areas.
    # Front = @(
    #     'Users\anna\Documents\passwords.kdbx'
    #     'Users\anna\Documents\Mail\'
    # )

    # Folders to copy after everything else of their area, rank 1-9 (higher = later), e.g. things that can be
    # downloaded again or old archives. They are still copied, just last.
    # Late = @{
    #     'Projects\old-archive' = 1
    #     'Projects\third-party' = 2
    # }

    # Folders not to rescue at all, e.g. repositories that are complete on GitHub, clones of public projects,
    # installers. Copies made before stay in the target.
    # Exclude = @(
    #     'Projects\third-party\chromium'
    # )

    # Folder names skipped everywhere: caches and build output that can be recreated. This is the default list;
    # setting it replaces the list. (.git, bin and dist ARE copied.)
    # SkipDirs = @('node_modules', '.venv', 'venv', '__pycache__', 'obj', '.next', '.pytest_cache', '.mypy_cache')

    # More folders in the partition root to skip. 'System Volume Information', '$RECYCLE.BIN' and 'Config.Msi'
    # are always skipped. For an old Windows system disk you might skip the Windows folders:
    # SkipRootDirs = @('Windows', 'Program Files', 'Program Files (x86)', '$WinREAgent')

    # Files matching this regular expression are copied after the other files of their area (media, disk images).
    # LateExtensions = '\.(wmv|mp4|avi|mkv|mov|mpg|iso|vhdx?|vmdk|ova)$'

    # Files larger than this (MB) come in a final pass, after all smaller files of all areas. Big files resume
    # where they stopped (the position is saved every 8 MB).
    # BigMB = 500

    # React after this many seconds without an answer from the disk (0 = never): message, and over USB 3 the
    # request to unplug and plug in the disk again.
    # HangSeconds = 5

    # Only if the partition is encrypted with BitLocker and NOT unlocked automatically on this PC: a text file
    # whose first line is the 48-digit recovery password. Keep it outside the repository and delete it after
    # the rescue. Without it, the script asks for the password once (the autostart task cannot ask).
    # BitLockerKeyFile = 'C:\Private\bitlocker-recovery.txt'

    # Rarely needed:
    # WaitSeconds = 0          # how long to wait for the disk; 0 = forever
    # PortRestart = $false     # experimental: USB port restart / device off-on instead of asking to replug
    # OffSeconds  = 5          # with PortRestart: how long the USB device stays off
}
