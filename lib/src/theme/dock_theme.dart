import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/dock_config.dart';
import 'dock_color_scheme.dart';

/// 독 시스템 표시 설정.
class DockDisplaySettings {
  /// 클린 모드: true이면 핀 고정되지 않은 패널 숨김.
  final bool hideUnpinned;

  /// 포커스된 패널 그룹 테두리 하이라이트 표시 여부.
  final bool showFocusHighlight;

  /// 패널 헤더 호버 시 오버레이 버튼 표시 여부.
  final bool showHeaderOverlay;

  const DockDisplaySettings({
    this.hideUnpinned = false,
    this.showFocusHighlight = true,
    this.showHeaderOverlay = true,
  });
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
  /// [_DockOverlayRow]가 받는 형식: `(left, center, right)` 각각 `List<Widget>`.
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

/// 헤더 오버레이 3구역 레이아웃.
class DockOverlayLayout {
  final List<Widget> left;
  final List<Widget> center;
  final List<Widget> right;

  const DockOverlayLayout({
    this.left = const [],
    this.center = const [],
    this.right = const [],
  });

  bool get isEmpty => left.isEmpty && center.isEmpty && right.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// 독 시스템 전체 테마를 하위 위젯 트리에 전달하는 [InheritedWidget].
///
/// [DockOverlay]가 자동으로 삽입한다. 내부 독 위젯들은
/// [DockTheme.of(context)]로 색상·설정·델리게이트에 접근한다.
class DockTheme extends InheritedWidget {
  final DockColorScheme colorScheme;
  final DockConfig config;
  final DockDisplaySettings displaySettings;
  final DockPanelDelegate panelDelegate;

  const DockTheme({
    super.key,
    required this.colorScheme,
    required this.config,
    required this.displaySettings,
    required this.panelDelegate,
    required super.child,
  });

  static DockTheme of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<DockTheme>();
    if (t == null) {
      throw FlutterError(
        'DockTheme을 찾을 수 없습니다. DockOverlay 하위에서 사용하세요.',
      );
    }
    return t;
  }

  @override
  bool updateShouldNotify(DockTheme old) =>
      colorScheme != old.colorScheme ||
      config != old.config ||
      displaySettings != old.displaySettings ||
      panelDelegate != old.panelDelegate;
}
