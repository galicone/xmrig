# XMRig Config Templates for AMD Ryzen 9 5950X + RandomSFX

These configuration templates are for systematic A/B testing of RandomSFX (rx/sfx) mining on Windows with AMD Ryzen 9 5950X.

## Usage

1. Copy the desired config file to your xmrig directory
2. Rename to `config.json` or run with `-c filename.json`
3. Run as Administrator for full optimization
4. Record results for comparison

## Template Descriptions

### config_benchmark_baseline.json
- Benchmark mode (1M hashes)
- No optimizations (baseline measurement)
- Use this to establish baseline hashrate

### config_benchmark_optimized.json
- Benchmark mode (1M hashes)
- All auto-detected optimizations enabled
- Large pages + MSR mod

### config_16t_physical.json
- 16 threads on physical cores only (no SMT partners)
- Typical optimal for RandomX when memory bandwidth limited
- Tests CCD0 cores 0-7 + CCD1 cores 16-23

### config_32t_all.json
- 32 threads (all logical processors)
- May or may not be faster depending on memory subsystem
- Test against 16-thread config

### config_ccd0_only.json
- 8 threads on CCD0 physical cores only
- Tests single-CCD performance (32MB L3)

### config_ccd1_only.json
- 8 threads on CCD1 physical cores only
- Tests single-CCD performance (32MB L3)

### config_ccd_balanced.json
- 16 threads: 8 per CCD (physical only)
- Balanced cross-CCD configuration

## Important Notes

1. **Run as Administrator** for large pages and MSR mod
2. **WinRing0x64.sys** must be in the same directory as xmrig.exe for MSR
3. **Thermal stability**: Allow 5+ minutes between tests for thermals to stabilize
4. **Repeatability**: Run each config at least 3 times and average results
5. **Background processes**: Close unnecessary applications during testing

## Verifying rx/sfx Algorithm

Check the log output for:
```
randomx  init dataset algo rx/sfx
```

If you see `algo rx/0` instead, the Safex algorithm is NOT being used.

## Expected Log Entries (Optimal)

```
HUGE PAGES   supported
randomx  allocated 2336 MB (2080+256) huge pages 100% 1168/1168 +JIT
msr      register values for "ryzen_19h" preset has been set successfully
```

If huge pages show 0%, run as Administrator and potentially reboot.
If MSR fails, ensure WinRing0x64.sys is present.
