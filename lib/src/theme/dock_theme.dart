import 'package:flutter/widgets.dart';

import '../config/dock_config.dart';
import '../config/dock_display_settings.dart';
import '../config/dock_panel_delegate.dart';
import 'dock_color_scheme.dart';

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
