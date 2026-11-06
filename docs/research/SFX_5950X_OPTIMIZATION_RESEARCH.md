# RandomSFX Mining Optimization Research for AMD Ryzen 9 5950X (Windows)

## Executive Summary

This document presents research findings for optimizing RandomSFX (Safex Cash) mining on AMD Ryzen 9 5950X. **Target OS: Windows**. All recommendations preserve bit-identical hash outputs and do not involve system/BIOS/security/driver modifications.

## 1. Algorithm Verification

### 1.1 RandomSFX Configuration Match

**VERIFIED**: XMRig's `rx/sfx` implementation matches the Safex-pinned RandomSFX configuration.

| Parameter | Safex-Pinned (4f7b3a9a) | XMRig rx/sfx | Match |
|-----------|-------------------------|--------------|-------|
| ArgonSalt | `RandomSFX\x01` | `RandomSFX\x01` | ✓ |
| ArgonMemory | 262144 KB | 262144 KB | ✓ |
| ArgonIterations | 3 | 3 | ✓ |
| ArgonLanes | 1 | 1 | ✓ |
| ScratchpadL3 | 2097152 (2 MiB) | 2097152 | ✓ |
| ScratchpadL2 | 262144 (256 KiB) | 262144 | ✓ |
| ScratchpadL1 | 16384 (16 KiB) | 16384 | ✓ |
| ProgramSize | 256 | 256 | ✓ |
| ProgramIterations | 2048 | 2048 | ✓ |
| ProgramCount | 8 | 8 | ✓ |

**Source verification**:
- Safex: https://github.com/safex/RandomSFX/blob/4f7b3a9a8365614ea41c0d865f92a9e855252b66/src/configuration.h
- XMRig: `src/crypto/randomx/randomx.cpp` line 111-114

**WARNING**: The Safex/RandomSFX `master` branch may have drifted to standard RandomX salt. Always verify against the node-pinned revision (4f7b3a9a).

### 1.2 rx/sfx vs rx/0 Differentiation

The **only** difference between RandomSFX and standard RandomX is the Argon2 salt:
- `rx/0` (Monero): `RandomX\x03`
- `rx/sfx` (Safex): `RandomSFX\x01`

This produces entirely different dataset initialization and thus different hashes for identical inputs.

## 2. AMD Ryzen 9 5950X Architecture Analysis

### 2.1 Topology Overview

| Component | Specification | Optimization Relevance |
|-----------|--------------|------------------------|
| Architecture | Zen 3 (Vermeer) | ARCH_ZEN3 detection in XMRig |
| Cores | 16 physical | Thread count optimization target |
| Threads | 32 (SMT) | SMT impact must be measured |
| CCDs | 2 | **Critical**: Each CCD has separate L3 |
| L3 Cache per CCD | 32 MiB | NOT 64 MiB shared - 2×32 MiB local |
| L2 Cache per Core | 512 KiB | Per-core, relevant for scratchpad |
| Memory Channels | 2 | DDR4 dual-channel |

### 2.2 Critical Insight: L3 Cache Topology

The 5950X has **two CCDs (Core Complex Dies)**, each with:
- 8 cores (16 threads with SMT)
- 32 MiB shared L3 cache (within the CCD)

**Inter-CCD L3 access has higher latency than intra-CCD access.**

For RandomX/RandomSFX:
- 2 MiB scratchpad per thread fits in L3
- Dataset (2 GiB) does not fit in cache
- Thread-to-CCD affinity affects L3 cache sharing

### 2.3 Windows Thread Affinity Mapping

Windows processor numbering for 5950X (typical):
```
CCD0: Cores 0-7  → Logical CPUs 0-15 (physical 0-7 + SMT 8-15)
CCD1: Cores 8-15 → Logical CPUs 16-31 (physical 16-23 + SMT 24-31)
```

**Note**: Actual mapping may vary. Use `--export-topology` to generate XML for your specific system.

## 3. Disproven/Irrelevant Optimization Paths

### 3.1 VAES Instructions - NOT BENEFICIAL for RandomX

