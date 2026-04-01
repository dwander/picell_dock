import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/panel_zoom_provider.dart';

/// 패널 컨텐츠에 텍스트/아이콘 배율을 적용하는 래퍼.
///
/// - [MediaQuery.textScaler] 오버라이드: textTheme 텍스트 자동 스케일
/// - [PanelScale]: 아이콘 크기를 하위 트리에 제공
/// - Ctrl+스크롤 휠: 한 단계씩 확대/축소
/// - 핀치 줌 (터치): 임계값 초과 시 한 단계씩 확대/축소
class PanelZoomWrapper extends ConsumerStatefulWidget {
  final String panelId;
  final Widget child;

  const PanelZoomWrapper({
    super.key,
    required this.panelId,
    required this.child,
  });

  @override
  ConsumerState<PanelZoomWrapper> createState() => _PanelZoomWrapperState();
}

class _PanelZoomWrapperState extends ConsumerState<PanelZoomWrapper> {
  /// 핀치 제스처 시작 시점 기준 누적 배율
  double _pinchScale = 1.0;

  /// 한 단계 확대/축소로 인정하는 핀치 임계값
  static const double _pinchUpThreshold = 1.15;
  static const double _pinchDownThreshold = 0.87;

  void _stepZoom(int direction) {
    final current = ref.read(panelZoomProvider)[widget.panelId] ?? 1.0;
    var idx = panelZoomLevels.indexOf(current);
    if (idx == -1) idx = panelZoomLevels.indexOf(1.0);
    final newIdx = (idx + direction).clamp(0, panelZoomLevels.length - 1);
    if (newIdx != idx) {
      ref
          .read(panelZoomProvider.notifier)
          .setZoom(widget.panelId, panelZoomLevels[newIdx]);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed) return;

    // 이벤트를 소비해 하위 스크롤뷰에 전달되지 않도록 차단
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final dy = (event as PointerScrollEvent).scrollDelta.dy;
      if (dy < 0) _stepZoom(1);   // 위로 스크롤 → 확대
      if (dy > 0) _stepZoom(-1);  // 아래로 스크롤 → 축소
    });
  }

  @override
  Widget build(BuildContext context) {
    final scale = ref.watch(
      panelZoomProvider.select((m) => m[widget.panelId] ?? 1.0),
    );

    Widget content = PanelScale(scale: scale, child: widget.child);

    if (scale != 1.0) {
      content = MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
        ),
        child: content,
      );
    }

    return Listener(
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        onScaleStart: (_) => _pinchScale = 1.0,
        onScaleUpdate: (details) => _pinchScale = details.scale,
        onScaleEnd: (_) {
          if (_pinchScale > _pinchUpThreshold) _stepZoom(1);
          if (_pinchScale < _pinchDownThreshold) _stepZoom(-1);
          _pinchScale = 1.0;
        },
        child: content,
      ),
    );
  }
}

/// 패널 아이콘 배율을 하위 위젯 트리에 제공하는 InheritedWidget.
class PanelScale extends InheritedWidget {
  final double scale;

  const PanelScale({
    super.key,
    required this.scale,
    required super.child,
  });

  /// 현재 컨텍스트의 패널 배율 반환 (PanelScale 없으면 1.0)
  static double of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<PanelScale>()
            ?.scale ??
        1.0;
  }

  @override
  bool updateShouldNotify(PanelScale oldWidget) => oldWidget.scale != scale;
}
