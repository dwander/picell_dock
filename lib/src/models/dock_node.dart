import 'package:equatable/equatable.dart';

/// 독 레이아웃 트리의 노드.
///
/// Rust 버전의 DockNode enum을 Dart sealed class로 포팅.
/// exhaustive switch 패턴 매칭으로 안전하게 처리.
sealed class DockNode extends Equatable {
  const DockNode();

  Map<String, dynamic> toJson();

  static DockNode fromJson(Map<String, dynamic> json) {
    return switch (json['type'] as String) {
      'leaf' => DockLeaf.fromJson(json),
      'split' => DockSplit.fromJson(json),
      'tabbed' => DockTabbed.fromJson(json),
      _ => throw FormatException('Unknown DockNode type: ${json['type']}'),
    };
  }
}

/// 단일 패널을 표시하는 리프 노드.
class DockLeaf extends DockNode {
  final String panelId;

  const DockLeaf({required this.panelId});

  DockLeaf copyWith({String? panelId}) =>
      DockLeaf(panelId: panelId ?? this.panelId);

  @override
  Map<String, dynamic> toJson() => {'type': 'leaf', 'panelId': panelId};

  factory DockLeaf.fromJson(Map<String, dynamic> json) =>
      DockLeaf(panelId: json['panelId'] as String);

  @override
  List<Object?> get props => [panelId];
}

/// 스플릿 축 방향.
enum SplitAxis { horizontal, vertical }

/// 축 기준으로 자식들을 분할하는 노드.
///
/// [ratios]는 [children]과 같은 길이이며, 합계가 1.0.
class DockSplit extends DockNode {
  final SplitAxis axis;
  final List<DockNode> children;
  final List<double> ratios;

  const DockSplit({
    required this.axis,
    required this.children,
    required this.ratios,
  }) : assert(children.length == ratios.length),
       assert(children.length >= 2);

  DockSplit copyWith({
    SplitAxis? axis,
    List<DockNode>? children,
    List<double>? ratios,
  }) {
    return DockSplit(
      axis: axis ?? this.axis,
      children: children ?? this.children,
      ratios: ratios ?? this.ratios,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'split',
    'axis': axis.name,
    'children': [for (final c in children) c.toJson()],
    'ratios': ratios,
  };

  factory DockSplit.fromJson(Map<String, dynamic> json) => DockSplit(
    axis: SplitAxis.values.byName(json['axis'] as String),
    children: [
      for (final c in json['children'] as List)
        DockNode.fromJson(c as Map<String, dynamic>),
    ],
    ratios: [for (final r in json['ratios'] as List) (r as num).toDouble()],
  );

  @override
  List<Object?> get props => [axis, children, ratios];
}

/// 탭으로 묶인 패널 그룹 노드.
class DockTabbed extends DockNode {
  final List<String> tabIds;
  final int activeIndex;

  /// 패널이 접혀 있는지 여부.
  final bool collapsed;

  /// 접히기 전 원래 픽셀 높이 (접힌 상태에서만 유효).
  /// 플로팅 그룹에서 펼칠 때 원래 높이를 복원하는 데 사용.
  final double? expandedHeight;

  const DockTabbed({
    required this.tabIds,
    this.activeIndex = 0,
    this.collapsed = false,
    this.expandedHeight,
  }) : assert(tabIds.length > 0), // ignore: prefer_is_empty — const constructor
       assert(activeIndex >= 0 && activeIndex < tabIds.length);

  /// 지정한 필드만 변경한 복사본 생성.
  ///
  /// [clearExpandedHeight]가 true이면 expandedHeight를 null로 초기화.
  DockTabbed copyWith({
    List<String>? tabIds,
    int? activeIndex,
    bool? collapsed,
    double? expandedHeight,
    bool clearExpandedHeight = false,
  }) {
    return DockTabbed(
      tabIds: tabIds ?? this.tabIds,
      activeIndex: activeIndex ?? this.activeIndex,
      collapsed: collapsed ?? this.collapsed,
      expandedHeight: clearExpandedHeight
          ? null
          : (expandedHeight ?? this.expandedHeight),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tabbed',
    'tabIds': tabIds,
    'activeIndex': activeIndex,
    if (collapsed) 'collapsed': true,
    if (expandedHeight != null) 'expandedHeight': expandedHeight,
  };

  factory DockTabbed.fromJson(Map<String, dynamic> json) => DockTabbed(
    tabIds: [for (final id in json['tabIds'] as List) id as String],
    activeIndex: json['activeIndex'] as int? ?? 0,
    collapsed: json['collapsed'] as bool? ?? false,
    expandedHeight: (json['expandedHeight'] as num?)?.toDouble(),
  );

  @override
  List<Object?> get props => [tabIds, activeIndex, collapsed, expandedHeight];
}

/// DockNode 트리 유틸리티.
extension DockNodeUtils on DockNode {
  /// 트리 내 모든 패널 ID를 수집.
  List<String> collectPanelIds() {
    return switch (this) {
      DockLeaf(:final panelId) => [panelId],
      DockSplit(:final children) => [
        for (final child in children) ...child.collectPanelIds(),
      ],
      DockTabbed(:final tabIds) => [...tabIds],
    };
  }

  /// 이 노드가 접혀 있는지 여부.
  bool get isCollapsed => switch (this) {
    DockTabbed(:final collapsed) => collapsed,
    _ => false,
  };

  /// 트리 내 모든 리프/탭 노드가 접혀 있는지 여부.
  bool get isAllCollapsed => switch (this) {
    DockLeaf() => false,
    DockTabbed(:final collapsed) => collapsed,
    DockSplit(:final children) => children.every((c) => c.isAllCollapsed),
  };
}
