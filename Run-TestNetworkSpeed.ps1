## Run-TestNetworkSpeed
## Author: Jacob Sweany
## Date: 6/28/2018
##
## This script will run the function Test-NetworkSpeed against a list of paths and append the results 
## to a CSV file, save the output as a nicely formatted HTML table and email the results to listed recipients.
## 
## NOTE: This script will not run properly without populating "\\path" with appropriate UNC paths.
##
## Function was modified from this source:
## http://community.spiceworks.com/scripts/show/2502-network-bandwidth-test-test-networkspeed-ps1

$SourceServer = hostname
Write-Warning "Hostname is $SourceServer"

# Check for a lockfile, to avoid more than one speed test at one time. If lockfile is detected, terminate script.
# This is not needed if only one test is run in the environment.
$LockFileCheck = (Get-ChildItem "\\path\" -Recurse -Filter "*.lockfile").Name
if ($LockFileCheck) {
    Write-Warning "Lockfile $LockFileCheck detected. Terminating script!"
    exit
}
# Create lockfile
Write-Warning "Creating lockfile for $SourceServer at $(Get-Date)" | Out-File "\\path\$SourceServer.lockfile" -Force

## Function definition
function Test-NetworkSpeed {
    <#
    .SYNOPSIS
        Determine network speed in Mbps
    .DESCRIPTION
        This script will create a dummy file, default size of 20mb, and copy to
        and from a target server.  The Mbps will be determined from the time it 
        takes to perform this operation.
    
        A folder will be created in the designated Path location called SpeedTest.
        The dummy file will be copied to and from that location to determine the
        network speed.
    .PARAMETER Path
        Each Path specified must be in UNC format, i.e. \\server\share
    .PARAMETER Size
        Designate the size of the dummy file in MB
    .INPUTS
        <string> UNC of path
    .OUTPUTS
        PSCustomObject
            Server          Name of Server
            TimeStamp       Time when script was run
            WriteTime       TimeSpan object of how long the write test took
            WriteMbps       Mbps of the write test
            ReadTime        TimeSpan object of how long the read test took
            ReadMbps        Mbps of the read test
    .EXAMPLE
        .\Test-NetworkSpeed.ps1 -Path "\\server1\share","\\server2\share2"
    .EXAMPLE
        .\Test-NetworkSpeed.ps1 -Path (Get-Content c:\shares.txt) -Size 25 -Verbose
    
        Pulls paths from c:\Shares.txt (in UNC format), creates a 25mb dummy file for
        testing and produces Verbose output.
    .EXAMPLE
        Get-Content c:\shares.txt | .\Test-NetworkSpeed.ps1 -Size 100
    
        Also pulls paths from c:\Shares.txt, but takes input from the pipeline.  Dummy
        file size will be 100mb.
    #>
    #requires -Version 3.0
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory,ValueFromPipeline,HelpMessage="Enter UNC's to server to test (dummy file will be saved in this path)")]
        [String[]]$Path,
        [ValidateRange(1,1000)]
        [int]$Size = 10
    )

    Begin {
        Write-Verbose "$(Get-Date): Test-NetworkSpeed Script begins"
        Write-Verbose "$(Get-Date): Create dummy file, Size: $($Size)MB"
        $Source = $PSScriptRoot
        Remove-Item $Source\Test.txt -ErrorAction SilentlyContinue
        Set-Location $Source
        $DummySize = $Size * 1048576
        $CreateMsg = fsutil file createnew test.txt $DummySize

        Try {
            $TotalSize = (Get-ChildItem $Source\Test.txt -ErrorAction Stop).Length
        }
        Catch {
            Write-Warning "Unable to locate dummy file"
            Write-Warning "Create Message: $CreateMsg"
            Write-Warning "Last error: $($Error[0])"
            # !important Remove lock file on exit
            Remove-Item -Path "\\path\$SourceServer.lockfile" -Force -ErrorAction SilentlyContinue
            Exit
        }
        Write-Verbose "$(Get-Date): Source for dummy file: $Source\Test.txt"
        $RunTime = Get-Date
    }

    Process {
        ForEach ($ServerPath in $Path)
        {   $Server = $ServerPath.Split("\")[2]
            $Target = "$ServerPath\SpeedTest"
            Write-Verbose "$(Get-Date): Checking speed for $Server..."
            Write-Verbose "$(Get-Date): Destination: $Target"
        
            If (-not (Test-Path $Target))
            {   Try {
                    New-Item -Path $Target -ItemType Directory -ErrorAction Stop | Out-Null
                }
                Catch {
                    Write-Warning "Problem creating $Target folder because: $($Error[0])"
                    [PSCustomObject]@{
                        Server = $Server
                        TimeStamp = $RunTime
                        Status = "$($Error[0])"
                        WriteTime = New-TimeSpan -Days 0
                        WriteMbps = 0
                        ReadTime = New-TimeSpan -Days 0
                        ReadMbps = 0
                        SourceServer = $SourceServer
                        Size = $Size
                    }
                    Continue
                }
            }
        
            Try {
                Write-Verbose "$(Get-Date): Write Test..."
                $WriteTest = Measure-Command { 
                    Copy-Item $Source\Test.txt $Target -ErrorAction Stop
                }
            
                Write-Verbose "$(Get-Date): Read Test..."
                $ReadTest = Measure-Command {
                    Copy-Item $Target\Test.txt $Source\TestRead.txt -ErrorAction Stop
                }
                $Status = "OK"
                $WriteMbps = [Math]::Round((($TotalSize * 8) / $WriteTest.TotalSeconds) / 1048576,2)
                $ReadMbps = [Math]::Round((($TotalSize * 8) / $ReadTest.TotalSeconds) / 1048576,2)
            }
            Catch {
                Write-Warning "Problem during speed test: $($Error[0])"
                $Status = "$($Error[0])"
                $WriteMbps = $ReadMbps = 0
                $WriteTest = $ReadTest = New-TimeSpan -Days 0
            }
        
            $Output = [PSCustomObject]@{
                Server = $Server
                TimeStamp = $RunTime
                Status = "OK"
                WriteTime = $WriteTest
                WriteMbps = $WriteMbps
                ReadTime = $ReadTest
                ReadMbps = $ReadMbps
                SourceServer = $SourceServer
                Size = $Size
            }
            Remove-Item $Target\Test.txt -ErrorAction SilentlyContinue
            Remove-Item $Source\TestRead.txt -ErrorAction SilentlyContinue
            return $Output
        }
    }

    End {
        Remove-Item $Source\Test.txt -Force -ErrorAction SilentlyContinue
        Write-Verbose "$(Get-Date): Test-NetworkSpeed completed!"
    }
}

