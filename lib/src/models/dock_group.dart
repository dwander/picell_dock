import 'dart:ui';

import 'package:equatable/equatable.dart';

import '../config/dock_config.dart';
import 'dock_node.dart';

// 기본 DockConfig 인스턴스 — 모델 내부 계산에서 사용.
const _config = DockConfig();

/// 뷰포트 엣지 도킹 방향.
enum ViewportEdge { left, right }

/// X축 앵커 (3분할).
enum AnchorX { left, center, right }

/// Y축 앵커 (3분할).
enum AnchorY { top, center, bottom }

/// 하나의 독립적인 플로팅 독 그룹.
///
/// 앵커 기반 좌표계: 뷰포트를 9개 존으로 나누어
/// 창 크기 변경 시 앵커 기준으로 패널이 자동 재배치.
class DockGroup extends Equatable {
  final String id;
  final DockNode root;

  /// 앵커 기준점.
  final AnchorX anchorX;
  final AnchorY anchorY;

  /// 앵커 기준 오프셋.
  final double offsetX;
  final double offsetY;

  final double width;
  final double height;
  final int zOrder;

  /// null = 플로팅, non-null = 해당 엣지에 고정.
  final ViewportEdge? dockedEdge;

  /// 핀 고정 상태 — true이면 항상 최상위 유지.
  final bool pinned;

  /// 헤더리스 프레임 — true이면 탭바 없이 콘텐츠만 표시.
  final bool headerless;

  /// 최대화 이전 상태 저장 (복귀용).
  ///
  /// null이면 최대화 상태가 아님. 앱 재시작 시에도 유지되도록 직렬화한다.
  /// [dockedEdge]는 최대화 전 엣지 도킹 상태였을 경우 복귀에 사용.
  final ({
    double left,
    double top,
    double width,
    double height,
    ViewportEdge? dockedEdge,
  })? savedState;

  const DockGroup({
    required this.id,
    required this.root,
    this.anchorX = AnchorX.left,
    this.anchorY = AnchorY.top,
    required this.offsetX,
    required this.offsetY,
    required this.width,
    required this.height,
    this.zOrder = 0,
    this.dockedEdge,
    this.pinned = false,
    this.headerless = false,
    this.savedState,
  });

  /// 앵커 좌표 → 절대 X 좌표 변환.
  double absoluteX(double viewportW) {
    return switch (anchorX) {
      AnchorX.left => offsetX,
      AnchorX.center => viewportW / 2 + offsetX - width / 2,
      AnchorX.right => viewportW - offsetX - width,
    };
  }

  /// 앵커 좌표 → 절대 Y 좌표 변환.
  double absoluteY(double viewportH) {
    return switch (anchorY) {
      AnchorY.top => offsetY,
      AnchorY.center => viewportH / 2 + offsetY - height / 2,
      AnchorY.bottom => viewportH - offsetY - height,
    };
  }

  /// 절대 좌표 → 앵커 좌표 역변환 (존 판정 포함).
  ///
  /// 3개 존에 걸치면 중앙 배제 후 양 끝 겹침 비교.
  DockGroup updateFromAbsolute(
    double absX,
    double absY,
    double viewportW,
    double viewportH,
  ) {
    final newAnchorX = _determineAnchorX(absX, width, viewportW);
    final newAnchorY = _determineAnchorY(absY, height, viewportH);

    final newOffsetX = switch (newAnchorX) {
      AnchorX.left => absX,
      AnchorX.center => absX + width / 2 - viewportW / 2,
      AnchorX.right => viewportW - absX - width,
    };

    final newOffsetY = switch (newAnchorY) {
      AnchorY.top => absY,
      AnchorY.center => absY + height / 2 - viewportH / 2,
      AnchorY.bottom => viewportH - absY - height,
    };

    return DockGroup(
      id: id,
      root: root,
      anchorX: newAnchorX,
      anchorY: newAnchorY,
      offsetX: newOffsetX,
      offsetY: newOffsetY,
      width: width,
      height: height,
      zOrder: zOrder,
      dockedEdge: dockedEdge,
      pinned: pinned,
      headerless: headerless,
      savedState: savedState,
    );
  }

