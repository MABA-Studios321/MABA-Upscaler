# Changelog

## 1.4.0 - 2026-11-12

First public release.

- Quality build: low-contrast pixels now cost the same 2 texture reads as the fast build; only
  pixels on visible edges pay for the 12-tap kernel.
- Relicensed under Apache 2.0. Repository layout, logo, notices.

## 1.3

- Quality modes: Dynamic (default), Ultra Quality, Quality, Balanced, Performance.
- `maba_upscaler.h`: mode presets and the Dynamic controller.
- The shader can read from a region of a larger texture, so changing resolution never
  reallocates the render target.

## 1.2

- Quality build made adaptive: the 12-tap edge kernel fades in by local contrast.

## 1.1

- New default path: edge-directed reconstruction from the 2x2 block, about 1 ms per frame over
  bilinear on a Galaxy A05.

## 1.0

- Single-pass upscaler with a 12-tap luma kernel derived from FSR 1.0 EASU.