## Set up variables for run paths to test, CSV output file, size of tests, number of times to test

# Number of times the test will be run for each path
$RunTimes = 2

# Where to email the report to after test is complete
$Recpients = @('email@ngc.com', 'email2.ngc.com')

# RunBank array will store each run of each test, output is a table when done
$RunBank = New-Object psobject @{}
# Define each path to test
$Paths = 
"\\path1",
"\\path2",
"\\path3"
"\\path4"

# Define CSV file for logging each speed test run
$LogCsv = "\\path\NetworkSpeedTests.csv"
# Define size (in MB) of each speed test
$size = 512

# Create CSV file if it doesn't exist
if (!(Test-Path $LogCsv)) {
    New-Item -ItemType File -Path $LogCsv | Out-Null
}

# All speed test actions are here. Each test will repeat $RunTimes, each test will be logged to CSV and $RunBank array for HTML/email export.
for ($i=1; $i -le $RunTimes; $i++) {
    foreach ($path in $Paths) {
        # Speed test action
        $TestRun = Test-NetworkSpeed -Path $path -Size $size -Verbose
        # Append data to CSV file
        $TestRun | Export-Csv -Path $LogCsv -Append -NoTypeInformation
        # Add test results to $RunBank array
        [array]$RunBank += $TestRun
    }
}

## HTML formatting/email creation
$table = $RunBank | select Server, TimeStamp, WriteMbps, ReadMbps, SourceServer, Size | ConvertTo-Html -Fragment
$Title = "Speed Test Run: $(Get-Date)"
$ReportDescription = "Description for report goes here"
# Define HTML head/styles
$Head = @"
<Title>$Title</Title>
<style>
body { background-color: #white; font-family: Segoe UI, Sans-Serif; font-size: 11pt; }
td, th, table { border:1px solid grey; border-collapse:collapse; }
h1, h2, h3, h4, h5, h6 { font-family Segoe UI, Segoe UI Light, Sans-Serif; font-weight: lighter; }
h1 { font-size: 26pt; }
h4 { font-size: 14pt; }
th { color: #383838; background-color: lightgrey; text-align: left; }
table, tr, td, th { padding: 2px; margin: 0px; }
table { width: 95%; margin-left: 5px; margin-bottom: 20px; }
</style>
<h1>$Title</h1>
<h4>$ReportDescription</h4>
"@

# Formulate email body
[string]$emailBody = ConvertTo-Html -Head $Head -Body $table #| Out-File "\\path\report.htm" -Encoding ascii -Force

# Send email - make sure to populate "From" and "SmtpServer" fields
Send-MailMessage -BodyAsHtml -From "noreply@test.com" -Subject $Title -Body $emailBody -To $Recpients -SmtpServer "mail.test.com"

# !important Remove lock file on exit
Remove-Item -Path "\\path\$SourceServer.lockfile" -Force -ErrorAction SilentlyContinue