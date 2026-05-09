<#
.SYNOPSIS
Converts a MikroTik CHR VHDX image so it can boot as a Hyper-V Generation 2 VM.

.DESCRIPTION
Official x86_64 MikroTik CHR images contain \EFI\BOOT\BOOTX64.EFI, but the
first boot partition is ext2/3. Hyper-V Generation 2 firmware expects the EFI
fallback loader to live on a FAT filesystem, so it does not boot the stock
image.

This script creates a patched copy of the VHDX by:
  1. mounting the VHDX with the Hyper-V PowerShell module,
  2. reading files from the first ext2/3 boot partition,
  3. building a FAT16 filesystem containing those boot files,
  4. writing that FAT16 filesystem back to the first partition.

It intentionally leaves the RouterOS/root partition untouched. For RouterOS
7.15+ images with a one-sector GPT overlap, the FAT size is capped at the start
of the next partition to avoid overwriting RouterOS data.

Requirements:
  - Run from an elevated PowerShell session.
  - Hyper-V PowerShell module must be installed.
  - Secure Boot must be disabled on the Hyper-V Gen2 VM.

.EXAMPLE
.\Convert-MikroTikChrVhdxGen2.ps1 -Path .\chr-7.20.8.vhdx

Creates .\chr-7.20.8.gen2.vhdx.

.EXAMPLE
.\Convert-MikroTikChrVhdxGen2.ps1 -Path .\chr.vhdx -OutputPath .\chr-gen2.vhdx -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path,

    [Parameter(Position = 1)]
    [string]$OutputPath,

    [switch]$Force,

    [switch]$KeepWorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }
}

function Resolve-NewPath {
    param([Parameter(Mandatory = $true)][string]$MaybeRelativePath)

    if ([IO.Path]::IsPathRooted($MaybeRelativePath)) {
        return [IO.Path]::GetFullPath($MaybeRelativePath)
    }

    return [IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $MaybeRelativePath))
}

function Get-DefaultOutputPath {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $directory = Split-Path -Parent $InputPath
    $name = [IO.Path]::GetFileNameWithoutExtension($InputPath)
    $extension = [IO.Path]::GetExtension($InputPath)
    return Join-Path -Path $directory -ChildPath "$name.gen2$extension"
}

function Read-DiskBytes {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][Int64]$Offset,
        [Parameter(Mandatory = $true)][int]$Count
    )

    # Windows raw disk handles require sector-aligned reads. ext inodes and
    # group descriptors are smaller than a sector, so read the containing
    # sectors first and then slice out the requested bytes.
    $sectorSize = 512
    $alignedOffset = $Offset - ($Offset % $sectorSize)
    $delta = [int]($Offset - $alignedOffset)
    $alignedCount = [int]([Math]::Ceiling(($delta + $Count) / [double]$sectorSize) * $sectorSize)

    [void]$Stream.Seek($alignedOffset, [IO.SeekOrigin]::Begin)
    [byte[]]$buffer = New-Object byte[] $alignedCount
    $done = 0
    while ($done -lt $alignedCount) {
        $read = $Stream.Read($buffer, $done, $alignedCount - $done)
        if ($read -le 0) {
            throw "Unexpected end of disk while reading $alignedCount bytes at offset $alignedOffset."
        }
        $done += $read
    }

    [byte[]]$result = New-Object byte[] $Count
    [Array]::Copy($buffer, $delta, $result, 0, $Count)
    return ,$result
}

function Write-DiskBytes {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][Int64]$Offset,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    [void]$Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}

function Read-U16 {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-U32 {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Set-U16 {
    param([byte[]]$Bytes, [int]$Offset, [UInt16]$Value)
    $Bytes[$Offset] = [byte]($Value -band 0xff)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xff)
}

function Set-U32 {
    param([byte[]]$Bytes, [int]$Offset, [UInt32]$Value)
    $Bytes[$Offset] = [byte]($Value -band 0xff)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xff)
    $Bytes[$Offset + 2] = [byte](($Value -shr 16) -band 0xff)
    $Bytes[$Offset + 3] = [byte](($Value -shr 24) -band 0xff)
}

