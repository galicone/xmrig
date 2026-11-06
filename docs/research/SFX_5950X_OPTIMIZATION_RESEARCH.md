# RandomSFX Deep Code Optimization Research for AMD Ryzen 9 5950X (Windows)

## Document Status

**Fork**: galicone/xmrig  
**Base**: XMRig v6.26.0 (commit `b2ca7248`)  
**Research branch**: `cursor/sfx-5950x-research-b908`  
**Target OS**: Windows (research conducted on Linux VM)  
**Target Algorithm**: rx/sfx (RandomSFX)  
**Target Hardware**: AMD Ryzen 9 5950X (Zen 3)

**CRITICAL CONSTRAINTS**:
- All configs use `"wrmsr": false, "rdmsr": false` (safe defaults)
- **NO mining hot-path code changes** in this research
- No BIOS/OS/security/driver modifications recommended
- No performance percentages claimed without user measurement
- Windows execution NOT validated (Linux VM only)

---

## 1. Algorithm Verification

### 1.1 RandomSFX Salt - VERIFIED

**XMRig source** (`src/crypto/randomx/randomx.cpp` lines 111-114):
```cpp
RandomX_ConfigurationSafex::RandomX_ConfigurationSafex()
{
    ArgonSalt = "RandomSFX\x01";  // Safex salt
}
```

**Safex Core 7.0.3** pins RandomSFX to commit `4f7b3a9a8365614ea41c0d865f92a9e855252b66` in `external/RandomSFX/`.

**WARNING**: The public `safex/RandomSFX` master branch has drifted to standard Monero salt `RandomX\x03`. XMRig's rx/sfx uses the correct Safex salt `RandomSFX\x01`.

### 1.2 Benchmark Code Path - VERIFIED

**Algorithm ID** (`src/base/crypto/Algorithm.h` line 80):
```cpp
RX_SFX = 0x72151273,  // RANDOM_X family (0x72000000)
```

**CLI routing** (`src/core/config/ConfigTransform.cpp` line 324):
```cpp
case IConfig::AlgorithmKey: /* --algo */
    return set(doc, BenchConfig::kBenchmark, BenchConfig::kAlgo, arg);
```

**Family check** (`src/base/net/stratum/benchmark/BenchConfig.cpp` lines 68-72):
```cpp
auto f = m_algorithm.family();
if (!m_algorithm.isValid() || (f != Algorithm::RANDOM_X ...)) {
    m_algorithm = Algorithm::RX_0;  // Only fallback if NOT RANDOM_X family
}
```

Since `RX_SFX & 0xff000000 = 0x72000000 = RANDOM_X`, no fallback occurs.

### 1.3 Benchmark Output - VERIFIED

Three runs on research VM with identical parameters produced identical hash sums:
```
Run 1: hash sum = 648BA68C1B05A0B6
Run 2: hash sum = 648BA68C1B05A0B6
Run 3: hash sum = 648BA68C1B05A0B6
```

This proves implementation determinism but **NOT correctness vs. Safex reference** (see 1.4).

### 1.4 Known-Answer Validation - LIMITATION

`src/backend/common/benchmark/BenchState_test.h` contains reference hashes for:
- `Algorithm::RX_0` (rx/0)
- `Algorithm::RX_V2` (rx/2)
- `Algorithm::RX_WOW` (rx/wow)

**NO reference hashes for `RX_SFX`**. The hash sum is computed but NOT validated.

To fully validate rx/sfx correctness, one would need to:
1. Build the Safex-pinned RandomSFX reference (commit `4f7b3a9a8365614ea41c0d865f92a9e855252b66`)
2. Generate reference hashes with known inputs
3. Cross-check XMRig's output

The `safex/RandomSFX` master has drifted to Monero salt, so building from master would not produce valid reference hashes.

---

## 2. Memory Layout - CORRECTED TERMINOLOGY

### 2.1 Dataset Size

**Protocol constants** (`src/crypto/randomx/randomx.h` lines 73-74):
```cpp
DatasetBaseSize = 2147483648,  // 2048 MiB (2 GiB exactly)
DatasetExtraSize = 33554368,   // ~32 MiB + 64 bytes alignment
```

Total dataset: `2147483648 + 33554368 = 2181038016 bytes` (~2079.5 MiB)

**Allocated size** (from log): `2336 MB (2080+256)` means:
- 2080 MiB = Rounded dataset allocation
- 256 MiB = **Argon2 cache** (NOT scratchpad)

### 2.2 Scratchpad Size - CORRECTION

**256 MiB is Argon2 initialization cache, NOT scratchpad.**

Scratchpad is defined per-algorithm (`src/crypto/randomx/randomx.h` line 89):
```cpp
uint32_t ScratchpadL3_Size;  // Default: 2097152 bytes = 2 MiB
```

**Scratchpad is 2 MiB PER WORKER**, not 256 MiB total. Each mining thread allocates its own scratchpad.

### 2.3 Log Line Interpretation

