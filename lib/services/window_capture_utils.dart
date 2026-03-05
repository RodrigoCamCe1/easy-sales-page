import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Utility to hide/show all app windows from screen capture software
/// (Google Meet, Zoom, Discord, OBS, etc.) using the Win32
/// SetWindowDisplayAffinity API with WDA_EXCLUDEFROMCAPTURE.

bool _enabled = false;

/// Whether invisible mode is currently active.
bool get invisibleModeEnabled => _enabled;

/// Toggle all app windows in/out of screen capture.
void setInvisibleMode(bool enabled) {
  if (!Platform.isWindows) return;
  _enabled = enabled;
  _applyToAllWindows();
}

/// Re-apply current mode to all windows.  Call after opening a new
/// sub-window (e.g. recording bar) so it inherits the setting.
void reapplyInvisibleMode() {
  if (!Platform.isWindows || !_enabled) return;
  _applyToAllWindows();
}

// ── Win32 FFI bindings ──────────────────────────────────────────

final _user32 = DynamicLibrary.open('user32.dll');

// HWND FindWindowExW(HWND parent, HWND childAfter, LPCWSTR class, LPCWSTR window)
final _findWindowEx = _user32.lookupFunction<
    IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, IntPtr),
    int Function(int, int, Pointer<Utf16>, int)>('FindWindowExW');

// BOOL SetWindowDisplayAffinity(HWND hWnd, DWORD dwAffinity)
final _setAffinity = _user32.lookupFunction<
    Int32 Function(IntPtr, Uint32),
    int Function(int, int)>('SetWindowDisplayAffinity');

const _wdaNone = 0x00000000;
const _wdaExcludeFromCapture = 0x00000011;

// Window class names used by Flutter runner and desktop_multi_window plugin.
const _classNames = [
  'FLUTTER_RUNNER_WIN32_WINDOW', // main window
  'FlutterMultiWindow',          // sub-windows (recording bar, settings)
];

void _applyToAllWindows() {
  final affinity = _enabled ? _wdaExcludeFromCapture : _wdaNone;

  for (final name in _classNames) {
    final className = name.toNativeUtf16();
    int hwnd = 0;
    while (true) {
      hwnd = _findWindowEx(0, hwnd, className, 0);
      if (hwnd == 0) break;
      _setAffinity(hwnd, affinity);
    }
    malloc.free(className);
  }
}
