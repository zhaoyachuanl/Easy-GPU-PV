Set-ExecutionPolicy RemoteSigned
# 检查hyperv是否启用
Function Get-HyperVEnabled {
    if (Get-WindowsOptionalFeature -Online | Where-Object FeatureName -Like 'Microsoft-Hyper-V-All') {
        Return $true
    }
    Else {
        Write-Warning "You need to enable Virtualisation in your motherboard and then add the Hyper-V Windows Feature and reboot"
        Return $false
    }
}

Function Get-WindowsCompatibleOS {
    $build = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($build.CurrentBuild -ge 19041 -and ($($build.editionid -like 'Professional*') -or $($build.editionid -like 'Enterprise*') -or $($build.editionid -like 'Education*'))) {
        Return $true
    }
    Else {
        Write-Warning "Only Windows 10 20H1 or Windows 11 (Pro or Enterprise) is supported"
        Return $false
    }
}

Function Get-VMGpuPartitionAdapterFriendlyName {
    $Devices = (Get-WmiObject -Class "Msvm_PartitionableGpu" -ComputerName $env:COMPUTERNAME -Namespace "ROOT\virtualization\v2").name
    Foreach ($GPU in $Devices) {
        $GPUParse = $GPU.Split('#')[1]
        Get-WmiObject Win32_PNPSignedDriver | Where-Object { ($_.HardwareID -eq "PCI\$GPUParse") } | Select-Object DeviceName -ExpandProperty DeviceName
    }
}


function Select_Item {
    param (
        [System.Object]$list
    )
    # 提示用户输入索引
    Write-Host "avaliable items:"
    # 显示索引和虚拟机名称
    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host "$i : $($list[$i])"
    }
    # 提示用户输入索引
    $index = Read-Host "selected index:"
    # 验证索引是否有效
    if ($index -ge 0 -and $index -lt $list.Count) {
        $selected_item = $list[$index]
        Write-Host "selected item: $selected_item"
    }
    else {
        Write-Host "invalid index!"
    }
    Return $selected_item
}

function Get-SeletedVMName {
    # vm_list = Get-VM | Select-Object -ExpandProperty Name
    $vm_list = Get-VM
    Return Select_Item -list $vm_list.name
}

function Get-SelectedGpuName {
    $gpu_list = Get-VMGpuPartitionAdapterFriendlyName
    return Select_Item -list $gpu_list
}


function precheck() {
    Write-Host "HyperV is enabled: $(Get-HyperVEnabled)" 
    Write-Host "Windows Version is Compatible: $(Get-WindowsCompatibleOS)" 
    Pause
}

function Add_vGpu {
    $vm = Get-SeletedVMName
    forceshutdown_vm -vmname $vm
    $vmem = Read-Host -Prompt "input vgpu ram size (if 8G as 8)"
    $vmem = ($vmem / 1) * 1GB

    Add-VMGpuPartitionAdapter -VMName $vm
    Set-VMGpuPartitionAdapter -VMName $vm
    Set-VM -GuestControlledCacheTypes $true -VMName $vm
    Set-VM -LowMemoryMappedIoSpace 256MB -VMName $vm
    Set-VM -HighMemoryMappedIoSpace "$vmem" -VMName $vm
    Write-Host "done"
    Pause
}

function Config_vgpu() {
    $vm = Get-SeletedVMName
    forceshutdown_vm -vmname $vm
    Get-VMGpuPartitionAdapter -VMName $vm | Remove-VMGpuPartitionAdapter
    Add-VMGpuPartitionAdapter -VMName $vm
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionVRAM 1
    Set-VMGpuPartitionAdapter -VMName $vm -MaxPartitionVRAM 11
    Set-VMGpuPartitionAdapter -VMName $vm -OptimalPartitionVRAM 10
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionEncode 1
    Set-VMGpuPartitionAdapter -VMName $vm -MaxPartitionEncode 11
    Set-VMGpuPartitionAdapter -VMName $vm -OptimalPartitionEncode 10
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionDecode 1
    Set-VMGpuPartitionAdapter -VMName $vm -MaxPartitionDecode 11
    Set-VMGpuPartitionAdapter -VMName $vm -OptimalPartitionDecode 10
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionCompute 1
    Set-VMGpuPartitionAdapter -VMName $vm -MaxPartitionCompute 11
    Set-VMGpuPartitionAdapter -VMName $vm -OptimalPartitionCompute 10
    Set-VM -GuestControlledCacheTypes $true -VMName $vm
    Set-VM -LowMemoryMappedIoSpace 1Gb -VMName $vm
    Set-VM -HighMemoryMappedIoSpace 32GB -VMName $vm
    Pause
}

