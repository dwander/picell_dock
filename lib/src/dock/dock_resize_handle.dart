import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dock_group.dart';
import '../providers/dock_provider.dart';
import '../theme/dock_theme.dart';

/// 8방향 리사이즈 방향.
enum ResizeEdge {
  top,
  bottom,
  left,
  right,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// 리사이즈 핸들의 히트 영역 크기.
const double _handleThickness = 6.0;
const double _cornerSize = 12.0;

/// DockGroup 테두리에 배치되는 리사이즈 핸들.
///
/// 투명한 히트 영역으로 커서 변경 + 드래그 리사이즈 처리.
/// 절대 좌표 기반으로 뷰포트 이탈 후 재진입 시에도 정확히 보정.
class DockResizeHandles extends StatelessWidget {
  final String groupId;
  final Size viewerSize;
  final GlobalKey stackKey;

  /// 엣지 패널일 경우 뷰어 방향 단일 핸들만 활성화.
  final ViewportEdge? dockedEdge;

  const DockResizeHandles({
    super.key,
    required this.groupId,
    required this.viewerSize,
    required this.stackKey,
    this.dockedEdge,
  });

  static const _edgeHandles = {
    ViewportEdge.left:  [ResizeEdge.right],
    ViewportEdge.right: [ResizeEdge.left],
  };

  @override
  Widget build(BuildContext context) {
    final allowedEdges = dockedEdge != null
        ? _edgeHandles[dockedEdge]!
        : ResizeEdge.values.toList();

    return Stack(
      children: [
        for (final edge in allowedEdges)
          _ResizeHandle(
            edge: edge,
            groupId: groupId,
            viewerSize: viewerSize,
            stackKey: stackKey,
          ),
      ],
    );
  }
}

class _ResizeHandle extends ConsumerStatefulWidget {
  final ResizeEdge edge;
  final String groupId;
  final Size viewerSize;
  final GlobalKey stackKey;

  const _ResizeHandle({
    required this.edge,
    required this.groupId,
    required this.viewerSize,
    required this.stackKey,
  });