function Get-ExtFileSystem {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][Int64]$PartitionOffset
    )

    $super = Read-DiskBytes -Stream $Stream -Offset ($PartitionOffset + 1024) -Count 1024
    $magic = Read-U16 -Bytes $super -Offset 56
    if ($magic -ne 0xef53) {
        throw 'The first partition is not ext2/3/4, or it has already been patched.'
    }

    $logBlockSize = [int](Read-U32 -Bytes $super -Offset 24)
    $blockSize = 1024 -shl $logBlockSize
    $descriptorSize = 32
    $featureIncompat = Read-U32 -Bytes $super -Offset 96
    if (($featureIncompat -band 0x80) -ne 0 -and $super.Length -ge 256) {
        $fromSuper = Read-U16 -Bytes $super -Offset 254
        if ($fromSuper -ge 32) {
            $descriptorSize = $fromSuper
        }
    }

    $inodeSize = Read-U16 -Bytes $super -Offset 88
    if ($inodeSize -eq 0) {
        $inodeSize = 128
    }

    $groupDescriptorOffset = if ($blockSize -eq 1024) {
        $PartitionOffset + (2 * $blockSize)
    } else {
        $PartitionOffset + $blockSize
    }

    return @{
        Stream = $Stream
        PartitionOffset = $PartitionOffset
        BlockSize = $blockSize
        BlocksPerGroup = Read-U32 -Bytes $super -Offset 32
        InodesPerGroup = Read-U32 -Bytes $super -Offset 40
        InodeSize = [int]$inodeSize
        DescriptorSize = [int]$descriptorSize
        GroupDescriptorOffset = $groupDescriptorOffset
    }
}

function Read-ExtBlock {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fs,
        [Parameter(Mandatory = $true)][UInt64]$BlockNumber
    )

    $offset = [Int64]($Fs.PartitionOffset + ([Int64]$BlockNumber * [Int64]$Fs.BlockSize))
    return ,(Read-DiskBytes -Stream $Fs.Stream -Offset $offset -Count $Fs.BlockSize)
}

function Get-ExtInode {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fs,
        [Parameter(Mandatory = $true)][UInt32]$InodeNumber
    )

    if ($InodeNumber -lt 1) {
        throw "Invalid inode number $InodeNumber."
    }

    $zeroBased = [UInt64]($InodeNumber - 1)
    $group = [UInt64][Math]::Floor($zeroBased / [double]$Fs.InodesPerGroup)
    $index = [UInt64]($zeroBased % [UInt64]$Fs.InodesPerGroup)
    $descriptorOffset = [Int64]($Fs.GroupDescriptorOffset + ([Int64]$group * [Int64]$Fs.DescriptorSize))
    $descriptor = Read-DiskBytes -Stream $Fs.Stream -Offset $descriptorOffset -Count $Fs.DescriptorSize
    [UInt64]$inodeTableBlock = Read-U32 -Bytes $descriptor -Offset 8
    if ($Fs.DescriptorSize -ge 64) {
        [UInt64]$inodeTableBlock += ([UInt64](Read-U32 -Bytes $descriptor -Offset 40) * 4294967296)
    }

    $inodeOffset = [Int64]($Fs.PartitionOffset + ([Int64]$inodeTableBlock * [Int64]$Fs.BlockSize) + ([Int64]$index * [Int64]$Fs.InodeSize))
    $raw = Read-DiskBytes -Stream $Fs.Stream -Offset $inodeOffset -Count $Fs.InodeSize
    [UInt64]$size = Read-U32 -Bytes $raw -Offset 4
    if ($Fs.InodeSize -gt 108) {
        [UInt64]$size += ([UInt64](Read-U32 -Bytes $raw -Offset 108) * 4294967296)
    }

    $blockPointers = New-Object 'System.Collections.Generic.List[UInt32]'
    for ($i = 0; $i -lt 15; $i++) {
        [void]$blockPointers.Add((Read-U32 -Bytes $raw -Offset (40 + ($i * 4))))
    }

    return [pscustomobject]@{
        Number = $InodeNumber
        Mode = Read-U16 -Bytes $raw -Offset 0
        Size = $size
        Flags = Read-U32 -Bytes $raw -Offset 32
        Raw = $raw
        Blocks = $blockPointers
    }
}

function Get-ExtentsFromNode {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fs,
        [Parameter(Mandatory = $true)][byte[]]$NodeBytes
    )

    $magic = Read-U16 -Bytes $NodeBytes -Offset 0
    if ($magic -ne 0xf30a) {
        throw 'Unsupported ext4 extent tree.'
    }

    $entries = Read-U16 -Bytes $NodeBytes -Offset 2
    $depth = Read-U16 -Bytes $NodeBytes -Offset 6
    $result = New-Object 'System.Collections.Generic.List[object]'

    if ($depth -eq 0) {
        for ($i = 0; $i -lt $entries; $i++) {
            $entryOffset = 12 + ($i * 12)
            $logical = Read-U32 -Bytes $NodeBytes -Offset $entryOffset
            $length = (Read-U16 -Bytes $NodeBytes -Offset ($entryOffset + 4)) -band 0x7fff
            [UInt64]$physical = ([UInt64](Read-U16 -Bytes $NodeBytes -Offset ($entryOffset + 6)) * 4294967296) + [UInt64](Read-U32 -Bytes $NodeBytes -Offset ($entryOffset + 8))
            [void]$result.Add([pscustomobject]@{
                Logical = [UInt32]$logical
                Physical = [UInt64]$physical
                Length = [UInt32]$length
            })
        }
    } else {
        for ($i = 0; $i -lt $entries; $i++) {
            $entryOffset = 12 + ($i * 12)
            [UInt64]$leaf = [UInt64](Read-U32 -Bytes $NodeBytes -Offset ($entryOffset + 4)) + ([UInt64](Read-U16 -Bytes $NodeBytes -Offset ($entryOffset + 8)) * 4294967296)
            $child = Read-ExtBlock -Fs $Fs -BlockNumber $leaf
            $childExtents = Get-ExtentsFromNode -Fs $Fs -NodeBytes $child
            foreach ($extent in $childExtents) {
                [void]$result.Add($extent)
            }
        }
    }

    return ,$result.ToArray()
}

