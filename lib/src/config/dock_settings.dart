import '../models/dock_group.dart';

/// 독 시스템 동작 설정.
///
/// [dockSettingsProvider]를 통해 주입. 호스트 앱은 [ProviderScope.overrides]로
/// 앱 자체 설정과 연결한다.
///
/// ```dart
/// // 호스트 앱 ProviderScope:
/// dockSettingsProvider.overrideWith((ref) => DockSettings(
///   allowAutoAvoidance: true,
///   allowHorizontalPanelDock: true,   // 기본값 true, false면 상하 도킹만
///   isHeaderless: PanelRegistry.isHeaderless,
///   defaultLayout: () => myDefaultGroups,
///   initialFocusedPanelId: 'thumbnail',
/// ))
/// ```
class DockSettings {
  /// 창 리사이즈 시 패널 겹침 방지 1축 회피 허용 여부.
  final bool allowAutoAvoidance;

  /// 패널 간 좌우(수평) 엣지 도킹 허용 여부.
  final bool allowHorizontalPanelDock;

  /// 저장된 레이아웃이 없을 때 사용할 기본 패널 그룹 목록.
  ///
  /// null이면 빈 상태로 시작.
  final List<DockGroup> Function()? defaultLayout;

  /// 독립 그룹일 때 헤더 없이 프레임만 표시할 패널 여부.
  final bool Function(String panelId) isHeaderless;

  /// 초기 포커스 패널 ID (저장 레이아웃 미존재 시).
  final String? initialFocusedPanelId;

  const DockSettings({
    this.allowAutoAvoidance = false,
    this.allowHorizontalPanelDock = true,
    this.defaultLayout,
    this.isHeaderless = _alwaysFalse,
    this.initialFocusedPanelId,
  });

  static bool _alwaysFalse(String _) => false;
}
