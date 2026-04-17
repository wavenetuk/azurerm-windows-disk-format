<#
    .DESCRIPTION
    Disk formatting Script
#>

Param (
    [Parameter(Mandatory = $false)]
    [ValidateNotNullorEmpty()]
    [string] $diskConfig
)

begin {
    function Write-Log {
        [CmdletBinding()]
        <#
            .SYNOPSIS
            Create log function
        #>
        param (
            [Parameter(Mandatory = $True)]
            [ValidateNotNullOrEmpty()]
            [System.String] $logPath,

            [Parameter(Mandatory = $True)]
            [ValidateNotNullOrEmpty()]
            [System.String] $object,

            [Parameter(Mandatory = $True)]
            [ValidateNotNullOrEmpty()]
            [System.String] $message,

            [Parameter(Mandatory = $True)]
            [ValidateNotNullOrEmpty()]
            [ValidateSet('Information', 'Warning', 'Error', 'Verbose', 'Debug')]
            [System.String] $severity,

            [Parameter(Mandatory = $False)]
            [Switch] $toHost
        )

        begin {
            $date = (Get-Date).ToLongTimeString()
        }
        process {
            if (($severity -eq "Information") -or ($severity -eq "Warning") -or ($severity -eq "Error") -or ($severity -eq "Verbose" -and $VerbosePreference -ne "SilentlyContinue") -or ($severity -eq "Debug" -and $DebugPreference -ne "SilentlyContinue")) {
                if ($True -eq $toHost) {
                    Write-Host $date -ForegroundColor Cyan -NoNewline
                    Write-Host " - [" -ForegroundColor White -NoNewline
                    Write-Host "$object" -ForegroundColor Yellow -NoNewline
                    Write-Host "] " -ForegroundColor White -NoNewline
                    Write-Host ":: " -ForegroundColor White -NoNewline

                    Switch ($severity) {
                        'Information' {
                            Write-Host "$message" -ForegroundColor White
                        }
                        'Warning' {
                            Write-Warning "$message"
                        }
                        'Error' {
                            Write-Host "ERROR: $message" -ForegroundColor Red
                        }
                        'Verbose' {
                            Write-Verbose "$message"
                        }
                        'Debug' {
                            Write-Debug "$message"
                        }
                    }
                }
            }

            switch ($severity) {
                "Information" { [int]$type = 1 }
                "Warning" { [int]$type = 2 }
                "Error" { [int]$type = 3 }
                'Verbose' { [int]$type = 2 }
                'Debug' { [int]$type = 2 }
            }

            if (!(Test-Path (Split-Path $logPath -Parent))) { New-Item -Path (Split-Path $logPath -Parent) -ItemType Directory -Force | Out-Null }

            $content = "<![LOG[$message]LOG]!>" + `
                "<time=`"$(Get-Date -Format "HH:mm:ss.ffffff")`" " + `
                "date=`"$(Get-Date -Format "M-d-yyyy")`" " + `
                "component=`"$object`" " + `
                "context=`"$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " + `
                "type=`"$type`" " + `
                "thread=`"$([Threading.Thread]::CurrentThread.ManagedThreadId)`" " + `
                "file=`"`">"
            if (($severity -eq "Information") -or ($severity -eq "Warning") -or ($severity -eq "Error") -or ($severity -eq "Verbose" -and $VerbosePreference -ne "SilentlyContinue") -or ($severity -eq "Debug" -and $DebugPreference -ne "SilentlyContinue")) {
                Add-Content -Path $($logPath + ".log") -Value $content
            }
        }
        end {}
    }

    $LogPath = "$env:SYSTEMROOT\TEMP\Deployment_" + (Get-Date -Format 'yyyy-MM-dd')

    $textInfo = (Get-Culture).TextInfo

    # Set Variables
    $diskConfigArray = @()
    foreach ($item in $diskConfig.split(';')) {
        $myObject = [PSCustomObject]@{
            driveLetter = $item.split(',')[0].Replace(" ","")
            lun         = $item.split(',')[1].Replace(" ","")
            volumeLabel = $item.split(',')[2].Replace(" ","")
        }
        $diskConfigArray += $myObject
    }
}

process {
    # Change Optical Drive to Z:
    $Optical = Get-CimInstance -Class Win32_CDROMDrive | Select-Object -ExpandProperty Drive
    if (!($null -eq $Optical) -and !($Optical -eq 'Z:')) {
        Set-CimInstance -InputObject ( Get-CimInstance -Class Win32_volume -Filter "DriveLetter = '$Optical'" ) -Arguments @{DriveLetter = 'Z:' }
        Write-Log -Object "Disk Formatting" -Message "Set Optical Drive to Z:" -Severity Information -LogPath $LogPath
    }

    # Dismount any attached ISOs
    Get-Volume | Where-Object { $_.DriveType -eq "CD-ROM" } | Get-DiskImage | Dismount-DiskImage

    # Initialize and format Data Disks
    [array]$dataDisks = Get-Disk | Where-Object { ($_.IsSystem -eq $false) -and ($_.PartitionStyle -eq 'RAW') }
    if ($dataDisks) {
        foreach ($disk in $dataDisks) {
            $config = $diskConfigArray | Where-Object { $_.lun -eq ($disk.Location -split 'LUN ')[1] }
            $usedDriveLetters = (Get-Volume).driveLetter | Sort-Object
            if ([string]::IsNullOrEmpty($config.driveLetter)) {
                $partitionParams = @{
                    AssignDriveLetter = $true
                }
            }
            else {
                if ($usedDriveLetters -notcontains $config.driveLetter) {
                    $driveLetter = $config.driveLetter
                }
                else {
                    $driveLetter = 'EFGHIJKLMNOPQRSTUVWXY' -replace ("$($diskConfigArray.DriveLetter -join '|')", '') -split '' | Where-Object { $_ -notin (Get-CimInstance -ClassName win32_logicaldisk).DeviceID.Substring(0, 1) } | Where-Object { $_ } | Select-Object -first 1
                    Write-Log -Object "Disk Formatting" -Message "Drive Letter: $($config.driveLetter) in use, using $driveLetter instead" -Severity Information -LogPath $LogPath
                }
                $partitionParams = @{
                    DriveLetter = $driveLetter
                }
            }
            $disk | Initialize-Disk -PartitionStyle GPT
            $partition = New-Partition -DiskNumber $disk.Number @partitionParams -UseMaximumSize
            $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel $config.volumeLabel
            Write-Log -Object "Disk Formatting" -Message "Formatted disk:$($disk.Number) lun:$($config.lun) driveLetter:$($partition.DriveLetter) volumeLabel:$($config.volumeLabel)" -Severity Information -LogPath $LogPath
        }
    }
}
