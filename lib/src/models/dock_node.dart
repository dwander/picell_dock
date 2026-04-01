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

  const DockTabbed({required this.tabIds, this.activeIndex = 0})
    : assert(tabIds.length > 0),
      assert(activeIndex >= 0 && activeIndex < tabIds.length);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tabbed',
    'tabIds': tabIds,
    'activeIndex': activeIndex,
  };

  factory DockTabbed.fromJson(Map<String, dynamic> json) => DockTabbed(
    tabIds: [for (final id in json['tabIds'] as List) id as String],
    activeIndex: json['activeIndex'] as int? ?? 0,
  );

  @override
  List<Object?> get props => [tabIds, activeIndex];
}