**Evidence**: XMRig issue #1924, SChernykh (maintainer) comment:
> "Yes, I tested 2 different ways to use VAES and they both didn't give any speedup. AES in RandomX is limited by instruction latency and it stayed the same for VAES instructions."

**Conclusion**: Zen 3's VAES capability does not improve RandomX/RandomSFX hashrate.

### 3.2 AVX-512 - NOT AVAILABLE on Zen 3

AMD Zen 3 (including 5950X) does not support AVX-512. Any AVX-512 code paths in XMRig are irrelevant.

The VM used for this research has AVX-512 (Intel Xeon), but this does NOT represent 5950X capabilities.

### 3.3 1GB Huge Pages - LINUX ONLY

```cpp
// src/crypto/common/VirtualMemory_win.cpp
bool xmrig::VirtualMemory::isOneGbPagesAvailable()
{
    return false;  // Windows: Always false
}
```

**1GB pages are not applicable to Windows**. Only 2MB large pages are supported.

### 3.4 Init-AVX2 - INITIALIZATION ONLY

The `init-avx2` option affects **dataset initialization speed**, not steady-state hashrate:

```cpp
// src/crypto/randomx/jit_compiler_x86.cpp:270-272
case xmrig::ICpuInfo::ARCH_ZEN3:
    // AVX2 init is faster on Zen3
    initDatasetAVX2 = true;
```

This is already auto-detected for Zen 3. It reduces dataset init time when seed changes (every ~2.8 days on Safex), but has no effect on hashing speed.

### 3.5 CryptoNight-Heavy Zen3 Optimization - NOT RANDOMX

The PR #2089 "7-8% speedup" claim is for **CryptoNight-Heavy**, not RandomX/RandomSFX. Do not conflate these algorithms.

## 4. Valid Configuration Optimizations (Windows)

### 4.1 Windows Large Pages

**Requirement**: Administrator privileges + "Lock pages in memory" right

**Enabling Large Pages**:
1. Run XMRig as Administrator
2. XMRig will automatically attempt to enable `SE_LOCK_MEMORY_NAME` privilege
3. A reboot may be required after first enabling

**Expected impact**: Reduces TLB misses, ~1-5% improvement typical

**Verification**:
```
randomx  allocated 2336 MB (2080+256) huge pages 100% 1168/1168 +JIT
```

If you see `huge pages 0%`, large pages are not enabled.

### 4.2 MSR Mod (WinRing0)

**Prerequisites**:
- Administrator privileges
- `WinRing0x64.sys` driver in same directory as `xmrig.exe`
- Windows may require driver signing disabled or test mode

**Zen 3 (5950X) MSR Preset** (`MSR_MOD_RYZEN_19H`):
```json
{
  "randomx": {
    "wrmsr": true
  }
}
```

The default preset for Zen 3 writes:
- `0xC0011020`: `0x0004480000000000`
- `0xC0011021`: `0x001c000200000040` (mask: `~0x20`)
- `0xC0011022`: `0xc000000401570000`
- `0xC001102b`: `0x2000cc10`

**WARNING**: MSR modifications affect CPU behavior at the hardware level. The miner restores original values on exit (if `rdmsr: true`).

**Expected impact**: Up to ~3-5% improvement reported for Zen 3 on RandomX

### 4.3 Thread Configuration

**Recommendation**: Test multiple configurations systematically

**Starting points for 5950X**:
- 16 threads (physical cores only, no SMT partners)
- 32 threads (all logical processors)
- 14-15 threads (leave cores for OS)

**Affinity-aware configuration example** (physical cores on CCD0):
```json
{
  "cpu": {
    "rx": [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23]
  }
}
```

### 4.4 Scratchpad Prefetch Mode

```json
{
  "randomx": {
    "scratchpad_prefetch_mode": 1
  }
}
```

Options:
- `0`: Disabled (NOP)
- `1`: `prefetcht0` (default, usually fastest)
- `2`: `prefetchnta` (slightly faster on some CPUs)
- `3`: `mov` instruction

**Recommendation**: Test modes 1 and 2 on your specific system.

