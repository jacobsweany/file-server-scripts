<#
.SYNOPSIS
  Tests network speeds over multiple endpoints.
.DESCRIPTION
  Tests network speeds using Measure-Command and file copying. Script will generate random data ONLY at the source,
  not at the endpoints.
  Use the other script, Generate-RandomData.ps1 as locally as possible for each remote endpoint if possible if 
  you are running traffic through WAN optimization.

  Script will generate a CSV file, an HTML report, and a formatted email to be sent at each script run.
  NOTE: This script will not run properly without populating "\\path" with appropriate UNC paths.
.PARAMETER
  None
.INPUTS
  None
.OUTPUTS
  None
.NOTES
  Version:        24.0
  Author:         Jacob Sweany
  Creation Date:  3/28/2018
  Purpose/Change: Introduced Wait-forTCPDrop function.
  
  Function Test-NetworkSpeed was modified from this source:
  http://community.spiceworks.com/scripts/show/2502-network-bandwidth-test-test-networkspeed-ps1

  Function Generate-RandomData was modified from this source:
  https://gallery.technet.microsoft.com/scriptcenter/Generate-random-binary-3e891264
  
.EXAMPLE
  None
#>



# Log verbose transcript of every script run
$VerbosePreference = "Continue"
$LogPath = "\\path\to\logs"
$LogPathName = Join-Path $LogPath -ChildPath "$($MyInvocation.ScriptName)-$(Get-Date -Format 'MM-dd-yyy').log"
Start-Transcript $LogPathName -Append


# Start initial script configuration
$SourceServer = hostname
Write-Warning "Hostname is $SourceServer"

# Where to locally store test data
$SharePath = "\\sharepath"
$RunServer = ""

# Toggle check for TCP drops between each test
$RunTCPDropCheck = $true
$DropCheckSeconds = 900

#Paths to test
$Paths = "
\\path1,
\\path2,
\\path3"

# Isilon IP ranges
$isilon1 = 10..30 | foreach {"10.10.10.$_"}
$isilon2 = 10..30 | foreach {"20.10.10.$_"}
$isilon3 = 10..30 | foreach {"30.10.10.$_"}

