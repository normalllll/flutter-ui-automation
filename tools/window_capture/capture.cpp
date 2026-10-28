// Standalone PrintWindow / WGC HWND capture. No Flutter or desktop input.
#include <windows.h>
#include <dwmapi.h>
#include <d3d11.h>
#include <wincodec.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <io.h>
#include <fcntl.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include "capture_environment.h"

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;
using Clock = std::chrono::steady_clock;

struct Frame {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> bytes;
};

// Optional test-app presentation fence. Coordinates are physical client pixels.
// We sample the actual HWND bitmap; no Flutter pixels are composited into it.
struct Probe {
  bool enabled = false;
  uint32_t token = 0;
  double x = 0, y = 0, width = 0, height = 0;

  bool Matches(const Frame& frame, HWND hwnd, bool wgc, bool exact_token = true) const {
    if (!enabled) return true;
    RECT capture_bounds{};
    if (wgc) {
      check_hresult(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS,
        &capture_bounds, sizeof(capture_bounds)));
      if (capture_bounds.right - capture_bounds.left != frame.width ||
          capture_bounds.bottom - capture_bounds.top != frame.height) {
        // Transient while the window resizes/settles DPI: reject this frame and
        // keep waiting instead of aborting the bounded presentation wait.
        return false;
      }
    } else if (!GetWindowRect(hwnd, &capture_bounds)) {
      throw std::runtime_error("Cannot locate capture bounds");
    }
    POINT origin{};
    if (!ClientToScreen(hwnd, &origin)) throw std::runtime_error("Cannot locate client origin");
    // 8x4 dot matrix, row-major from the top-left: 1010, 24-bit token, 0101.
    // Pink (1) and aqua (0) are calibrated from the header's own dots, so a
    // uniform colour shift does not reject a presented probe.
    const uint32_t word = (0xau << 28) | (token << 4) | 0x5;
    double samples[32][3];
    for (int bit = 0; bit < 32; ++bit) {
      const int column = bit % 8, row = bit / 8;
      const int cx = static_cast<int>(origin.x - capture_bounds.left + x + (column + .5) * width / 8);
      const int cy = static_cast<int>(origin.y - capture_bounds.top + y + (row + .5) * height / 4);
      if (cx < 1 || cy < 1 || cx >= frame.width - 1 || cy >= frame.height - 1) {
        return false;  // Geometry not settled yet; treat as an unpresented frame.
      }
      double sum[3] = {0, 0, 0};
      for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
          const size_t offset = (static_cast<size_t>(cy + dy) * frame.width + (cx + dx)) * 4;
          // BGRA to RGB.
          sum[0] += frame.bytes[offset + 2];
          sum[1] += frame.bytes[offset + 1];
          sum[2] += frame.bytes[offset];
        }
      }
      for (int c = 0; c < 3; ++c) samples[bit][c] = sum[c] / 9;
    }
    return ProbeBitsMatch(samples, word, exact_token);
  }

  // Nominal RGB: 1 = #FF8FB1 (pink), 0 = #38BDD8 (aqua). Must match the
  // fixture's LabProbe and tools/automation/lib/src/pixels.dart.
  static bool ProbeBitsMatch(const double samples[32][3], uint32_t word, bool exact_token) {
    static const double kOne[3] = {255, 143, 177}, kZero[3] = {56, 189, 216};
    auto distance = [](const double* a, const double* b) {
      double sum = 0;
      for (int c = 0; c < 3; ++c) sum += (a[c] - b[c]) * (a[c] - b[c]);
      return std::sqrt(sum);
    };
    if (distance(samples[0], samples[2]) > 40 || distance(samples[1], samples[3]) > 40) return false;
    double one[3], zero[3];
    for (int c = 0; c < 3; ++c) {
      one[c] = (samples[0][c] + samples[2][c]) / 2;
      zero[c] = (samples[1][c] + samples[3][c]) / 2;
      if (std::abs(one[c] - kOne[c]) > 64 || std::abs(zero[c] - kZero[c]) > 64) return false;
    }
    const double separation = distance(one, zero);
    if (separation < 90) return false;
    for (int bit = 0; bit < 32; ++bit) {
      const double to_one = distance(samples[bit], one), to_zero = distance(samples[bit], zero);
      if ((to_one < to_zero ? to_one : to_zero) > separation * .45) return false;
      // While recording, later screenshots may advance the token payload; keep
      // validating the header, trailer and palette without pinning the payload.
      if (!exact_token && bit >= 4 && bit < 28) continue;
      if ((to_one < to_zero) != (((word >> (31 - bit)) & 1) != 0)) return false;
    }
    return true;
  }
};