  @override
  ConsumerState<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends ConsumerState<_ResizeHandle> {
  Offset _stackOrigin = Offset.zero;
  Offset _startCursor = Offset.zero;
  late double _startLeft;
  late double _startTop;
  late double _startWidth;
  late double _startHeight;
  late double _minWidth;
  late double _minHeight;

  Offset _getStackOrigin() {
    final renderBox =
        widget.stackKey.currentContext?.findRenderObject() as RenderBox?;
    return renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    final config = DockTheme.of(context).config;
    _minWidth = config.groupMinWidth;
    _minHeight = config.groupMinHeight;
    return Positioned(
      left: _posLeft,
      right: _posRight,
      top: _posTop,
      bottom: _posBottom,
      width: _width,
      height: _height,
      child: MouseRegion(
        cursor: _cursor,
        child: GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          behavior: HitTestBehavior.translucent,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  void _onPanStart(DragStartDetails details) {
    _stackOrigin = _getStackOrigin();
    _startCursor = details.globalPosition - _stackOrigin;

    final notifier = ref.read(dockProvider.notifier);
    final group = ref
        .read(dockProvider)
        .groups
        .firstWhereOrNull((g) => g.id == widget.groupId);
    if (group == null) return;

    if (group.dockedEdge != null) {
      // 엣지 패널: zOrder 변경 없이 리사이즈 상태만 시작
      notifier.startResize(widget.groupId);
    } else {
      // 플로팅 패널: bringToFront → startResize(commitDisplayRect 포함)
      notifier.bringToFront(widget.groupId);
      notifier.startResize(widget.groupId);
    }

    _startLeft = group.absoluteX(widget.viewerSize.width);
    _startTop = group.absoluteY(widget.viewerSize.height);
    _startWidth = group.width;
    _startHeight = group.height;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final cursor = details.globalPosition - _stackOrigin;
    final dx = cursor.dx - _startCursor.dx;
    final dy = cursor.dy - _startCursor.dy;

    // 엣지 패널: 뷰어 방향 핸들 하나만 활성화 → resizeEdgePanel 호출
    final group = ref
        .read(dockProvider)
        .groups
        .firstWhereOrNull((g) => g.id == widget.groupId);
    if (group?.dockedEdge != null) {
      final newSize = switch (widget.edge) {
        ResizeEdge.right => _startWidth + dx,
        ResizeEdge.left  => _startWidth - dx,
        ResizeEdge.top   => _startHeight - dy,
        _ => null,
      };
      if (newSize != null) {
        ref.read(dockProvider.notifier).resizeEdgePanel(widget.groupId, newSize);
      }
      return;
    }

    double newLeft = _startLeft;
    double newTop = _startTop;
    double newWidth = _startWidth;
    double newHeight = _startHeight;

    final edge = widget.edge;

    // 좌측 엣지: left 이동 + width 조절
    if (edge == ResizeEdge.left ||
        edge == ResizeEdge.topLeft ||
        edge == ResizeEdge.bottomLeft) {
      final maxDx = _startWidth - _minWidth;
      final clampedDx = dx.clamp(-_startLeft, maxDx);
      newLeft = _startLeft + clampedDx;
      newWidth = _startWidth - clampedDx;
    }

    // 우측 엣지: width만 조절
    if (edge == ResizeEdge.right ||
        edge == ResizeEdge.topRight ||
        edge == ResizeEdge.bottomRight) {
      newWidth = (_startWidth + dx).clamp(
        _minWidth,
        widget.viewerSize.width - _startLeft,
      );
    }

    // 상단 엣지: top 이동 + height 조절
    if (edge == ResizeEdge.top ||
        edge == ResizeEdge.topLeft ||
        edge == ResizeEdge.topRight) {
      final maxDy = _startHeight - _minHeight;
      final clampedDy = dy.clamp(-_startTop, maxDy);
      newTop = _startTop + clampedDy;
      newHeight = _startHeight - clampedDy;
    }

    // 하단 엣지: height만 조절
    if (edge == ResizeEdge.bottom ||
        edge == ResizeEdge.bottomLeft ||
        edge == ResizeEdge.bottomRight) {
      newHeight = (_startHeight + dy).clamp(
        _minHeight,
        widget.viewerSize.height - _startTop,
      );
    }

    ref
        .read(dockProvider.notifier)
        .resizeGroup(
          widget.groupId,
          left: newLeft,
          top: newTop,
          width: newWidth,
          height: newHeight,
        );
  }

  void _onPanEnd(DragEndDetails details) {
    ref.read(dockProvider.notifier).endResize(widget.groupId);
  }

  // ── Positioned 레이아웃 ──

  double? get _posLeft => switch (widget.edge) {
    ResizeEdge.left || ResizeEdge.top || ResizeEdge.bottom => 0,
    ResizeEdge.topLeft || ResizeEdge.bottomLeft => 0,
    ResizeEdge.right || ResizeEdge.topRight || ResizeEdge.bottomRight => null,
  };

  double? get _posRight => switch (widget.edge) {
    ResizeEdge.right || ResizeEdge.top || ResizeEdge.bottom => 0,
    ResizeEdge.topRight || ResizeEdge.bottomRight => 0,
    ResizeEdge.left || ResizeEdge.topLeft || ResizeEdge.bottomLeft => null,
  };

  double? get _posTop => switch (widget.edge) {
    ResizeEdge.top || ResizeEdge.left || ResizeEdge.right => 0,
    ResizeEdge.topLeft || ResizeEdge.topRight => 0,
    ResizeEdge.bottom ||
    ResizeEdge.bottomLeft ||
    ResizeEdge.bottomRight => null,
  };

  double? get _posBottom => switch (widget.edge) {
    ResizeEdge.bottom || ResizeEdge.left || ResizeEdge.right => 0,
    ResizeEdge.bottomLeft || ResizeEdge.bottomRight => 0,
    ResizeEdge.top || ResizeEdge.topLeft || ResizeEdge.topRight => null,
  };

  double? get _width => switch (widget.edge) {
    ResizeEdge.left || ResizeEdge.right => _handleThickness,
    ResizeEdge.topLeft ||
    ResizeEdge.topRight ||
    ResizeEdge.bottomLeft ||
    ResizeEdge.bottomRight => _cornerSize,
    ResizeEdge.top || ResizeEdge.bottom => null,
  };

  double? get _height => switch (widget.edge) {
    ResizeEdge.top || ResizeEdge.bottom => _handleThickness,
    ResizeEdge.topLeft ||
    ResizeEdge.topRight ||
    ResizeEdge.bottomLeft ||
    ResizeEdge.bottomRight => _cornerSize,
    ResizeEdge.left || ResizeEdge.right => null,
  };

  MouseCursor get _cursor => switch (widget.edge) {
    ResizeEdge.top || ResizeEdge.bottom => SystemMouseCursors.resizeUpDown,
    ResizeEdge.left || ResizeEdge.right => SystemMouseCursors.resizeLeftRight,
    ResizeEdge.topLeft ||
    ResizeEdge.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    ResizeEdge.topRight ||
    ResizeEdge.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
  };
}
