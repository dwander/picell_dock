part of 'dock_node_widget.dart';


// ── 헤더리스 프레임 ──

/// 헤더 없이 콘텐츠만 표시하는 패널 프레임.
///
/// 히스토그램, 카메라 정보 등 독립 그룹일 때 사용.
/// 프레임 전체가 드래그 핸들 역할.
class _HeaderlessFrame extends ConsumerStatefulWidget {
  final String panelId;
  final DockDragContext? dragContext;

  const _HeaderlessFrame({
    required this.panelId,
    this.dragContext,
  });

  @override
  ConsumerState<_HeaderlessFrame> createState() => _HeaderlessFrameState();
}

class _HeaderlessFrameState extends ConsumerState<_HeaderlessFrame>
    with SingleTickerProviderStateMixin {
  Offset _grabOffset = Offset.zero;
  Offset _stackOrigin = Offset.zero;

  late final AnimationController _overlayCtrl;
  late final CurvedAnimation _overlayAnim;

  static const Duration _overlayDuration = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _overlayCtrl = AnimationController(
      duration: _overlayDuration,
      vsync: this,
    );
    _overlayAnim = CurvedAnimation(
      parent: _overlayCtrl,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _overlayCtrl.dispose();
    super.dispose();
  }

  void _onHoverChanged(bool hovering) {
    if (hovering) {
      _overlayCtrl.forward();
    } else {
      _overlayCtrl.reverse();
    }
  }

  void _onDragStart(DragStartDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    _stackOrigin = dc.stackOrigin;
    final cursorInStack = details.globalPosition - _stackOrigin;
    final groups = ref.read(dockProvider).groups;
    final group = groups.where((g) => g.id == dc.groupId).firstOrNull;
    if (group == null) return;
    _grabOffset = Offset(
      cursorInStack.dx - group.absoluteX(dc.viewerSize.width),
      cursorInStack.dy - group.absoluteY(dc.viewerSize.height),
    );
    final notifier = ref.read(dockProvider.notifier);
    notifier.bringToFront(dc.groupId);
    notifier.startDrag(dc.groupId);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dc = widget.dragContext;
    if (dc == null) return;
    final cursorInStack = details.globalPosition - _stackOrigin;
    ref.read(dockProvider.notifier).updateDrag(
      dc.groupId,
      cursorInStack - _grabOffset,
      dc.viewerSize,
      cursorInStack: cursorInStack,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    ref.read(dockProvider.notifier).endDrag();
  }

  @override
  Widget build(BuildContext context) {
    final dc = widget.dragContext;
    final delegate = DockTheme.of(context).panelDelegate;
    final panelLayout = delegate.buildOverlayLayout?.call(widget.panelId, ref) ?? const DockOverlayLayout();
    final dockedEdge = dc == null
        ? null
        : ref.watch(dockProvider.select(
            (s) => s.groups
                .where((g) => g.id == dc.groupId)
                .firstOrNull
                ?.dockedEdge,
          ));
    final rightButtons = [
      ...panelLayout.right,
      if (dockedEdge != null)
        _HeaderActionButton(
          icon: PhosphorIconsRegular.pictureInpicture,
          tooltip: '플로팅 모드로 전환',
          onPressed: () => ref
              .read(dockProvider.notifier)
              .undockFromViewportEdge(dc!.groupId),
          buttonSize: 24.0,
          iconSize: 18.0,
          flat: true,
        ),
    ];
    final hasOverlay = panelLayout.isNotEmpty || rightButtons.isNotEmpty;

    return Listener(
      onPointerDown: (_) {
        if (dc != null) {
          ref.read(dockProvider.notifier).bringToFront(dc.groupId);
        }
        ref.read(dockProvider.notifier).focusPanel(widget.panelId);
      },
      behavior: HitTestBehavior.translucent,
      child: MouseRegion(
        onEnter: hasOverlay ? (_) => _onHoverChanged(true) : null,
        onExit: hasOverlay ? (_) => _onHoverChanged(false) : null,
        child: GestureDetector(
          onPanStart: dc == null ? null : _onDragStart,
          onPanUpdate: dc == null ? null : _onDragUpdate,
          onPanEnd: dc == null ? null : _onDragEnd,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Builder(
              builder: (context) {
                final cs = DockTheme.of(context).colorScheme;
                final cfg = DockTheme.of(context).config;
                return Stack(
                  children: [
                    delegate.buildPanel(widget.panelId),
                    if (hasOverlay)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: SizeTransition(
                          sizeFactor: _overlayAnim,
                          axisAlignment: -1.0,
                          child: Container(
                            height: cfg.headerOverlayHeight,
                            decoration: BoxDecoration(
                              color: cs.headerOverlay,
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(cfg.headerOverlayRadius),
                                bottomRight: Radius.circular(cfg.headerOverlayRadius),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: _OverlayZoneRow(
                              left: panelLayout.left,
                              center: panelLayout.center,
                              right: rightButtons,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