// Classify sampled client pixels for failure reporting only. This never relaxes
// the exact marker acceptance condition or modifies the captured image.
std::string FrameDiagnostics(const Frame& frame) {
  if (frame.bytes.empty()) return "{\"frameStatus\":\"no_frames\"}";
  int low[3] = {255,255,255}, high[3] = {0,0,0};
  for (int y = frame.height / 5; y < frame.height * 9 / 10; y += std::max(1, frame.height / 24)) {
    for (int x = frame.width / 10; x < frame.width * 9 / 10; x += std::max(1, frame.width / 32)) {
      const size_t offset = (static_cast<size_t>(y) * frame.width + x) * 4;
      for (int c = 0; c < 3; ++c) {
        const int value = frame.bytes[offset + (2 - c)];
        low[c] = std::min(low[c], value); high[c] = std::max(high[c], value);
      }
    }
  }
  const int range = std::max({high[0]-low[0], high[1]-low[1], high[2]-low[2]});
  std::ostringstream out;
  out << "{\"frameStatus\":\"" << (range == 0 ? "uniform_client" : "probe_mismatch")
    << "\",\"width\":" << frame.width << ",\"height\":" << frame.height
    << ",\"sampledRgbMin\":[" << low[0] << "," << low[1] << "," << low[2]
    << "],\"sampledRgbMax\":[" << high[0] << "," << high[1] << "," << high[2] << "]}";
  return out.str();
}

class WgcCapture {
 public:
  explicit WgcCapture(HWND hwnd) {
    if (!IsWindow(hwnd) || !IsWindowVisible(hwnd) || IsIconic(hwnd)) {
      throw std::runtime_error("Target must be an existing visible, non-minimized HWND");
    }
    if (!GraphicsCaptureSession::IsSupported()) throw std::runtime_error("WGC unsupported");
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      flags, nullptr, 0, D3D11_SDK_VERSION, device_.put(), nullptr, context_.put()));
    auto dxgi = device_.as<IDXGIDevice>();
    com_ptr<IInspectable> inspectable;
    check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
    auto winrt_device = inspectable.as<IDirect3DDevice>();
    auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    item_ = nullptr;
    check_hresult(interop->CreateForWindow(hwnd, guid_of<GraphicsCaptureItem>(), put_abi(item_)));
    size_ = item_.Size();
    pool_ = Direct3D11CaptureFramePool::CreateFreeThreaded(winrt_device,
      DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size_);
    session_ = pool_.CreateCaptureSession(item_);
    if (auto session2 = session_.try_as<IGraphicsCaptureSession2>()) {
      session2.IsCursorCaptureEnabled(false);
    }
    // Keep the OS capture border/consent policy intact. Never request global capture.
    session_.StartCapture();
  }
  ~WgcCapture() {
    // Destructors are noexcept; a failing Close during unwinding must not
    // terminate the helper before the original error reaches stderr.
    try {
      if (session_) session_.Close();
      if (pool_) pool_.Close();
    } catch (...) {
    }
  }

  bool Read(Frame& out) {
    auto frame = pool_.TryGetNextFrame();
    if (!frame) return false;
    const auto size = frame.ContentSize();
    if (size.Width != size_.Width || size.Height != size_.Height) {
      throw std::runtime_error("Target resized during capture; restart capture at its new size");
    }
    auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    com_ptr<ID3D11Texture2D> texture;
    check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    if (size.Width <= 0 || size.Height <= 0 ||
        static_cast<UINT>(size.Width) > desc.Width || static_cast<UINT>(size.Height) > desc.Height) {
      throw std::runtime_error("Invalid WGC frame bounds");
    }
    desc.BindFlags = 0;
    desc.MiscFlags = 0;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    com_ptr<ID3D11Texture2D> staging;
    check_hresult(device_->CreateTexture2D(&desc, nullptr, staging.put()));
    context_->CopyResource(staging.get(), texture.get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    check_hresult(context_->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped));
    out.width = size.Width;
    out.height = size.Height;
    const size_t stride = static_cast<size_t>(size.Width) * 4;
    out.bytes.resize(stride * size.Height);
    for (int y = 0; y < size.Height; ++y) {
      std::memcpy(out.bytes.data() + y * stride,
        static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch, stride);
    }
    context_->Unmap(staging.get(), 0);
    frame.Close();
    return true;
  }

 private:
  com_ptr<ID3D11Device> device_;
  com_ptr<ID3D11DeviceContext> context_;
  GraphicsCaptureItem item_{nullptr};
  Direct3D11CaptureFramePool pool_{nullptr};
  GraphicsCaptureSession session_{nullptr};
  winrt::Windows::Graphics::SizeInt32 size_{};
};

