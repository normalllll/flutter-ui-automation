#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  lab_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "capture_lab/native",
      &flutter::StandardMethodCodec::GetInstance());
  lab_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "status") { result->NotImplemented(); return; }
    const HWND foreground = GetForegroundWindow();
    const HWND focus = GetFocus();
    POINT cursor{};
    GetCursorPos(&cursor);
    RECT bounds{};
    GetWindowRect(GetHandle(), &bounds);
    bool below_foreground = false;
    for (HWND above = GetWindow(GetHandle(), GW_HWNDPREV); above;
         above = GetWindow(above, GW_HWNDPREV)) {
      if (above == foreground) { below_foreground = true; break; }
    }
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    GetMonitorInfo(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST), &monitor);
    int monitor_count = 0;
    EnumDisplayMonitors(nullptr, nullptr,
      [](HMONITOR, HDC, LPRECT, LPARAM data) -> BOOL {
        ++*reinterpret_cast<int*>(data); return TRUE;
      }, reinterpret_cast<LPARAM>(&monitor_count));
    auto rect_map = [](const RECT& rect) {
      flutter::EncodableMap map;
      map[flutter::EncodableValue("left")] = flutter::EncodableValue(static_cast<int64_t>(rect.left));
      map[flutter::EncodableValue("top")] = flutter::EncodableValue(static_cast<int64_t>(rect.top));
      map[flutter::EncodableValue("right")] = flutter::EncodableValue(static_cast<int64_t>(rect.right));
      map[flutter::EncodableValue("bottom")] = flutter::EncodableValue(static_cast<int64_t>(rect.bottom));
      return flutter::EncodableValue(map);
    };
    flutter::EncodableMap status;
    status[flutter::EncodableValue("hwnd")] = flutter::EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(GetHandle())));
    status[flutter::EncodableValue("pid")] = flutter::EncodableValue(static_cast<int64_t>(GetCurrentProcessId()));
    status[flutter::EncodableValue("foregroundHwnd")] = flutter::EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(foreground)));
    status[flutter::EncodableValue("isForeground")] = flutter::EncodableValue(foreground == GetHandle());
    status[flutter::EncodableValue("hasNativeFocus")] = flutter::EncodableValue(focus == GetHandle() || (focus != nullptr && IsChild(GetHandle(), focus)));
    status[flutter::EncodableValue("activationCount")] = flutter::EncodableValue(activation_count_);
    status[flutter::EncodableValue("isBelowForeground")] = flutter::EncodableValue(below_foreground);
    status[flutter::EncodableValue("topmost")] = flutter::EncodableValue((GetWindowLongPtr(GetHandle(), GWL_EXSTYLE) & WS_EX_TOPMOST) != 0);
    status[flutter::EncodableValue("monitorPrimary")] = flutter::EncodableValue((monitor.dwFlags & MONITORINFOF_PRIMARY) != 0);
    status[flutter::EncodableValue("monitorCount")] = flutter::EncodableValue(monitor_count);
    status[flutter::EncodableValue("windowBounds")] = rect_map(bounds);
    status[flutter::EncodableValue("monitorWorkArea")] = rect_map(monitor.rcWork);
    status[flutter::EncodableValue("cursorX")] = flutter::EncodableValue(static_cast<int64_t>(cursor.x));
    status[flutter::EncodableValue("cursorY")] = flutter::EncodableValue(static_cast<int64_t>(cursor.y));
    status[flutter::EncodableValue("visible")] = flutter::EncodableValue(IsWindowVisible(GetHandle()) != FALSE);
    status[flutter::EncodableValue("minimized")] = flutter::EncodableValue(IsIconic(GetHandle()) != FALSE);
    result->Success(flutter::EncodableValue(status));
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    // The first raster frame may have completed before the host was visible.
    // Request presentation after show without activating the host window.
    flutter_controller_->ForceRedraw();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  lab_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE) {
    ++activation_count_;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
