# RandomSFX Mining Optimization Research for AMD Ryzen 9 5950X (Windows)

## Executive Summary

This document presents research findings for optimizing RandomSFX (Safex Cash) mining on AMD Ryzen 9 5950X. **Target OS: Windows**. All configurations preserve existing security settings and do not require system/BIOS/driver modifications.

**Key constraints**:
- All config examples use `"wrmsr": false, "rdmsr": false` (safe defaults)
- MSR modifications are documented separately as an explicit opt-in experiment
- No BIOS/OS/security changes recommended
- No performance claims without user measurement on actual target hardware

## 1. Algorithm Verification

### 1.1 RandomSFX Salt Configuration - VERIFIED

**Source code evidence** (XMRig v6.26.0):

```cpp
// src/crypto/randomx/randomx.cpp lines 111-114
// https://github.com/xmrig/xmrig/blob/v6.26.0/src/crypto/randomx/randomx.cpp#L111-L114
RandomX_ConfigurationSafex::RandomX_ConfigurationSafex()
{
    ArgonSalt = "RandomSFX\x01";
}
```

This matches the Safex-pinned RandomSFX configuration:
- **Safex Core 7.0.3** pins commit `4f7b3a9a8365614ea41c0d865f92a9e855252b66`
- **Safex RandomSFX salt**: `RandomSFX\x01`
- **Monero RandomX salt**: `RandomX\x03`

Reference: https://github.com/safex/RandomSFX/blob/4f7b3a9a8365614ea41c0d865f92a9e855252b66/src/configuration.h

**WARNING**: The Safex/RandomSFX `master` branch has drifted to standard RandomX salt. Always verify against the node-pinned revision.

### 1.2 Benchmark Algorithm Verification - CODE TRACE

The user raised concern about whether `--bench -a rx/sfx` actually uses RandomSFX. Here is the code evidence:

**Algorithm ID encoding** (src/base/crypto/Algorithm.h line 80):
```cpp
// https://github.com/xmrig/xmrig/blob/v6.26.0/src/base/crypto/Algorithm.h#L80
RX_SFX = 0x72151273,   // "rx/sfx"  RandomSFX
```

**Family detection** (src/base/crypto/Algorithm.h line 178):
```cpp
// https://github.com/xmrig/xmrig/blob/v6.26.0/src/base/crypto/Algorithm.h#L178
constexpr static inline Id family(Id id) { return id & (isCN(id) ? 0xffff0000 : 0xff000000); }
```
- `RX_SFX (0x72151273) & 0xff000000 = 0x72000000 = RANDOM_X family` ✓

**CLI --algo routes to benchmark config** (src/core/config/ConfigTransform.cpp line 324):
```cpp
// https://github.com/xmrig/xmrig/blob/v6.26.0/src/core/config/ConfigTransform.cpp#L324
case IConfig::AlgorithmKey: /* --algo */
    return set(doc, BenchConfig::kBenchmark, BenchConfig::kAlgo, arg);
```

**Benchmark fallback logic** (src/base/net/stratum/benchmark/BenchConfig.cpp lines 68-72):
```cpp
// https://github.com/xmrig/xmrig/blob/v6.26.0/src/base/net/stratum/benchmark/BenchConfig.cpp#L68-L72
auto f = m_algorithm.family();
if (!m_algorithm.isValid() || (f != Algorithm::RANDOM_X ...)) {
    m_algorithm = Algorithm::RX_0;  // Falls back ONLY if NOT in RANDOM_X family
}
```
Since RX_SFX IS in RANDOM_X family, **no fallback occurs**.

### 1.3 Benchmark Verification - ACTUAL RUN OUTPUT

Run captured on this research VM (see `/opt/cursor/artifacts/sfx_benchmark_proof.txt`):