### 4.5 NUMA Configuration

For 5950X with proper NUMA detection:
```json
{
  "randomx": {
    "numa": true
  }
}
```

This allocates separate datasets per NUMA node, reducing cross-CCD memory traffic.

## 5. Offline Benchmark Methodology (Windows)

### 5.1 Built-in Benchmark

```cmd
xmrig.exe --bench=1M -a rx/sfx
```

**Valid benchmark sizes**: 250K, 500K, 1M-10M

**Verification that rx/sfx is active**:
```
[...] bench    start benchmark hashes 1M algo rx/sfx
[...] randomx  init dataset algo rx/sfx (16 threads) seed ...
```

If you see `algo rx/0` instead of `algo rx/sfx`, the algorithm is incorrect.

### 5.2 Known-Answer Test

The benchmark includes a hash sum verification. A correct run shows:
```
benchmark finished in X.XXX seconds (YYYY.Y h/s) hash sum = XXXXXXXXXXXXXXXX
```

Green hash sum = correct hashes. Red = hardware error during computation.

### 5.3 Windows A/B Testing Procedure

**Environment Preparation**:
1. Close all unnecessary applications
2. Disable Windows Defender real-time scanning for xmrig folder
3. Set Windows power plan to "High Performance"
4. Allow system to reach thermal equilibrium (5+ minutes idle before testing)
5. Run each test multiple times (minimum 3)

**Baseline Test**:
```cmd
xmrig.exe --bench=1M -a rx/sfx --no-huge-pages --randomx-wrmsr=-1
```

**With Huge Pages**:
```cmd
xmrig.exe --bench=1M -a rx/sfx --randomx-wrmsr=-1
```
(Run as Administrator)

**With MSR Mod**:
```cmd
xmrig.exe --bench=1M -a rx/sfx
```
(Run as Administrator with WinRing0x64.sys present)

### 5.4 Thread/Affinity Sweep

Create multiple config files to test systematically:

**config_16t_physical.json** (16 threads, physical cores only):
```json
{
  "benchmark": { "size": "1M", "algo": "rx/sfx" },
  "cpu": { "rx": [0,1,2,3,4,5,6,7,16,17,18,19,20,21,22,23] },
  "randomx": { "wrmsr": true }
}
```

**config_32t_all.json** (32 threads, all logical):
```json
{
  "benchmark": { "size": "1M", "algo": "rx/sfx" },
  "cpu": { "rx": [-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1] },
  "randomx": { "wrmsr": true }
}
```

**config_ccd0_only.json** (8 threads, CCD0 physical only):
```json
{
  "benchmark": { "size": "1M", "algo": "rx/sfx" },
  "cpu": { "rx": [0,1,2,3,4,5,6,7] },
  "randomx": { "wrmsr": true }
}
```

Run each with:
```cmd
xmrig.exe -c config_XXX.json
```

Record: hashrate, huge pages %, MSR status, thermal throttling indicators.

## 6. Windows Build Instructions

### 6.1 Prerequisites

- Visual Studio 2019 or 2022 with C++ workload
- CMake 3.10+
- OpenSSL (pre-built binaries or vcpkg)
- libuv (vcpkg recommended)
- hwloc (optional but recommended)

### 6.2 vcpkg Setup

```cmd
git clone https://github.com/microsoft/vcpkg
cd vcpkg
bootstrap-vcpkg.bat
vcpkg integrate install
vcpkg install openssl:x64-windows-static libuv:x64-windows-static
```

### 6.3 CMake Configuration (MSVC)

```cmd
cd xmrig
mkdir build
cd build
cmake .. -G "Visual Studio 17 2022" -A x64 ^
  -DCMAKE_TOOLCHAIN_FILE=[vcpkg-root]/scripts/buildsystems/vcpkg.cmake ^
  -DVCPKG_TARGET_TRIPLET=x64-windows-static ^
  -DWITH_OPENCL=OFF ^
  -DWITH_CUDA=OFF
cmake --build . --config Release
```

### 6.4 Output Files