  /// 뷰포트 클램핑된 표시용 사각형 계산.
  ///
  /// 앵커 기준점을 유지한 채 반대쪽만 축소하여, 패널이 앵커에서
  /// 밀려나지 않음. 크기보다 위치 보정을 우선하여 작은 패널은
  /// 크기를 유지한 채 위치만 조정됨.
  Rect displayRect(double viewportW, double viewportH) {
    var x = absoluteX(viewportW);
    var y = absoluteY(viewportH);
    var w = width;
    var h = height;

    final effectiveH = viewportH;

    // ── X축: 앵커 기준점 고정, 반대쪽만 조정 ──
    if (w > viewportW) w = viewportW;
    switch (anchorX) {
      case AnchorX.left:
        // 좌측 고정: x 유지, 우단 초과 시 w 축소
        if (x < 0) x = 0;
        if (x + w > viewportW) {
          w = (viewportW - x).clamp(_config.groupMinWidth, w);
        }
      case AnchorX.right:
        // 우측 고정: 우단(x+w) 유지, 좌단 초과 시 w 축소
        if (x + w > viewportW) {
          x = viewportW - w;
        }
        if (x < 0) {
          w = (w + x).clamp(_config.groupMinWidth, w);
          x = 0;
        }
      case AnchorX.center:
        // 중앙 고정: 위치 밀어넣기 우선, 그래도 안 되면 축소
        if (x + w > viewportW) x = viewportW - w;
        if (x < 0) x = 0;
        if (x + w > viewportW) {
          w = (viewportW - x).clamp(_config.groupMinWidth, w);
        }
    }

    // ── Y축: 앵커 기준점 고정, 반대쪽만 조정 ──
    if (h > effectiveH) h = effectiveH;
    switch (anchorY) {
      case AnchorY.top:
        // 상단 고정: y 유지, 하단 초과 시 h 축소
        if (y < 0) y = 0;
        if (y + h > effectiveH) {
          h = (effectiveH - y).clamp(_config.groupMinHeight, h);
        }
      case AnchorY.bottom:
        // 하단 고정: 하단(y+h) 유지, 상단 초과 시 h 축소
        if (y + h > effectiveH) {
          y = effectiveH - h;
        }
        if (y < 0) {
          h = (h + y).clamp(_config.groupMinHeight, h);
          y = 0;
        }
      case AnchorY.center:
        // 중앙 고정: 위치 밀어넣기 우선, 그래도 안 되면 축소
        if (y + h > effectiveH) y = effectiveH - h;
        if (y < 0) y = 0;
        if (y + h > effectiveH) {
          h = (effectiveH - y).clamp(_config.groupMinHeight, h);
        }
    }

    return Rect.fromLTWH(x, y, w, h);
  }

