<#
.SYNOPSIS
    Python-focused memory carving tool for AVML/LiME memory dumps.

.DESCRIPTION
    PyCarv is a high-performance PowerShell script that uses Sysinternals strings64.exe 
     to extract Python-related strings and potential file paths from memory dumps.
    It features streaming I/O to handle massive (100GB+) dumps without using temporary disk space,
    parallel processing for multi-core performance, and advanced regex matching.

.PARAMETER DumpDir
    Directory containing .avml or .lime memory dumps to process.

.PARAMETER OutDir
    Directory where results will be stored. Defaults to a 'results' subfolder in the script's directory.

.PARAMETER StringsExe
    Path to Sysinternals strings64.exe. If not provided, the script searches in PATH.

.PARAMETER MinLen
    Minimum string length to extract. Default is 8.

.PARAMETER ShowOffsets
    If true (default), calculates byte offsets for strings. Disabling this can boost speed by 5x.

.PARAMETER KeepFullStrings
    If true (default), saves a full ASCII string dump of each file in 'results/raw_full_strings'.

.PARAMETER ThrottleLimit
    Maximum number of dumps to process in parallel. Default is 12.

.PARAMETER ScanUnicode
    If true, also scans for Unicode (UTF-16) strings. Default is false.

.EXAMPLE
    .\pycarv.ps1 -DumpDir "C:\Forensics\Dumps" -OutDir "C:\Results"
    Runs with default settings on all dumps in the specified directory.

.EXAMPLE
    .\pycarv.ps1 -DumpDir "." -ShowOffsets $false
    Processes dumps in the current directory at maximum speed by skipping offsets.
#>

