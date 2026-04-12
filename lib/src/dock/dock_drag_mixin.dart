import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/dock_provider.dart';
import 'dock_node_widget.dart';
import '../theme/dock_theme.dart';

/// 패널 헤더/탭 바 공통 드래그 + 호버 오버레이 로직.
///
/// [ConsumerState] + [SingleTickerProviderStateMixin]이 적용된 State에서
/// `with DockDragMixin`으로 사용.
mixin DockDragMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T>, TickerProviderStateMixin<T> {
  Offset grabOffset = Offset.zero;
  Offset stackOrigin = Offset.zero;
  bool isHovered = false;
  late final AnimationController overlayController;
  late final Animation<double> overlayAnimation;

  static const Duration animationDuration = Duration(milliseconds: 150);

  // ── 고스트 관련 필드 ──
  bool undockPending = false;
  OverlayEntry? _ghostEntry;
  Offset _ghostPosition = Offset.zero;
  Size _ghostSize = const Size(200, 120);

  /// 현재 고스트 크기 (도킹 프리뷰 계산용).
  Size get ghostSize => _ghostSize;

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

  // ── 고스트 메서드 ──

  void showGhost(String label, Offset globalPosition, {Size? nodeSize}) {
    if (nodeSize != null && nodeSize.width > 0 && nodeSize.height > 0) {
      _ghostSize = nodeSize;
    }
    _ghostPosition = Offset(
      globalPosition.dx - _ghostSize.width / 2,
      globalPosition.dy - 10,
    );
    _ghostEntry = OverlayEntry(builder: (_) => _buildGhost(label));
    Overlay.of(context).insert(_ghostEntry!);
  }

  void updateGhost(Offset globalPosition) {
    _ghostPosition = Offset(
      globalPosition.dx - _ghostSize.width / 2,
      globalPosition.dy - 10,
    );
    _ghostEntry?.markNeedsBuild();
  }

  void removeGhost() {
    _ghostEntry?.remove();
    _ghostEntry = null;
  }

  Widget _buildGhost(String label) {
    final theme = DockTheme.of(context);
    final cs = theme.colorScheme;
    final cfg = theme.config;
    final textTheme = Theme.of(context).textTheme;
    return Positioned(
      left: _ghostPosition.dx,
      top: _ghostPosition.dy,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.85,
            child: Container(
              width: _ghostSize.width,
              height: _ghostSize.height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: cs.panelBackground,
                borderRadius: BorderRadius.circular(cfg.groupBorderRadius),
                border: Border.all(color: cs.border),
                boxShadow: cs.groupShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: cfg.panelHeaderHeight,
                    color: cs.bg0,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label,
                      style: textTheme.labelSmall?.copyWith(
                        color: cs.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