class PrintCapture {
 public:
  explicit PrintCapture(HWND hwnd) : hwnd_(hwnd) {
    if (!IsWindow(hwnd) || !IsWindowVisible(hwnd) || IsIconic(hwnd)) {
      throw std::runtime_error("Target must be an existing visible, non-minimized HWND");
    }
    RECT bounds{};
    if (!GetWindowRect(hwnd, &bounds)) throw std::runtime_error("GetWindowRect failed");
    width_ = bounds.right - bounds.left;
    height_ = bounds.bottom - bounds.top;
    if (width_ <= 0 || height_ <= 0) throw std::runtime_error("Empty window bounds");
    source_ = GetDC(hwnd);
    dc_ = CreateCompatibleDC(source_);
    // Use explicit device-compatible capture and readback. API success still
    // needs pixel validation: some targets return a blank or stale bitmap.
    bitmap_ = CreateCompatibleBitmap(source_, width_, height_);
    if (!source_ || !dc_ || !bitmap_) {
      Cleanup();
      throw std::runtime_error("Cannot create PrintWindow bitmap");
    }
    old_ = SelectObject(dc_, bitmap_);
  }
  ~PrintCapture() { Cleanup(); }
  bool Read(Frame& frame) {
    RECT bounds{};
    if (!IsWindow(hwnd_) || !IsWindowVisible(hwnd_) || IsIconic(hwnd_) ||
        !GetWindowRect(hwnd_, &bounds)) throw std::runtime_error("Target unavailable");
    if (bounds.right - bounds.left != width_ || bounds.bottom - bounds.top != height_) {
      throw std::runtime_error("Target resized during capture; restart at new size");
    }
    if (!PrintWindow(hwnd_, dc_, 0x00000002 /* PW_RENDERFULLCONTENT */)) {
      throw std::runtime_error("PrintWindow failed");
    }
    GdiFlush();
    frame.width = width_;
    frame.height = height_;
    frame.bytes.resize(static_cast<size_t>(width_) * height_ * 4);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width_;
    info.bmiHeader.biHeight = -height_;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    SelectObject(dc_, old_);
    const int rows = GetDIBits(dc_, bitmap_, 0, height_, frame.bytes.data(), &info, DIB_RGB_COLORS);
    SelectObject(dc_, bitmap_);
    if (rows != height_) throw std::runtime_error("GetDIBits did not return the complete frame");
    // GDI does not supply meaningful alpha for the window bitmap.
    for (size_t i = 3; i < frame.bytes.size(); i += 4) frame.bytes[i] = 255;
    return true;
  }
 private:
  void Cleanup() {
    if (dc_ && old_) SelectObject(dc_, old_);
    if (bitmap_) DeleteObject(bitmap_);
    if (dc_) DeleteDC(dc_);
    if (source_) ReleaseDC(hwnd_, source_);
    bitmap_ = nullptr; dc_ = nullptr; source_ = nullptr; old_ = nullptr;
  }
  HWND hwnd_;
  HDC source_ = nullptr;
  HDC dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ old_ = nullptr;
  int width_ = 0;
  int height_ = 0;
};

