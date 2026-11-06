<#
.SYNOPSIS
    RandomSFX (rx/sfx) Benchmark Harness for Windows
    
.DESCRIPTION
    Runs systematic A/B benchmarks for RandomSFX on AMD Ryzen 9 5950X.
    
    SAFETY:
    - All configs use wrmsr:false, rdmsr:false (no MSR modifications)
    - Huge pages OFF by default (no privilege changes)
    - No auto-elevation or driver loading
    - Uses specific PID for process control (no taskkill-by-name)
    - Does not modify caller's config.json
    
    LIMITATIONS:
    - Windows execution was NOT validated (developed on Linux VM)
    - Must be tested on actual Windows system before production use
    
.PARAMETER XmrigPath
    Path to xmrig.exe (default: .\xmrig.exe)
    
.PARAMETER ThreadCounts
    Array of thread counts to test (default: 16,24,28,30,32)
    
.PARAMETER Repetitions
    Number of times to run each configuration (default: 3)
    
.PARAMETER BenchSize
    Benchmark size: 250K, 500K, 1M-10M (default: 250K for faster testing)
    
.PARAMETER Timeout
    Maximum seconds per benchmark run (default: 600)
    
.PARAMETER OutputDir
    Directory for results (default: .\benchmark_results)

.EXAMPLE
    .\Benchmark-SFX.ps1 -ThreadCounts 16,32 -Repetitions 3
#>

[CmdletBinding()]
param(
    [string]$XmrigPath = ".\xmrig.exe",
    [int[]]$ThreadCounts = @(16, 24, 28, 30, 32),
    [int]$Repetitions = 3,
    [string]$BenchSize = "250K",
    [int]$Timeout = 600,
    [string]$OutputDir = ".\benchmark_results"
)

$ErrorActionPreference = "Stop"
$Script:Version = "1.0.0"

# Validate xmrig exists
if (-not (Test-Path $XmrigPath)) {
    Write-Error "xmrig.exe not found at: $XmrigPath"
    exit 1
}

$XmrigPath = Resolve-Path $XmrigPath

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ResultsFile = Join-Path $OutputDir "results_$Timestamp.csv"
$LogFile = Join-Path $OutputDir "harness_$Timestamp.log"

function Write-Log {
    param([string]$Message)
    $LogEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $LogEntry
    Write-Host $LogEntry
}

