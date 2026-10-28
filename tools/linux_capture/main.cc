#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <png.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

static bool x_error = false;
static int on_error(Display*, XErrorEvent*) { x_error = true; return 0; }
static unsigned char component(unsigned long pixel, unsigned long mask) {
  if (!mask) return 0;
  while (!(mask & 1)) { mask >>= 1; pixel >>= 1; }
  return static_cast<unsigned char>((pixel & mask) * 255 / mask);
}
int main(int argc, char** argv) {
  unsigned long window = 0, pid = 0;
  const char* output = nullptr;
  for (int i = 1; i + 1 < argc; i += 2) {
    if (!std::strcmp(argv[i], "--window")) window = std::strtoul(argv[i + 1], nullptr, 10);
    else if (!std::strcmp(argv[i], "--pid")) pid = std::strtoul(argv[i + 1], nullptr, 10);
    else if (!std::strcmp(argv[i], "--output")) output = argv[i + 1];
    else return 2;
  }
  if (!window || !pid || !output) return 2;
  Display* display = XOpenDisplay(nullptr);
  if (!display) { std::cerr << "X11 display unavailable\n"; return 1; }
  XSetErrorHandler(on_error);
  Atom type = None; int format = 0; unsigned long count = 0, remaining = 0;
  unsigned char* value = nullptr;
  XGetWindowProperty(display, window, XInternAtom(display, "_NET_WM_PID", False),
                     0, 1, False, AnyPropertyType, &type, &format, &count, &remaining, &value);
  const bool owned = !x_error && value && format == 32 && count == 1 &&
                     *reinterpret_cast<unsigned long*>(value) == pid;
  if (value) XFree(value);
  XWindowAttributes attributes{};
  if (!owned || !XGetWindowAttributes(display, window, &attributes) ||
      attributes.map_state != IsViewable || attributes.width <= 0 || attributes.height <= 0) {
    std::cerr << "Target window is unavailable or belongs to another process\n";
    XCloseDisplay(display); return 1;
  }
  if (static_cast<unsigned long long>(attributes.width) * attributes.height > 64000000) {
    std::cerr << "Window dimensions exceed capture bounds\n"; XCloseDisplay(display); return 1;
  }
  XImage* image = XGetImage(display, window, 0, 0, attributes.width, attributes.height, AllPlanes, ZPixmap);
  XSync(display, False);
  if (!image || x_error) { std::cerr << "X11 capture failed\n"; XCloseDisplay(display); return 1; }
  std::vector<unsigned char> pixels(attributes.width * attributes.height * 3);
  for (int y = 0; y < attributes.height; ++y) for (int x = 0; x < attributes.width; ++x) {
    const auto pixel = XGetPixel(image, x, y);
    const size_t offset = (y * attributes.width + x) * 3;
    pixels[offset] = component(pixel, image->red_mask);
    pixels[offset + 1] = component(pixel, image->green_mask);
    pixels[offset + 2] = component(pixel, image->blue_mask);
  }
  png_image png{}; png.version = PNG_IMAGE_VERSION;
  png.width = attributes.width; png.height = attributes.height; png.format = PNG_FORMAT_RGB;
  const bool saved = png_image_write_to_file(&png, output, 0, pixels.data(), 0, nullptr);
  XDestroyImage(image); XCloseDisplay(display);
  if (!saved) { std::cerr << png.message << '\n'; return 1; }
  std::cout << "{\"source\":\"X11 window\",\"windowId\":" << window
            << ",\"pid\":" << pid << ",\"width\":" << attributes.width
            << ",\"height\":" << attributes.height << "}\n";
  return 0;
}
