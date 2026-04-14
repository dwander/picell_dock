import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 헤더 오버레이 3구역 레이아웃.
///
/// 반환 위젯은 좌/중/우 3구역 Row로 배치된다.
class DockOverlayLayout {
  final List<Widget> left;
  final List<Widget> center;
  final List<Widget> right;

  const DockOverlayLayout({
    this.left = const [],
    this.center = const [],
    this.right = const [],
  });

  /// 지정한 필드만 변경한 복사본 생성.
  DockOverlayLayout copyWith({
    List<Widget>? left,
    List<Widget>? center,
    List<Widget>? right,
  }) {
    return DockOverlayLayout(
      left: left ?? this.left,
      center: center ?? this.center,
      right: right ?? this.right,
    );
  }

  bool get isEmpty => left.isEmpty && center.isEmpty && right.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// 독 시스템의 패널 빌드/정보 제공 델리게이트.
///
/// 호스트 앱에서 패널 ID에 따라 위젯, 이름, 동작을 제공한다.
class DockPanelDelegate {
  /// 패널 ID에 해당하는 위젯을 반환.
  final Widget Function(String panelId) buildPanel;

  /// 패널 ID의 표시 이름을 반환.
  final String Function(String panelId) labelOf;

  /// 닫기 가능한 패널 여부.
  final bool Function(String panelId) isClosable;

  /// 패널 헤더 오버레이에 표시할 위젯을 반환.
  ///
  /// null이면 오버레이 없음. 반환 위젯은 좌/중/우 3구역 Row로 배치된다.
  /// [DockOverlayLayout]이 받는 형식: `(left, center, right)` 각각 `List<Widget>`.
  final DockOverlayLayout? Function(String panelId, WidgetRef ref)?
      buildOverlayLayout;

  const DockPanelDelegate({
    required this.buildPanel,
    required this.labelOf,
    this.isClosable = _alwaysFalse,
    this.buildOverlayLayout,
  });

  static bool _alwaysFalse(String _) => false;
}