function Get-ExtFileBlockMap {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fs,
        [Parameter(Mandatory = $true)]$Inode
    )

    $neededBlocks = [int][Math]::Ceiling([double]$Inode.Size / [double]$Fs.BlockSize)
    $blocks = New-Object 'System.Collections.Generic.List[UInt64]'
    if ($neededBlocks -eq 0) {
        return ,$blocks.ToArray()
    }

    if (($Inode.Flags -band 0x00080000) -ne 0) {
        $extentHeader = New-Object byte[] 60
        [Array]::Copy($Inode.Raw, 40, $extentHeader, 0, 60)
        $extents = Get-ExtentsFromNode -Fs $Fs -NodeBytes $extentHeader
        [UInt64[]]$map = New-Object UInt64[] $neededBlocks

        foreach ($extent in $extents) {
            for ($i = 0; $i -lt $extent.Length; $i++) {
                $logical = [int]($extent.Logical + $i)
                if ($logical -lt $neededBlocks) {
                    $map[$logical] = [UInt64]($extent.Physical + $i)
                }
            }
        }

        foreach ($block in $map) {
            [void]$blocks.Add($block)
        }
        return ,$blocks.ToArray()
    }

    function Add-IndirectBlocks {
        param(
            [Parameter(Mandatory = $true)][hashtable]$LocalFs,
            [Parameter(Mandatory = $true)][UInt64]$BlockNumber,
            [Parameter(Mandatory = $true)][int]$Level,
            [Parameter(Mandatory = $true)]$TargetList,
            [Parameter(Mandatory = $true)][int]$Limit
        )

        if ($BlockNumber -eq 0 -or $TargetList.Count -ge $Limit) {
            return
        }

        $bytes = Read-ExtBlock -Fs $LocalFs -BlockNumber $BlockNumber
        $pointers = [int]($LocalFs.BlockSize / 4)
        for ($i = 0; $i -lt $pointers; $i++) {
            if ($TargetList.Count -ge $Limit) {
                return
            }

            [UInt64]$pointer = Read-U32 -Bytes $bytes -Offset ($i * 4)
            if ($Level -eq 1) {
                [void]$TargetList.Add($pointer)
            } else {
                Add-IndirectBlocks -LocalFs $LocalFs -BlockNumber $pointer -Level ($Level - 1) -TargetList $TargetList -Limit $Limit
            }
        }
    }

    for ($i = 0; $i -lt 12 -and $blocks.Count -lt $neededBlocks; $i++) {
        [void]$blocks.Add([UInt64]$Inode.Blocks[$i])
    }

    Add-IndirectBlocks -LocalFs $Fs -BlockNumber ([UInt64]$Inode.Blocks[12]) -Level 1 -TargetList $blocks -Limit $neededBlocks
    Add-IndirectBlocks -LocalFs $Fs -BlockNumber ([UInt64]$Inode.Blocks[13]) -Level 2 -TargetList $blocks -Limit $neededBlocks
    Add-IndirectBlocks -LocalFs $Fs -BlockNumber ([UInt64]$Inode.Blocks[14]) -Level 3 -TargetList $blocks -Limit $neededBlocks

    return ,$blocks.ToArray()
}

function Read-ExtFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fs,
        [Parameter(Mandatory = $true)]$Inode
    )

    if ($Inode.Size -eq 0) {
        return ,(New-Object byte[] 0)
    }

    $modeType = $Inode.Mode -band 0xf000
    if ($modeType -eq 0xa000 -and $Inode.Size -le 60) {
        [byte[]]$inline = New-Object byte[] ([int]$Inode.Size)
        [Array]::Copy($Inode.Raw, 40, $inline, 0, [int]$Inode.Size)
        return ,$inline
    }

    $stream = New-Object IO.MemoryStream
    [Int64]$remaining = $Inode.Size
    $blockMap = Get-ExtFileBlockMap -Fs $Fs -Inode $Inode
    foreach ($blockNumber in $blockMap) {
        if ($remaining -le 0) {
            break
        }

        $count = [int][Math]::Min([Int64]$Fs.BlockSize, $remaining)
        if ($blockNumber -eq 0) {
            [byte[]]$zeroes = New-Object byte[] $Fs.BlockSize
            $stream.Write($zeroes, 0, $count)
        } else {
            $block = Read-ExtBlock -Fs $Fs -BlockNumber $blockNumber
            $stream.Write($block, 0, $count)
        }
        $remaining -= $count
    }

    if ($remaining -gt 0) {
        throw "Could not read complete file from inode $($Inode.Number)."
    }

    return ,$stream.ToArray()
}

