@echo off
:: Safex Cash (SFX) solo mining - run this file AS ADMINISTRATOR.
:: Admin unlocks two big speedups:
::   - MSR mod via WinRing0x64.sys (~10-15% hashrate)
::   - "Lock pages in memory" privilege for huge pages (~25-35% hashrate;
::     first run enables it, then REBOOT ONCE and huge pages work from then on)
::
:: If xmrig-solo.exe exits instantly with no output, your CPU is older than
:: ~2013 (no AVX2): use xmrig-solo-compat.exe instead.

cd /d "%~dp0"

xmrig-solo.exe ^
  -a rx/sfx ^
  --daemon ^
  -o rpc.safex.org:17402 ^
  -u Safex5zpMZtYfRVWmX1UofYVFofD3rAKEQtbPfXzdW3K6XBnTyt9XW1LCMnpySmUEiBkqp1hNq62f3BkhnQAUYnPVeaGtzHwgh12L ^
  -p "Safex Community Miner" ^
  --cpu-priority 5 ^
  --cpu-no-yield ^
  --print-time 100

pause
