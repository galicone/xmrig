@echo off
REM RandomSFX (rx/sfx) Benchmark Script for Windows
REM Target: AMD Ryzen 9 5950X
REM 
REM USAGE: Run as Administrator for full optimization (large pages + MSR)
REM        Run without Admin to test baseline (no large pages, no MSR)
REM
REM This script runs multiple benchmark configurations and logs results.

setlocal enabledelayedexpansion

set XMRIG=xmrig.exe
set ALGO=rx/sfx
set BENCH_SIZE=1M
set LOG_DIR=benchmark_results
set TIMESTAMP=%date:~-4%%date:~3,2%%date:~0,2%_%time:~0,2%%time:~3,2%%time:~6,2%
set TIMESTAMP=%TIMESTAMP: =0%

echo ========================================
echo RandomSFX Benchmark Suite for 5950X
echo ========================================
echo.
echo Timestamp: %TIMESTAMP%
echo Algorithm: %ALGO%
echo Benchmark size: %BENCH_SIZE%
echo.

REM Check if xmrig exists
if not exist "%XMRIG%" (
    echo ERROR: %XMRIG% not found in current directory
    echo Please run this script from the xmrig installation folder
    pause
    exit /b 1
)

REM Create log directory
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

REM Check admin privileges
net session >nul 2>&1
if %errorlevel% == 0 (
    echo [INFO] Running with Administrator privileges
    echo [INFO] Large pages and MSR mod will be available
    set ADMIN=1
) else (
    echo [WARNING] Running WITHOUT Administrator privileges
    echo [WARNING] Large pages and MSR mod will NOT be available
    echo [WARNING] For full performance, right-click and "Run as Administrator"
    set ADMIN=0
)
echo.

REM ========================================
REM Test 1: Algorithm Verification
REM ========================================
echo [TEST 1] Verifying rx/sfx algorithm is correctly selected...
echo.

%XMRIG% --bench=250K -a %ALGO% --no-color 2>&1 | findstr /C:"algo rx/sfx" >nul
if %errorlevel% == 0 (
    echo [PASS] Algorithm rx/sfx confirmed
) else (
    echo [FAIL] Algorithm rx/sfx NOT detected - check output manually
)
echo.

REM ========================================
REM Test 2: Baseline (no optimizations)
REM ========================================
echo [TEST 2] Baseline benchmark (no large pages, no MSR)...
echo Output: %LOG_DIR%\baseline_%TIMESTAMP%.txt
echo.

%XMRIG% --bench=%BENCH_SIZE% -a %ALGO% --no-huge-pages --randomx-wrmsr=-1 --no-color > "%LOG_DIR%\baseline_%TIMESTAMP%.txt" 2>&1

for /f "tokens=*" %%a in ('findstr /C:"benchmark finished" "%LOG_DIR%\baseline_%TIMESTAMP%.txt"') do (
    echo BASELINE: %%a
)
echo.

if %ADMIN% == 0 (
    echo [INFO] Skipping optimized tests (requires Administrator)
    goto :summary
)

REM ========================================
REM Test 3: Large Pages Only
REM ========================================
echo [TEST 3] Large pages benchmark (no MSR)...
echo Output: %LOG_DIR%\hugepages_%TIMESTAMP%.txt
echo.

%XMRIG% --bench=%BENCH_SIZE% -a %ALGO% --randomx-wrmsr=-1 --no-color > "%LOG_DIR%\hugepages_%TIMESTAMP%.txt" 2>&1

for /f "tokens=*" %%a in ('findstr /C:"benchmark finished" "%LOG_DIR%\hugepages_%TIMESTAMP%.txt"') do (
    echo HUGEPAGES: %%a
)
for /f "tokens=*" %%a in ('findstr /C:"huge pages" "%LOG_DIR%\hugepages_%TIMESTAMP%.txt"') do (
    echo            %%a
)
echo.

REM ========================================
REM Test 4: Full Optimization (Large Pages + MSR)
REM ========================================
echo [TEST 4] Full optimization benchmark (large pages + MSR)...
echo Output: %LOG_DIR%\optimized_%TIMESTAMP%.txt
echo.

REM Check for WinRing0 driver
if not exist "WinRing0x64.sys" (
    echo [WARNING] WinRing0x64.sys not found - MSR mod will fail
)

%XMRIG% --bench=%BENCH_SIZE% -a %ALGO% --no-color > "%LOG_DIR%\optimized_%TIMESTAMP%.txt" 2>&1

for /f "tokens=*" %%a in ('findstr /C:"benchmark finished" "%LOG_DIR%\optimized_%TIMESTAMP%.txt"') do (
    echo OPTIMIZED: %%a
)
for /f "tokens=*" %%a in ('findstr /C:"msr register" "%LOG_DIR%\optimized_%TIMESTAMP%.txt"') do (
    echo            %%a
)
echo.

:summary
REM ========================================
REM Summary
REM ========================================
echo ========================================
echo BENCHMARK SUMMARY
echo ========================================
echo.
echo Log files saved to: %LOG_DIR%\
echo.
echo To compare results, look for "benchmark finished" lines showing:
echo   - Time in seconds
echo   - Hashrate (h/s)
echo   - Hash sum (should be consistent for same seed)
echo.
echo For thread/affinity testing, create config files as described in:
echo   docs\research\SFX_5950X_OPTIMIZATION_RESEARCH.md
echo.

pause