function Get-ExtDirectoryEntries {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fs,
        [Parameter(Mandatory = $true)]$Inode
    )

    $data = Read-ExtFile -Fs $Fs -Inode $Inode
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $offset = 0
    while ($offset + 8 -le $data.Length) {
        $inodeNumber = Read-U32 -Bytes $data -Offset $offset
        $recordLength = Read-U16 -Bytes $data -Offset ($offset + 4)
        $nameLength = [int]$data[$offset + 6]
        if ($recordLength -lt 8) {
            break
        }

        if ($inodeNumber -ne 0 -and $nameLength -gt 0 -and ($offset + 8 + $nameLength) -le $data.Length) {
            $nameBytes = New-Object byte[] $nameLength
            [Array]::Copy($data, $offset + 8, $nameBytes, 0, $nameLength)
            $name = [Text.Encoding]::UTF8.GetString($nameBytes)
            if ($name -ne '.' -and $name -ne '..') {
                [void]$entries.Add([pscustomobject]@{
                    Name = $name
                    Inode = [UInt32]$inodeNumber
                })
            }
        }

        $offset += $recordLength
    }

    return ,$entries.ToArray()
}

function Export-ExtDirectory {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fs,
        [Parameter(Mandatory = $true)][UInt32]$InodeNumber,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $inode = Get-ExtInode -Fs $Fs -InodeNumber $InodeNumber
    $entries = Get-ExtDirectoryEntries -Fs $Fs -Inode $inode
    foreach ($entry in $entries) {
        $childInode = Get-ExtInode -Fs $Fs -InodeNumber $entry.Inode
        $modeType = $childInode.Mode -band 0xf000
        $target = Join-Path -Path $Destination -ChildPath $entry.Name

        if ($modeType -eq 0x4000) {
            Export-ExtDirectory -Fs $Fs -InodeNumber $entry.Inode -Destination $target
        } elseif ($modeType -eq 0x8000) {
            $bytes = Read-ExtFile -Fs $Fs -Inode $childInode
            [IO.File]::WriteAllBytes($target, $bytes)
        } else {
            Write-Verbose "Skipping non-regular boot partition entry: $($entry.Name)"
        }
    }
}

function Get-Fat83ShortName {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $upper = $Name.ToUpperInvariant()
    if ($upper -eq '.' -or $upper -eq '..') {
        return $null
    }

    $parts = $upper.Split('.')
    if ($parts.Count -gt 2) {
        return $null
    }

    $base = $parts[0]
    $extension = if ($parts.Count -eq 2) { $parts[1] } else { '' }
    if ($base.Length -lt 1 -or $base.Length -gt 8 -or $extension.Length -gt 3) {
        return $null
    }

    $allowed = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' + '$' + "%'-_@~" + '`' + '!(){}^#&'
    foreach ($character in $base.ToCharArray()) {
        if ($allowed.IndexOf($character) -lt 0) {
            return $null
        }
    }
    foreach ($character in $extension.ToCharArray()) {
        if ($allowed.IndexOf($character) -lt 0) {
            return $null
        }
    }

    return ($base.PadRight(8, ' ') + $extension.PadRight(3, ' '))
}

function New-FatTree {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$Name = '',
        [string]$ShortName = ''
    )

    $children = New-Object 'System.Collections.Generic.List[object]'
    $clusters = New-Object 'System.Collections.Generic.List[UInt16]'
    $node = [pscustomobject]@{
        Name = $Name
        ShortName = $ShortName
        Path = $SourcePath
        IsDirectory = $true
        Size = [Int64]0
        Children = $children
        Clusters = $clusters
        FirstCluster = [UInt16]0
    }

    $usedShortNames = @{}
    $items = Get-ChildItem -LiteralPath $SourcePath -Force | Sort-Object -Property @{ Expression = 'PSIsContainer'; Descending = $true }, Name
    foreach ($item in $items) {
        if ($item.Name -eq 'lost+found') {
            Write-Verbose 'Skipping ext lost+found directory.'
            continue
        }

        $childShortName = Get-Fat83ShortName -Name $item.Name
        if ($null -eq $childShortName) {
            Write-Warning "Skipping '$($item.Name)' because it is not an 8.3 FAT name. It is not required for CHR UEFI boot."
            continue
        }
        if ($usedShortNames.ContainsKey($childShortName)) {
            Write-Warning "Skipping '$($item.Name)' because its FAT 8.3 name collides with another file."
            continue
        }
        $usedShortNames[$childShortName] = $true

        if ($item.PSIsContainer) {
            [void]$children.Add((New-FatTree -SourcePath $item.FullName -Name $item.Name -ShortName $childShortName))
        } else {
            $fileClusters = New-Object 'System.Collections.Generic.List[UInt16]'
            [void]$children.Add([pscustomobject]@{
                Name = $item.Name
                ShortName = $childShortName
                Path = $item.FullName
                IsDirectory = $false
                Size = [Int64]$item.Length
                Children = $null
                Clusters = $fileClusters
                FirstCluster = [UInt16]0
            })
        }
    }

    return $node
}