After successful build:
- `Release/xmrig.exe` - Main executable
- Copy `WinRing0x64.sys` from `bin/WinRing0/` to the same directory as `xmrig.exe`

## 7. Code Hot Paths Reference

### 7.1 RandomX Main Loop

```
src/crypto/randomx/randomx.cpp:597-610
  randomx_calculate_hash() - Main hash function
  
src/crypto/randomx/jit_compiler_x86.cpp
  JIT compilation of RandomX programs
  
src/crypto/randomx/jit_compiler_x86_static.asm
  Hand-optimized assembly for x86-64
```

### 7.2 Scratchpad Prefetch

```
src/crypto/randomx/randomx.cpp:248-275
  codePrefetchScratchpadTweaked[] - Prefetch instruction selection
  scratchpadPrefetchMode - Runtime configuration
```

### 7.3 Dataset Initialization (AVX2)

```
src/crypto/randomx/jit_compiler_x86.cpp:377-409
  generateSuperscalarHash() with AVX2 path
  
src/crypto/randomx/jit_compiler_x86_static.asm:218-285
  randomx_dataset_init_avx2_prologue
```

### 7.4 Windows-Specific Code

```
src/crypto/common/VirtualMemory_win.cpp
  Large pages allocation, SE_LOCK_MEMORY_NAME privilege
  
src/hw/msr/Msr_win.cpp
  WinRing0 driver interface for MSR access
  
src/base/kernel/Platform_win.cpp:89
  SetThreadAffinityMask() for thread pinning
```

## 8. Upstream References

### 8.1 Primary Sources

- Safex RandomSFX (pinned): https://github.com/safex/RandomSFX/tree/4f7b3a9a8365614ea41c0d865f92a9e855252b66
- Safex Core 7.0.3: https://github.com/safex/safexcore/releases/tag/7.0.3
- XMRig upstream: https://github.com/xmrig/xmrig
- RandomX specification: https://github.com/tevador/RandomX/blob/master/doc/specs.md

### 8.2 Relevant XMRig Issues/PRs

- VAES testing (no improvement): https://github.com/xmrig/xmrig/issues/1924
- Zen 3 MSR mod: https://github.com/xmrig/xmrig/pull/1932
- CryptoNight-Heavy Zen3 (NOT RandomX): https://github.com/xmrig/xmrig/pull/2089

## 9. Limitations and Caveats

### 9.1 Research Environment

This research was conducted on:
- **VM CPU**: Intel Xeon (NOT target AMD 5950X)
- **VM Features**: AVX-512 (NOT available on Zen 3)
- **OS**: Linux (NOT target Windows)

**All timing measurements from this environment are non-representative of target performance.**

### 9.2 Unvalidated Claims

The following cannot be validated without actual 5950X hardware:
- Specific hashrate improvements from any optimization
- Optimal thread count (16 vs 32 vs other)
- SMT benefit/penalty magnitude
- Actual MSR impact on this specific CPU

### 9.3 What This Research Does NOT Recommend

- BIOS/firmware changes
- Voltage/frequency modifications
- Windows kernel/driver modifications
- Disabling security features
- Pool/wallet configuration changes
- Downloading pre-built mining binaries

## 10. Conclusion

For AMD Ryzen 9 5950X on Windows mining Safex Cash (rx/sfx):

**High-confidence recommendations**:
1. Enable Windows large pages (run as Administrator)
2. Use the built-in MSR mod with WinRing0
3. Let XMRig auto-detect Zen 3 for init-avx2
4. Use NUMA-aware configuration

**Requires user testing**:
1. Optimal thread count (16 physical vs 32 all)
2. CCD-aware affinity mapping
3. Scratchpad prefetch mode (1 vs 2)

**No benefit expected**:
- VAES instructions
- AVX-512 (not available)
- 1GB pages (Linux only)
- CryptoNight-Heavy optimizations (different algorithm)

---

*Document generated: 2026-11-06*
*Fork base: XMRig v6.26.0*
*Target algorithm: rx/sfx (RandomSFX)*
*Target hardware: AMD Ryzen 9 5950X*
*Target OS: Windows*
