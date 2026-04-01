import 'dart:math' as math;
import 'dart:ui';

import '../models/dock_node.dart';

/// 노드 rect 정보 (도킹 감지용).
class NodeRect {
  final Rect rect;
  final List<int> path;
  final DockNode node;

  const NodeRect({required this.rect, required this.path, required this.node});
}

/// 경로를 따라 노드를 찾아 반환.
DockNode getNodeAt(DockNode root, List<int> path) {
  DockNode current = root;
  for (final index in path) {
    if (current is DockSplit) {
      assert(
        index >= 0 && index < current.children.length,
        'getNodeAt: index $index out of bounds (children: ${current.children.length})',
      );
      if (index < 0 || index >= current.children.length) return current;
      current = current.children[index];
    } else {
      assert(
        false,
        'getNodeAt: expected DockSplit but got ${current.runtimeType} with remaining path',
      );
      return current;
    }
  }
  return current;
}

/// 경로의 노드를 새 노드로 교체한 트리를 반환.
DockNode replaceNodeAt(DockNode root, List<int> path, DockNode newNode) {
  if (path.isEmpty) return newNode;

  if (root is DockSplit) {
    final index = path.first;
    assert(
      index >= 0 && index < root.children.length,
      'replaceNodeAt: index $index out of bounds (children: ${root.children.length})',
    );
    if (index < 0 || index >= root.children.length) return root;
    final newChildren = [
      for (int i = 0; i < root.children.length; i++)
        if (i == index)
          replaceNodeAt(root.children[i], path.sublist(1), newNode)
        else
          root.children[i],
    ];
    return DockSplit(
      axis: root.axis,
      children: newChildren,
      ratios: root.ratios,
    );
  }
  return newNode;
}

/// Split 노드에서 자식을 제거하고 트리를 정리.
///
/// 자식이 1개만 남으면 해당 자식으로 대체 (Split 해소).
DockNode removeChildAt(DockSplit split, int childIndex) {
  final newChildren = [...split.children]..removeAt(childIndex);
  final newRatios = [...split.ratios]..removeAt(childIndex);

  // 비율 재정규화
  final sum = newRatios.fold<double>(0, (a, b) => a + b);
  final normalizedRatios = sum > 1e-6
      ? [for (final r in newRatios) r / sum]
      : [for (int i = 0; i < newRatios.length; i++) 1.0 / newRatios.length];

  if (newChildren.length == 1) return newChildren.first;

  return DockSplit(
    axis: split.axis,
    children: newChildren,
    ratios: normalizedRatios,
  );
}

/// 그룹 내 개별 패널(리프/탭) rect를 재귀적으로 계산.
List<NodeRect> calcNodeRects(
  DockNode node,
  Rect rect,
  List<int> parentPath,
) {
  return switch (node) {
    DockLeaf() ||
    DockTabbed() => [NodeRect(rect: rect, path: parentPath, node: node)],
    DockSplit(:final axis, :final children, :final ratios) => () {
      final results = <NodeRect>[];
      double offset = 0;
      for (int i = 0; i < children.length; i++) {
        final childRect = axis == SplitAxis.horizontal
            ? Rect.fromLTWH(
                rect.left + offset,
                rect.top,
                rect.width * ratios[i],
                rect.height,
              )
            : Rect.fromLTWH(
                rect.left,
                rect.top + offset,
                rect.width,
                rect.height * ratios[i],
              );
        results.addAll(
          calcNodeRects(children[i], childRect, [...parentPath, i]),
        );
        offset += axis == SplitAxis.horizontal
            ? rect.width * ratios[i]
            : rect.height * ratios[i];
      }
      return results;
    }(),
  };
}

/// Split의 직속 자식별 rect를 계산.
List<Rect> calcDirectChildRects(DockSplit split, Rect rect) {
  final rects = <Rect>[];
  double offset = 0;
  for (int i = 0; i < split.children.length; i++) {
    final childRect = split.axis == SplitAxis.horizontal
        ? Rect.fromLTWH(
            rect.left + offset,
            rect.top,
            rect.width * split.ratios[i],
            rect.height,
          )
        : Rect.fromLTWH(
            rect.left,
            rect.top + offset,
            rect.width,
            rect.height * split.ratios[i],
          );
    rects.add(childRect);
    offset += split.axis == SplitAxis.horizontal
        ? rect.width * split.ratios[i]
        : rect.height * split.ratios[i];
  }
  return rects;
}

/// 자식 제거 후 나머지 영역의 rect를 계산.
Rect calcRemainingRect(DockSplit split, Rect rect, int removedIndex) {
  final childRects = calcDirectChildRects(split, rect);
  double left = double.infinity, top = double.infinity;
  double right = 0, bottom = 0;
  for (int i = 0; i < childRects.length; i++) {
    if (i == removedIndex) continue;
    final r = childRects[i];
    left = math.min(left, r.left);
    top = math.min(top, r.top);
    right = math.max(right, r.right);
    bottom = math.max(bottom, r.bottom);
  }
  if (left == double.infinity) return rect;
  return Rect.fromLTRB(left, top, right, bottom);
}