function Remove_vGpu {
    $vm = Get-SeletedVMName
    forceshutdown_vm -vmname $vm
    # 删除分配的vGPU
    Remove-VMGpuPartitionAdapter -VMName $vm
    Write-Host "remove vGpu for $vm successfully"
    Pause
}

function forceshutdown_vm {
    param (
        [string]$vmname
    )
    $VM = Get-VM -VMName $VMName
    if ($VM.state -ne "Off") {
        "Attemping to shutdown VM..."
        Write-Host "shutting down $vmname"
        Stop-VM -Name $VMName -Force
    } 

    While ($VM.State -ne "Off") {
        Start-Sleep -s 3
        "Waiting for VM to shutdown - make sure there are no unsaved documents..."
    }
}

function Update_vGpuDriver {
    param (
        [System.Object]$mode
    )
    $VMName = Get-SeletedVMName
    
    $Hostname = $ENV:Computername

    # Import-Module $PSSCriptRoot\Add-VMGpuPartitionAdapterFiles.psm1

    $VM = Get-VM -VMName $VMName
    $VHD = Get-VHD -VMId $VM.VMId

    forceshutdown_vm -vmname $VMName

    "Mounting Drive..."
    $DriveLetter = (Mount-VHD -Path $VHD.Path -PassThru | Get-Disk | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object DriveLetter)

    if ($mode -eq "clear") {
        Write-Host "clear..."
        $dirver_path = "Windows\System32\HostDriverStore\FileRepository"
        $full_dirver_path = Join-Path -Path "$DriveLetter`:" -ChildPath $dirver_path
        Remove-Item -Path $full_dirver_path -Recurse -Force
    }
    elseif ($mode -eq "add") {
        "Copying GPU Files - this could take a while..."
        $GPUName = Get-SelectedGpuName
        Write-Host "add..."
        Add-VMGPUPartitionAdapterFiles -hostname $Hostname -DriveLetter $DriveLetter -GPUName $GPUName
    }
    else {
        Write-Host "invalid para"
        <# Action when all if and elseif conditions are false #>
    }

    "Dismounting Drive..."
    Dismount-VHD -Path $VHD.Path

    "Done..."
    Pause
}