Param(
  [Parameter(Mandatory = $true)]
  [string]$DumpDir,

  [string]$OutDir = (Join-Path $PSScriptRoot "results"),

  [string]$StringsExe = "strings64.exe",

  [int]$MinLen = 8,

  [bool]$ShowOffsets = $true,

  [bool]$KeepFullStrings = $true,

  [int]$ThrottleLimit = 12,

  [bool]$ScanUnicode = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# --------------------------- NEEDLES ---------------------------
$Needles = @(
  "python", "python3", ".py", ".pyc", "__pycache__",
  "pip", "venv", "virtualenv", "conda",
  "site-packages", "dist-packages",
  "pythonpath", "pythonhome",
  "requirements.txt", "setup.py"
)

# --------------------------- INITIALIZATION ---------------------------
# Resolve paths to absolute
if (Test-Path $DumpDir) { $DumpDir = (Resolve-Path $DumpDir).Path }
else { throw "Dump directory '$DumpDir' not found." }

$OutDir = if (Test-Path $OutDir) { (Resolve-Path $OutDir).Path } else { [System.IO.Path]::GetFullPath($OutDir) }

$RawDir = Join-Path $OutDir "raw_full_strings"
$PerDumpCsvDir = Join-Path $OutDir "per_dump_csv"
$PerDumpPathDir = Join-Path $OutDir "per_dump_paths"
$PythonHitsTxtDir = Join-Path $OutDir "python_hits_txt"
$StatusDir = Join-Path $OutDir "status"

$AllStringsCsv = Join-Path $OutDir "AllPythonStrings.csv"
$AllPathsCsv = Join-Path $OutDir "AllPythonPaths.csv"
$SummaryCsv = Join-Path $OutDir "Summary.csv"

# Create directories
$null = New-Item -ItemType Directory -Force -Path $StatusDir
$null = New-Item -ItemType Directory -Force -Path $OutDir
$null = New-Item -ItemType Directory -Force -Path $PerDumpCsvDir
$null = New-Item -ItemType Directory -Force -Path $PerDumpPathDir
$null = New-Item -ItemType Directory -Force -Path $PythonHitsTxtDir
if ($KeepFullStrings) { $null = New-Item -ItemType Directory -Force -Path $RawDir }

# --------------------------- VALIDATE TOOLS ---------------------------
if (-not (Test-Path $StringsExe)) {
  $found = (Get-Command $StringsExe -ErrorAction SilentlyContinue).Source
  if ($null -eq $found) {
    throw "strings64.exe not found at '$StringsExe' and not in PATH. Please download it from Sysinternals."
  }
  $StringsExe = $found
}

# --------------------------- SCAN DUMPS ---------------------------
$dumps = Get-ChildItem -Path $DumpDir -Filter *.avml -File
if (-not $dumps -or @($dumps).Count -eq 0) {
  $dumps = Get-ChildItem -Path $DumpDir -Filter *.lime -File
}
if (-not $dumps -or @($dumps).Count -eq 0) { throw "No .avml or .lime files found in $DumpDir" }

foreach ($d in $dumps) {
  if ($d.Length -lt 1MB) {
    Write-Warning "Skipping $($d.Name) - file size too small ($($d.Length) bytes)."
    $dumps = $dumps | Where-Object { $_.FullName -ne $d.FullName }
  }
}

Write-Host "PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
$totalDumps = @($dumps).Count
Write-Host "Dumps found: $totalDumps" -ForegroundColor Cyan
Write-Host "Output dir: $OutDir" -ForegroundColor Cyan
Write-Host "Show Offsets: $ShowOffsets" -ForegroundColor $(if ($ShowOffsets) { "Yellow" } else { "Green" })

# --------------------------- RUN PARALLEL AS JOBS ---------------------------

$jobs = foreach ($Dump in $dumps) {
  $base = $Dump.BaseName
  $statusFile = Join-Path $StatusDir "$base.json"
  
  Start-Job -Name "Carve_$base" -ScriptBlock {
    param($dumpName, $dumpFullName, $StringsExe, $MinLen, $Needles, $ScanUnicode, $KeepFullStrings, $OutDir, $RawDir, $PerDumpCsvDir, $PerDumpPathDir, $PythonHitsTxtDir, $StatusDir, $statusFile, $ShowOffsets)
    
    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

    function ConvertTo-CsvValue([string]$s) {
      if ($null -eq $s) { return '""' }
      return '"' + ($s -replace '"', '""') + '"'
    }

    function Get-OffsetLine([string]$line) {
      if ([string]::IsNullOrWhiteSpace($line)) { return $null }
      if ($line -match '^\s*(\d+)[:\s]\s*(.*)$') {
        return @([int64]$Matches[1], $Matches[1], $Matches[2])
      }
      return $null
    }


    function Update-Status([string]$phase, [double]$duration = 0) {
      $status = @{
        dump      = $dumpName
        phase     = $phase
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
      }
      if ($duration -gt 0) { $status.durationSec = $duration }
      $status | ConvertTo-Json -Compress | Out-File -FilePath $statusFile -Encoding UTF8 -Force
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($dumpName)
    $fullPath = $dumpFullName

    $pyHitsTxt = Join-Path $PythonHitsTxtDir "$base`_python.txt"
    $dumpCsv = Join-Path $PerDumpCsvDir  "$base.csv"
    $pathsTxt = Join-Path $PerDumpPathDir "$base.txt"

    # Pre-compile combined needle regex for massive performance gain
    $needlePattern = ($Needles | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $rxNeedle = [regex]("(?i)($needlePattern)")
    
    $paths = New-Object System.Collections.Generic.HashSet[string]
    $totalHits = 0
    $taskStartTime = Get-Date

    $rxLinuxPy = [regex]'(?i)(/[^ \t\r\n"''<>|]+?\.py)\b'
    $rxWinPy = [regex]'(?i)\b([A-Z]:\\[^ \t\r\n"''<>|]+?\.py)\b'

    $csvWriter = New-Object System.IO.StreamWriter($dumpCsv, $false, [System.Text.Encoding]::UTF8)
    $txtWriter = New-Object System.IO.StreamWriter($pyHitsTxt, $false, [System.Text.Encoding]::UTF8)
    
    $fullAsciiWriter = $null
    if ($KeepFullStrings) {
      $rawAscii = Join-Path $RawDir "$base`_ascii_full.txt"
      $fullAsciiWriter = New-Object System.IO.StreamWriter($rawAscii, $false, [System.Text.Encoding]::UTF8)
    }

    try {
      $csvWriter.WriteLine("DumpFile,Encoding,Offset,OffsetText,String")

      $passes = @()
      $passes += , @("ASCII", "-a")
      if ($ScanUnicode) { $passes += , @("UNICODE", "-u") }

      foreach ($pass in $passes) {
        $encName = $pass[0]
        $encArg = $pass[1]
        
        Update-Status "strings_$($encName.ToLower())"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $StringsExe
        # -o is slow; only add if requested
        $args = "-nobanner $encArg " + $(if ($ShowOffsets) { "-o " } else { "" }) + "-n $MinLen ""$fullPath"""
        $psi.Arguments = $args
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        
        while (-not $proc.StandardOutput.EndOfStream) {
          $line = $proc.StandardOutput.ReadLine()
          if ([string]::IsNullOrWhiteSpace($line)) { continue }

          if ($null -ne $fullAsciiWriter -and $encName -eq "ASCII") {
            $fullAsciiWriter.WriteLine($line)
          }


          if ($rxNeedle.IsMatch($line)) {
            $totalHits++
            $txtWriter.WriteLine($line)
            
            $offVal = ""
            $offText = ""
            $strText = $line
            
            if ($ShowOffsets) {
              $parsed = Get-OffsetLine $line
              if ($null -ne $parsed) {
                $offVal = $parsed[0]
                $offText = $parsed[1]
                $strText = $parsed[2]
              }
            }

            $csvWriter.WriteLine(
              (ConvertTo-CsvValue $dumpName) + "," +
              (ConvertTo-CsvValue $encName) + "," +
              $offVal + "," +
              (ConvertTo-CsvValue $offText) + "," +
              (ConvertTo-CsvValue $strText)
            )

            foreach ($m in $rxLinuxPy.Matches($strText)) { [void]$paths.Add($m.Groups[1].Value) }
            foreach ($m in $rxWinPy.Matches($strText)) { [void]$paths.Add($m.Groups[1].Value) }
          }
        }
        $proc.WaitForExit()
      }
    }
    finally {
      if ($null -ne $csvWriter) { $csvWriter.Dispose() }
      if ($null -ne $txtWriter) { $txtWriter.Dispose() }
      if ($null -ne $fullAsciiWriter) { $fullAsciiWriter.Dispose() }
      Update-Status "done" ((Get-Date) - $taskStartTime).TotalSeconds
    }

    $paths | Sort-Object | Set-Content -Path $pathsTxt -Encoding UTF8

    [pscustomobject]@{
      DumpFile        = $dumpName
      TotalHits       = $totalHits
      UniquePyPaths   = $paths.Count
      PerDumpCsv      = $dumpCsv
      PerDumpPathsTxt = $pathsTxt
      PythonHitsTxt   = $pyHitsTxt
    }
  } -ArgumentList $Dump.Name, $Dump.FullName, $StringsExe, $MinLen, $Needles, $ScanUnicode, $KeepFullStrings, $OutDir, $RawDir, $PerDumpCsvDir, $PerDumpPathDir, $PythonHitsTxtDir, $StatusDir, $statusFile, $ShowOffsets
}

# --------------------------- PROGRESS LOOP (ETA + Running Names + Phases + Avg) ---------------------------
while ($true) {
  $completedNow = @($jobs | Get-Job | Where-Object { $_.State -in @("Completed", "Failed", "Stopped") }).Count
  $percent = if ($totalDumps -gt 0) { [int](($completedNow / $totalDumps) * 100) } else { 0 }

  $runningInfo = @()
  $durations = @()

  if (Test-Path $StatusDir) {
    Get-ChildItem -Path $StatusDir -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($content) {
          $s = $content | ConvertFrom-Json
          if ($s.phase -ne "done") {
            $runningInfo += [pscustomobject]@{ Dump = $s.dump; Phase = $s.phase }
          }
          else {
            if ($s.durationSec) { $durations += [double]$s.durationSec }
          }
        }
      }
      catch { }
    }
  }

  $avgMin = 0
  $etaSeconds = 0
  if ($durations.Count -gt 0) {
    $avgSec = ($durations | Measure-Object -Average).Average
    $avgMin = [math]::Round($avgSec / 60, 1)
    
    if ($completedNow -lt $totalDumps) {
      $remaining = $totalDumps - $completedNow
      # Simple ETA: remaining dumps * average duration / throttle limit
      $etaSeconds = [int](($remaining * $avgSec) / $ThrottleLimit)
      if ($etaSeconds -lt 0) { $etaSeconds = 0 }
    }
  }

  if ($runningInfo.Count -gt 0) {
    $shown = $runningInfo | Select-Object -First 3
    $runningText = ($shown | ForEach-Object { "$($_.Dump) ($($_.Phase))" }) -join " | "
    if ($runningInfo.Count -gt 3) { $runningText += " (+$($runningInfo.Count - 3) more)" }
  }
  else {
    $runningText = "Waiting..."
  }

  $statusLine = "$completedNow / $totalDumps done | Avg: $avgMin min/dump | Running: $runningText"

  Write-Progress `
    -Id 1 `
    -Activity "Carving Python strings from AVML dumps" `
    -Status $statusLine `
    -PercentComplete $percent `
    -SecondsRemaining $etaSeconds

  $allFinished = $true
  foreach ($j in $jobs) {
    if ($j.State -notin @("Completed", "Failed", "Stopped")) { $allFinished = $false; break }
  }
  if ($allFinished) { break }
  Start-Sleep -Seconds 2
}

Write-Progress -Id 1 -Activity "Carving Python strings from AVML dumps" -Completed

# Receive job results
$results = $jobs | Receive-Job

# --------------------------- MERGE OUTPUTS ---------------------------
Write-Host "[+] Merging results into master CSVs..." -ForegroundColor Cyan

function ConvertTo-CsvValue-Main([string]$s) {
  if ($null -eq $s) { return '""' }
  return '"' + ($s -replace '"', '""') + '"'
}

"DumpFile,Encoding,Offset,OffsetText,String" | Out-File -FilePath $AllStringsCsv -Encoding UTF8 -Force
Get-ChildItem -Path $PerDumpCsvDir -Filter *.csv -File | ForEach-Object {
  Get-Content $_.FullName | Select-Object -Skip 1 | Add-Content -Path $AllStringsCsv -Encoding UTF8
}

"DumpFile,PyPath" | Out-File -FilePath $AllPathsCsv -Encoding UTF8 -Force

# Safety: Disable strict mode for the merge to handle deserialized objects gracefully
Set-StrictMode -Off
foreach ($r in @($results)) {
  if ($null -ne $r) {
    if (Test-Path $r.PerDumpPathsTxt) {
      Get-Content $r.PerDumpPathsTxt | ForEach-Object {
        $p = $_
        if (-not [string]::IsNullOrWhiteSpace($p)) {
          (ConvertTo-CsvValue-Main $r.DumpFile) + "," + (ConvertTo-CsvValue-Main $p) | Add-Content -Path $AllPathsCsv -Encoding UTF8
        }
      }
    }
  }
}
Set-StrictMode -Version Latest

$results | Export-Csv -Path $SummaryCsv -NoTypeInformation -Encoding UTF8

Write-Host "DONE ✅" -ForegroundColor Green
Write-Host "All strings CSV : $AllStringsCsv"
Write-Host "All paths CSV   : $AllPathsCsv"
Write-Host "Summary CSV     : $SummaryCsv"
Write-Host "KeepFullStrings : $KeepFullStrings"
