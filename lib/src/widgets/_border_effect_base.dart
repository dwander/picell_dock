import 'package:flutter/material.dart';

/// Effect 위젯 State들이 공유하는 AnimationController/CurvedAnimation 관리 믹스인.
///
/// 사용 측 위젯은 [effectDuration], [effectCurve], [onAttach], [onDetach] 를
/// 제공해야 한다.
///
/// 믹스인이 처리하는 것:
/// - initState: AnimationController + CurvedAnimation 생성, Controller attach
/// - didUpdateWidget: controller 교체 및 duration 변경 반영
/// - dispose: controller 해제 + detach
///
/// 사용 측이 구현해야 하는 것:
/// - [effectDuration]: 위젯에서 읽어오는 duration
/// - [effectCurve]: 커브 (서브클래스가 override)
/// - [onAttach]: controller에 트리거 콜백 등록 시 호출
/// - [onDetach]: controller에서 트리거 콜백 해제 시 호출
mixin BorderEffectMixin<W extends StatefulWidget> on State<W>,
    SingleTickerProviderStateMixin<W> {
  late AnimationController effectCtrl;
  late Animation<double> effectAnim;

  /// 위젯에서 읽어오는 애니메이션 지속 시간.
  Duration get effectDuration;

  /// 애니메이션 커브 (기본: easeOut).
  Curve get effectCurve => Curves.easeOut;

  /// Controller의 _attach() 역할 — 트리거 콜백 등록.
  void onAttach();

  /// Controller의 _detach() 역할 — 트리거 콜백 해제.
  void onDetach();

  @override
  void initState() {
    super.initState();
    effectCtrl = AnimationController(duration: effectDuration, vsync: this);
    effectAnim = CurvedAnimation(parent: effectCtrl, curve: effectCurve);
    onAttach();
  }

  /// didUpdateWidget에서 공통 처리 — 서브클래스가 반드시 호출해야 한다.
  void handleControllerChange(bool controllerChanged) {
    if (controllerChanged) {
      onDetach();
      onAttach();
    }
  }

  void handleDurationChange() {
    effectCtrl.duration = effectDuration;
  }

  @override
  void dispose() {
    onDetach();
    effectCtrl.dispose();
    super.dispose();
  }

  /// 애니메이션을 처음부터 재생한다.
  void playEffect() => effectCtrl.forward(from: 0);
}

// ─────────────────────────────────────────────

/// Effect 위젯들의 공통 build 구조를 제공하는 스캐폴드.
///
/// Stack → child + Positioned.fill → IgnorePointer → AnimatedBuilder
/// → v==0 이면 SizedBox.shrink, 아니면 CustomPaint 패턴을 캡슐화한다.
///
/// [painterBuilder]에서 현재 진행도(0.0~1.0)를 받아 [CustomPainter]를 반환한다.
class BorderEffectScaffold extends StatelessWidget {
  final Widget child;
  final Animation<double> animation;
  final CustomPainter Function(double progress) painterBuilder;

  const BorderEffectScaffold({
    super.key,
    required this.child,
    required this.animation,
    required this.painterBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, _) {
                final v = animation.value;
                if (v == 0) return const SizedBox.shrink();
                return CustomPaint(painter: painterBuilder(v));
              },
            ),
          ),
        ),
      ],
    );
  }
}
