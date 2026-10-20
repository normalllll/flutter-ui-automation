# Third-party notices

## Flutter project scaffolding

The fixture contains project scaffolding derived from Flutter's templates,
including the Windows runner/CMake project and Android host/resources under
`examples/capture_lab/`. Adaptations include the custom Windows capture and
non-activation integration and the Android fixture integration. The upstream
scaffolding retains the BSD license below; original project additions are
GPL-3.0-or-later as described in COPYRIGHT.

Source: [Flutter](https://github.com/flutter/flutter), reference SDK 3.47.6.
Upstream license: [Flutter LICENSE](https://github.com/flutter/flutter/blob/3.47.6/LICENSE).

```text
Copyright 2014 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## External dependencies

Flutter/Dart, Flutter SDK test/Driver packages, `flutter_lints`, Android/Windows
SDKs, Gradle and FFmpeg/FFprobe are external prerequisites or resolved build
dependencies. Their licenses remain with their respective upstream projects.
No copy of these SDKs, runtimes or FFmpeg binaries is distributed in this source
repository. Review the licenses of any binaries/dependencies you redistribute.