```
[2026-11-06 14:49:08.950]  bench    start benchmark hashes 250K algo rx/sfx
[2026-11-06 14:49:08.950]  randomx  init dataset algo rx/sfx (2 threads) seed 0000000000000000...
[2026-11-06 14:49:08.950]  randomx  allocated 2336 MB (2080+256) huge pages 0% 0/1168 +JIT (0 ms)
...
[2026-11-06 14:51:27.323]  bench    benchmark finished in 129.069 seconds (1936.9 h/s) hash sum = 648BA68C1B05A0B6
```

**Confirmed**: `algo rx/sfx` appears in output, NOT `algo rx/0`.

### 1.4 Known-Answer Validation - LIMITATION

**IMPORTANT**: XMRig has reference hashes for rx/0, rx/2, rx/wow but **NOT for rx/sfx**.

Source: `src/backend/common/benchmark/BenchState_test.h` contains:
```cpp
static const std::map<int, std::map<uint32_t, uint64_t> > hashCheck = {
    { Algorithm::RX_0, { ... }},    // Has reference hashes
    { Algorithm::RX_V2, { ... }},   // Has reference hashes
    { Algorithm::RX_WOW, { ... }}   // Has reference hashes
    // NO entry for RX_SFX
};
```

The hash sum `648BA68C1B05A0B6` is computed but **not validated** against any known-correct value. Full validation would require cross-checking with actual Safex pool acceptance.

## 2. AMD Ryzen 9 5950X Architecture Analysis

### 2.1 Topology Overview

| Component | Specification |
|-----------|--------------|
| Architecture | Zen 3 (Vermeer) |
| Physical Cores | 16 |
| Threads | 32 (SMT) |
| CCDs | 2 (8 cores each) |
| L3 Cache per CCD | 32 MiB (NOT shared between CCDs) |
| L2 Cache per Core | 512 KiB |
| Memory Channels | 2 (DDR4) |

### 2.2 CCD vs NUMA - CLARIFICATION

The 5950X has **two CCDs**, each with 32 MiB L3 cache. However:

- **Desktop 5950X typically presents as ONE NUMA node** to the OS
- Windows NUMA APIs may not expose CCD-level topology
- `"numa": true` in XMRig does NOT automatically allocate per-CCD

To discover actual topology on your system:
```cmd
xmrig.exe --export-topology topology.xml
```

Examine the generated XML for the actual NUMA/CCD mapping before configuring affinity.

### 2.3 Thread Affinity - NO HARDCODED MAPPINGS

**Do NOT assume specific CPU ID mappings**. The mapping depends on:
- BIOS version and settings
- Windows power management
- AMD CPPC (Collaborative Processor Performance Control)

Use `--export-topology` to discover your specific system's mapping, then create affinity configurations accordingly.

## 3. Disproven/Irrelevant Optimization Paths

### 3.1 VAES Instructions - NOT BENEFICIAL

**Evidence**: XMRig issue #1924, SChernykh (upstream maintainer) explicitly tested and rejected VAES:

> "Yes, I tested 2 different ways to use VAES and they both didn't give any speedup. AES in RandomX is limited by instruction latency and it stayed the same for VAES instructions."

Reference: https://github.com/xmrig/xmrig/issues/1924

**Conclusion**: Zen 3's VAES capability does NOT improve RandomX/RandomSFX hashrate.

### 3.2 AVX-512 - NOT AVAILABLE on Zen 3

AMD Zen 3 (including 5950X) does not support AVX-512. Any AVX-512 code paths in XMRig are completely irrelevant to 5950X.

### 3.3 1GB Huge Pages - LINUX ONLY

**Source code evidence** (src/crypto/common/VirtualMemory_win.cpp lines 159-160):
```cpp
// https://github.com/xmrig/xmrig/blob/v6.26.0/src/crypto/common/VirtualMemory_win.cpp#L159-L160
bool xmrig::VirtualMemory::isOneGbPagesAvailable()
{
    return false;  // Always false on Windows
}
```

