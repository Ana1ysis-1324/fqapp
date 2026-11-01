// android_channel_stub.dart
//
// Android 端有一批 Kotlin 原生插件（系统栏/亮度/悬浮窗/TTS/下载/备份/手势/
// 渲染兼容/E-ink 等），在 iOS 上既没有对应实现也不影响核心阅读体验。
// 这些 MethodChannel 调用在 iOS 上必须跳过，否则会因为找不到 handler 抛
// MissingPluginException 或卡住。
//
// 用法（两选一）：
//  1) 把 `MethodChannel('fqapp/xxx').invokeMethod('yyy', args)` 改成
//     `AndroidChannel('fqapp/xxx').call('yyy', args)`。
//  2) 或者在原有调用外包一层 `if (Platform.isAndroid) { ... }`。
//
// 注意：登录通道 fqapp/fanqie_account 在 iOS 上有真实原生实现（见
// ios/Runner/FanqieAccountPlugin.swift），【不要】用本 stub 包裹它，
// 保持原来的 `MethodChannel('fqapp/fanqie_account')` 即可。

import 'dart:io';

import 'package:flutter/services.dart';

/// 仅在 Android 上实际调用原生通道；其它平台直接返回 null（功能不可用）。
class AndroidChannel {
  final MethodChannel _channel;

  AndroidChannel(String name) : _channel = MethodChannel(name);

  Future<T?> call<T>(String method, [Map<String, dynamic>? arguments]) async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<T>(method, arguments);
  }

  /// 带默认值的版本：非 Android 返回 [fallback]。
  Future<T> callOr<T>(String method, T fallback, [Map<String, dynamic>? arguments]) async {
    if (!Platform.isAndroid) return fallback;
    return (await _channel.invokeMethod<T>(method, arguments)) ?? fallback;
  }
}
