# DahliaAEC3

`DahliaAEC3.xcframework` is an arm64 macOS static library containing only the
WebRTC Audio Processing Module and Dahlia's small C bridge. It does not contain
WebRTC networking, video, codecs, or audio-device capture.

## Pinned upstream sources

- `webrtc-audio-processing` 2.1
  - Source: <https://gstreamer.freedesktop.org/data/src/mirror/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz>
  - SHA-256: `ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe`
- Abseil 20240722.0
  - Source: <https://github.com/abseil/abseil-cpp/releases/download/20240722.0/abseil-cpp-20240722.0.tar.gz>
  - SHA-256: `f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3`
- Meson WrapDB patch `abseil-cpp_20240722.0-3_patch.zip`
  - SHA-256: `12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b`

The packaged `libDahliaAEC3.a` SHA-256 is
`be09b9bb55a909b9809160fce5cc8a7ccfca5221184f52ad3e11d09a4890e01a`.

## Runtime configuration

The bridge enables desktop AEC3 only. WebRTC noise suppression, both gain
controllers, and transient suppression remain disabled. Dahlia feeds mono
Float32 10 ms render and capture frames through the C interface in
`DahliaAEC3Sources`.

The accompanying WebRTC, PATENTS, AUTHORS, and Abseil license files apply to
the vendored static library.
