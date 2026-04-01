import 'package:flutter/material.dart';

import '../theme/dock_theme.dart';

/// 도킹 프리뷰 하이라이트 오버레이.
///
/// 드래그 중 도킹 대상 영역을 반투명 액센트로 표시.
class DockDropIndicator extends StatelessWidget {
  final Rect rect;
  final bool isViewportEdge;

  const DockDropIndicator({
    super.key,
    required this.rect,
    this.isViewportEdge = false,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: DockTheme.of(context).colorScheme.accent.withValues(alpha: 0.12),
            border: Border.all(color: DockTheme.of(context).colorScheme.accent.withValues(alpha: 0.5)),
            borderRadius: isViewportEdge ? null : BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}
