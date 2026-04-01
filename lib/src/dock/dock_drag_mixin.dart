import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/dock_provider.dart';
import 'dock_node_widget.dart';

/// 패널 헤더/탭 바 공통 드래그 + 호버 오버레이 로직.
///
/// [ConsumerState] + [SingleTickerProviderStateMixin]이 적용된 State에서
/// `with DockDragMixin`으로 사용.
mixin DockDragMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T>, SingleTickerProviderStateMixin<T> {
  Offset grabOffset = Offset.zero;
  Offset stackOrigin = Offset.zero;
  bool isHovered = false;
  late final AnimationController overlayController;
  late final Animation<double> overlayAnimation;

  static const Duration animationDuration = Duration(milliseconds: 150);

  /// 서브클래스가 구현: 현재 위젯의 DockDragContext.
  DockDragContext? get dragContext;

  void initDragMixin() {
    overlayController = AnimationController(
      duration: animationDuration,
      vsync: this,
    );
    overlayAnimation = CurvedAnimation(
      parent: overlayController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
  }

  void disposeDragMixin() {
    overlayController.dispose();
  }

  void onHoverChanged(bool hovered) {
    setState(() => isHovered = hovered);
    if (hovered) {
      overlayController.forward();
    } else {
      overlayController.reverse();
    }
  }

  void onDragStart(DragStartDetails details) {
    final dc = dragContext;
    if (dc == null) return;
    stackOrigin = dc.stackOrigin;

    final groups = ref.read(dockProvider).groups;
    final group = groups.where((g) => g.id == dc.groupId).firstOrNull;
    if (group == null) return;
    final cursorInStack = details.globalPosition - stackOrigin;
    grabOffset = Offset(
      cursorInStack.dx - group.absoluteX(dc.viewerSize.width),
      cursorInStack.dy - group.absoluteY(dc.viewerSize.height),
    );

    final notifier = ref.read(dockProvider.notifier);
    notifier.bringToFront(dc.groupId);
    notifier.startDrag(dc.groupId);
  }

  void onDragUpdate(DragUpdateDetails details) {
    final dc = dragContext;
    if (dc == null) return;
    final cursorInStack = details.globalPosition - stackOrigin;
    ref
        .read(dockProvider.notifier)
        .updateDrag(
          dc.groupId,
          cursorInStack - grabOffset,
          dc.viewerSize,
          cursorInStack: cursorInStack,
        );
  }

  void onDragEnd(DragEndDetails details) {
    ref.read(dockProvider.notifier).endDrag();
  }
}