# Combine Isilon IP ranges with all servers used in test, remove duplicates
$iparray = New-Object psobject@{}
foreach ($path in $Paths) {
    $Server = $path.Split("\")[2]
    $ip = [System.Net.Dns]::GetHostAddresses("$Server").IPAddressToString
    [array]$iparray += $ip
}
$all_IPs = $isilon1 + $isilon2 + $isilon3 + $iparray | select -Unique

# End initial script configuration

$ScriptStartTime = Get-Date

# Check for a lockfile, to avoid more than one speed test at one time. If lockfile is detected, terminate script.
# This is not needed if only one test is run in the environment.
$LockFileCheck = (Get-ChildItem "$SharePath" -Recurse -Filter "*.lockfile").Name
if ($LockFileCheck) {
    Write-Warning "Lockfile $LockFileCheck detected. Terminating script!"
    #exit
}
# Create lockfile
Write-Warning "Creating lockfile for $SourceServer at $(Get-Date)" | Out-File "$SharePath\$SourceServer.lockfile" -Force

## Functions

function Wait-forTCPDrop {
    [CmdletBinding()]
    Param(
    [int]$TimeOutSeconds,
    [int]$RemotePort,
    [array]$CheckIPs
    )
    $RunOutTimer = New-TimeSpan -Seconds $TimeOutSeconds
    $Stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $Check = Get-NetTCPConnection -State Established -RemotePort $RemotePort -RemoteAddress $CheckIPs -ErrorAction SilentlyContinue | select -Unique
    while ($Check.State -eq "Established") {
        $Check = Get-NetTCPConnection -State Established -RemotePort $RemotePort -RemoteAddress $CheckIPs -ErrorAction SilentlyContinue | select -Unique
        Write-Verbose "Waiting for TCP session for $($Check.RemoteAddress | select -Unique) port $($check.RemotePort | select -Unique) to drop. $($Stopwatch.Elapsed.Minutes) mins $($Stopwatch.Elapsed.Seconds) seconds elapsed."
        if ($Stopwatch.Elapsed -ge $RunOutTimer) {
            Write-Warning "$TimeOutSeconds seconds have elapsed. Giving up TCP drop window wait"
            return
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "$($Stopwatch.Elapsed.Minutes) mins $($Stopwatch.Elapsed.Seconds) seconds elapsed total."
    $Stopwatch.Stop()
    Remove-Variable -Name Check
}

function Generate-RandomData {
    [CmdletBinding()] 
    Param( 
        [String] $TargetPath = "", 
        [int64] $filesize = 512MB, 
        [int] $timerangehours = 0   
    ) 
 
    # 
    # convert to absolute path as required by WriteAllBytes, and check existence of the directory.  
    # 
    #if (-not (Split-Path -IsAbsolute $TargetPath)) 
    #{ 
    #    $TargetPath = Join-Path (Get-Location).Path $TargetPath 
    #} 
    #if (-not (Test-Path -Path $TargetPath -PathType Container )) 
    #{ 
    #    throw "TargetPath '$TargetPath' does not exist or is not a directory" 
    #} 
 
    $currentsize = [int64]0 
    $currentime = Get-Date 
 
    # 
    # use a very fast .NET random generator 
    # 
    $data = new-object byte[] $filesize 
    (new-object Random).NextBytes($data) 
     
    # 
    # generate a random file name by shuffling the input filename seed.  
    # 
    #$filename = ($filenameseed.ToCharArray() | Get-Random -Count ($filenameseed.Length)) -join '' 
    $filename = "test"
    Write-Verbose "TargetPath = $TargetPath"
    ##$path_gen = Join-Path $TargetPath "$($filename).txt" 
 
    # 
    # write the binary data, and randomize the timestamps as required.  
    # 
    try 
    { 
        [IO.File]::WriteAllBytes($TargetPath, $data) 
        if ($timerangehours -gt 0) 
        { 
            $timestamp = $currentime.AddHours(-1 * (Get-Random -Minimum 0 -Maximum $timerangehours)) 
        } else { 
            $timestamp = $currentime 
        } 
        $fileobject = Get-Item -Path $TargetPath 
        $fileobject.CreationTime = $timestamp 
        $fileobject.LastWriteTime = $timestamp 
 
        # show results  
        [pscustomobject] @{ 
            filename = $path_gen 
            timestamp = $timestamp 
            datasize = $filesize 
        } 
    } catch { 
        $message = "failed to write data to $TargetPath, error $($_.Exception.Message)" 
        throw $message 
    }      

}

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
        [String]$ColdRun
        #[ValidateRange(1,1000)]
        #[int]$Size = 10,
    )

    Begin {
        if ($ColdRun -eq "ColdRun") {$IsColdRun = $true}
        if ($ColdRun -eq "WarmRun") {$IsColdRun = $false}

        Write-Verbose "$(Get-Date): Test-NetworkSpeed Script begins for $Path, ColdRun = $ColdRun"
        #Write-Verbose "$(Get-Date): Create dummy file, Size: $($Size)MB"
        $Source = "\\path"
        $SourceServer = hostname
        Set-Location $Source

        # COLD RUN
        # If cold run, remove local data file then generate random source file
        if ($IsColdRun) {
            Write-Verbose "$(Get-Date): COLD RUN: remove local data file then generate random source file, $Source\Test$RunServer.txt"
            Remove-Item $Source\Test$RunServer.txt -ErrorAction SilentlyContinue -Force
            $CreateMsg = Generate-RandomData -TargetPath "$Source\Test$RunServer.txt"
        }
        # WARM RUN
        # Data file is kept from last cold run, so no new file is generated
        if (!$IsColdRun) {
            Write-Verbose "$(Get-Date): WARM RUN: Data file is kept from last cold run, so no new file is generated"
        }

        # See if data file exists
        Try {
            $TotalSize = (Get-ChildItem $Source\test.txt -ErrorAction Stop).Length
        }
        Catch {
            Write-Warning "Unable to locate dummy file"
            Write-Warning "Create Message: $CreateMsg"
            Write-Warning "Last error: $($Error[0])"
            # !important Remove lock file on exit
            Remove-Item -Path "$Path\$SourceServer.lockfile" -Force -ErrorAction SilentlyContinue
            Exit
        }
        Write-Verbose "$(Get-Date): Source for dummy file: $Source\Test$RunServer.txt"
        $RunTime = Get-Date
    }
    # Main test process
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
                ##
                ##
                # Write test
                ##
                ##
                # Copy data from local folder to target folder
                Write-Verbose "$(Get-Date): WRITE TEST: copy data from local $Source to remote $Target"
                $WriteTest = Measure-Command { 
                    Copy-Item $Source\Test$RunServer.txt $Target -ErrorAction Stop -Force
                }
                # Remove copied data from from target
                Write-Verbose "$(Get-Date): WRITE TEST: remove $Target\Test$RunServer.txt"
                Remove-Item $Target\Test$RunServer.txt -ErrorAction SilentlyContinue
                
                # Wait for TCP session drop
                if ($RunTCPDropCheck) {
                    Wait-forTCPDrop -TimeOutSeconds $DropCheckSeconds -RemotePort 445 -CheckIPs $all_IPs -Verbose
                }
                
                ##
                ##
                # Read test
                ##
                ##
                Write-Verbose "$(Get-Date): READ TEST: Copy data from remote $Target to local $Source"

                # COLD RUN
                # If cold run, copy unique file from target to local, delete local file after copied,
                # but keep original target file.
                if ($IsColdRun) {
                    Write-Verbose "$(Get-Date): READ TEST: COLD RUN: copy unique file from target to local, delete local file after copied, but keep original target file."
                    # Identify data file from target to copy
                    $RandomFile = Get-ChildItem -Path "$Target\data\*.bin" | Select-Object -First 1
                    Write-Verbose "$(Get-Date): READ TEST: COLD RUN: Unique file selected: $RandomFile"
                    $RandomFile | select -ExpandProperty Name | Out-File "$Target\data\selected.txt" -Force
                    $ReadTest = Measure-Command {
                        Copy-Item $RandomFile $Source\TestRead.txt -ErrorAction Stop -Force
                    }
                    Write-Verbose "$(Get-Date): READ TEST: COLD RUN: Removing $Source\TestRead$RunServer.txt"
                    Remove-Item $Source\TestRead$RunServer.txt -ErrorAction SilentlyContinue -Force
                }
                # WARM RUN
                # If warm run, grab same unique random file from last cold run, copy from target to source,
                # delete file copied to source, and delete original source
                if (!$IsColdRun) {
                    Write-Verbose "$(Get-Date): READ TEST: WARM RUN: grab same unique random file from last cold run, copy from target to source, delete file copied to source, and delete original source"
                    $RandomFile = Get-Content "$Target\data\selected.txt"
                    Write-Verbose "$(Get-Date): READ TEST: WARM RUN: Random file selected from last cold run: $RandomFile"
                    $ReadTest = Measure-Command {
                        Copy-Item $Target\data\$RandomFile $Source\TestRead$RunServer.txt -ErrorAction Stop -Force
                    }
                    Write-Verbose "$(Get-Date): READ TEST: WARM RUN: Removing $Target\data\$RandomFile"
                    Remove-Item $Target\data\$RandomFile -ErrorAction SilentlyContinue -Force
                    Write-Verbose "$(Get-Date): READ TEST: WARM RUN: Removing $Source\TestRead$RunServer.txt"
                    Remove-Item $Source\TestRead$RunServer.txt -ErrorAction SilentlyContinue -Force
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
                Status = $Status
                WriteTime = $WriteTest
                WriteMbps = $WriteMbps
                ReadTime = $ReadTest
                ReadMbps = $ReadMbps
                SourceServer = $SourceServer
                Size = $Size
                ColdRun = $ColdRun
            }
            return $Output
        }
    }

    End {
        if (!$IsColdRun) {
            Write-Verbose "$(Get-Date): WARM RUN: Removing $Source\Test$RunServer.txt"
            Remove-Item $Source\Test$RunServer.txt -Force -ErrorAction SilentlyContinue
        }
        Write-Verbose "$(Get-Date): Test-NetworkSpeed complete for $Path, ColdRun = $ColdRun"
    }
}

