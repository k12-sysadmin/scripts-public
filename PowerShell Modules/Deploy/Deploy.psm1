# Copyright: Jonathan Jendrejack, 2019
# Released under GNU General Public License v3 as of December 2024
# https://www.gnu.org/licenses/gpl-3.0.en.html

Function Deploy-WindowsImage {
[CmdletBinding()]
Param (
[Parameter (Mandatory=$true, ParameterSetName="WithDiskObject", ValueFromPipeline=$true)][Microsoft.Management.Infrastructure.CimInstance][PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_Disk")]$Disk,
[Parameter (Mandatory=$true, ParameterSetName="WithDiskNumber")][uint32]$DiskNumber,
[Parameter (Mandatory=$true, Position=0)][string]$ImagePath,
[Parameter (Mandatory=$false, Position=1)][uint32]$Index=1,
[Parameter (Mandatory=$false)][ValidateSet ("MBR","GPT")]$PartitionStyle = "GPT",
[Parameter (Mandatory=$false)][switch]$Confirm = $true,
[Parameter (Mandatory=$false)][switch]$Force = $false
)

# Define string variables for the GPT partition types, for use when creating partitions later
[string]$GptTypeSystem = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
[string]$GptTypeMSR = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
[string]$GptTypeData = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

# Create variables for use later
[Microsoft.Management.Infrastructure.CimInstance][PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_Partition")]$SystemPartition = $null
[Microsoft.Management.Infrastructure.CimInstance][PSTypeName("Microsoft.Management.Infrastructure.CimInstance#ROOT/Microsoft/Windows/Storage/MSFT_Partition")]$WindowsPartition = $null
[string[]]$available_driveletters = $null
$PSDriveNames = (Get-PSDrive -PSProvider FileSystem).Name
69..90  |foreach {
    $letter = [char]$_
    if ($PSDriveNames -notcontains $letter) {
        $available_driveletters += $letter
    }
}
[string]$SystemDriveLetter = $available_driveletters[0]
Write-Verbose ('Selected ' + $SystemDriveLetter + ': as drive letter for system partition')
[string]$WindowsDriveLetter = $available_driveletters[1]
Write-Verbose ('Selected ' + $WindowsDriveLetter + ': as drive letter for Windows partition')
if($PSCmdlet.ParameterSetName -eq "WithDiskNumber") { $Disk = Get-Disk -Number $DiskNumber }
if (($Disk.Model -like '*USB*') -and !$Force) {
    Write-Error ('WARNING! DOUBLE CHECK WHICH DRIVE YOU ARE IMAGING!  The drive is reporting its model as ' + $Disk.Model + ', which contains the string "USB", which usually means the drive is a USB flash drive.  The requested operation has been canceled as a safety measure against accidentally overwriting your Windows PE boot drive instead of the local hard drive.  USB-to-SATA adapters should still report the actual model of the drive they are connected to, and should not trigger this warning.  If you are absolutely certain you are deploying the image to the correct drive, try again with -Force')
    return
}
if (($Disk.Model -like '*Flash*') -and !$Force) {
    Write-Error ('WARNING! DOUBLE CHECK WHICH DRIVE YOU ARE IMAGING!  The drive is reporting its model as ' + $Disk.Model + ', which contains the string "Flash", which usually means the drive is a USB flash drive.  The requested operation has been canceled as a safety measure against accidentally overwriting your Windows PE boot drive instead of the local hard drive.  USB-to-SATA adapters should still report the actual model of the drive they are connected to, and should not trigger this warning.  If you are absolutely certain you are deploying the image to the correct drive, try again with -Force')
    return
}

# If the disk is already initialized, clear it, require confirmation unless this script was run with -Confirm:$false   
if($Disk.PartitionStyle -ne "RAW"){
    Write-Verbose 'Disk was already initialized.  Clearing disk...'
    $Disk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$Confirm
    Write-Verbose 'Disk cleared'
} else {Write-Verbose 'Disk is already cleared'}
# Initialize the disk as the specified partition style, and create the partitions needed for setting up Windows.
switch ($PartitionStyle) {
    "MBR" {
        Write-Verbose 'Initializing disk with MBR partition style...'
        $Disk | Initialize-Disk -PartitionStyle MBR
        Write-Verbose 'Disk initialized'
        Write-Verbose 'Creating system partition...'
        $SystemPartition = $Disk | New-Partition -MbrType Huge -Size 350mb -DriveLetter $SystemDriveLetter -IsActive
        Write-Verbose 'System partition created.  Formatting...'
        $SystemPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel "System" | Out-Null
        Write-Verbose 'System partition formatted.  Creating Windows partition...'
        $WindowsPartition = $Disk | New-Partition -MbrType Huge -UseMaximumSize -DriveLetter $WindowsDriveLetter
        Write-Verbose 'Windows partition created.  Formatting...'
        $WindowsPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Windows" | Out-Null
        Write-Verbose 'Windows partition formatted.'
    }
    "GPT" {
    Write-Verbose 'Initializing disk with GPT partition style'
    $Disk | Initialize-Disk -PartitionStyle GPT
    Write-Verbose 'Disk initialized'
    $SystemPartition = $Disk | New-Partition -Size 100mb -GptType $GptTypeSystem -DriveLetter $SystemDriveLetter
    Write-Verbose 'System partition created.  Formatting...'
    $SystemPartition | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' | Out-Null
    Write-Verbose 'System partition formatted.  Creating MSR partition...'
    $Disk | New-Partition -GptType $GptTypeMSR -Size 16mb | Out-Null
    Write-Verbose 'MSR partition created.  Creating Windows partition...'
    $WindowsPartition = $Disk | New-Partition -UseMaximumSize -DriveLetter $WindowsDriveLetter
    Write-Verbose 'Windows partition created.  Formatting...'
    $WindowsPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows'| Out-Null
    Write-Verbose 'Windows partition formatted'
    }
}
Write-Verbose 'Applying WIM image to Windows partition...'
Expand-WindowsImage -ImagePath $ImagePath -Index $Index -ApplyPath ($WindowsDriveLetter + ':\') | Write-Verbose
Write-Verbose 'Image applied'
[string]$bcdboot_command = $WindowsDriveLetter + ':\Windows\System32\bcdboot.exe ' + $WindowsDriveLetter + ':\Windows /s ' + $SystemDriveLetter + ': /f '
switch ($PartitionStyle) {
    "MBR" {
    $bcdboot_command += 'BIOS'
    }
    "GPT" {
    $bcdboot_command += 'UEFI'
    }
}
Write-Verbose 'Executing bcdboot.exe to create boot files'
Write-Verbose ('Using command ' + $bcdboot_command)
(Invoke-Expression $bcdboot_command) | Write-Verbose

Write-Output 'Done.'
}