function New-ClusterRun {
    param(
        [Parameter(Mandatory = $true)][ref]$NextCluster,
        [Parameter(Mandatory = $true)][int]$Count
    )

    $clusters = New-Object 'System.Collections.Generic.List[UInt16]'
    for ($i = 0; $i -lt $Count; $i++) {
        if ($NextCluster.Value -gt 0xffef) {
            throw 'FAT16 cluster number limit exceeded.'
        }
        [void]$clusters.Add([UInt16]$NextCluster.Value)
        $NextCluster.Value = [int]$NextCluster.Value + 1
    }
    return ,$clusters
}

function Assign-FatClusters {
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][bool]$IsRoot,
        [Parameter(Mandatory = $true)][int]$ClusterBytes,
        [Parameter(Mandatory = $true)][ref]$NextCluster
    )

    if ($Node.IsDirectory) {
        if (-not $IsRoot) {
            $entryBytes = ($Node.Children.Count + 2) * 32
            $clusterCount = [Math]::Max(1, [int][Math]::Ceiling([double]$entryBytes / [double]$ClusterBytes))
            $Node.Clusters = New-ClusterRun -NextCluster $NextCluster -Count $clusterCount
            $Node.FirstCluster = $Node.Clusters[0]
        }

        foreach ($child in $Node.Children) {
            Assign-FatClusters -Node $child -IsRoot:$false -ClusterBytes $ClusterBytes -NextCluster $NextCluster
        }
    } else {
        if ($Node.Size -gt 0) {
            $clusterCount = [int][Math]::Ceiling([double]$Node.Size / [double]$ClusterBytes)
            $Node.Clusters = New-ClusterRun -NextCluster $NextCluster -Count $clusterCount
            $Node.FirstCluster = $Node.Clusters[0]
        }
    }
}

function Get-FatTimestamp {
    $now = Get-Date
    $year = [Math]::Max(1980, [Math]::Min(2107, $now.Year))
    $date = (($year - 1980) -shl 9) -bor ($now.Month -shl 5) -bor $now.Day
    $time = ($now.Hour -shl 11) -bor ($now.Minute -shl 5) -bor ([int]($now.Second / 2))
    return @{
        Date = [UInt16]$date
        Time = [UInt16]$time
    }
}

function New-FatDirectoryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ShortName,
        [Parameter(Mandatory = $true)][byte]$Attributes,
        [Parameter(Mandatory = $true)][UInt16]$FirstCluster,
        [Parameter(Mandatory = $true)][UInt32]$Size
    )

    $entry = New-Object byte[] 32
    $nameBytes = [Text.Encoding]::ASCII.GetBytes($ShortName)
    [Array]::Copy($nameBytes, 0, $entry, 0, 11)
    $entry[11] = $Attributes
    $stamp = Get-FatTimestamp
    Set-U16 -Bytes $entry -Offset 14 -Value $stamp.Time
    Set-U16 -Bytes $entry -Offset 16 -Value $stamp.Date
    Set-U16 -Bytes $entry -Offset 22 -Value $stamp.Time
    Set-U16 -Bytes $entry -Offset 24 -Value $stamp.Date
    Set-U16 -Bytes $entry -Offset 26 -Value $FirstCluster
    Set-U32 -Bytes $entry -Offset 28 -Value $Size
    return ,$entry
}

function New-FatDirectoryBytes {
    param(
        [Parameter(Mandatory = $true)]$Node,
        $ParentNode,
        [Parameter(Mandatory = $true)][bool]$IsRoot,
        [Parameter(Mandatory = $true)][int]$MinimumBytes
    )

    $entries = New-Object 'System.Collections.Generic.List[byte[]]'
    if (-not $IsRoot) {
        [void]$entries.Add((New-FatDirectoryEntry -ShortName '.          ' -Attributes 0x10 -FirstCluster $Node.FirstCluster -Size 0))
        $parentCluster = if ($null -eq $ParentNode) { [UInt16]0 } else { [UInt16]$ParentNode.FirstCluster }
        [void]$entries.Add((New-FatDirectoryEntry -ShortName '..         ' -Attributes 0x10 -FirstCluster $parentCluster -Size 0))
    }

    foreach ($child in $Node.Children) {
        $attributes = if ($child.IsDirectory) { [byte]0x10 } else { [byte]0x20 }
        [void]$entries.Add((New-FatDirectoryEntry -ShortName $child.ShortName -Attributes $attributes -FirstCluster $child.FirstCluster -Size ([UInt32]$child.Size)))
    }

    $neededBytes = $entries.Count * 32
    $bufferLength = [Math]::Max($MinimumBytes, $neededBytes)
    $buffer = New-Object byte[] $bufferLength
    for ($i = 0; $i -lt $entries.Count; $i++) {
        [Array]::Copy($entries[$i], 0, $buffer, $i * 32, 32)
    }
    return ,$buffer
}

