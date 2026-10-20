"""Host process identity for owned supervisors; guards against PID reuse."""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import subprocess

def process_identity(pid):
    if not pid: return None
    if os.name == 'nt': return _windows_identity(pid)
    result = subprocess.run(['ps','-p',str(int(pid)),'-o','lstart=','-o','comm='], capture_output=True,text=True,timeout=5)
    value=result.stdout.strip()
    if result.returncode or not value: return None
    return {'pid':int(pid),'created':value[:24],'image':value[25:].strip()}

def _kernel32():
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetProcessTimes.argtypes = [wintypes.HANDLE, *[ctypes.POINTER(wintypes.FILETIME)] * 4]
    kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                                   wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    return kernel32


def _windows_identity(pid):
    """Image path and creation time of a running process, or None. Guards against PID reuse."""
    if not pid:
        return None
    kernel32 = _kernel32()
    handle = kernel32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return None
    try:
        code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value != 259:  # STILL_ACTIVE
            return None
        times = [wintypes.FILETIME() for _ in range(4)]
        if not kernel32.GetProcessTimes(handle, *map(ctypes.byref, times)):
            return None
        size = wintypes.DWORD(32768)
        image = ctypes.create_unicode_buffer(size.value)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(size)):
            return None
        created = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
        return {"pid": int(pid), "image": image.value, "created": created}
    finally:
        kernel32.CloseHandle(handle)


def same_process(recorded):
    current = process_identity(recorded.get("pid")) if recorded else None
    return bool(current and current["created"] == recorded.get("created")
                and Path(current["image"]).resolve() == Path(recorded.get("image", "")).resolve())