```
randomx  allocated 2336 MB (2080+256) huge pages 0% 0/1168 +JIT
```
- `2080` = Dataset
- `256` = Argon2 cache (used during dataset initialization, then mostly idle)
- `0/1168` = Huge pages used/available
- `+JIT` = JIT compilation enabled

---

## 3. AMD Ryzen 9 5950X Architecture

### 3.1 Topology

| Component | Specification |
|-----------|--------------|
| Architecture | Zen 3 (Vermeer) |
| Physical Cores | 16 |
| Threads | 32 (SMT) |
| CCDs | 2 (8 cores each) |
| L3 Cache | 32 MiB per CCD (NOT shared between CCDs) |
| L2 Cache | 512 KiB per core |

### 3.2 NUMA vs CCD - CLARIFICATION

- 5950X has **two CCDs** with physically separate L3 caches
- **Desktop 5950X typically presents as ONE NUMA node** to the OS
- Windows NUMA APIs may NOT expose CCD-level topology
- `"numa": true` does NOT automatically allocate per-CCD

Use `xmrig.exe --export-topology topology.xml` to discover actual topology.

### 3.3 XMRig Zen3 Detection

**CPU Info** (`src/backend/cpu/interfaces/ICpuInfo.h` lines 50-56):
```cpp
enum Arch : uint32_t {
    ARCH_UNKNOWN,
    ARCH_ZEN,
    ARCH_ZEN_PLUS,
    ARCH_ZEN2,
    ARCH_ZEN3,  // Detected for 5950X
    ARCH_ZEN4,
    ARCH_ZEN5
};
```

**MSR Preset** (`src/backend/cpu/interfaces/ICpuInfo.h` line 62):
```cpp
MSR_MOD_RYZEN_19H,  // Used for Zen3
```

---

## 4. Zen3-Relevant Code Paths

### 4.1 JIT Compiler - Dataset Initialization

**File**: `src/crypto/randomx/jit_compiler_x86.cpp` lines 270-273
```cpp
case xmrig::ICpuInfo::ARCH_ZEN3:
    // AVX2 init is faster on Zen3
    initDatasetAVX2 = true;
    break;
```

This auto-enables AVX2 dataset initialization for Zen3. Affects **initialization speed** when seed changes (~every 2.8 days on mainnet), NOT steady-state hashrate.

### 4.2 Main Hash Loop

**Entry point**: `src/crypto/randomx/randomx.cpp` function `randomx_calculate_hash()`

**JIT code generation**: `src/crypto/randomx/jit_compiler_x86.cpp`

**Static assembly**: `src/crypto/randomx/jit_compiler_x86_static.asm`

The main hash loop executes JIT-compiled RandomX programs. Each program is:
- 256 instructions (`RANDOMX_PROGRAM_SIZE`)
- Executed 2048 iterations (`RANDOMX_PROGRAM_ITERATIONS`)
- 8 programs per hash (`RANDOMX_PROGRAM_COUNT`)

### 4.3 XOP Detection

**File**: `src/crypto/randomx/jit_compiler_x86.cpp` line 292
```cpp
hasXOP = xmrig::Cpu::info()->hasXOP();
```

XOP is AMD-specific. If available, uses `codeLoopLoadXOP` instead of `codeLoopLoad`.

### 4.4 MSR Preset Values (Zen3)

**File**: `src/hw/msr/MsrItem.cpp` (MSR_MOD_RYZEN_19H preset):
- `0xC0011020`: `0x0004480000000000`
- `0xC0011021`: `0x001c000200000040`
- `0xC0011022`: `0xc000000401570000`
- `0xC001102b`: `0x2000cc10`

These modify CPU prefetch behavior. **NOT ENABLED in default/safe configurations.**

---

## 5. Disproven/Irrelevant Optimization Paths

### 5.1 VAES - HISTORICAL CONTEXT

**Issue #1924 (2020)**: SChernykh tested two VAES implementations with no improvement:
> "AES in RandomX is limited by instruction latency and it stayed the same for VAES instructions."

**Current state**: XMRig v6.26.0 includes `aes_hash_vaes512.cpp` specifically for **Zen5** with AVX-512. This is **NOT applicable to Zen3** which lacks AVX-512.

The 2020 test result applies to the VAES implementations available then. New VAES-512 code exists but requires AVX-512.

### 5.2 AVX-512 - NOT AVAILABLE

Zen3 does NOT support AVX-512. All AVX-512 code paths are irrelevant.

### 5.3 1GB Huge Pages - LINUX ONLY

**File**: `src/crypto/common/VirtualMemory_win.cpp` lines 159-160
```cpp
bool xmrig::VirtualMemory::isOneGbPagesAvailable()
{
    return false;  // Always false on Windows
}
```

Windows only supports 2 MiB large pages via `MEM_LARGE_PAGES`.

### 5.4 CryptoNight Optimizations - DIFFERENT ALGORITHM

PR #2089 "7-8% speedup for Zen3" applies to **CryptoNight-Heavy**, NOT RandomX/RandomSFX.

---