void SavePng(const Frame& frame, const std::wstring& path) {
  com_ptr<IWICImagingFactory> factory;
  check_hresult(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
    __uuidof(IWICImagingFactory), factory.put_void()));
  com_ptr<IWICStream> stream;
  check_hresult(factory->CreateStream(stream.put()));
  check_hresult(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE));
  com_ptr<IWICBitmapEncoder> encoder;
  check_hresult(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.put()));
  check_hresult(encoder->Initialize(stream.get(), WICBitmapEncoderNoCache));
  com_ptr<IWICBitmapFrameEncode> bitmap;
  check_hresult(encoder->CreateNewFrame(bitmap.put(), nullptr));
  check_hresult(bitmap->Initialize(nullptr));
  check_hresult(bitmap->SetSize(frame.width, frame.height));
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  check_hresult(bitmap->SetPixelFormat(&format));
  if (format != GUID_WICPixelFormat32bppBGRA) throw std::runtime_error("Unsupported PNG pixel format");
  check_hresult(bitmap->WritePixels(frame.height, frame.width * 4,
    static_cast<UINT>(frame.bytes.size()), const_cast<BYTE*>(frame.bytes.data())));
  check_hresult(bitmap->Commit());
  check_hresult(encoder->Commit());
}

int wmain(int argc, wchar_t** argv) {
  try {
    init_apartment(apartment_type::multi_threaded);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (argc == 2 && std::wstring(argv[1]) == L"--help") {
      std::cout << "window_capture --hwnd DECIMAL [--backend printwindow|wgc] [--png FILE | --stream --seconds N --fps N] [--probe TOKEN X Y WIDTH HEIGHT] [--diagnostic-png FILE]\n"
        "Captures one HWND. Stream: BGRA on stdout; JSON metadata on stderr. Use --environment for read-only status without capture.\n";
      return 0;
    }
    HWND hwnd = nullptr;
    std::wstring png;
    std::wstring diagnostic_png;
    bool stream = false;
    bool environment_only = false;
    std::wstring backend = L"printwindow";
    int fps = 12;
    int seconds = 8;
    Probe probe;
    for (int i = 1; i < argc; ++i) {
      std::wstring arg = argv[i];
      auto next = [&]() -> std::wstring {
        if (++i >= argc) throw std::runtime_error("Missing argument value");
        return argv[i];
      };
      if (arg == L"--hwnd") hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(std::stoll(next())));
      else if (arg == L"--png") png = next();
      else if (arg == L"--diagnostic-png") diagnostic_png = next();
      else if (arg == L"--backend") backend = next();
      else if (arg == L"--stream") stream = true;
      else if (arg == L"--environment") environment_only = true;
      else if (arg == L"--fps") fps = std::stoi(next());
      else if (arg == L"--seconds") seconds = std::stoi(next());
      else if (arg == L"--probe") {
        probe.enabled = true;
        probe.token = static_cast<uint32_t>(std::stoul(next()));
        probe.x = std::stod(next()); probe.y = std::stod(next());
        probe.width = std::stod(next()); probe.height = std::stod(next());
        if (probe.token > 0xffffff || probe.x < 0 || probe.y < 0 ||
            probe.width <= 0 || probe.height <= 0) throw std::runtime_error("Invalid probe");
      }
      else throw std::runtime_error("Unknown argument");
    }
    if (environment_only) {
      if (!hwnd || !IsWindow(hwnd) || stream || !png.empty()) throw std::runtime_error("--environment requires one existing HWND and no capture output");
      CaptureEnvironment environment;
      std::cout << environment.Json(hwnd) << std::endl;
      return 0;
    }
    if (!hwnd || (stream == !png.empty()) || fps < 1 || fps > 60 || seconds < 1 || seconds > 120) {
      throw std::runtime_error("Specify HWND and exactly one of --png/--stream; fps 1..60, seconds 1..120");
    }
    if (backend != L"printwindow" && backend != L"wgc") throw std::runtime_error("Unknown backend");
    CaptureEnvironment environment;
    std::unique_ptr<WgcCapture> wgc;
    std::unique_ptr<PrintCapture> print;
    if (backend == L"wgc") wgc = std::make_unique<WgcCapture>(hwnd);
    else print = std::make_unique<PrintCapture>(hwnd);
    auto read = [&](Frame& frame) { return wgc ? wgc->Read(frame) : print->Read(frame); };
    Frame latest;
    const auto waiting = Clock::now();
    int attempts = 0;
    int rejected_frames = 0;
    int candidate_frames = 0;
    auto deadline = Clock::now() + std::chrono::seconds(10);
    while (true) {
      environment.Poll();
      ++attempts;
      if (read(latest)) {
        ++candidate_frames;
        if (probe.Matches(latest, hwnd, wgc != nullptr)) break;
        ++rejected_frames;
      }
      if (Clock::now() > deadline) {
        if (!diagnostic_png.empty() && !latest.bytes.empty()) SavePng(latest, diagnostic_png);
        std::cerr << "{\"error\":\"capture_not_presented\",\"message\":\"Timed out waiting for the requested presented frame (blank/stale/missing probe)\""
          << ",\"probeMatched\":false,\"expectedProbeToken\":" << probe.token
          << ",\"candidateFrames\":" << candidate_frames << ",\"rejectedFrames\":" << rejected_frames
          << ",\"diagnosticOnly\":true,\"diagnosticPath\":" << std::quoted(winrt::to_string(diagnostic_png))
          << ",\"frame\":" << FrameDiagnostics(latest) << ",\"environment\":" << environment.Json(hwnd) << "}" << std::endl;
        return 1;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    const auto wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - waiting).count();
    RECT bounds{};
    if (wgc) check_hresult(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &bounds, sizeof(bounds)));
    else if (!GetWindowRect(hwnd, &bounds)) throw std::runtime_error("Cannot locate window");
    POINT client{};
    if (!ClientToScreen(hwnd, &client)) throw std::runtime_error("Cannot locate client");
    // Instrumentation pixels in the saved image, so reviewers can exclude them.
    std::ostringstream probe_rect;
    if (probe.enabled) {
      probe_rect << ",\"probeRect\":{\"x\":" << static_cast<int>(client.x - bounds.left + probe.x)
        << ",\"y\":" << static_cast<int>(client.y - bounds.top + probe.y)
        << ",\"width\":" << static_cast<int>(probe.width + .5)
        << ",\"height\":" << static_cast<int>(probe.height + .5) << "}";
    }
    if (!stream) {
      SavePng(latest, png);
      std::cout << "{\"width\":" << latest.width << ",\"height\":" << latest.height
        << ",\"backend\":\"" << (wgc ? "wgc" : "printwindow") << "\""
        << ",\"probeMatched\":" << (probe.enabled ? "true" : "false")
        << ",\"firstFrameAttempts\":" << attempts << ",\"firstFrameWaitMs\":" << wait_ms
        << ",\"rejectedFrames\":" << rejected_frames
        << ",\"clientX\":" << client.x - bounds.left << ",\"clientY\":" << client.y - bounds.top
        << ",\"isForeground\":" << (GetForegroundWindow() == hwnd ? "true" : "false")
        << probe_rect.str()
        << ",\"environment\":" << environment.Json(hwnd) << "}" << std::endl;
      return 0;
    }
    _setmode(_fileno(stdout), _O_BINARY);
    std::cerr << "{\"ready\":true,\"width\":" << latest.width << ",\"height\":"
      << latest.height << ",\"fps\":" << fps << ",\"backend\":\"" << (wgc ? "wgc" : "printwindow") << "\""
      << ",\"probeMatched\":" << (probe.enabled ? "true" : "false")
      << ",\"firstFrameAttempts\":" << attempts << ",\"firstFrameWaitMs\":" << wait_ms
      << ",\"rejectedFrames\":" << rejected_frames
      << ",\"clientX\":" << client.x - bounds.left << ",\"clientY\":" << client.y - bounds.top
      << probe_rect.str()
      << ",\"environment\":" << environment.Json(hwnd) << "}" << std::endl;
    // The pacing clock starts after the first frame reaches the consumer. The
    // encoder starts only after the ready line, so starting earlier would make
    // the first frames burst out late and compress the video timeline.
    Clock::time_point start{};
    const long long interval_us = 1000000LL / fps;
    int foreground_samples = 0;
    int fresh_frames = 1;
    int late_frames = 0;
    long long max_lag_us = 0;
    for (int n = 0; n < seconds * fps; ++n) {
      environment.Poll();
      if (n > 0) {
        const auto lag = std::chrono::duration_cast<std::chrono::microseconds>(
          Clock::now() - (start + std::chrono::microseconds(n * 1000000LL / fps))).count();
        max_lag_us = std::max(max_lag_us, static_cast<long long>(lag));
        if (lag > interval_us / 2) ++late_frames;
      }
      if (!IsWindow(hwnd) || IsIconic(hwnd) || !IsWindowVisible(hwnd)) {
        throw std::runtime_error("Target closed, minimized or hidden during recording");
      }
      Frame current;
      // Drain queued frames, then repeat the latest valid frame for a CFR stream.
      // WGC delivers a frame only when DWM presents new content. PrintWindow
      // always returns a bitmap, so only changed pixels count as fresh.
      if (wgc) {
        while (read(current)) { latest = std::move(current); ++fresh_frames; }
      } else {
        read(current);
        if (current.bytes != latest.bytes) ++fresh_frames;
        latest = std::move(current);
      }
      // Later screenshots may advance the payload. Keep validating the visible
      // probe's framing/palette without rejecting legitimate token changes.
      if (!probe.Matches(latest, hwnd, wgc != nullptr, false)) {
        throw std::runtime_error("Presented content lost its capture probe during recording");
      }
      if (GetForegroundWindow() == hwnd) ++foreground_samples;
      std::cout.write(reinterpret_cast<const char*>(latest.bytes.data()), latest.bytes.size());
      if (!std::cout.good()) throw std::runtime_error("Video consumer closed its pipe");
      if (n == 0) {
        std::cout.flush();
        start = Clock::now();
      }
      std::this_thread::sleep_until(start + std::chrono::microseconds((n + 1) * 1000000LL / fps));
    }
    std::cout.flush();
    const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
    std::cerr << "{\"complete\":true,\"frames\":" << seconds * fps
      << ",\"freshFrames\":" << fresh_frames
      << ",\"freshFrameMeaning\":\"" << (wgc ? "wgc_presented_frames" : "printwindow_changed_frames") << "\""
      << ",\"elapsedMs\":" << elapsed_ms << ",\"expectedMs\":" << seconds * 1000
      << ",\"lateFrames\":" << late_frames << ",\"maxLagMs\":" << max_lag_us / 1000
      << ",\"foregroundSamples\":" << foreground_samples << "}\n";
    return 0;
  } catch (const hresult_error& error) {
    std::cerr << "WGC error: " << to_string(error.message()) << "\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
  }
  return 1;
}
