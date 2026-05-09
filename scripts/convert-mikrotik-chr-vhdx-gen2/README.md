# Convert MikroTik CHR VHDX for Hyper-V Generation 2

`Convert-MikroTikChrVhdxGen2.ps1` converts an official MikroTik Cloud Hosted
Router (CHR) VHDX image into a patched copy that can boot in a Hyper-V
Generation 2 virtual machine.

## Why This Exists

Official x86_64 CHR VHDX images include the UEFI fallback bootloader at
`\EFI\BOOT\BOOTX64.EFI`, but the first boot partition is formatted as ext2/3.
Hyper-V Generation 2 firmware expects that fallback loader to be on a FAT
filesystem. Because of that mismatch, a stock CHR VHDX can fail to boot as a
Gen2 VM even though the EFI loader is present.

This script keeps the RouterOS data partition intact and only replaces the
first boot partition in a copied VHDX with a FAT16 filesystem containing the
same boot files.

## What It Does

1. Copies the source VHDX to a new output file.
2. Mounts the copied VHDX with the Hyper-V PowerShell module.
3. Reads files from the first ext boot partition.
4. Builds a FAT16 filesystem containing those boot files.
5. Writes the FAT16 filesystem back to partition 1 in the copied VHDX.
6. Dismounts the VHDX and prints the patched output path.

For RouterOS 7.15+ images with a one-sector GPT overlap, the script caps the
FAT image at the start of the next partition so it does not overwrite RouterOS
data.

## Requirements

- Windows with PowerShell.
- An elevated PowerShell session.
- Hyper-V installed, including the Hyper-V PowerShell module.
- A MikroTik CHR x86_64 `.vhdx` image.
- Enough free disk space for a full copy of the input VHDX.
- Secure Boot disabled on the Hyper-V Generation 2 VM that will use the patched
  image.

## Quick Start

From the repository root:

```powershell
.\scripts\convert-mikrotik-chr-vhdx-gen2\Convert-MikroTikChrVhdxGen2.ps1 -Path .\chr-7.20.8.vhdx
```

From this directory:

```powershell
.\Convert-MikroTikChrVhdxGen2.ps1 -Path C:\Images\chr-7.20.8.vhdx
```

By default, the output file is created next to the input file with `.gen2`
inserted before the extension:

```text
chr-7.20.8.vhdx -> chr-7.20.8.gen2.vhdx
```

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `-Path` | Yes | Source CHR VHDX image. The file must already exist. |
| `-OutputPath` | No | Destination path for the patched VHDX. Defaults to `<source>.gen2.vhdx`. |
| `-Force` | No | Overwrite `-OutputPath` if it already exists. |
| `-KeepWorkDir` | No | Keep the temporary extracted boot files for inspection or troubleshooting. |
| `-Verbose` | No | Built-in PowerShell common parameter. Prints extra details from verbose script messages. |

## Examples

Create a patched image next to the source VHDX:

```powershell
.\Convert-MikroTikChrVhdxGen2.ps1 -Path .\chr-7.20.8.vhdx
```

Write the patched image to a specific path:

```powershell
.\Convert-MikroTikChrVhdxGen2.ps1 `
  -Path C:\Images\chr.vhdx `
  -OutputPath C:\Images\chr-gen2.vhdx
```

Overwrite an existing output image:

```powershell
.\Convert-MikroTikChrVhdxGen2.ps1 `
  -Path C:\Images\chr.vhdx `
  -OutputPath C:\Images\chr-gen2.vhdx `
  -Force
```

Keep temporary boot files after conversion:

```powershell
.\Convert-MikroTikChrVhdxGen2.ps1 -Path C:\Images\chr.vhdx -KeepWorkDir
```

## Create a Hyper-V Gen2 VM

After conversion, create or configure a Generation 2 VM and attach the patched
VHDX as the boot disk. Secure Boot must be disabled.

Example:

```powershell
New-VM `
  -Name chr-gen2 `
  -Generation 2 `
  -MemoryStartupBytes 256MB `
  -VHDPath C:\Images\chr-gen2.vhdx

Set-VMFirmware -VMName chr-gen2 -EnableSecureBoot Off
Start-VM -Name chr-gen2
```

## Safety Notes

- The source image is not patched in place. The script always works on a copy.
- `-OutputPath` must be different from `-Path`.
- If the output file already exists, the script stops unless `-Force` is used.
- The script opens the mounted VHDX through the Windows raw disk interface, so
  run it only against images you intended to convert.
- Keep a backup of important images before converting them.

## Troubleshooting

### `Run this script from an elevated PowerShell session.`

Start PowerShell as Administrator and run the command again.

### `Mount-VHD was not found.`

Install or enable Hyper-V and the Hyper-V PowerShell module.

### `The first partition is not ext2/3/4, or it has already been patched.`

Use the original MikroTik CHR VHDX image as input. This message can also appear
if the image layout is different from the official CHR layout expected by the
script.

### `Output file already exists`

Choose a different `-OutputPath` or add `-Force` if you want to overwrite the
existing output file.

### The VM still does not boot

Check that the VM is Generation 2, the patched VHDX is attached as the boot
disk, and Secure Boot is disabled.

## Known Limitations

- This is a Windows/Hyper-V utility.
- It expects a CHR-style image where partition 1 contains the EFI boot files and
  `EFI\BOOT\BOOTX64.EFI` exists.
- It reads the boot partition layout used by CHR images; it is not a general
  purpose ext filesystem migration tool.
- The script builds the replacement FAT16 boot partition in memory and rejects
  unexpectedly large boot partitions.
- It does not change RouterOS configuration, licensing, users, interfaces, or
  the RouterOS/root partition.
