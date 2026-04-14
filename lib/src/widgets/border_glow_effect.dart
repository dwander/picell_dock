import 'package:flutter/material.dart';

import '../theme/dock_theme.dart';
import '_border_effect_base.dart';

/// 위젯 테두리 전체가 동시에 빛나는 글로우 이펙트.
///
/// [BorderGlowController.trigger]를 호출하면 애니메이션이 재생된다.
///
/// ```dart
/// final _glowCtrl = BorderGlowController();
///
/// BorderGlowEffect(
///   controller: _glowCtrl,
///   borderRadius: 6,
///   child: MyWidget(),
/// )
///
/// // 이펙트 재생
/// _glowCtrl.trigger();
/// ```
class BorderGlowEffect extends StatefulWidget {
  final Widget child;
  final BorderGlowController controller;

  /// 글로우 색상 (기본: DockTheme 액센트 색)
  final Color? color;

  /// 전체 애니메이션 시간 (기본: 700ms)
  final Duration duration;

  /// 테두리 둥근 정도 (기본: 0)
  final double borderRadius;

  /// 이펙트 강도 (0.0~1.0, 기본: 1.0)
  final double intensity;

  const BorderGlowEffect({
    super.key,
    required this.child,
    required this.controller,
    this.color,
    this.duration = const Duration(milliseconds: 700),
    this.borderRadius = 0,
    this.intensity = 1.0,
  });

  @override
  State<BorderGlowEffect> createState() => _BorderGlowEffectState();
}

class _BorderGlowEffectState extends State<BorderGlowEffect>
    with SingleTickerProviderStateMixin, BorderEffectMixin<BorderGlowEffect> {
  @override
  Duration get effectDuration => widget.duration;

  @override
  Curve get effectCurve => Curves.easeOut;

  @override
  void onAttach() => widget.controller._attach(playEffect);

  @override
  void onDetach() => widget.controller._detach();

  @override
  void didUpdateWidget(BorderGlowEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      handleControllerChange(true);
    }
    if (oldWidget.duration != widget.duration) {
      handleDurationChange();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? DockTheme.of(context).colorScheme.accent;
    return BorderEffectScaffold(
      animation: effectAnim,
      painterBuilder: (v) => _BorderGlowPainter(
        progress: v,
        color: color,
        borderRadius: widget.borderRadius,
        intensity: widget.intensity,
      ),
      child: widget.child,
    );
  }
}

/// 이펙트 재생을 외부에서 제어하는 컨트롤러.
///
/// [trigger]를 호출하면 연결된 [BorderGlowEffect]의 애니메이션이 재생된다.
class BorderGlowController {
  VoidCallback? _trigger;

  void _attach(VoidCallback trigger) => _trigger = trigger;
  void _detach() => _trigger = null;

  /// 글로우 이펙트를 처음부터 재생.
  void trigger() => _trigger?.call();
}

/// 테두리 전체가 동시에 빛나는 글로우 페인터.
///
/// 애니메이션 3단계:
/// - 0.0 ~ 0.25: 페이드인 (빠르게 밝아짐)
/// - 0.25 ~ 0.45: 최대 밝기 유지
/// - 0.45 ~ 1.0: 페이드아웃 (천천히 사라짐)
class _BorderGlowPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double borderRadius;
  final double intensity;

  /// 메인 라인 두께
  static const double _strokeWidth = 1.5;

  /// 블러 글로우 확산 반경
  static const double _glowBlurRadius = 5.0;

  /// 외곽 글로우 MaskFilter 블러 반경.
  static const double _outerGlowBlur = 6.0;

  /// 코너 하이라이트 MaskFilter 블러 반경.
  static const double _cornerBlur = 3.0;

  /// 코너 원 반경.
  static const double _cornerTipRadius = 2.0;

  /// RRect 1px 인셋 (테두리가 클리핑되지 않도록).
  static const double _rrectInset = 1.0;

  /// 페이드인 종료 시점
  static const double _fadeInEnd = 0.25;

  /// 홀드 종료 시점
  static const double _holdEnd = 0.45;

  const _BorderGlowPainter({
    required this.progress,
    required this.color,
    required this.borderRadius,
    this.intensity = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    // ── 알파 계산 ──
    final double alpha;
    if (progress < _fadeInEnd) {
      // 페이드인
      final t = progress / _fadeInEnd;
      alpha = Curves.easeOutCubic.transform(t);
    } else if (progress < _holdEnd) {
      // 홀드
      alpha = 1.0;
    } else {
      // 페이드아웃
      final t = (progress - _holdEnd) / (1.0 - _holdEnd);
      alpha = 1.0 - Curves.easeInCubic.transform(t);
    }

    if (alpha <= 0) return;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(_rrectInset, _rrectInset, size.width - _rrectInset * 2, size.height - _rrectInset * 2),
      Radius.circular(borderRadius),
    );

    // ── 외곽 글로우 (넓은 블러) ──
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _glowBlurRadius
        ..color = color.withValues(alpha: alpha * 0.3 * intensity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _outerGlowBlur),
    );

    // ── 코어 라인 (선명한 테두리) ──
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..color = color.withValues(alpha: alpha * 0.8 * intensity),
    );

    // ── 코너 하이라이트 (모서리 포인트 강조) ──
    final tipAlpha = alpha * 0.5 * intensity;
    final tipPaint = Paint()
      ..color = color.withValues(alpha: tipAlpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _cornerBlur);
    final r = borderRadius;
    final corners = [
      Offset(r + _rrectInset, r + _rrectInset),
      Offset(size.width - r - _rrectInset, r + _rrectInset),
      Offset(r + _rrectInset, size.height - r - _rrectInset),
      Offset(size.width - r - _rrectInset, size.height - r - _rrectInset),
    ];
    for (final corner in corners) {
      canvas.drawCircle(corner, _cornerTipRadius, tipPaint);
    }
  }

  @override
  bool shouldRepaint(_BorderGlowPainter old) =>
      old.progress != progress || old.intensity != intensity;
}
