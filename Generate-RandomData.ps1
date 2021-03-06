function Generate-RandomData {
    <# 
    .Synopsis 
      Generate files with random binary data. 
    .DESCRIPTION 
      Random files are useful for testing synchronization processes, backup/restore 
      and anything in general that handles large quantities of file data. 
 
      This script specifically does not create sparse files, or files with zeros or 
      other constant data. Such data is easily compressible or can be optimize during transfer. 
      Instead, the script generates pseudo-random data that cannot be optimized. The .NET  
      random generator used here is quite fast with about 100 MB/s. Writing the data 
      is usually the bottleneck.  
 
      Some notes on usage: by default, about 15 files, 100 MB total is generated in the  
      current directory. If you specify a TargetPath, it must exist. File sizes are random betwee 
      Minfilesize and Maxfilesize; these are allowed to be equal, generating fixed-size files.  
      Also, the file timestamps are randomized between <now> and 24h ago, to give 
      synchronization algorithms something to work with. Filenames are generated by 
      randomly shuffling the "filenameseed" string, and always end with ".bin".  
    .EXAMPLE 
      .\Generate-RandomBinaryFiles -Targetpath c:\temp\Randomdata 
    .EXAMPLE 
      .\Generate-RandomBinaryFiles -Targetpath c:\temp\Randomdata -minfilesize 100MB -maxfilesize 100MB -totalsize 10GB -timerangehours 0 
    .NOTES 
        Version:        1.0 : first version.  
        Author:         Willem Kasdorp, Microsoft.  
        Creation Date:  1/10/2017 
        Last modified: 
    #> 
 
    [CmdletBinding()] 
    Param( 
        [String] $TargetPath = "", 
        [int64] $minfilesize = 512MB, 
        [int64] $maxfilesize = 512MB, 
        [int64] $totalsize = 10GB, 
        [int] $timerangehours = 0, 
        [string] $filenameseed = "abcdefghijkl012345"    
    ) 
    $RunFrom = hostname
 
    # 
    # convert to absolute path as required by WriteAllBytes, and check existence of the directory.  
    # 
    #if (-not (Split-Path -IsAbsolute $TargetPath)) 
    #{ 
    #    $TargetPath = Join-Path (Get-Location).Path $TargetPath 
    #} 
    if (-not (Test-Path -Path $TargetPath -PathType Container )) 
    { 
        throw "TargetPath '$TargetPath' does not exist or is not a directory" 
    } 
 
    $currentsize = [int64]0 
    $currentime = Get-Date 
    while ($currentsize -lt $totalsize) 
    { 
        # 
        # generate a random file size. Do the smart thing if min==max. Do not exceed the specified total size.  
        # 
        if ($minfilesize -lt $maxfilesize)  
        { 
            $filesize = Get-Random -Minimum $minfilesize -Maximum $maxfilesize 
        } else { 
            $filesize = $maxfilesize 
        } 
        if ($currentsize + $filesize -gt $totalsize) { 
            $filesize = $totalsize - $currentsize 
        } 
        $currentsize += $filesize 
 
        # 
        # use a very fast .NET random generator 
        # 
        $data = new-object byte[] $filesize 
        (new-object Random).NextBytes($data) 
     
        # 
        # generate a random file name by shuffling the input filename seed.  
        # 
        $filename = $($filenameseed.ToCharArray() | Get-Random -Count ($filenameseed.Length)) -join '' 
        $filename = "GeneratedFrom-$RunFrom-$filename"
        $path = Join-Path $TargetPath "$($filename).bin" 
 
        # 
        # write the binary data, and randomize the timestamps as required.  
        # 
        try 
        { 
            [IO.File]::WriteAllBytes($path, $data) 
            if ($timerangehours -gt 0) 
            { 
                $timestamp = $currentime.AddHours(-1 * (Get-Random -Minimum 0 -Maximum $timerangehours)) 
            } else { 
                $timestamp = $currentime 
            } 
            $fileobject = Get-Item -Path $path 
            $fileobject.CreationTime = $timestamp 
            $fileobject.LastWriteTime = $timestamp 
 
            # show what we did.  
            [pscustomobject] @{ 
                filename = $path 
                timestamp = $timestamp 
                datasize = $filesize 
            } 
        } catch { 
            $message = "failed to write data to $path, error $($_.Exception.Message)" 
            Throw $message 
        }     
    } 
}

$Paths = "
\\path1,
\\path2"

foreach ($path in $Paths) {
    if (!(Test-Path -Path "$path\Data")) {
        New-Item -ItemType Directory -Path "$path\Data" | Out-Null
    }
    Generate-RandomData -TargetPath $path\Data -Verbose
}