function Copy-BytesIntoImage {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Source,
        [Parameter(Mandatory = $true)][byte[]]$Image,
        [Parameter(Mandatory = $true)][Int64]$ImageOffset,
        [Parameter(Mandatory = $true)][int]$Count
    )

    [Array]::Copy($Source, 0, $Image, $ImageOffset, $Count)
}

function Set-FatEntry {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Fat,
        [Parameter(Mandatory = $true)][UInt16]$Cluster,
        [Parameter(Mandatory = $true)][UInt16]$Value
    )

    $offset = [int]$Cluster * 2
    Set-U16 -Bytes $Fat -Offset $offset -Value $Value
}

function Mark-FatChains {
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][byte[]]$Fat
    )

    if ($Node.Clusters -and $Node.Clusters.Count -gt 0) {
        for ($i = 0; $i -lt $Node.Clusters.Count; $i++) {
            $value = if ($i -eq ($Node.Clusters.Count - 1)) { [UInt16]0xffff } else { [UInt16]$Node.Clusters[$i + 1] }
            Set-FatEntry -Fat $Fat -Cluster $Node.Clusters[$i] -Value $value
        }
    }

    if ($Node.IsDirectory) {
        foreach ($child in $Node.Children) {
            Mark-FatChains -Node $child -Fat $Fat
        }
    }
}

function Write-FatNodeData {
    param(
        [Parameter(Mandatory = $true)]$Node,
        $ParentNode,
        [Parameter(Mandatory = $true)][byte[]]$Image,
        [Parameter(Mandatory = $true)][Int64]$DataOffset,
        [Parameter(Mandatory = $true)][int]$ClusterBytes
    )

    if ($Node.IsDirectory) {
        if ($Node.Clusters.Count -gt 0) {
            $directoryBytes = New-FatDirectoryBytes -Node $Node -ParentNode $ParentNode -IsRoot:$false -MinimumBytes ($Node.Clusters.Count * $ClusterBytes)
            for ($i = 0; $i -lt $Node.Clusters.Count; $i++) {
                $clusterOffset = $DataOffset + ([Int64]($Node.Clusters[$i] - 2) * $ClusterBytes)
                [Array]::Copy($directoryBytes, $i * $ClusterBytes, $Image, $clusterOffset, $ClusterBytes)
            }
        }

        foreach ($child in $Node.Children) {
            Write-FatNodeData -Node $child -ParentNode $Node -Image $Image -DataOffset $DataOffset -ClusterBytes $ClusterBytes
        }
    } elseif ($Node.Size -gt 0) {
        $fileBytes = [IO.File]::ReadAllBytes($Node.Path)
        $remaining = $fileBytes.Length
        $fileOffset = 0
        for ($i = 0; $i -lt $Node.Clusters.Count; $i++) {
            $count = [Math]::Min($ClusterBytes, $remaining)
            $clusterOffset = $DataOffset + ([Int64]($Node.Clusters[$i] - 2) * $ClusterBytes)
            [Array]::Copy($fileBytes, $fileOffset, $Image, $clusterOffset, $count)
            $fileOffset += $count
            $remaining -= $count
        }
    }
}

