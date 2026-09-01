/* XMRig
 * Copyright (c) 2018-2020 tevador     <tevador@gmail.com>
 * Copyright (c) 2018-2021 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2021 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with this program. If not, see <http://www.gnu.org/licenses/>.
 */


#include <winsock2.h>
#include <windows.h>
#include <ntsecapi.h>
#include <tchar.h>


#include <cstdint>
#include <map>
#include <mutex>
#include <utility>


#include "crypto/common/VirtualMemory.h"
#include "base/io/log/Log.h"
#include "crypto/common/portable/mm_malloc.h"


#ifndef MEM_REPLACE_PLACEHOLDER
#   define MEM_REPLACE_PLACEHOLDER  0x00004000
#endif

#ifndef MEM_RESERVE_PLACEHOLDER
#   define MEM_RESERVE_PLACEHOLDER  0x00040000
#endif

#ifndef MEM_PRESERVE_PLACEHOLDER
#   define MEM_PRESERVE_PLACEHOLDER 0x00000002
#endif


#ifdef XMRIG_SECURE_JIT
#   define SECURE_PAGE_EXECUTE_READWRITE PAGE_READWRITE
#else
#   define SECURE_PAGE_EXECUTE_READWRITE PAGE_EXECUTE_READWRITE
#endif


namespace xmrig {


static bool hugepagesAvailable = false;


/*****************************************************************
SetLockPagesPrivilege: a function to obtain or
release the privilege of locking physical pages.

Inputs:

HANDLE hProcess: Handle for the process for which the
privilege is needed

BOOL bEnable: Enable (TRUE) or disable?

Return value: TRUE indicates success, FALSE failure.

*****************************************************************/
/**
 * AWE Example: https://msdn.microsoft.com/en-us/library/windows/desktop/aa366531(v=vs.85).aspx
 * Creating a File Mapping Using Large Pages: https://msdn.microsoft.com/en-us/library/aa366543(VS.85).aspx
 */
static BOOL SetLockPagesPrivilege() {
    HANDLE token;

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) {
        return FALSE;
    }

    TOKEN_PRIVILEGES tp;
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;

    if (!LookupPrivilegeValue(nullptr, SE_LOCK_MEMORY_NAME, &(tp.Privileges[0].Luid))) {
        return FALSE;
    }

    BOOL rc = AdjustTokenPrivileges(token, FALSE, (PTOKEN_PRIVILEGES) &tp, 0, nullptr, nullptr);
    if (!rc || GetLastError() != ERROR_SUCCESS) {
        return FALSE;
    }

    CloseHandle(token);

    return TRUE;
}


static LSA_UNICODE_STRING StringToLsaUnicodeString(LPCTSTR string) {
    LSA_UNICODE_STRING lsaString;

    const auto dwLen = (DWORD) wcslen(string);
    lsaString.Buffer = (LPWSTR) string;
    lsaString.Length = (USHORT)((dwLen) * sizeof(WCHAR));
    lsaString.MaximumLength = (USHORT)((dwLen + 1) * sizeof(WCHAR));
    return lsaString;
}


static BOOL ObtainLockPagesPrivilege() {
    HANDLE token;
    PTOKEN_USER user = nullptr;

    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        DWORD size = 0;

        GetTokenInformation(token, TokenUser, nullptr, 0, &size);
        if (size) {
            user = (PTOKEN_USER) LocalAlloc(LPTR, size);
        }

        GetTokenInformation(token, TokenUser, user, size, &size);
        CloseHandle(token);
    }

    if (!user) {
        return FALSE;
    }

    LSA_HANDLE handle;
    LSA_OBJECT_ATTRIBUTES attributes;
    ZeroMemory(&attributes, sizeof(attributes));

    BOOL result = FALSE;
    if (LsaOpenPolicy(nullptr, &attributes, POLICY_ALL_ACCESS, &handle) == 0) {
        LSA_UNICODE_STRING str = StringToLsaUnicodeString(_T(SE_LOCK_MEMORY_NAME));

        if (LsaAddAccountRights(handle, user->User.Sid, &str, 1) == 0) {
            LOG_NOTICE("Huge pages support was successfully enabled, but reboot required to use it");
            result = TRUE;
        }

        LsaClose(handle);
    }

    LocalFree(user);
    return result;
}


static BOOL TrySetLockPagesPrivilege() {
    if (SetLockPagesPrivilege()) {
        return TRUE;
    }

    return ObtainLockPagesPrivilege() && SetLockPagesPrivilege();
}