**Windows only supports 2 MiB large pages**, not 1 GiB pages.

### 3.4 Init-AVX2 - INITIALIZATION ONLY

`init-avx2` affects **dataset initialization speed**, not steady-state hashrate.

**Source code evidence** (src/crypto/randomx/jit_compiler_x86.cpp lines 270-272):
```cpp
// https://github.com/xmrig/xmrig/blob/v6.26.0/src/crypto/randomx/jit_compiler_x86.cpp#L270-L272
case xmrig::ICpuInfo::ARCH_ZEN3:
    initDatasetAVX2 = true;
```

This is **already auto-detected** for Zen 3. It reduces dataset init time when seed changes (~every 2.8 days on Safex mainnet) but has **no effect on hashing speed**.

### 3.5 CryptoNight-Heavy Optimization (PR #2089) - NOT RANDOMX

PR #2089's "7-8% speedup" claim is for **CryptoNight-Heavy**, a completely different algorithm. Do not confuse with RandomX/RandomSFX.

## 4. Safe Baseline Configuration (Windows)

All configurations in this section use safe defaults that:
- Do NOT require Administrator privileges
- Do NOT write MSRs
- Do NOT modify system settings

### 4.1 Baseline Config Template

**config_sfx_baseline.json**:
```json
{
    "autosave": false,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true
    },
    "randomx": {
        "init": -1,
        "mode": "fast",
        "wrmsr": false,
        "rdmsr": false,
        "numa": false
    },
    "opencl": false,
    "cuda": false
}
```

**Notes**:
- `"wrmsr": false` - No MSR writes (safe)
- `"rdmsr": false` - No MSR reads (safe)
- `"huge-pages": true` - Will attempt but gracefully fail without privileges
- `"numa": false` - Disabled since 5950X typically presents as one NUMA node

### 4.2 Windows Large Pages

Windows large pages (2 MiB) require:
1. Administrator privileges
2. `SE_LOCK_MEMORY_NAME` privilege ("Lock pages in memory")

XMRig attempts to enable this privilege automatically when run as Administrator. First run may require logout/login or reboot after privilege is granted.

**Verification**: Look for this in output:
```
randomx  allocated 2336 MB (2080+256) huge pages 100% 1168/1168 +JIT
```

If you see `huge pages 0%`, large pages are not enabled.

### 4.3 Scratchpad Prefetch Mode

```json
{
    "randomx": {
        "scratchpad_prefetch_mode": 1
    }
}
```

Options:
- `0`: Disabled
- `1`: `prefetcht0` (default)
- `2`: `prefetchnta`
- `3`: `mov` instruction

Test modes 1 and 2 on your specific system to determine which performs better.

## 5. MSR Modifications - EXPLICIT OPT-IN EXPERIMENT

**This section documents MSR modifications as an explicit, opt-in experiment. These are NOT enabled in any default or recommended configuration.**

### 5.1 Prerequisites

- Administrator privileges
- `WinRing0x64.sys` driver in same directory as `xmrig.exe`
- Understanding that MSR writes modify CPU registers at hardware level

### 5.2 WinRing0 Driver

The WinRing0 driver enables user-mode MSR access. XMRig includes this driver in `bin/WinRing0/`.

**Note**: Windows may block unsigned drivers. This research does NOT recommend disabling driver signature enforcement or enabling test mode.

### 5.3 MSR Experiment Config

**ONLY use this if you explicitly want to test MSR modifications**:

```json
{
    "randomx": {
        "wrmsr": true,
        "rdmsr": true
    }
}
```

Zen 3 MSR preset (`MSR_MOD_RYZEN_19H`) writes:
- `0xC0011020`: `0x0004480000000000`
- `0xC0011021`: `0x001c000200000040`
- `0xC0011022`: `0xc000000401570000`
- `0xC001102b`: `0x2000cc10`

XMRig saves original values (if `rdmsr: true`) and restores them on exit.