function Run-SingleBenchmark {
    param(
        [string]$XmrigExe,
        [int]$Threads,
        [string]$Size,
        [int]$TimeoutSec,
        [string]$RunId
    )
    
    $TempConfig = Join-Path $env:TEMP "xmrig_bench_$RunId.json"
    $TempOutput = Join-Path $env:TEMP "xmrig_output_$RunId.txt"
    
    # Create isolated config file
    $Config = @{
        autosave = $false
        background = $false
        colors = $false
        benchmark = @{
            size = $Size
            algo = "rx/sfx"
        }
        cpu = @{
            enabled = $true
            "huge-pages" = $false
            "huge-pages-jit" = $false
            "hw-aes" = $null
            priority = $null
            asm = $true
            yield = $true
        }
        randomx = @{
            init = -1
            "init-avx2" = -1
            mode = "fast"
            "1gb-pages" = $false
            wrmsr = $false
            rdmsr = $false
            numa = $false
            scratchpad_prefetch_mode = 1
        }
        opencl = $false
        cuda = $false
    }
    
    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $TempConfig -Encoding UTF8
    
    $Result = @{
        RunId = $RunId
        Threads = $Threads
        Size = $Size
        StartTime = Get-Date
        EndTime = $null
        Hashrate = $null
        HashSum = $null
        AlgoVerified = $false
        ThreadsVerified = $false
        Completed = $false
        Error = $null
        ProcessId = $null
        ExitCode = $null
        OutputFile = $null
    }
    
    try {
        # Build arguments
        $Arguments = @(
            "-c", $TempConfig,
            "--threads=$Threads",
            "--no-color"
        )
        
        Write-Log "Starting: $XmrigExe $($Arguments -join ' ')"
        Write-Log "Config: $TempConfig"
        
        # Start process with output redirection
        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = $XmrigExe
        $ProcessInfo.Arguments = $Arguments -join ' '
        $ProcessInfo.RedirectStandardOutput = $true
        $ProcessInfo.RedirectStandardError = $true
        $ProcessInfo.UseShellExecute = $false
        $ProcessInfo.CreateNoWindow = $true
        
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcessInfo
        
        $OutputBuilder = New-Object System.Text.StringBuilder
        $ErrorBuilder = New-Object System.Text.StringBuilder
        
        # Event handlers for async output
        $OutputHandler = {
            if (-not [String]::IsNullOrEmpty($EventArgs.Data)) {
                $Event.MessageData.AppendLine($EventArgs.Data)
            }
        }
        
        $OutputEvent = Register-ObjectEvent -InputObject $Process -EventName OutputDataReceived -Action $OutputHandler -MessageData $OutputBuilder
        $ErrorEvent = Register-ObjectEvent -InputObject $Process -EventName ErrorDataReceived -Action $OutputHandler -MessageData $ErrorBuilder
        
        $Process.Start() | Out-Null
        $Result.ProcessId = $Process.Id
        Write-Log "Process started: PID $($Process.Id)"
        
        $Process.BeginOutputReadLine()
        $Process.BeginErrorReadLine()
        
        # Monitor for completion
        $StartWait = Get-Date
        $Completed = $false
        
        while (-not $Completed -and ((Get-Date) - $StartWait).TotalSeconds -lt $TimeoutSec) {
            Start-Sleep -Milliseconds 500
            
            $CurrentOutput = $OutputBuilder.ToString()
            
            # Check if benchmark finished
            if ($CurrentOutput -match "benchmark finished in ([\d.]+) seconds \(([\d.]+) h/s\) hash sum = ([A-F0-9]+)") {
                $Result.Hashrate = [double]$Matches[2]
                $Result.HashSum = $Matches[3]
                $Result.Completed = $true
                $Completed = $true
                Write-Log "Benchmark completed: $($Result.Hashrate) H/s, hash=$($Result.HashSum)"
            }
            
            # Verify algorithm
            if ($CurrentOutput -match "algo rx/sfx") {
                $Result.AlgoVerified = $true
            }
            
            # Verify thread count (look for "READY threads X/Y")
            if ($CurrentOutput -match "READY threads (\d+)/(\d+)") {
                $ActualThreads = [int]$Matches[1]
                $Result.ThreadsVerified = ($ActualThreads -eq $Threads)
                if (-not $Result.ThreadsVerified) {
                    Write-Log "WARNING: Requested $Threads threads but got $ActualThreads"
                }
            }
            
            # Check if process died unexpectedly
            if ($Process.HasExited -and -not $Completed) {
                $Result.Error = "Process exited unexpectedly with code $($Process.ExitCode)"
                break
            }
        }
        
        # Gracefully terminate if still running
        if (-not $Process.HasExited) {
            Write-Log "Terminating process PID $($Process.Id)"
            $Process.Kill()
            $Process.WaitForExit(5000)
        }
        
        $Result.ExitCode = $Process.ExitCode
        $Result.EndTime = Get-Date
        
        # Unregister events
        Unregister-Event -SourceIdentifier $OutputEvent.Name
        Unregister-Event -SourceIdentifier $ErrorEvent.Name
        
        # Save full output
        $FullOutput = $OutputBuilder.ToString() + $ErrorBuilder.ToString()
        Set-Content -Path $TempOutput -Value $FullOutput -Encoding UTF8
        $Result.OutputFile = $TempOutput
        
        if (-not $Result.Completed -and -not $Result.Error) {
            $Result.Error = "Timeout after $TimeoutSec seconds"
        }
        
    }
    catch {
        $Result.Error = $_.Exception.Message
        Write-Log "ERROR: $($Result.Error)"
    }
    finally {
        # Cleanup temp config (keep output for analysis)
        if (Test-Path $TempConfig) {
            Remove-Item $TempConfig -Force
        }
    }
    
    return $Result
}

# Main execution
Write-Log "========================================"
Write-Log "RandomSFX Benchmark Harness v$Script:Version"
Write-Log "========================================"
Write-Log "XMRig: $XmrigPath"
Write-Log "Thread counts: $($ThreadCounts -join ', ')"
Write-Log "Repetitions: $Repetitions"
Write-Log "Bench size: $BenchSize"
Write-Log "Timeout: $Timeout seconds"
Write-Log "Output: $OutputDir"
Write-Log ""
Write-Log "SAFETY SETTINGS:"
Write-Log "  wrmsr: false (no MSR writes)"
Write-Log "  rdmsr: false (no MSR reads)"
Write-Log "  huge-pages: false (no privilege required)"
Write-Log "  No auto-elevation"
Write-Log ""