// VirtualAlloc2 is loaded dynamically so the binary still runs on Windows
// versions that lack it (pre-1803); those fall back to all-or-nothing allocation.
typedef PVOID (WINAPI *VirtualAlloc2_t)(HANDLE, PVOID, SIZE_T, ULONG, ULONG, PVOID, ULONG);

static VirtualAlloc2_t resolveVirtualAlloc2()
{
    static VirtualAlloc2_t func = []() -> VirtualAlloc2_t {
        HMODULE module = GetModuleHandleA("kernelbase.dll");

        return module ? reinterpret_cast<VirtualAlloc2_t>(GetProcAddress(module, "VirtualAlloc2")) : nullptr;
    }();

    return func;
}


// Regions assembled from individual placeholder-backed chunks must be released
// chunk by chunk, so remember their layout.
static std::mutex chunkedRegionsMutex;
static std::map<void *, std::pair<size_t, size_t> > chunkedRegions; // base -> {chunk size, chunk count}


static void releaseChunks(uint8_t *base, size_t chunkSize, size_t count)
{
    for (size_t i = 0; i < count; ++i) {
        VirtualFree(base + i * chunkSize, 0, MEM_RELEASE);
    }
}


// Windows grants large pages only when it can find free contiguous physical memory,
// so a single all-or-nothing VirtualAlloc of the whole region (2336 MB for the RandomX
// dataset) usually fails once memory is fragmented. Instead, reserve a placeholder
// region and replace it chunk by chunk, keeping every large-page chunk the kernel
// gives us and falling back to normal pages for the rest.
static void *allocateLargePagesBestEffort(size_t size, size_t *hugePagesCount)
{
    const size_t chunkSize = GetLargePageMinimum();
    if (chunkSize == 0) {
        return nullptr;
    }

    size = xmrig::VirtualMemory::align(size, chunkSize);

    void *mem = VirtualAlloc(nullptr, size, MEM_COMMIT | MEM_RESERVE | MEM_LARGE_PAGES, PAGE_READWRITE);
    if (mem) {
        if (hugePagesCount) {
            *hugePagesCount = size / chunkSize;
        }

        return mem;
    }

    auto virtualAlloc2 = resolveVirtualAlloc2();
    if (!virtualAlloc2) {
        return nullptr;
    }

    // Over-reserve so a large-page aligned sub-region always exists, then carve off
    // the unaligned head and tail placeholders and release them.
    const size_t reserveSize = size + chunkSize;
    auto base = static_cast<uint8_t *>(virtualAlloc2(GetCurrentProcess(), nullptr, reserveSize, MEM_RESERVE | MEM_RESERVE_PLACEHOLDER, PAGE_NOACCESS, nullptr, 0));
    if (!base) {
        return nullptr;
    }

    auto aligned = reinterpret_cast<uint8_t *>((reinterpret_cast<uintptr_t>(base) + chunkSize - 1) & ~(chunkSize - 1));

    if (aligned > base) {
        if (!VirtualFree(base, aligned - base, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER)) {
            VirtualFree(base, 0, MEM_RELEASE);

            return nullptr;
        }

        VirtualFree(base, 0, MEM_RELEASE);
    }

    if (const size_t tail = (base + reserveSize) - (aligned + size)) {
        if (!VirtualFree(aligned, size, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER)) {
            VirtualFree(aligned, 0, MEM_RELEASE);

            return nullptr;
        }

        VirtualFree(aligned + size, 0, MEM_RELEASE);
    }

    const size_t count          = size / chunkSize;
    size_t hugeCount            = 0;
    size_t consecutiveFailures  = 0;

    // Each rejected large-page request is slow (the kernel scans for contiguous
    // memory), so once a long run of chunks fails assume physical memory is too
    // fragmented and stop asking; a success resets the counter.
    constexpr size_t maxConsecutiveFailures = 8;

    for (size_t i = 0; i < count; ++i) {
        uint8_t *addr = aligned + i * chunkSize;

        // Split the current chunk off the remaining placeholder (except the last one,
        // which already has the right size).
        if (i + 1 < count && !VirtualFree(addr, chunkSize, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER)) {
            releaseChunks(aligned, chunkSize, i);
            VirtualFree(addr, 0, MEM_RELEASE);

            return nullptr;
        }

        void *p = nullptr;

        if (consecutiveFailures < maxConsecutiveFailures) {
            p = virtualAlloc2(GetCurrentProcess(), addr, chunkSize, MEM_RESERVE | MEM_COMMIT | MEM_REPLACE_PLACEHOLDER | MEM_LARGE_PAGES, PAGE_READWRITE, nullptr, 0);
        }

        if (p) {
            ++hugeCount;
            consecutiveFailures = 0;
        }
        else {
            ++consecutiveFailures;

            if (!virtualAlloc2(GetCurrentProcess(), addr, chunkSize, MEM_RESERVE | MEM_COMMIT | MEM_REPLACE_PLACEHOLDER, PAGE_READWRITE, nullptr, 0)) {
                releaseChunks(aligned, chunkSize, i);
                VirtualFree(addr, 0, MEM_RELEASE);

                if (i + 1 < count) {
                    VirtualFree(addr + chunkSize, 0, MEM_RELEASE);
                }

                return nullptr;
            }
        }
    }

    // No large pages at all: release the region so the caller uses the regular
    // allocation path and huge pages are correctly reported as unavailable.
    if (hugeCount == 0) {
        releaseChunks(aligned, chunkSize, count);

        return nullptr;
    }

    {
        std::lock_guard<std::mutex> lock(chunkedRegionsMutex);
        chunkedRegions.insert({ aligned, { chunkSize, count } });
    }

    if (hugePagesCount) {
        *hugePagesCount = hugeCount;
    }

    return aligned;
}


} // namespace xmrig