Function Add-VMGpuPartitionAdapterFiles {
    param(
        [string]$hostname = $ENV:COMPUTERNAME,
        [string]$DriveLetter,
        [string]$GPUName
    )

    If (!($DriveLetter -like "*:*")) {
        $DriveLetter = $Driveletter + ":"
    }

    If ($GPUName -eq "AUTO") {
        $PartitionableGPUList = Get-WmiObject -Class "Msvm_PartitionableGpu" -ComputerName $env:COMPUTERNAME -Namespace "ROOT\virtualization\v2"
        $DevicePathName = $PartitionableGPUList.Name | Select-Object -First 1
        $GPU = Get-PnpDevice | Where-Object { ($_.DeviceID -like "*$($DevicePathName.Substring(8,16))*") -and ($_.Status -eq "OK") } | Select-Object -First 1
        $GPUName = $GPU.Friendlyname
        $GPUServiceName = $GPU.Service 
    }
    Else {
        $GPU = Get-PnpDevice | Where-Object { ($_.Name -eq "$GPUName") -and ($_.Status -eq "OK") } | Select-Object -First 1
        $GPUServiceName = $GPU.Service
    }
    # Get Third Party drivers used, that are not provided by Microsoft and presumably included in the OS

    Write-Host "INFO   : Finding and copying driver files for $GPUName to VM. This could take a while..."

    $Drivers = Get-WmiObject Win32_PNPSignedDriver | where { $_.DeviceName -eq "$GPUName" }

    New-Item -ItemType Directory -Path "$DriveLetter\windows\system32\HostDriverStore" -Force | Out-Null

    #copy directory associated with sys file 
    $servicePath = (Get-WmiObject Win32_SystemDriver | Where-Object { $_.Name -eq "$GPUServiceName" }).Pathname
    $ServiceDriverDir = $servicepath.split('\')[0..5] -join ('\')
    $ServicedriverDest = ("$driveletter" + "\" + $($servicepath.split('\')[1..5] -join ('\'))).Replace("DriverStore", "HostDriverStore")
    if (!(Test-Path $ServicedriverDest)) {
        Copy-item -path "$ServiceDriverDir" -Destination "$ServicedriverDest" -Recurse
    }

    # Initialize the list of detected driver packages as an array
    $DriverFolders = @()
    foreach ($d in $drivers) {

        $DriverFiles = @()
        $ModifiedDeviceID = $d.DeviceID -replace "\\", "\\"
        $Antecedent = "\\" + $hostname + "\ROOT\cimv2:Win32_PNPSignedDriver.DeviceID=""$ModifiedDeviceID"""
        $DriverFiles += Get-WmiObject Win32_PNPSignedDriverCIMDataFile | where { $_.Antecedent -eq $Antecedent }
        $DriverName = $d.DeviceName
        $DriverID = $d.DeviceID
        if ($DriverName -like "NVIDIA*") {
            New-Item -ItemType Directory -Path "$driveletter\Windows\System32\drivers\Nvidia Corporation\" -Force | Out-Null
        }
        foreach ($i in $DriverFiles) {
            $path = $i.Dependent.Split("=")[1] -replace '\\\\', '\'
            $path2 = $path.Substring(1, $path.Length - 2)
            $InfItem = Get-Item -Path $path2
            $Version = $InfItem.VersionInfo.FileVersion
            If ($path2 -like "c:\windows\system32\driverstore\*") {
                $DriverDir = $path2.split('\')[0..5] -join ('\')
                $driverDest = ("$driveletter" + "\" + $($path2.split('\')[1..5] -join ('\'))).Replace("driverstore", "HostDriverStore")
                if (!(Test-Path $driverDest)) {
                    Copy-item -path "$DriverDir" -Destination "$driverDest" -Recurse
                }
            }
            Else {
                $ParseDestination = $path2.Replace("c:", "$driveletter")
                $Destination = $ParseDestination.Substring(0, $ParseDestination.LastIndexOf('\'))
                if (!$(Test-Path -Path $Destination)) {
                    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
                }
                Copy-Item $path2 -Destination $Destination -Force
                
            }

        }
    }

}
function Show-Menu {
    Clear-Host

    Write-Host "avaliable func:"
    Write-Host "1: Precheck"
    Write-Host "2: Add_vgpu"
    Write-Host "3: Config_vGpu"
    Write-Host "4: Remove_vGpu"
    Write-Host "5: Update_vGpuDriver(for nv gpu)"
    Write-Host "6: Clear_vGpuDriver(for nv gpu)"
    Write-Host "q: quit"
}



do {
    Show-Menu
    $choice = Read-Host "choose:"

    switch ($choice) {
        '1' { Precheck }
        '2' { Add_vGpu }
        '3' { Config_vgpu }
        '4' { Remove_vGpu }
        '5' { Update_vGpuDriver -mode "add" }
        '6' { Update_vGpuDriver -mode "clear" }
        'q' { Write-Host "quit..."; break }
        default { Write-Host "invalid input"; Pause }
    }
    if ($choice -eq 'q') {
        break
    }
} while ($true)