  /// [clearDockedEdge]를 true로 넘기면 dockedEdge를 null로 초기화.
  /// [clearSavedState]를 true로 넘기면 savedState를 null로 초기화.
  DockGroup copyWith({
    DockNode? root,
    AnchorX? anchorX,
    AnchorY? anchorY,
    double? offsetX,
    double? offsetY,
    double? width,
    double? height,
    int? zOrder,
    ViewportEdge? dockedEdge,
    bool clearDockedEdge = false,
    bool? pinned,
    bool? headerless,
    ({
      double left,
      double top,
      double width,
      double height,
      ViewportEdge? dockedEdge,
    })? savedState,
    bool clearSavedState = false,
  }) {
    return DockGroup(
      id: id,
      root: root ?? this.root,
      anchorX: anchorX ?? this.anchorX,
      anchorY: anchorY ?? this.anchorY,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      width: width ?? this.width,
      height: height ?? this.height,
      zOrder: zOrder ?? this.zOrder,
      dockedEdge: clearDockedEdge ? null : (dockedEdge ?? this.dockedEdge),
      pinned: pinned ?? this.pinned,
      headerless: headerless ?? this.headerless,
      savedState: clearSavedState ? null : (savedState ?? this.savedState),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'root': root.toJson(),
    'anchorX': anchorX.name,
    'anchorY': anchorY.name,
    'offsetX': offsetX,
    'offsetY': offsetY,
    'width': width,
    'height': height,
    'zOrder': zOrder,
    if (dockedEdge != null) 'dockedEdge': dockedEdge!.name,
    if (pinned) 'pinned': true,
    if (headerless) 'headerless': true,
    if (savedState != null) 'savedState': {
      'left': savedState!.left,
      'top': savedState!.top,
      'width': savedState!.width,
      'height': savedState!.height,
      if (savedState!.dockedEdge != null)
        'dockedEdge': savedState!.dockedEdge!.name,
    },
  };

  factory DockGroup.fromJson(Map<String, dynamic> json) => DockGroup(
    id: json['id'] as String,
    root: DockNode.fromJson(json['root'] as Map<String, dynamic>),
    anchorX: AnchorX.values.byName(json['anchorX'] as String),
    anchorY: AnchorY.values.byName(json['anchorY'] as String),
    offsetX: (json['offsetX'] as num).toDouble(),
    offsetY: (json['offsetY'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    zOrder: json['zOrder'] as int? ?? 0,
    dockedEdge: json['dockedEdge'] != null
        ? ViewportEdge.values.where((e) => e.name == json['dockedEdge']).firstOrNull
        : null,
    pinned: json['pinned'] as bool? ?? false,
    headerless: json['headerless'] as bool? ?? false,
    savedState: _savedStateFromJson(json['savedState']),
  );

  static ({
    double left,
    double top,
    double width,
    double height,
    ViewportEdge? dockedEdge,
  })? _savedStateFromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    return (
      left: (raw['left'] as num).toDouble(),
      top: (raw['top'] as num).toDouble(),
      width: (raw['width'] as num).toDouble(),
      height: (raw['height'] as num).toDouble(),
      dockedEdge: raw['dockedEdge'] != null
          ? ViewportEdge.values
              .where((e) => e.name == raw['dockedEdge'])
              .firstOrNull
          : null,
    );
  }

  @override
  List<Object?> get props => [
    id,
    root,
    anchorX,
    anchorY,
    offsetX,
    offsetY,
    width,
    height,
    zOrder,
    dockedEdge,
    pinned,
    headerless,
    savedState,
  ];

  // ── 존 판정 ──

  static AnchorX _determineAnchorX(double absX, double w, double vw) {
    final panelRight = absX + w;
    final zone1 = vw / 3;
    final zone2 = vw * 2 / 3;

    // 3개 존에 모두 걸치면 양 끝 겹침 비교
    if (absX < zone1 && panelRight > zone2) {
      final leftOverlap = zone1 - absX;
      final rightOverlap = panelRight - zone2;
      return leftOverlap >= rightOverlap ? AnchorX.left : AnchorX.right;
    }

    // 2개 이하: 중심점 기준
    final center = absX + w / 2;
    if (center < zone1) return AnchorX.left;
    if (center < zone2) return AnchorX.center;
    return AnchorX.right;
  }

  static AnchorY _determineAnchorY(double absY, double h, double vh) {
    final panelBottom = absY + h;
    final zone1 = vh / 3;
    final zone2 = vh * 2 / 3;

    if (absY < zone1 && panelBottom > zone2) {
      final topOverlap = zone1 - absY;
      final bottomOverlap = panelBottom - zone2;
      return topOverlap >= bottomOverlap ? AnchorY.top : AnchorY.bottom;
    }

    final center = absY + h / 2;
    if (center < zone1) return AnchorY.top;
    if (center < zone2) return AnchorY.center;
    return AnchorY.bottom;
  }
}
