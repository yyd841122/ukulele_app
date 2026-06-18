// lib/core/result/result.dart
//
// 来自 PRD_Architecture.md §6.2（Auditor: Anti_Ambiguity）
//
// 统一的 Result<T, AppError> 函数式返回包装 + V2 约定的所有异常类型。
// 所有底层契约（Audio/IO/Permission）必须通过 Result 向上传递失败，
// 禁止在业务层使用 throw/catch 流程控制。

import 'package:meta/meta.dart';

/// 函数式返回包装。sealed class 保证模式匹配穷尽。
@immutable
sealed class Result<T, E> {
  const Result();

  /// 工厂：成功。
  const factory Result.success(T value) = Success<T, E>;

  /// 工厂：失败。
  const factory Result.failure(E error) = Failure<T, E>;

  /// 模式匹配。
  R when<R>({
    required R Function(T value) success,
    required R Function(E error) failure,
  }) {
    if (this is Success<T, E>) return success((this as Success<T, E>).value);
    return failure((this as Failure<T, E>).error);
  }

  /// 取值或 null。
  T? get valueOrNull {
    final s = this;
    return s is Success<T, E> ? s.value : null;
  }

  /// 取错误或 null。
  E? get errorOrNull {
    final s = this;
    return s is Failure<T, E> ? s.error : null;
  }

  bool get isSuccess => this is Success<T, E>;
  bool get isFailure => this is Failure<T, E>;
}

final class Success<T, E> extends Result<T, E> {
  final T value;
  const Success(this.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Success<T, E> && other.value == value);

  @override
  int get hashCode => value.hashCode;
}

final class Failure<T, E> extends Result<T, E> {
  final E error;
  const Failure(this.error);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Failure<T, E> && other.error == error);

  @override
  int get hashCode => error.hashCode;
}

// ──────────────────────────────────────────────────────────────
// V2 AppError 体系（PRD §6.2）
// ──────────────────────────────────────────────────────────────

/// 错误基类。所有 AppError 子类必须 code 唯一、message 非空。
sealed class AppError {
  final String code;
  final String message;
  const AppError({required this.code, required this.message});

  @override
  String toString() => '$runtimeType(code: $code, message: $message)';
}

// ── 权限 ─────────────────────────────────────────────────────
class MicNotGrantedException extends AppError {
  const MicNotGrantedException()
      : super(code: 'mic_not_granted', message: 'RECORD_AUDIO permission not granted');
}

class MicPermanentlyDeniedException extends AppError {
  const MicPermanentlyDeniedException()
      : super(code: 'mic_permanently_denied', message: 'RECORD_AUDIO permanently denied');
}

// ── 音频会话冲突（V2 新增）────────────────────────────────────
class AudioSessionBusyException extends AppError {
  final String requestedMode;
  final String currentMode;
  const AudioSessionBusyException({
    required this.requestedMode,
    required this.currentMode,
  }) : super(
          code: 'audio_session_busy',
          message: 'Cannot acquire $requestedMode while holding $currentMode',
        );
}

// ── Oboe/AAudio Native 层（V2 新增）──────────────────────────
class OboeReleaseTimeoutException extends AppError {
  final int actualMs;
  const OboeReleaseTimeoutException(this.actualMs)
      : super(
          code: 'oboe_release_timeout',
          message: 'Oboe/AAudio stream release exceeded 10ms budget (actual: ${actualMs}ms)',
        );
}

class UseAfterFreeException extends AppError {
  const UseAfterFreeException()
      : super(
          code: 'use_after_free',
          message: 'Native handle accessed after release (use-after-free prevented)',
        );
}

// ── 资源 / I/O ───────────────────────────────────────────────
class AudioNotLoadedException extends AppError {
  const AudioNotLoadedException()
      : super(code: 'audio_not_loaded', message: 'Audio asset not loaded before play()');
}

class AssetNotFoundException extends AppError {
  final String assetPath;
  const AssetNotFoundException(this.assetPath)
      : super(code: 'asset_not_found', message: 'Asset not found: $assetPath');
}

// ── 性能 / 渲染 ──────────────────────────────────────────────
class AudioLatencyOverflowException extends AppError {
  final int actualMs;
  final int budgetMs;
  const AudioLatencyOverflowException({required this.actualMs, required this.budgetMs})
      : super(
          code: 'audio_latency_overflow',
          message: 'Audio latency $actualMs ms exceeded budget $budgetMs ms',
        );
}

class RenderBudgetOverflowException extends AppError {
  final double actualMs;
  RenderBudgetOverflowException(this.actualMs)
      : super(
          code: 'render_budget_overflow',
          message: 'Frame render ${actualMs.toStringAsFixed(2)}ms exceeded 16.6ms budget',
        );
}

// ── 解析 / 协议 ──────────────────────────────────────────────
class SchemaMismatchException extends AppError {
  final String version;
  const SchemaMismatchException(this.version)
      : super(code: 'schema_mismatch', message: 'UnifiedScore schema version mismatch: $version');
}

class InvalidTimingException extends AppError {
  final String entity;
  final int startMs;
  final int endMs;
  const InvalidTimingException({
    required this.entity,
    required this.startMs,
    required this.endMs,
  }) : super(
          code: 'invalid_timing',
          message: '$entity timing invalid: startMs=$startMs, endMs=$endMs',
        );
}

/// 提供一个非 const 工厂以支持运行时动态字段（如 request 状态）。
/// 推荐使用 const 构造；该工厂仅在 const 不可用时使用。
AppError schemaMismatch(String v) => SchemaMismatchException(v);