bool xmrig::VirtualMemory::isHugepagesAvailable()
{
    return hugepagesAvailable;
}


bool xmrig::VirtualMemory::isOneGbPagesAvailable()
{
    return false;
}


bool xmrig::VirtualMemory::protectRW(void *p, size_t size)
{
    DWORD oldProtect;

    return VirtualProtect(p, size, PAGE_READWRITE, &oldProtect) != 0;
}


bool xmrig::VirtualMemory::protectRWX(void *p, size_t size)
{
    DWORD oldProtect;

    return VirtualProtect(p, size, PAGE_EXECUTE_READWRITE, &oldProtect) != 0;
}


bool xmrig::VirtualMemory::protectRX(void *p, size_t size)
{
    DWORD oldProtect;

    return VirtualProtect(p, size, PAGE_EXECUTE_READ, &oldProtect) != 0;
}


void *xmrig::VirtualMemory::allocateExecutableMemory(size_t size, bool hugePages)
{
    void* result = nullptr;

    if (hugePages) {
        result = VirtualAlloc(nullptr, align(size), MEM_COMMIT | MEM_RESERVE | MEM_LARGE_PAGES, SECURE_PAGE_EXECUTE_READWRITE);
    }

    if (!result) {
        result = VirtualAlloc(nullptr, size, MEM_COMMIT | MEM_RESERVE, SECURE_PAGE_EXECUTE_READWRITE);
    }

    return result;
}


void *xmrig::VirtualMemory::allocateLargePagesMemory(size_t size)
{
    return allocateLargePagesBestEffort(size, nullptr);
}


void *xmrig::VirtualMemory::allocateOneGbPagesMemory(size_t)
{
    return nullptr;
}


void xmrig::VirtualMemory::flushInstructionCache(void *p, size_t size)
{
    ::FlushInstructionCache(GetCurrentProcess(), p, size);
}


void xmrig::VirtualMemory::freeLargePagesMemory(void *p, size_t)
{
    {
        std::lock_guard<std::mutex> lock(chunkedRegionsMutex);

        const auto it = chunkedRegions.find(p);
        if (it != chunkedRegions.end()) {
            releaseChunks(static_cast<uint8_t *>(p), it->second.first, it->second.second);
            chunkedRegions.erase(it);

            return;
        }
    }

    VirtualFree(p, 0, MEM_RELEASE);
}


void xmrig::VirtualMemory::osInit(size_t hugePageSize)
{
    if (hugePageSize) {
        hugepagesAvailable = TrySetLockPagesPrivilege();
    }
}


bool xmrig::VirtualMemory::allocateLargePagesMemory()
{
    m_scratchpad = static_cast<uint8_t*>(allocateLargePagesBestEffort(m_size, &m_hugePagesCount));
    if (m_scratchpad) {
        m_flags.set(FLAG_HUGEPAGES, true);

        return true;
    }

    return false;
}

bool xmrig::VirtualMemory::allocateOneGbPagesMemory()
{
    m_scratchpad = nullptr;
    return false;
}


bool xmrig::VirtualMemory::adviseLargePages(void *p, size_t size)
{
    return false;
}


void xmrig::VirtualMemory::freeLargePagesMemory()
{
    freeLargePagesMemory(m_scratchpad, m_size);
}
