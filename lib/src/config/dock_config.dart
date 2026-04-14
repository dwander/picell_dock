/// 독 시스템 레이아웃 상수.
///
/// [DockOverlay]에 [DockConfig]를 넘겨 기본값을 재정의할 수 있다.
class DockConfig {
  // ── 그룹 ──
  final double groupHeaderHeight;
  final double groupBorderRadius;
  final double groupMinWidth;
  final double groupMinHeight;

  // ── 패널 헤더 / 탭 바 ──
  final double panelHeaderHeight;
  final double headerOverlayHeight;
  final double headerOverlayRadius;
  final double tabBarHeight;

  // ── Split 세퍼레이터 ──
  final double splitSeparatorThickness;

  // ── 포커스 인디케이터 ──
  final double focusIndicatorHeight;

  // ── 엣지 도킹 ──
  final double edgePanelMinSize;
  final double edgePanelDefaultSize;
  final double edgeDetectThreshold;
  final double edgeHintWidth;

  const DockConfig({
    this.groupHeaderHeight = 4.0,
    this.groupBorderRadius = 8.0,
    this.groupMinWidth = 180.0,
    this.groupMinHeight = 120.0,
    this.panelHeaderHeight = 24.0,
    this.headerOverlayHeight = 36.0,
    this.headerOverlayRadius = 10.0,
    this.tabBarHeight = 24.0,
    this.splitSeparatorThickness = 4.0,
    this.focusIndicatorHeight = 2.0,
    this.edgePanelMinSize = 150.0,
    this.edgePanelDefaultSize = 280.0,
    this.edgeDetectThreshold = 1.0,
    this.edgeHintWidth = 4.0,
  });

  /// 지정한 필드만 변경한 복사본 생성.
  DockConfig copyWith({
    double? groupHeaderHeight,
    double? groupBorderRadius,
    double? groupMinWidth,
    double? groupMinHeight,
    double? panelHeaderHeight,
    double? headerOverlayHeight,
    double? headerOverlayRadius,
    double? tabBarHeight,
    double? splitSeparatorThickness,
    double? focusIndicatorHeight,
    double? edgePanelMinSize,
    double? edgePanelDefaultSize,
    double? edgeDetectThreshold,
    double? edgeHintWidth,
  }) {
    return DockConfig(
      groupHeaderHeight: groupHeaderHeight ?? this.groupHeaderHeight,
      groupBorderRadius: groupBorderRadius ?? this.groupBorderRadius,
      groupMinWidth: groupMinWidth ?? this.groupMinWidth,
      groupMinHeight: groupMinHeight ?? this.groupMinHeight,
      panelHeaderHeight: panelHeaderHeight ?? this.panelHeaderHeight,
      headerOverlayHeight: headerOverlayHeight ?? this.headerOverlayHeight,
      headerOverlayRadius: headerOverlayRadius ?? this.headerOverlayRadius,
      tabBarHeight: tabBarHeight ?? this.tabBarHeight,
      splitSeparatorThickness:
          splitSeparatorThickness ?? this.splitSeparatorThickness,
      focusIndicatorHeight: focusIndicatorHeight ?? this.focusIndicatorHeight,
      edgePanelMinSize: edgePanelMinSize ?? this.edgePanelMinSize,
      edgePanelDefaultSize: edgePanelDefaultSize ?? this.edgePanelDefaultSize,
      edgeDetectThreshold: edgeDetectThreshold ?? this.edgeDetectThreshold,
      edgeHintWidth: edgeHintWidth ?? this.edgeHintWidth,
    );
  }

  /// 기본값으로 생성된 [DockConfig] 인스턴스.
  ///
  /// dock_group.dart, dock_provider.dart 등에서 `const DockConfig()`를 직접
  /// 선언하는 대신 이 상수를 사용한다.
  static const DockConfig defaultConfig = DockConfig();
}
