<#
.SYNOPSIS
    Formats every unformatted EBS data volume on an EC2 Windows Server 2022
    instance and assigns it a drive letter.

.DESCRIPTION
    Default behaviour, no parameters needed:
      - finds every non-boot disk that has no partitions
      - brings it online / clears read-only if needed
      - initializes GPT, creates one max-size partition
      - formats NTFS and assigns a drive letter, always starting at D:
        (D:, E:, F: ... skipping any letter already in use)

    Idempotent -- disks that are already formatted are left alone.

.PARAMETER FileSystem
    NTFS (default) or ReFS.

.PARAMETER AllocationUnitSize
    Cluster size in bytes. Default 65536 (64K).

.PARAMETER LabelPrefix
    Volume label prefix; labels become Data1, Data2, ... Default 'Data'.

.PARAMETER Force
    Also wipe and re-provision disks that already contain partitions. DESTRUCTIVE.

.EXAMPLE
    .\Initialize-EbsVolumes.ps1
    Format all new volumes, assign D:, E:, F: ...

.EXAMPLE
    .\Initialize-EbsVolumes.ps1 -WhatIf
    Show what would be done, change nothing.

.EXAMPLE
    .\Initialize-EbsVolumes.ps1 -LabelPrefix SQL

.NOTES
    Run elevated. Windows Server 2022, Nitro (NVMe) and Xen instance families.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('NTFS', 'ReFS')]
    [string] $FileSystem = 'NTFS',

    [ValidateSet(4096, 8192, 16384, 32768, 65536)]
    [int]    $AllocationUnitSize = 65536,

    [string] $LabelPrefix = 'Data',

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ReFS supports 4K and 64K clusters only; NTFS accepts the full set.
if ($FileSystem -eq 'ReFS' -and $AllocationUnitSize -notin @(4096, 65536)) {
    throw "ReFS supports only 4096 or 65536 byte clusters (got $AllocationUnitSize)."
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string] $Level = 'INFO'
    )
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

# Must be elevated -- disk management fails silently-ish otherwise.
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run from an elevated (Administrator) PowerShell session.'
}

# Drive letters always start at D: -- C: is the EC2 root volume.
$script:FirstDriveLetter = 'D'

function Get-FreeDriveLetters {
    param([char] $From = 'D')

    # Each source is wrapped in @() first: these cmdlets return $null (not an
    # empty array) when nothing matches, and property access on $null throws
    # under Set-StrictMode. Win32_NetworkConnection is $null on any server with
    # no mapped network drives, which is the normal case.
    $used = New-Object System.Collections.Generic.List[string]

    # Reads one property StrictMode-safely: tolerates a $null element and an
    # object that simply does not carry the property.
    function Get-Prop {
        param($InputObject, [string] $Name)
        if ($null -eq $InputObject) { return $null }
        $p = $InputObject.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $null
    }

    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue)) {
        $dl = Get-Prop $v 'DriveLetter'
        if ($dl) { $used.Add([string]$dl) }
    }

    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $nm = Get-Prop $d 'Name'
        if ($nm -and ([string]$nm).Length -eq 1) { $used.Add([string]$nm) }
    }

    foreach ($n in @(Get-CimInstance -ClassName Win32_NetworkConnection -ErrorAction SilentlyContinue)) {
        $ln = Get-Prop $n 'LocalName'
        if ($ln) { $used.Add(([string]$ln).TrimEnd(':')) }
    }

    $used = @($used | ForEach-Object { $_.ToUpper() } | Sort-Object -Unique)

    [int][char]$From..[int][char]'Z' | ForEach-Object {
        $l = [char]$_
        if ($used -notcontains "$l") { $l }
    }
}

# ---- Find the disks that need work --------------------------------------

$bootDiskNumbers = @(
    (Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.IsBoot -or $_.IsSystem -or $_.DriveLetter -eq 'C' }
    ).DiskNumber
) | Sort-Object -Unique

$candidates = Get-Disk | Sort-Object Number | Where-Object {
    $_.Number -notin $bootDiskNumbers -and
    ($Force -or $_.PartitionStyle -eq 'RAW' -or $_.NumberOfPartitions -eq 0)
}

if (-not $candidates) {
    Write-Log 'No unformatted data disks found. Nothing to do.' 'OK'
    Get-Disk | Select-Object Number, FriendlyName, BusType, PartitionStyle,
        @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } } | Format-Table -AutoSize
    return
}

Write-Log ("Found {0} disk(s) to format: {1}" -f `
    @($candidates).Count, (@($candidates).Number -join ', ')) 'OK'

$freeLetters = [System.Collections.ArrayList]@(Get-FreeDriveLetters -From $script:FirstDriveLetter)
$index   = 0
$results = @()

foreach ($disk in $candidates) {

    $index++
    $sizeGB = [math]::Round($disk.Size / 1GB, 1)
    $tag    = "Disk $($disk.Number) [$($disk.BusType), ${sizeGB}GB]"

    if ($freeLetters.Count -eq 0) {
        Write-Log "$tag -> no free drive letters remaining. Skipping." 'ERROR'
        $results += [pscustomobject]@{ Disk = $disk.Number; Drive = ''; Label = ''; SizeGB = $sizeGB; Status = 'NoLetterAvailable' }
        continue
    }

    $letter = $freeLetters[0]
    $label  = "$LabelPrefix$index"

    if (-not $PSCmdlet.ShouldProcess($tag, "Initialize GPT, format $FileSystem, assign ${letter}:")) {
        [void]$freeLetters.Remove($letter)
        $results += [pscustomobject]@{ Disk = $disk.Number; Drive = "${letter}:"; Label = $label; SizeGB = $sizeGB; Status = 'WhatIf' }
        continue
    }

    try {
        Write-Log "$tag -> provisioning as ${letter}: ($label)"

        # EBS volumes frequently attach offline and/or read-only.
        if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false;  Write-Log '  brought online' }
        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false; Write-Log '  cleared read-only' }

        $disk = Get-Disk -Number $disk.Number

        if ($Force -and $disk.PartitionStyle -ne 'RAW') {
            Write-Log '  -Force: clearing existing partitions (DESTRUCTIVE)' 'WARN'
            Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
            $disk = Get-Disk -Number $disk.Number
        }

        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false | Out-Null
            Write-Log '  initialized GPT'
        }

        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letter
        Write-Log "  created partition -> ${letter}:"

        $partition | Format-Volume -FileSystem $FileSystem `
            -NewFileSystemLabel $label `
            -AllocationUnitSize $AllocationUnitSize `
            -Confirm:$false -Force | Out-Null
        Write-Log "  formatted $FileSystem ($($AllocationUnitSize / 1KB)K clusters), label '$label'" 'OK'

        [void]$freeLetters.Remove($letter)
        $results += [pscustomobject]@{ Disk = $disk.Number; Drive = "${letter}:"; Label = $label; SizeGB = $sizeGB; Status = 'Formatted' }
    }
    catch {
        Write-Log "$tag -> FAILED: $($_.Exception.Message)" 'ERROR'
        $results += [pscustomobject]@{ Disk = $disk.Number; Drive = "${letter}:"; Label = $label; SizeGB = $sizeGB; Status = "Failed: $($_.Exception.Message)" }
    }
}

Write-Log '--- Summary ---' 'OK'
$results | Format-Table -AutoSize

if ($results | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'NoLetterAvailable' }) { exit 1 }
exit 0