### 5.4 MSR Impact

**No quantified claims**. Impact varies by:
- Specific CPU stepping
- BIOS version
- System configuration
- Thermal conditions

Measure on your own system with A/B testing.

## 6. Offline Benchmark Methodology (Windows)

### 6.1 Built-in Benchmark Command

```cmd
xmrig.exe --bench=1M -a rx/sfx --randomx-wrmsr=-1 --no-color
```

- `--bench=1M` - 1 million hashes
- `-a rx/sfx` - RandomSFX algorithm
- `--randomx-wrmsr=-1` - Explicitly disable MSR writes
- `--no-color` - Clean output for logging

**Valid benchmark sizes**: 250K, 500K, 1M-10M

### 6.2 Verify Algorithm Selection

In output, look for:
```
bench    start benchmark hashes 1M algo rx/sfx
randomx  init dataset algo rx/sfx
```

If you see `algo rx/0` instead of `algo rx/sfx`, something is wrong.

### 6.3 Hash Sum Output

Benchmark completes with:
```
benchmark finished in X.XXX seconds (YYYY.Y h/s) hash sum = XXXXXXXXXXXXXXXX
```

**Note**: The hash sum is NOT validated against a reference for rx/sfx (see section 1.4).

### 6.4 A/B Testing Procedure

**Environment preparation**:
1. Close unnecessary applications
2. Set Windows power plan to "High Performance"
3. Allow 5+ minutes idle before testing for thermal equilibrium
4. Run each configuration at least 3 times
5. Record ambient temperature

**Test sequence** (all with MSR disabled):

1. **Baseline (no huge pages)**:
   ```cmd
   xmrig.exe --bench=1M -a rx/sfx --no-huge-pages --randomx-wrmsr=-1 --no-color
   ```

2. **With huge pages** (run as Administrator):
   ```cmd
   xmrig.exe --bench=1M -a rx/sfx --randomx-wrmsr=-1 --no-color
   ```

3. **Thread count variations**: Use config files with different thread counts

### 6.5 Thread Count Testing

Create config files to test systematically. Example for thread count comparison:

**config_benchmark_auto.json** (auto-detect):
```json
{
    "benchmark": { "size": "1M", "algo": "rx/sfx" },
    "randomx": { "wrmsr": false, "rdmsr": false }
}
```

Then test with different `--threads` values:
```cmd
xmrig.exe -c config_benchmark_auto.json --threads=16
xmrig.exe -c config_benchmark_auto.json --threads=32
```

### 6.6 Topology-Based Affinity Testing

1. First, export topology:
   ```cmd
   xmrig.exe --export-topology topology.xml
   ```

2. Examine the XML to identify:
   - Which processor IDs map to which physical cores
   - Which cores share L3 cache (same CCD)

3. Create affinity configs based on YOUR specific topology

## 7. Windows Build Instructions

### 7.1 Prerequisites

- Visual Studio 2019 or 2022 with C++ workload
- CMake 3.10+
- Git

### 7.2 vcpkg Setup

```cmd
git clone https://github.com/microsoft/vcpkg
cd vcpkg
bootstrap-vcpkg.bat
vcpkg integrate install
vcpkg install openssl:x64-windows-static libuv:x64-windows-static hwloc:x64-windows-static
```

### 7.3 CMake Build (MSVC)

```cmd
git clone https://github.com/xmrig/xmrig.git
cd xmrig
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64 ^
  -DCMAKE_TOOLCHAIN_FILE=[vcpkg-root]/scripts/buildsystems/vcpkg.cmake ^
  -DVCPKG_TARGET_TRIPLET=x64-windows-static ^
  -DWITH_OPENCL=OFF -DWITH_CUDA=OFF
cmake --build . --config Release
```

### 7.4 Output

- `Release/xmrig.exe` - Main executable
- Copy `WinRing0x64.sys` to same directory only if explicitly testing MSR

## 8. Code Hot Paths Reference

