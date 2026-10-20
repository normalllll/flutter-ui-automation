#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <flutter_windows.h>
#include <algorithm>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {
struct Monitor {
  HMONITOR handle;
  MONITORINFO info;
};

BOOL CALLBACK CollectMonitor(HMONITOR handle, HDC, LPRECT, LPARAM data) {
  auto* monitors = reinterpret_cast<std::vector<Monitor>*>(data);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfo(handle, &info)) monitors->push_back({handle, info});
  return TRUE;
}

Monitor SelectMonitor() {
  std::vector<Monitor> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&monitors));
  wchar_t setting[32]{};
  GetEnvironmentVariableW(L"CAPTURE_LAB_PLACEMENT", setting, 32);
  const bool primary_only = std::wstring(setting) == L"primary";
  Monitor selected{MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY), {}};
  selected.info.cbSize = sizeof(selected.info);
  GetMonitorInfo(selected.handle, &selected.info);
  LONG largest_secondary = 0;
  for (const auto& monitor : monitors) {
    if (primary_only || (monitor.info.dwFlags & MONITORINFOF_PRIMARY)) continue;
    const auto& work = monitor.info.rcWork;
    const LONG area = (work.right - work.left) * (work.bottom - work.top);
    if (area > largest_secondary) {
      largest_secondary = area;
      selected = monitor;
    }
  }
  return selected;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  const auto monitor = SelectMonitor();
  const auto& work = monitor.info.rcWork;
  const double scale = FlutterDesktopGetDpiForMonitor(monitor.handle) / 96.0;
  const int margin = static_cast<int>(24 * scale);
  const int width = std::min(1280, std::max(1, static_cast<int>((work.right - work.left - margin * 2) / scale)));
  const int height = std::min(720, std::max(1, static_cast<int>((work.bottom - work.top - margin * 2) / scale)));
  Win32Window::Point origin(
    work.left + (work.right - work.left - static_cast<int>(width * scale)) / 2,
    work.top + (work.bottom - work.top - static_cast<int>(height * scale)) / 2);
  Win32Window::Size size(width, height);
  if (!window.Create(L"Flutter Capture Lab", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
