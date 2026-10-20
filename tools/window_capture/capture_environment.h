// Read-only capture environment diagnostics. No input or power-state changes.
#pragma once
#include <windows.h>
#include <dwmapi.h>
#include <sstream>
#include <iomanip>
#include <string>
#include <cstring>

class CaptureEnvironment {
 public:
  CaptureEnvironment() {
    WNDCLASSW wc{};
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"FlutterCaptureEnvironment";
    atom_ = RegisterClassW(&wc);
    if (!atom_) return;
    window_ = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, wc.hInstance, this);
    if (window_) notification_ = RegisterPowerSettingNotification(window_, &kSessionDisplay, 0);
    // The initial notification is asynchronous. Unknown remains unknown rather
    // than being inferred from visibility or the presence of a monitor.
    const ULONGLONG deadline = GetTickCount64() + 100;
    while (display_state_ < 0 && notification_ && GetTickCount64() < deadline) {
      Poll();
      Sleep(5);
    }
  }
  ~CaptureEnvironment() {
    if (notification_) UnregisterPowerSettingNotification(notification_);
    if (window_) DestroyWindow(window_);
    if (atom_) UnregisterClassW(L"FlutterCaptureEnvironment", GetModuleHandleW(nullptr));
  }
  void Poll() {
    MSG msg{};
    while (window_ && PeekMessageW(&msg, window_, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
  std::string Json(HWND target) {
    Poll();
    DWORD pid = 0;
    const DWORD target_thread = GetWindowThreadProcessId(target, &pid);
    DWORD own_session = 0, target_session = 0;
    const bool own_session_ok = ProcessIdToSessionId(GetCurrentProcessId(), &own_session) != FALSE;
    const bool target_session_ok = ProcessIdToSessionId(pid, &target_session) != FALSE;
    const std::string thread_desktop = DesktopName(GetThreadDesktop(GetCurrentThreadId()));
    const std::string target_desktop = DesktopName(GetThreadDesktop(target_thread));
    const HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    const DWORD input_error = input ? 0 : GetLastError();
    const std::string input_desktop = DesktopName(input);
    if (input) CloseDesktop(input);
    DWORD cloaked = 0, affinity = 0;
    const bool cloaked_ok = SUCCEEDED(DwmGetWindowAttribute(target, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)));
    const bool affinity_ok = GetWindowDisplayAffinity(target, &affinity) != FALSE;
    BOOL composed = FALSE;
    const bool composed_ok = SUCCEEDED(DwmIsCompositionEnabled(&composed));
    GUITHREADINFO gui{};
    gui.cbSize = sizeof(gui);
    const bool gui_ok = GetGUIThreadInfo(target_thread, &gui) != FALSE;
    const bool native_focus = gui_ok && (gui.hwndFocus == target || (gui.hwndFocus && IsChild(target, gui.hwndFocus)));
    LASTINPUTINFO last{};
    last.cbSize = sizeof(last);
    const bool idle_ok = GetLastInputInfo(&last) != FALSE;
    RECT client{};
    GetClientRect(target, &client);
    const char* display = display_state_ == 0 ? "off" : display_state_ == 1 ? "on" : display_state_ == 2 ? "dim" : "unknown";
    std::ostringstream out;
    out << "{\"displayState\":\"" << display << "\",\"displayStateObserved\":" << Bool(display_state_ >= 0)
      << ",\"helperDesktop\":" << std::quoted(thread_desktop)
      << ",\"targetDesktop\":" << std::quoted(target_desktop)
      << ",\"inputDesktop\":" << std::quoted(input_desktop)
      << ",\"inputDesktopError\":" << input_error
      << ",\"targetOnInputDesktop\":" << (input_desktop.empty() || target_desktop.empty() ? "null" : Bool(input_desktop == target_desktop))
      << ",\"helperSessionId\":" << (own_session_ok ? std::to_string(own_session) : "null")
      << ",\"targetSessionId\":" << (target_session_ok ? std::to_string(target_session) : "null")
      << ",\"activeConsoleSessionId\":" << WTSGetActiveConsoleSessionId()
      << ",\"dwmCompositionEnabled\":" << (composed_ok ? Bool(composed != FALSE) : "null")
      << ",\"windowCloaked\":" << (cloaked_ok ? std::to_string(cloaked) : "null")
      << ",\"displayAffinity\":" << (affinity_ok ? std::to_string(affinity) : "null")
      << ",\"visible\":" << Bool(IsWindowVisible(target) != FALSE)
      << ",\"minimized\":" << Bool(IsIconic(target) != FALSE)
      << ",\"isForeground\":" << Bool(GetForegroundWindow() == target)
      << ",\"hasNativeFocus\":" << (gui_ok ? Bool(native_focus) : "null")
      << ",\"lastInputAgeMs\":" << (idle_ok ? std::to_string(static_cast<DWORD>(GetTickCount() - last.dwTime)) : "null")
      << ",\"clientWidth\":" << client.right << ",\"clientHeight\":" << client.bottom << "}";
    return out.str();
  }
 private:
  static constexpr GUID kSessionDisplay{0x2b84c20e,0xad23,0x4ddf,{0x93,0xdb,0x05,0xff,0xbd,0x7e,0xfc,0xa5}};
  static const char* Bool(bool value) { return value ? "true" : "false"; }
  static std::string DesktopName(HDESK desktop) {
    if (!desktop) return {};
    wchar_t name[256]{};
    DWORD needed = 0;
    if (!GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &needed)) return {};
    const int count = WideCharToMultiByte(CP_UTF8, 0, name, -1, nullptr, 0, nullptr, nullptr);
    if (count <= 1) return {};
    std::string result(static_cast<size_t>(count), '\0');
    WideCharToMultiByte(CP_UTF8, 0, name, -1, result.data(), count, nullptr, nullptr);
    result.pop_back();
    return result;
  }
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
      auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<CaptureEnvironment*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self && message == WM_POWERBROADCAST && wparam == PBT_POWERSETTINGCHANGE && lparam) {
      const auto* setting = reinterpret_cast<const POWERBROADCAST_SETTING*>(lparam);
      if (IsEqualGUID(setting->PowerSetting, kSessionDisplay) && setting->DataLength == sizeof(DWORD)) {
        DWORD value = 0;
        memcpy(&value, setting->Data, sizeof(value));
        self->display_state_ = value <= 2 ? static_cast<int>(value) : -1;
      }
      return TRUE;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
  ATOM atom_ = 0;
  HWND window_ = nullptr;
  HPOWERNOTIFY notification_ = nullptr;
  int display_state_ = -1;
};