### 8.1 RandomX Main Hash Loop

```
src/crypto/randomx/randomx.cpp
  Line 597-610: randomx_calculate_hash() - Main entry point
  
src/crypto/randomx/jit_compiler_x86.cpp
  JIT compilation of RandomX VM programs
  
src/crypto/randomx/jit_compiler_x86_static.asm
  Hand-optimized x86-64 assembly
```

### 8.2 Dataset Size

```cpp
// Dataset is exactly 2080 MiB (2,181,570,560 bytes)
// NOT generic "2 GiB"
// Scratchpad adds 256 MiB
// Total allocation: 2336 MiB
```

### 8.3 Windows-Specific Code

```
src/crypto/common/VirtualMemory_win.cpp
  Large pages allocation via VirtualAlloc with MEM_LARGE_PAGES
  SE_LOCK_MEMORY_NAME privilege handling
  
src/hw/msr/Msr_win.cpp
  WinRing0 driver interface for MSR access
  
src/base/kernel/Platform_win.cpp
  SetThreadAffinityMask() for thread pinning (line 89)
```

## 9. Upstream References

### Primary Sources

- **Safex RandomSFX (pinned)**: https://github.com/safex/RandomSFX/tree/4f7b3a9a8365614ea41c0d865f92a9e855252b66
- **Safex Core 7.0.3**: https://github.com/safex/safexcore/releases/tag/7.0.3
- **XMRig upstream**: https://github.com/xmrig/xmrig
- **RandomX specification**: https://github.com/tevador/RandomX/blob/master/doc/specs.md

### Relevant XMRig Issues/PRs

- **VAES testing (no improvement)**: https://github.com/xmrig/xmrig/issues/1924
- **Zen 3 MSR mod**: https://github.com/xmrig/xmrig/pull/1932
- **CryptoNight-Heavy Zen3 (NOT RandomX)**: https://github.com/xmrig/xmrig/pull/2089

## 10. Limitations and Caveats

### 10.1 Research Environment

This research was conducted on:
- **VM CPU**: Intel Xeon (NOT target AMD 5950X)
- **VM Features**: AVX-512 (NOT available on Zen 3)
- **OS**: Linux (NOT target Windows)

**All timing measurements from this environment are NOT representative of target performance. No performance claims are made.**

### 10.2 Unvalidated on Target Hardware

The following require measurement on actual 5950X:
- Specific hashrate from any configuration
- Optimal thread count
- Large pages impact
- MSR impact (if explicitly tested)

### 10.3 What This Research Does NOT Recommend

- Any BIOS/firmware changes
- Voltage/frequency modifications  
- Disabling Windows security features
- Disabling driver signature enforcement
- Enabling Windows test mode
- Pool/wallet configuration changes
- Downloading pre-built mining binaries

## 11. Conclusion

For AMD Ryzen 9 5950X on Windows mining Safex Cash (rx/sfx):

**Verified**:
- `--bench -a rx/sfx` correctly uses RandomSFX algorithm (code trace + run evidence)
- RandomSFX salt matches Safex-pinned configuration
- VAES does NOT improve RandomX (upstream maintainer confirmation)
- AVX-512 is NOT available on Zen 3
- 1GB pages are Linux-only

**Safe to test**:
- Windows large pages (run as Administrator)
- Thread count optimization
- Scratchpad prefetch mode (1 vs 2)

**Explicit opt-in only**:
- MSR modifications via WinRing0 (separate experiment, not default)

**Requires user measurement**:
- All performance impacts (no percentage claims without user data)

---

*Document generated: 2026-11-06*  
*Fork base: XMRig v6.26.0*  
*Target algorithm: rx/sfx (RandomSFX)*  
*Target hardware: AMD Ryzen 9 5950X*  
*Target OS: Windows*  
*Raw benchmark proof: /opt/cursor/artifacts/sfx_benchmark_proof.txt*
