// test/core/native/android_audio_bridge_test.dart
//
// 来自 PRD_Architecture.md §3.5 (Checker: Oboe_AAudio_Gatekeeper)
//
// 单元测试锁死 V2 硬指标：
//   - Channel name 固定 "com.yyd841122.ukulele_app/audio"
//   - startCapture() 前未授权 → Result.failure(MicNotGrantedException)
//   - 权限状态机转换：unrequested → granted/denied/permanentlyDenied
//   - onLifecyclePause() 必须释放 native 句柄
//   - EventChannel 帧推送可被监听

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ukulele_app/core/audio/pcm_frame.dart';
import 'package:ukulele_app/core/native/android_audio_bridge.dart';
import 'package:ukulele_app/core/result/result.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidAudioBridge · 硬指标门禁', () {
    test('kAudioChannelName 必须 == "com.yyd841122.ukulele_app/audio"', () {
      expect(kAudioChannelName, 'com.yyd841122.ukulele_app/audio');
    });

    test('kAudioCaptureEventChannel 必须以 audio_frames 结尾', () {
      expect(kAudioCaptureEventChannel, endsWith('audio_frames'));
    });

    test('AudioMethod.requestMicPermission 常量名不能为空', () {
      expect(AudioMethod.requestMicPermission, isNotEmpty);
    });

    test('AudioMethod.startCapture / stopCapture / releaseStream / getNativeHandle 都有定义', () {
      expect(AudioMethod.startCapture, 'startCapture');
      expect(AudioMethod.stopCapture, 'stopCapture');
      expect(AudioMethod.releaseStream, 'releaseStream');
      expect(AudioMethod.getNativeHandle, 'getNativeHandle');
    });
  });

  group('FakeAndroidAudioBridge · 权限生命周期', () {
    test('初始 micState == unrequested', () {
      final b = FakeAndroidAudioBridge();
      expect(b.micState, MicState.unrequested);
      b.dispose();
    });

    test('requestPermission() 默认返回 granted 并广播', () async {
      final b = FakeAndroidAudioBridge();
      final events = <MicState>[];
      final sub = b.micStateStream.listen(events.add);

      final s = await b.requestPermission();
      expect(s, MicState.granted);
      expect(b.micState, MicState.granted);
      await Future<void>.delayed(Duration.zero);
      expect(events, contains(MicState.granted));
      await sub.cancel();
      await b.dispose();
    });

    test('debugConfigure 注入 denied：requestPermission 返回 denied', () async {
      final b = FakeAndroidAudioBridge();
      b.debugConfigure(AudioMethod.requestMicPermission, 'denied');
      final s = await b.requestPermission();
      expect(s, MicState.denied);
      await b.dispose();
    });

    test('debugConfigure 注入 permanentlyDenied', () async {
      final b = FakeAndroidAudioBridge();
      b.debugConfigure(AudioMethod.requestMicPermission, 'permanentlyDenied');
      final s = await b.requestPermission();
      expect(s, MicState.permanentlyDenied);
      await b.dispose();
    });
  });

  group('FakeAndroidAudioBridge · startCapture 守卫（任务核心场景）', () {
    test('未授权状态下 startCapture() 返回 Result.failure(MicNotGrantedException)',
        () async {
      final b = FakeAndroidAudioBridge();
      // 不调用 requestPermission，初始 unrequested
      final r = await b.startCapture();
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull, isA<MicNotGrantedException>());
      expect((r.errorOrNull as MicNotGrantedException).code, 'mic_not_granted');
      await b.dispose();
    });

    test('denied 状态下 startCapture() 同样返回 MicNotGrantedException', () async {
      final b = FakeAndroidAudioBridge();
      b.debugConfigure(AudioMethod.requestMicPermission, 'denied');
      await b.requestPermission();
      final r = await b.startCapture();
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull, isA<MicNotGrantedException>());
      await b.dispose();
    });

    test('granted 状态下 startCapture() 成功，isCapturing == true', () async {
      final b = FakeAndroidAudioBridge();
      await b.requestPermission();
      final r = await b.startCapture();
      expect(r.isSuccess, isTrue);
      expect(b.isCapturing, isTrue);
      expect(b.methodCalls, contains(AudioMethod.startCapture));
      await b.dispose();
    });

    test('startCapture() 注入 Exception → Result.failure(NativeBridgeException)',
        () async {
      final b = FakeAndroidAudioBridge();
      await b.requestPermission();
      b.debugConfigure(AudioMethod.startCapture, Exception('native start failed'));
      final r = await b.startCapture();
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull, isA<NativeBridgeException>());
      await b.dispose();
    });
  });

  group('FakeAndroidAudioBridge · 生命周期守卫（任务核心场景）', () {
    test('onLifecyclePause() 在采集中时立即 stopCapture 并释放句柄', () async {
      final b = FakeAndroidAudioBridge();
      await b.requestPermission();
      await b.startCapture();
      expect(b.isCapturing, isTrue);

      await b.onLifecyclePause();
      expect(b.isCapturing, isFalse);
      expect(b.methodCalls, contains(AudioMethod.stopCapture));
      await b.dispose();
    });

    test('onLifecyclePause() 在未采集中时幂等不抛', () async {
      final b = FakeAndroidAudioBridge();
      await b.onLifecyclePause();
      expect(b.isCapturing, isFalse);
      await b.dispose();
    });

    test('stopCapture() 幂等：多次调用不抛', () async {
      final b = FakeAndroidAudioBridge();
      await b.requestPermission();
      await b.startCapture();
      await b.stopCapture();
      await b.stopCapture();
      await b.stopCapture();
      expect(b.isCapturing, isFalse);
      await b.dispose();
    });
  });

  group('MethodChannelAudioBridge · 帧回调', () {
    test('debugPushFrame 推送的 PcmFrame 可被订阅者收到', () async {
      final b = FakeAndroidAudioBridge();
      final received = <PcmFrame>[];
      final sub = b.frames.listen(received.add);

      final frame = PcmFrame(
        samples: Int16List(2048),
        sampleRate: 44100,
        capturedAt: DateTime.now(),
      );
      b.debugPushFrame(frame);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.first.samples.length, 2048);
      await sub.cancel();
      await b.dispose();
    });

    test('MethodChannel 构造函数不抛（platform channel 默认绑定）', () {
      // 不实际 invoke method，仅构造
      final bridge = MethodChannelAudioBridge();
      expect(bridge.micState, MicState.unrequested);
      expect(bridge.isCapturing, isFalse);
      bridge.dispose();
    });
  });

  group('MethodChannelAudioBridge · MethodCallHandler 集成', () {
    test('startCapture 在未授权时不会调用 native method（守护前置）', () async {
      // 验证未授权时 startCapture 不发请求到 platform
      final bridge = MethodChannelAudioBridge();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(kAudioChannelName),
              (MethodCall call) async {
        calls.add(call);
        return null;
      });

      final r = await bridge.startCapture();
      expect(r.isFailure, isTrue);
      expect(calls, isEmpty,
          reason: 'must short-circuit before invoking platform method');
      await bridge.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(kAudioChannelName), null);
    });
  });

  group('NativeBridgeException · 异常类型契约', () {
    test('NativeBridgeException 携带 nativeCode / code / message', () {
      const e = NativeBridgeException('PERMISSION_DENIED', 'user denied');
      expect(e.nativeCode, 'PERMISSION_DENIED');
      expect(e.code, 'native_bridge');
      expect(e.message, contains('PERMISSION_DENIED'));
      expect(e, isA<AppError>());
    });
  });
}