## 6. Ranked Optimization Hypotheses

**IMPORTANT**: These are hypotheses requiring measurement on actual 5950X. No speedup percentages are claimed.

### 6.1 Windows Large Pages (2 MiB)

**Mechanism**: Reduces TLB misses for 2 GiB dataset access.

**Evidence**: Widespread user reports of improvement; standard recommendation.

**Risk**: Low (graceful fallback if unavailable).

**Requirement**: Administrator + "Lock pages in memory" privilege.

**Verification**: Look for `huge pages 100%` in log output.

### 6.2 Thread Count Optimization

**Mechanism**: Balance between parallelism and resource contention.

**Evidence**: RandomX benefits from one thread per 2 MiB L3 cache slice. 5950X has 64 MiB total L3 (32×2 MiB per CCD).

**Risk**: None (behavioral only).

**Testing**: Sweep 16, 24, 28, 30, 32 threads and measure.

### 6.3 MSR Modifications (Explicit Opt-In Only)

**Mechanism**: Modifies CPU prefetch/speculation behavior.

**Evidence**: User reports exist but vary. MSR effects are workload-dependent.

**Risk**: Medium - requires WinRing0 driver, modifies CPU registers.

**Requirement**: Administrator, WinRing0x64.sys, explicit configuration.

**NOT enabled in any default configuration in this research.**

### 6.4 Scratchpad Prefetch Mode

**Mechanism**: Different prefetch instructions (prefetcht0, prefetchnta, mov).

**Evidence**: Performance varies by CPU microarchitecture.

**Risk**: None.

**Testing**: Test modes 1 (prefetcht0) and 2 (prefetchnta).

---

## 7. What This Research Does NOT Provide

1. **No mining hot-path code changes** - This is research/documentation only
2. **No BIOS/firmware recommendations**
3. **No driver installation instructions**
4. **No security bypass recommendations**
5. **No pool/wallet configuration**
6. **No specific hashrate predictions**
7. **No Windows execution validation** (conducted on Linux VM)

---

## 8. Offline Benchmark Methodology

### 8.1 Process Lifecycle - IMPORTANT

**The benchmark does NOT auto-exit after completion.** It prints "press Ctrl+C to exit" and waits indefinitely.

Harness scripts must:
1. Monitor output for "benchmark finished" line
2. Terminate process by PID (NOT taskkill-by-name)
3. Implement timeout

### 8.2 Valid Benchmark Sizes

Per `src/base/net/stratum/benchmark/BenchConfig.cpp` lines 144-151:
- `250K` (250,000 hashes)
- `500K` (500,000 hashes)
- `1M` through `10M` (1-10 million hashes)

Other values are ignored/default to 250K.

### 8.3 PowerShell Harness

See `docs/research/Benchmark-SFX.ps1` for a harness that:
- Uses explicit config files (never user's config.json)
- Handles process lifecycle correctly
- Verifies algorithm on each run
- Verifies thread count on each run
- Randomizes test order
- Includes warmup run
- Reports median/spread statistics
- Keeps huge pages OFF by default

**Windows execution NOT validated.**

---

## 9. Build Instructions

### 9.1 Using This Fork

```cmd
git clone https://github.com/galicone/xmrig.git
cd xmrig
git checkout cursor/sfx-5950x-research-b908
```

This provides the research documentation and configs. The xmrig binary builds from upstream code.

### 9.2 Building from Upstream

For comparison against upstream:
```cmd
git clone https://github.com/xmrig/xmrig.git
cd xmrig
git checkout v6.26.0
```

### 9.3 Windows Build (MSVC)

```cmd
vcpkg install openssl:x64-windows-static libuv:x64-windows-static hwloc:x64-windows-static
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64 ^
  -DCMAKE_TOOLCHAIN_FILE=[vcpkg]/scripts/buildsystems/vcpkg.cmake ^
  -DVCPKG_TARGET_TRIPLET=x64-windows-static ^
  -DWITH_OPENCL=OFF -DWITH_CUDA=OFF
cmake --build . --config Release
```

---

## 10. Files Provided

| File | Purpose |
|------|---------|
| `docs/research/SFX_5950X_OPTIMIZATION_RESEARCH.md` | This document |
| `docs/research/configs/benchmark_base.json` | Safe baseline config (wrmsr/rdmsr false, huge-pages false) |
| `docs/research/Benchmark-SFX.ps1` | PowerShell harness (Windows execution not validated) |

---

## 11. Upstream References

- **XMRig**: https://github.com/xmrig/xmrig (v6.26.0 base)
- **Safex Core 7.0.3**: https://github.com/safex/safexcore/releases/tag/7.0.3
- **RandomX Spec**: https://github.com/tevador/RandomX/blob/master/doc/specs.md
- **VAES issue #1924**: https://github.com/xmrig/xmrig/issues/1924
- **Zen3 MSR PR #1932**: https://github.com/xmrig/xmrig/pull/1932

---

*Generated: 2026-11-06*  
*This document does NOT claim Windows validation or target performance improvements.*
