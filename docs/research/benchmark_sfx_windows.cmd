@echo off
REM RandomSFX (rx/sfx) Benchmark Script for Windows
REM Target: AMD Ryzen 9 5950X
REM
REM This script runs benchmark configurations and logs results.
REM All tests use safe defaults (wrmsr disabled, no security changes required).
REM
REM USAGE: 
REM   Regular user:   Run to test baseline performance
REM   Administrator:  Run as Admin to test with large pages enabled
REM
REM MSR modifications are NOT included by default. See MSR EXPERIMENT section
REM in SFX_5950X_OPTIMIZATION_RESEARCH.md if you explicitly want to test MSR.

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
echo NOTE: All tests use safe defaults (MSR writes disabled)
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
    echo [INFO] Large pages may be available if privilege is granted
    set ADMIN=1
) else (
    echo [INFO] Running as regular user
    echo [INFO] Large pages will not be available
    echo [INFO] To test with large pages, right-click and "Run as Administrator"
    set ADMIN=0
)
echo.

REM ========================================
REM Test 1: Algorithm Verification
REM ========================================
echo [TEST 1] Verifying rx/sfx algorithm is correctly selected...
echo.

%XMRIG% --bench=250K -a %ALGO% --randomx-wrmsr=-1 --no-color 2>&1 | findstr /C:"algo rx/sfx" >nul
if %errorlevel% == 0 (
    echo [PASS] Algorithm rx/sfx confirmed
) else (
    echo [FAIL] Algorithm rx/sfx NOT detected - check output manually
)
echo.

REM ========================================
REM Test 2: Baseline (no large pages, no MSR)
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
    echo [INFO] Skipping large pages test (requires Administrator)
    goto :thread_tests
)

REM ========================================
REM Test 3: Large Pages (no MSR)
REM ========================================
echo [TEST 3] Large pages benchmark (no MSR)...
echo Output: %LOG_DIR%\largepages_%TIMESTAMP%.txt
echo.

%XMRIG% --bench=%BENCH_SIZE% -a %ALGO% --randomx-wrmsr=-1 --no-color > "%LOG_DIR%\largepages_%TIMESTAMP%.txt" 2>&1

for /f "tokens=*" %%a in ('findstr /C:"benchmark finished" "%LOG_DIR%\largepages_%TIMESTAMP%.txt"') do (
    echo LARGEPAGES: %%a
)
for /f "tokens=*" %%a in ('findstr /C:"huge pages" "%LOG_DIR%\largepages_%TIMESTAMP%.txt"') do (
    echo             %%a
)
echo.

:thread_tests
REM ========================================
REM Test 4: Thread Count Variations
REM ========================================
echo [TEST 4] Thread count test (16 threads)...
echo Output: %LOG_DIR%\threads16_%TIMESTAMP%.txt
echo.

%XMRIG% --bench=%BENCH_SIZE% -a %ALGO% --threads=16 --randomx-wrmsr=-1 --no-color > "%LOG_DIR%\threads16_%TIMESTAMP%.txt" 2>&1

for /f "tokens=*" %%a in ('findstr /C:"benchmark finished" "%LOG_DIR%\threads16_%TIMESTAMP%.txt"') do (
    echo THREADS16: %%a
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
echo   - Hash sum (should match between runs with same config)
echo.
echo NOTE: Hash sum for rx/sfx is NOT validated against reference.
echo       See SFX_5950X_OPTIMIZATION_RESEARCH.md section 1.4.
echo.
echo For thread/affinity testing, first export your topology:
echo   xmrig.exe --export-topology topology.xml
echo.
echo Then create config files based on YOUR specific CPU mapping.
echo Do NOT use hardcoded affinity examples from generic guides.
echo.
echo For MSR experiments (explicit opt-in), see:
echo   docs\research\SFX_5950X_OPTIMIZATION_RESEARCH.md section 5
echo.

pause