## Set up variables for run paths to test, CSV output file, size of tests, number of times to test

# Number of times the test will be run for each path
$RunTimes = 2

# Where to email the report to after test is complete
$Recpients = @('email@test.com', 'email2.test.com')

# RunBank array will store each run of each test, output is a table when done
$RunBank = New-Object psobject @{}
# Define each path to test

# Define CSV file for logging each speed test run
$LogCsv = "$SharePath\NetworkSpeedTests.csv"
# Define size (in MB) of each speed test
$size = 512

# Create CSV file if it doesn't exist
if (!(Test-Path $LogCsv)) {
    New-Item -ItemType File -Path $LogCsv | Out-Null
}

# All speed test actions are here. Each test will repeat $RunTimes, each test will be logged to CSV and $RunBank array for HTML/email export.
for ($i=1; $i -le $RunTimes; $i++) {
    foreach ($path in $Paths) {
        # Speed test: Cold run
        $TestRun = Test-NetworkSpeed -Path $path -ColdRun "ColdRun" -Verbose
        $TestRun
        # Append data to CSV file
        $TestRun | Export-Csv -Path $LogCsv -Append -NoTypeInformation
        # Add test results to $RunBank array
        [array]$RunBank += $TestRun
        
        # wait for TCP session drop
        if ($RunTCPDropCheck) {
            Wait-forTCPDrop -TimeOutSeconds $DropCheckSeconds -RemotePort 445 -CheckIPs $all_IPs -Verbose
        }
        # Speed test: Warm run
        $TestRun = Test-NetworkSpeed -Path $path -ColdRun "WarmRun" -Verbose
        $TestRun
        # Append data to CSV file
        $TestRun | Export-Csv -Path $LogCsv -Append -NoTypeInformation
        # Add test results to $RunBank array
        [array]$RunBank += $TestRun
        
        # wait for TCP session drop
        if ($RunTCPDropCheck) {
            Wait-forTCPDrop -TimeOutSeconds $DropCheckSeconds -RemotePort 445 -CheckIPs $all_IPs -Verbose
        }

        # Wait additional minute between passes
        Write-Verbose "Waiting additional minute between passes.."
        Start-Sleep -Seconds 60
    }
}