# Verify algorithm before full suite
Write-Log "Verifying rx/sfx algorithm selection..."
$VerifyResult = Run-SingleBenchmark -XmrigExe $XmrigPath -Threads 4 -Size "250K" -TimeoutSec 180 -RunId "verify"
if (-not $VerifyResult.AlgoVerified) {
    Write-Log "FATAL: Could not verify rx/sfx algorithm selection"
    Write-Log "Check xmrig output: $($VerifyResult.OutputFile)"
    exit 1
}
Write-Log "Algorithm verification: PASS (rx/sfx confirmed)"
Write-Log ""

# Build test matrix with randomization
$TestMatrix = @()
for ($rep = 1; $rep -le $Repetitions; $rep++) {
    foreach ($threads in $ThreadCounts) {
        $TestMatrix += @{
            Threads = $threads
            Repetition = $rep
        }
    }
}

# Shuffle for randomized order
$TestMatrix = $TestMatrix | Sort-Object { Get-Random }

Write-Log "Test matrix: $($TestMatrix.Count) runs (randomized order)"
Write-Log ""

# Initialize results CSV
"RunId,Threads,Repetition,Hashrate,HashSum,AlgoVerified,ThreadsVerified,Duration,Completed,Error" | Set-Content $ResultsFile

# Warmup run
Write-Log "Running warmup (discarded)..."
$WarmupResult = Run-SingleBenchmark -XmrigExe $XmrigPath -Threads $ThreadCounts[0] -Size $BenchSize -TimeoutSec $Timeout -RunId "warmup"
Write-Log "Warmup complete, hashrate: $($WarmupResult.Hashrate) H/s"
Write-Log ""

# Run test matrix
$RunNumber = 0
$AllResults = @()

foreach ($Test in $TestMatrix) {
    $RunNumber++
    $RunId = "run_${RunNumber}_t$($Test.Threads)_r$($Test.Repetition)"
    
    Write-Log "----------------------------------------"
    Write-Log "Run $RunNumber/$($TestMatrix.Count): $($Test.Threads) threads (rep $($Test.Repetition))"
    
    $Result = Run-SingleBenchmark -XmrigExe $XmrigPath -Threads $Test.Threads -Size $BenchSize -TimeoutSec $Timeout -RunId $RunId
    $Result.Repetition = $Test.Repetition
    
    $Duration = if ($Result.EndTime -and $Result.StartTime) { 
        ($Result.EndTime - $Result.StartTime).TotalSeconds 
    } else { 
        0 
    }
    
    # Append to CSV
    "$RunId,$($Test.Threads),$($Test.Repetition),$($Result.Hashrate),$($Result.HashSum),$($Result.AlgoVerified),$($Result.ThreadsVerified),$Duration,$($Result.Completed),$($Result.Error)" | Add-Content $ResultsFile
    
    $AllResults += $Result
    
    if (-not $Result.Completed) {
        Write-Log "WARNING: Run failed - $($Result.Error)"
    }
}

# Summary statistics
Write-Log ""
Write-Log "========================================"
Write-Log "SUMMARY"
Write-Log "========================================"

foreach ($threads in $ThreadCounts) {
    $ThreadResults = $AllResults | Where-Object { $_.Threads -eq $threads -and $_.Completed }
    if ($ThreadResults.Count -gt 0) {
        $Hashrates = $ThreadResults | ForEach-Object { $_.Hashrate }
        $Sorted = $Hashrates | Sort-Object
        $Median = $Sorted[[math]::Floor($Sorted.Count / 2)]
        $Min = $Sorted[0]
        $Max = $Sorted[-1]
        $Spread = $Max - $Min
        
        Write-Log "$threads threads: Median=$([math]::Round($Median, 1)) H/s, Range=[$([math]::Round($Min, 1)), $([math]::Round($Max, 1))], Spread=$([math]::Round($Spread, 1)) H/s"
    }
    else {
        Write-Log "$threads threads: NO VALID RESULTS"
    }
}

Write-Log ""
Write-Log "Results saved to: $ResultsFile"
Write-Log "Harness log: $LogFile"
Write-Log ""
Write-Log "NOTE: This harness was developed on Linux VM."
Write-Log "Windows execution has NOT been validated."
Write-Log "Test on actual Windows system before production use."
