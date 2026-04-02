import 'package:flutter/material.dart';

import '../theme/dock_theme.dart';

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

  const BorderGlowEffect({
    super.key,
    required this.child,
    required this.controller,
    this.color,
    this.duration = const Duration(milliseconds: 700),
    this.borderRadius = 0,
  });

  @override
  State<BorderGlowEffect> createState() => BorderGlowEffectState();
}

class BorderGlowEffectState extends State<BorderGlowEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: widget.duration, vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    widget.controller._attach(this);
  }

  @override
  void didUpdateWidget(BorderGlowEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._detach();
      widget.controller._attach(this);
    }
    if (oldWidget.duration != widget.duration) {
      _ctrl.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    widget.controller._detach();
    _ctrl.dispose();
    super.dispose();
  }

  void trigger() => _ctrl.forward(from: 0);

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? DockTheme.of(context).colorScheme.accent;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, _) {
                final v = _anim.value;
                if (v == 0) return const SizedBox.shrink();
                return CustomPaint(
                  painter: _BorderGlowPainter(
                    progress: v,
                    color: color,
                    borderRadius: widget.borderRadius,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 이펙트 재생을 외부에서 제어하는 컨트롤러.
///
/// [trigger]를 호출하면 연결된 [BorderGlowEffect]의 애니메이션이 재생된다.
class BorderGlowController {
  BorderGlowEffectState? _state;

  void _attach(BorderGlowEffectState state) => _state = state;
  void _detach() => _state = null;

  /// 글로우 이펙트를 처음부터 재생.
  void trigger() => _state?.trigger();
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

  /// 메인 라인 두께
  static const double _strokeWidth = 1.5;

  /// 블러 글로우 확산 반경
  static const double _glowBlurRadius = 5.0;

  /// 페이드인 종료 시점
  static const double _fadeInEnd = 0.25;

  /// 홀드 종료 시점
  static const double _holdEnd = 0.45;

  const _BorderGlowPainter({
    required this.progress,
    required this.color,
    required this.borderRadius,
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
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(borderRadius),
    );

    // ── 외곽 글로우 (넓은 블러) ──
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _glowBlurRadius
        ..color = color.withValues(alpha: alpha * 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // ── 코어 라인 (선명한 테두리) ──
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..color = color.withValues(alpha: alpha * 0.8),
    );

    // ── 코너 하이라이트 (모서리 포인트 강조) ──
    final tipAlpha = alpha * 0.5;
    final tipPaint = Paint()
      ..color = color.withValues(alpha: tipAlpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final r = borderRadius;
    final corners = [
      Offset(r + 1, r + 1),
      Offset(size.width - r - 1, r + 1),
      Offset(r + 1, size.height - r - 1),
      Offset(size.width - r - 1, size.height - r - 1),
    ];
    for (final corner in corners) {
      canvas.drawCircle(corner, 2.0, tipPaint);
    }
  }

  @override
  bool shouldRepaint(_BorderGlowPainter old) => old.progress != progress;
}