function New-Fat16Image {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][UInt32]$TotalSectors,
        [Parameter(Mandatory = $true)][UInt32]$HiddenSectors
    )

    $bytesPerSector = 512
    $sectorsPerCluster = 2
    $reservedSectors = 1
    $fatCount = 2
    $rootEntries = 512
    $rootDirectorySectors = [int][Math]::Ceiling(($rootEntries * 32) / [double]$bytesPerSector)
    $fatSectors = 1

    do {
        $previousFatSectors = $fatSectors
        $dataSectors = [int]$TotalSectors - $reservedSectors - $rootDirectorySectors - ($fatCount * $fatSectors)
        $clusterCount = [int][Math]::Floor($dataSectors / [double]$sectorsPerCluster)
        $fatSectors = [int][Math]::Ceiling((($clusterCount + 2) * 2) / [double]$bytesPerSector)
    } while ($fatSectors -ne $previousFatSectors)

    $dataSectors = [int]$TotalSectors - $reservedSectors - $rootDirectorySectors - ($fatCount * $fatSectors)
    $clusterCount = [int][Math]::Floor($dataSectors / [double]$sectorsPerCluster)
    if ($clusterCount -lt 4085 -or $clusterCount -ge 65525) {
        throw "The boot partition size yields $clusterCount clusters, which is not valid FAT16."
    }

    $clusterBytes = $bytesPerSector * $sectorsPerCluster
    $root = New-FatTree -SourcePath $SourceDirectory
    $nextClusterValue = 2
    $nextCluster = [ref]$nextClusterValue
    Assign-FatClusters -Node $root -IsRoot:$true -ClusterBytes $clusterBytes -NextCluster $nextCluster
    $usedClusters = [int]$nextCluster.Value - 2
    if ($usedClusters -gt $clusterCount) {
        throw "Boot files need $usedClusters clusters but the FAT16 image has only $clusterCount."
    }

    $imageLength = [int64]$TotalSectors * $bytesPerSector
    if ($imageLength -gt 512MB) {
        throw "Refusing to build a $imageLength byte FAT image in memory."
    }

    [byte[]]$image = New-Object byte[] ([int]$imageLength)
    $boot = New-Object byte[] $bytesPerSector
    $boot[0] = 0xeb
    $boot[1] = 0x3c
    $boot[2] = 0x90
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('MSDOS5.0'), 0, $boot, 3, 8)
    Set-U16 -Bytes $boot -Offset 11 -Value ([UInt16]$bytesPerSector)
    $boot[13] = [byte]$sectorsPerCluster
    Set-U16 -Bytes $boot -Offset 14 -Value ([UInt16]$reservedSectors)
    $boot[16] = [byte]$fatCount
    Set-U16 -Bytes $boot -Offset 17 -Value ([UInt16]$rootEntries)
    if ($TotalSectors -lt 65536) {
        Set-U16 -Bytes $boot -Offset 19 -Value ([UInt16]$TotalSectors)
    } else {
        Set-U16 -Bytes $boot -Offset 19 -Value 0
        Set-U32 -Bytes $boot -Offset 32 -Value $TotalSectors
    }
    $boot[21] = 0xf8
    Set-U16 -Bytes $boot -Offset 22 -Value ([UInt16]$fatSectors)
    Set-U16 -Bytes $boot -Offset 24 -Value 63
    Set-U16 -Bytes $boot -Offset 26 -Value 255
    Set-U32 -Bytes $boot -Offset 28 -Value $HiddenSectors
    $boot[36] = 0x80
    $boot[38] = 0x29
    $volumeId = [UInt32]((Get-Random -Minimum 1 -Maximum ([int]::MaxValue)) -band 0xffffffff)
    Set-U32 -Bytes $boot -Offset 39 -Value $volumeId
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('ROUTEROS   '), 0, $boot, 43, 11)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('FAT16   '), 0, $boot, 54, 8)
    $boot[510] = 0x55
    $boot[511] = 0xaa
    [Array]::Copy($boot, 0, $image, 0, $bytesPerSector)

    [byte[]]$fat = New-Object byte[] ($fatSectors * $bytesPerSector)
    Set-FatEntry -Fat $fat -Cluster 0 -Value 0xfff8
    Set-FatEntry -Fat $fat -Cluster 1 -Value 0xffff
    Mark-FatChains -Node $root -Fat $fat

    $fatOffset = $reservedSectors * $bytesPerSector
    for ($i = 0; $i -lt $fatCount; $i++) {
        [Array]::Copy($fat, 0, $image, $fatOffset + ($i * $fat.Length), $fat.Length)
    }

    $rootDirectoryOffset = ($reservedSectors + ($fatCount * $fatSectors)) * $bytesPerSector
    $rootDirectoryBytes = New-FatDirectoryBytes -Node $root -ParentNode $null -IsRoot:$true -MinimumBytes ($rootDirectorySectors * $bytesPerSector)
    if ($rootDirectoryBytes.Length -gt ($rootDirectorySectors * $bytesPerSector)) {
        throw 'Too many files in the FAT16 root directory.'
    }
    [Array]::Copy($rootDirectoryBytes, 0, $image, $rootDirectoryOffset, $rootDirectoryBytes.Length)

    $dataOffset = ($reservedSectors + ($fatCount * $fatSectors) + $rootDirectorySectors) * $bytesPerSector
    foreach ($child in $root.Children) {
        Write-FatNodeData -Node $child -ParentNode $root -Image $image -DataOffset $dataOffset -ClusterBytes $clusterBytes
    }

    Write-Verbose "Built FAT16 image: sectors=$TotalSectors clusters=$clusterCount usedClusters=$usedClusters fatSectors=$fatSectors."
    return ,$image
}

