$env:WSL_UTF8=1 # Encoding for consistent outputs.


function yesNoReprompt {
  param ([String]$prompt)

  while ($true) {
    $response = Read-Host -Prompt "$prompt(y/n)"

    if ($response -eq 'y') {
      return $true
    }
    if ($response -eq 'n') {
      return $false
    }
  }
}

function getMigrationTarget{
  $path = Read-Host -Prompt "`nEnter the path to migrate wsl or '.' for current directory (defaults to 'wsl' folder in the root of a random partition other than 'C:/')"

  if ($path -eq ".") {
    return (pwd).Path
  }
  if ($path -eq "") {
    $qualified_drive = getPriorityDrive
    $path = "$($qualified_drive)\wsl"

    if (!(Test-Path -Path $path)) {
      New-Item -Path $path -ItemType "Directory" > $Null
      return $path
    }

    $response = yesNoReprompt "`n$path already exists. You want to perform migration within it? "
    if ($response -eq 'y') {
      return $path
    }
    if ($response -eq 'n') {
      $response = yesNoReprompt "Do you want to choose a custom path? "
      if ($response -eq 'n') {
        exit
      }
    }

    $path = Read-Host -Prompt "`nChoose a custom path"
  }

  while (!(Test-Path -Path $path)) {
    $path = Read-Host -Prompt "$path does not exists. Choose another path"
  }

  return $path;
}

function GetDistribution{
  param([Object[]]$distro_list)

  $mapped_distro_list = @{}
  $mapped_distro_list.clear()

  $distro_count = 1
  foreach ($distro in $distro_list) {
    Write-Host -NoNewline "[$distro_count] " -f green
    if ($distro_count -eq 1) {
      Write-Host -NoNewline "$($distro) "
      Write-Host "(Current Default)"
    }
    else {
      Write-Host "$($distro)"
    }

    $mapped_distro_list.add([String]$distro_count,$distro)
    $distro_count = $distro_count + 1
  }

  do {
    Write-Host -NoNewline "Select any one option ("
    Write-Host -NoNewline "[1]" -f green
    Write-Host -NoNewline " and "
    Write-Host -NoNewline "[$($distro_count - 1)]" -f green
    Write-Host -NoNewline " inclusive) or leave blank to migrate defaults: "
    $distro_choice = Read-Host
  }
  while (!($mapped_distro_list[$distro_choice]) -and  ($distro_choice -ne ""))

  if ($distro_choice -eq "") {
    return $mapped_distro_list[0];
  }

  return $mapped_distro_list[$distro_choice];
}

function getPriorityDrive{
  $disk = Get-PhysicalDisk | ForEach-Object {
    $physicalDisk = $_
    #
    $physicalDisk | # Get MediaType.
    Get-Disk | # Pipes from 'Get-PhysicalDisk:UniqueId' to 'Get-Partition:ObjectId'
    Get-Partition | # Get DriveLetter and DiskPath.
    ?{$_.DiskPath -match "scsi"} | ?{$_.DriveLetter -match "[A-B,D-Z]"} |
    Where-Object DriveLetter | Select-Object DriveLetter, @{n='MediaType';e={
    $physicalDisk.MediaType }}
  } | select DriveLetter, @{Name="Priority";Expression={ if ($_.MediaType -eq "SSD") {1} else {2} }} # Prioritize SSDs over others.

  $table = foreach ($volume in Get-Volume) {
      $disk_volume_join = $disk | where-object { $_.DriveLetter -eq $volume.DriveLetter }

      foreach ($tmp in $disk_volume_join) {
          new-object PSObject -prop @{
          DriveLetter = $volume.DriveLetter
          SizeRemaining = $volume.SizeRemaining
          Priority = $tmp.Priority
        }
      }
  }
  $target_drive = $table | Sort Priority ,@{Expression="SizeRemaining";Descending=$true} | select -First 1 | select DriveLetter # Sort by prority.

  foreach ($drive in $target_drive) {
    $row=$drive.DriveLetter
  }

  $qualified_drive = "$($row):"

  return $qualified_drive
}

if (!(Get-Command wsl -errorAction SilentlyContinue)) {
    Write-Host "Migration cannot proceed.`nCommand 'wsl' could not be sourced. Verify if wsl is installed." -f red
    exit
}


$distro_list = (wsl.exe -l -q | ?{$_.trim() -ne "" })
$distro_count = ($distro_list | Measure-Object).Count
$distro = ""

if ($distro_count -eq 0) {
  Write-Host "wsl could not find any installed distribution."
  exit
}
elseif ($distro_count -eq 1) {
  $distro = $distro_list # $distro_list contains a single line entry.
  Write-Host "Single distribution detected: $distro_list"
}
else {
  Write-Host "List of installed distributions:"
  $distro = GetDistribution $distro_list
}


$wsl_path = ""
do {
  $wsl_path = getMigrationTarget
  $pre_existing_distribution = (Get-ItemProperty -Path "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\*" | ?{$_.BasePath -like "*$wsl_path"}).DistributionName
  if ($pre_existing_distribution) {
    Write-Host "Distribution named '$pre_existing_distribution' already exists on $wsl_path. Choose another path."
  }
} while ($pre_existing_distribution)

$old_pwd = (pwd).Path
cd $wsl_path
Write-Host ""
wsl --export $distro wsl.tar
Write-Host ""

# Store original default UID before migration as it defaults to root post-migration.
$distro_DefaultUidValue = (Get-ItemProperty -Path "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\*" | ?{$_.DistributionName -eq $distro}).DefaultUid
wsl --unregister $distro
Write-Host ""

try {
  wsl.exe --import $distro $wsl_path wsl.tar
}
catch {
  exit
}
Remove-Item $wsl_path\wsl.tar
Write-Host "`n$distro successfully migrated to $wsl_path"

# Change the login user to the original UID.
$distro_NewUidValue = (Get-ItemProperty -Path "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\*" | ?{$_.DistributionName -eq $distro}).DefaultUid
if ($distro_NewUidValue -ne $distro_DefaultUidValue) {
  $distro_NewPSChildName  = (Get-ItemProperty -Path "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\*" | ?{$_.DistributionName -eq $distro}).PSChildName
  Set-ItemProperty -Path "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\$distro_NewPSChildName" -Name "DefaultUid" -Value $distro_DefaultUidValue
}

cd $old_pwd

