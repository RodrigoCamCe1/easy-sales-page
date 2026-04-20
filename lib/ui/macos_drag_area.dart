import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

const MethodChannel _macosWindowChannel =
    MethodChannel('easyexpert/window_drag');

/// Fallbacks for macOS desktop_multi_window sub-windows, which don't get the
/// window_manager plugin registered on their FlutterEngine. A native channel
/// is installed in AppDelegate.swift (windowDidBecomeKey) that forwards these
/// to the NSWindow owning the calling engine.
Future<void> macosWindowStartDragging() =>
    _macosWindowChannel.invokeMethod('startDragging');
Future<void> macosWindowMinimize() =>
    _macosWindowChannel.invokeMethod('minimize');
Future<void> macosWindowClose() =>
    _macosWindowChannel.invokeMethod('close');

/// Drop-in replacement for [DragToMoveArea] that works on macOS sub-windows.
class PlatformDragArea extends StatelessWidget {
  const PlatformDragArea({super.key, required this.child});

  final Widget child;

  Future<void> _startDrag() async {
    if (Platform.isMacOS) {
      try {
        await macosWindowStartDragging();
        return;
      } catch (e) {
        debugPrint('[PlatformDragArea] macOS drag channel failed: $e');
      }
    }
    try {
      await windowManager.startDragging();
    } catch (e) {
      debugPrint('[PlatformDragArea] windowManager drag failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons == kPrimaryMouseButton) {
          _startDrag();
        }
      },
      child: child,
    );
  }
}