function Get-UsableBootPartitionSectors {
    param(
        [Parameter(Mandatory = $true)]$BootPartition,
        [Parameter(Mandatory = $true)]$AllPartitions
    )

    $sectorSize = 512
    [UInt64]$partitionSectors = [UInt64]($BootPartition.Size / $sectorSize)
    $nextPartition = $AllPartitions |
        Where-Object { $_.Offset -gt $BootPartition.Offset } |
        Sort-Object Offset |
        Select-Object -First 1

    if ($null -ne $nextPartition) {
        [UInt64]$gapSectors = [UInt64](($nextPartition.Offset - $BootPartition.Offset) / $sectorSize)
        if ($gapSectors -gt 0 -and $gapSectors -lt $partitionSectors) {
            Write-Warning "Partition table reports partition 1 as $partitionSectors sectors, but partition 2 starts after $gapSectors sectors. Using $gapSectors sectors to avoid overlap."
            return [UInt32]$gapSectors
        }
    }

    return [UInt32]$partitionSectors
}

Assert-Administrator
if (-not (Get-Command Mount-VHD -ErrorAction SilentlyContinue)) {
    throw 'Mount-VHD was not found. Install/enable the Hyper-V PowerShell module first.'
}

$sourcePath = (Resolve-Path -LiteralPath $Path).Path
if (-not $OutputPath) {
    $OutputPath = Get-DefaultOutputPath -InputPath $sourcePath
}
$targetPath = Resolve-NewPath -MaybeRelativePath $OutputPath

if ([string]::Equals($sourcePath, $targetPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputPath must be different from Path. This script patches a copy to keep the source image intact.'
}

if ((Test-Path -LiteralPath $targetPath) -and -not $Force) {
    throw "Output file already exists: $targetPath. Use -Force to overwrite it."
}

$targetDirectory = Split-Path -Parent $targetPath
if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $targetDirectory | Out-Null
}

if (Test-Path -LiteralPath $targetPath) {
    Remove-Item -LiteralPath $targetPath -Force
}

Write-Host "Copying source VHDX to: $targetPath"
Copy-Item -LiteralPath $sourcePath -Destination $targetPath

$workDir = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('chr-gen2-' + [guid]::NewGuid().ToString('N'))
$bootFilesDir = Join-Path -Path $workDir -ChildPath 'bootpart'
New-Item -ItemType Directory -Force -Path $bootFilesDir | Out-Null

$mounted = $null
$rawStream = $null
try {
    Write-Host 'Mounting VHDX...'
    $mounted = Mount-VHD -Path $targetPath -PassThru
    $disk = $mounted | Get-Disk
    if ($disk.IsOffline) {
        Set-Disk -Number $disk.Number -IsOffline $false
    }
    if ($disk.IsReadOnly) {
        Set-Disk -Number $disk.Number -IsReadOnly $false
    }

    $partitions = @(Get-Partition -DiskNumber $disk.Number | Sort-Object Offset)
    if ($partitions.Count -lt 1) {
        throw 'No partitions found in the VHDX.'
    }

    $bootPartition = $partitions[0]
    $usableSectors = Get-UsableBootPartitionSectors -BootPartition $bootPartition -AllPartitions $partitions
    if ($usableSectors -lt 8192) {
        throw "Boot partition is unexpectedly small: $usableSectors sectors."
    }

    $physicalDrive = "\\.\PhysicalDrive$($disk.Number)"
    $rawStream = [IO.File]::Open($physicalDrive, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)

    Write-Host 'Reading ext2/3 boot partition...'
    $ext = Get-ExtFileSystem -Stream $rawStream -PartitionOffset ([Int64]$bootPartition.Offset)
    Export-ExtDirectory -Fs $ext -InodeNumber 2 -Destination $bootFilesDir

    $bootLoader = Join-Path -Path $bootFilesDir -ChildPath 'EFI\BOOT\BOOTX64.EFI'
    if (-not (Test-Path -LiteralPath $bootLoader -PathType Leaf)) {
        throw 'EFI\BOOT\BOOTX64.EFI was not found on the CHR boot partition.'
    }

    Write-Host 'Building FAT16 boot partition image...'
    $hiddenSectors = [UInt32]($bootPartition.Offset / 512)
    $fatImage = New-Fat16Image -SourceDirectory $bootFilesDir -TotalSectors $usableSectors -HiddenSectors $hiddenSectors

    Write-Host 'Writing FAT16 filesystem to partition 1...'
    Write-DiskBytes -Stream $rawStream -Offset ([Int64]$bootPartition.Offset) -Bytes $fatImage
}
finally {
    if ($null -ne $rawStream) {
        $rawStream.Dispose()
    }

    if ($null -ne $mounted) {
        Write-Host 'Dismounting VHDX...'
        Dismount-VHD -Path $targetPath
    }

    if ($KeepWorkDir) {
        Write-Host "Keeping temporary files: $workDir"
    } elseif (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
}

Write-Host ''
Write-Host 'Done.'
Write-Host "Patched VHDX: $targetPath"
Write-Host 'Create a Hyper-V Generation 2 VM with Secure Boot disabled and attach this VHDX as the boot disk.'