# Append data to CSV file
#$RunBank | select Server, TimeStamp, WriteMbps, ReadMbps, SourceServer, Size | Export-Csv -Path $LogCsv -NoTypeInformation -Force -Append

## HTML formatting/email creation
$table = $RunBank | select Server, TimeStamp, WriteMbps, ReadMbps, SourceServer, Size, ColdRun | ConvertTo-Html -Fragment

$ScriptEndTime = Get-Date
$ScriptTotalRunTime = New-TimeSpan -Start $ScriptStartTime -End $ScriptEndTime

if ($ScriptTotalRunTime.Hours -gt 0) {$ScriptHrs = "$($ScriptTotalRunTime.Hours) Hours, "}
if ($ScriptTotalRunTime.Minutes -gt 0) {$ScriptMins = "$($ScriptTotalRunTime.Minutes) Minutes, "}

$ScriptTotalRunTimeText = "$ScriptHrs$ScriptMins$($ScriptTotalRunTime.Seconds) Seconds"


$Title = "Speed Test Run: $(Get-Date)"
$ReportDescription = "Description for report goes here. <br/> <b>Total runtime: $ScriptTotalRunTimeText</b>"
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
[string]$emailBody = ConvertTo-Html -Head $Head -Body $table | Out-File "$SharePath\report.htm" -Encoding ascii -Force

# Send email - make sure to populate "From" and "SmtpServer" fields
Send-MailMessage -BodyAsHtml -From "noreply@test.com" -Subject $Title -Body $emailBody -To $Recpients -SmtpServer "mail.test.com"

# !important Remove lock file on exit
Remove-Item -Path "$SharePath\$SourceServer.lockfile" -Force -ErrorAction SilentlyContinue
