import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../models/dock_group.dart';
import '../models/dock_node.dart';
import '../providers/dock_node_tree.dart';
import '../providers/dock_provider.dart';
import '../theme/dock_theme.dart';
import '../widgets/border_glow_effect.dart';
import '../widgets/border_scan_effect.dart';
import '../widgets/edge_dock_effect.dart';
import '../widgets/edge_glow_decoration.dart';
import 'dock_node_widget.dart';
import 'dock_resize_handle.dart';

/// 단일 DockGroup을 Positioned 박스로 렌더링.
///
/// 그룹 헤더 없이 내부 패널 헤더/탭 바가 드래그 핸들 역할.
/// 최초 마운트 시 스케일 + 페이드 등장 애니메이션 재생.
class DockGroupWidget extends ConsumerStatefulWidget {
  final DockGroup group;
  final Size viewerSize;
  final GlobalKey stackKey;

  const DockGroupWidget({
    super.key,
    required this.group,
    required this.viewerSize,
    required this.stackKey,
  });

  @override
  ConsumerState<DockGroupWidget> createState() => _DockGroupWidgetState();
}

class _DockGroupWidgetState extends ConsumerState<DockGroupWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cleanModeController;
  late final CurvedAnimation _cleanModeCurve;
  final _scanController = BorderScanController();
  final _dockGlowController = BorderGlowController();
  final _focusFlashController = BorderGlowController();
  final _edgeDockController = EdgeDockEffectController();

  /// 초기 레이아웃 로드 중 발생하는 dockedEdge 변경에서
  /// 이펙트가 트리거되지 않도록 두 번째 프레임 이후에 true로 설정.
  bool _hasSettled = false;

  /// 패널 그룹 호버 상태 — 뱃지 버튼 표시 제어.
  bool _isHovered = false;

  /// 노드 수준 스캔 이펙트의 대상 rect (그룹 내 상대 좌표).
  /// null이면 노드 스캔 오버레이 비활성.
  Rect? _nodeScanRect;

  /// 이전 프레임의 animateHide 값. false→true 전환 시 스냅 처리에 사용.
  bool _prevAnimateHide = true;

  static const Duration _cleanModeDuration = Duration(milliseconds: 400);

  /// 보더 글로우 애니메이션 지속 시간 (오버레이 유지용).
  static const Duration _glowDuration = Duration(milliseconds: 700);

  /// 뱃지 버튼이 패널 옆으로 돌출되는 폭 — 호버 영역 확장에 사용.
  static const double _badgeOverhang = _GroupBadgeButtons._sideOffset +
      _GroupBadgeButtons._containerPadding * 2 +
      _GroupBadgeButtons._buttonSize;

  @override
  void initState() {
    super.initState();
    _cleanModeController = AnimationController(
      duration: _cleanModeDuration,
      vsync: this,
    );
    _cleanModeCurve = CurvedAnimation(
      parent: _cleanModeController,
      curve: Curves.easeInOutCubic,
    );
    // 저장된 레이아웃 로드(첫 번째 프레임 콜백)가 끝난 뒤 settled 처리.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hasSettled = true;
        // 언도킹으로 새로 생성된 그룹: 마운트 후 스캔 트리거.
        _consumeScanPending();
      });
    });
  }

  /// scanPendingNodes에 이 그룹이 있으면 스캔 트리거 후 제거.
  void _consumeScanPending() {
    final groupId = widget.group.id;
    final pending = ref.read(dockProvider).scanPendingNodes;
    final path = pending[groupId];
    if (path == null) return;

    ref.read(dockProvider.notifier).clearScanPending(groupId);

    if (path.isEmpty) {
      // 그룹 전체 글로우 (언도킹으로 새로 생성된 그룹)
      _dockGlowController.trigger();
    } else {
      // 노드 수준 스캔 (도킹으로 합쳐진 노드)
      final group = widget.group;
      final displayRect = ref.read(dockProvider).displayRects[groupId];
      final groupSize = displayRect != null
          ? Size(displayRect.width, displayRect.height)
          : Size(group.width, group.height);
      final nodeRect = calcNodeRectAt(
        group.root,
        Rect.fromLTWH(0, 0, groupSize.width, groupSize.height),
        path,
      );
      setState(() => _nodeScanRect = nodeRect);
      // 애니메이션 완료 후 오버레이 제거.
      Future.delayed(_glowDuration, () {
        if (mounted) setState(() => _nodeScanRect = null);
      });
    }
  }

  @override
  void didUpdateWidget(DockGroupWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final layoutSettled = ref.read(dockProvider).layoutSettled;
    if (layoutSettled && widget.group.dockedEdge != oldWidget.group.dockedEdge) {
      if (widget.group.dockedEdge != null) {
        // 플로팅 → 엣지 패널: 도킹 방향 테두리 글로우 펄스
        _edgeDockController.trigger(widget.group.dockedEdge!);
      } else {
        // 엣지 패널 → 플로팅: 보더 스캔 이펙트
        _scanController.trigger();
      }
    }
  }

  @override
  void dispose() {
    _cleanModeCurve.dispose();
    _cleanModeController.dispose();
    super.dispose();
  }

  /// 패널 중심에서 가장 가까운 뷰포트 가장자리 방향으로
  /// 완전히 밀어내는 오프셋을 계산.
  Offset _computeSlideOffset(Rect rect, Size viewerSize) {
    final centerX = rect.left + rect.width / 2;
    final centerY = rect.top + rect.height / 2;

    final distLeft = centerX;
    final distRight = viewerSize.width - centerX;
    final distTop = centerY;
    final distBottom = viewerSize.height - centerY;

    final minDist = [distLeft, distRight, distTop, distBottom]
        .reduce((a, b) => a < b ? a : b);

    if (minDist == distLeft) {
      return Offset(-(rect.left + rect.width), 0);
    } else if (minDist == distRight) {
      return Offset(viewerSize.width - rect.left, 0);
    } else if (minDist == distTop) {
      return Offset(0, -(rect.top + rect.height));
    } else {
      return Offset(0, viewerSize.height - rect.top);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final viewerSize = widget.viewerSize;
    final theme = DockTheme.of(context);
    final cs = theme.colorScheme;
    final cfg = theme.config;

    // 도킹/언도킹 보더 스캔 트리거 감지.
    ref.listen(
      dockProvider.select(
        (s) => s.scanPendingNodes.containsKey(group.id),
      ),
      (prev, next) {
        if (next && _hasSettled) _consumeScanPending();
      },
    );

    // 키보드 포커스 전환 시 테두리 플래시 (클릭은 제외).
    ref.listen(
      dockProvider.select((s) => s.flashPanelId),
      (_, flashId) {
        if (flashId != null && group.root.collectPanelIds().contains(flashId)) {
          _focusFlashController.trigger();
        }
      },
    );

    final dockState = ref.watch(dockProvider);
    final rect =
        dockState.displayRects[group.id] ??
        Rect.fromLTWH(
          group.absoluteX(viewerSize.width),
          group.absoluteY(viewerSize.height),
          group.width,
          group.height,
        );

    final focusedPanelId = dockState.focusedPanelId;
    final isFocused =
        focusedPanelId != null &&
        group.root.collectPanelIds().contains(focusedPanelId);
    final displaySettings = DockTheme.of(context).displaySettings;
    final showFocusHighlight = displaySettings.showFocusHighlight;

    final shouldHide = displaySettings.hideAll ||
        (displaySettings.hideUnpinned && !group.pinned);
    // 이전·현재 프레임 모두 animateHide가 true일 때만 애니메이션.
    // false→true 전환(전체화면 복귀 등)에서는 스냅 처리.
    final shouldAnimate = displaySettings.animateHide && _prevAnimateHide;
    _prevAnimateHide = displaySettings.animateHide;
    if (shouldAnimate) {
      if (shouldHide) {
        _cleanModeController.forward();
      } else {
        _cleanModeController.reverse();
      }
    } else {
      _cleanModeController.value = shouldHide ? 1.0 : 0.0;
    }

    final slideOffset = _computeSlideOffset(rect, viewerSize);

    // 최대화 그룹은 뱃지를 숨기므로 overhang 불필요 — 0으로 줄여서 인접 패널의
    // 리사이즈 핸들이 자기 영역에 덮이지 않도록 한다.
    final overhang = group.savedState != null ? 0.0 : _badgeOverhang;

    // 뱃지가 좌우로 돌출되므로 호버 영역을 양쪽으로 확장
    return Positioned(
      left: rect.left - overhang,
      top: rect.top,
      width: rect.width + overhang * 2,
      height: rect.height,
      child: AnimatedBuilder(
        animation: _cleanModeCurve,
        builder: (context, child) {
          final t = _cleanModeCurve.value;
          return Transform.translate(
            offset: slideOffset * t,
            child: Opacity(opacity: (1.0 - t).clamp(0.0, 1.0), child: child),
          );
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 패널 본체 — Padding으로 중앙 배치
              Padding(
                padding: EdgeInsets.symmetric(horizontal: overhang),
                child: BorderGlowEffect(
                  controller: _focusFlashController,
                  color: cs.borderFocused,
                  borderRadius: cfg.groupBorderRadius,
                  duration: const Duration(milliseconds: 400),
                  intensity: 0.35,
                  child: EdgeDockEffect(
                    controller: _edgeDockController,
                    color: cs.accent,
                    borderRadius: cfg.groupBorderRadius,
                    child: BorderScanEffect(
                      controller: _scanController,
                      color: cs.accent,
                      borderRadius: cfg.groupBorderRadius,
                    child: BorderGlowEffect(
                      controller: _dockGlowController,
                      color: cs.dockScanAccent,
                      borderRadius: cfg.groupBorderRadius,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          GestureDetector(
                            onTap: () => ref
                                .read(dockProvider.notifier)
                                .bringToFront(group.id),
                            child: Container(
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: cs.panelBackground,
                                borderRadius: BorderRadius.circular(
                                  cfg.groupBorderRadius,
                                ),
                                boxShadow: cs.groupShadow,
                              ),
                              foregroundDecoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  cfg.groupBorderRadius,
                                ),
                                border: Border.all(color: cs.border),
                              ),
                              child: DockNodeWidget(
                                node: group.root,
                                dragContext: DockDragContext(
                                  groupId: group.id,
                                  viewerSize: viewerSize,
                                  stackKey: widget.stackKey,
                                ),
                              ),
                            ),
                          ),
                          // 노드 수준 보더 글로우 오버레이
                          if (_nodeScanRect != null)
                            Positioned(
                              left: _nodeScanRect!.left,
                              top: _nodeScanRect!.top,
                              width: _nodeScanRect!.width,
                              height: _nodeScanRect!.height,
                              child: IgnorePointer(
                                child: _NodeGlowOverlay(
                                  color: cs.dockScanAccent,
                                ),
                              ),
                            ),
                          // 포커스 인디케이터 — 테두리 위에 오버레이
                          if (isFocused && showFocusHighlight)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: EdgeGlowDecoration(
                                    color: cs.borderFocused,
                                    borderRadius: cfg.groupBorderRadius,
                                  ),
                                ),
                              ),
                            ),
                          // 리사이즈 핸들 표시 조건:
                          // - 플로팅 그룹에서 모든 패널이 접혀 있으면 불가
                          // - 최대화 상태면 불가 (윈도우 최대화처럼 가장자리 리사이즈 잠금)
                          if ((group.dockedEdge != null ||
                                  !group.root.isAllCollapsed) &&
                              group.savedState == null)
                            DockResizeHandles(
                              groupId: group.id,
                              viewerSize: viewerSize,
                              stackKey: widget.stackKey,
                              dockedEdge: group.dockedEdge,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
              // 뱃지 버튼 — 확장된 영역 내에 배치 (overflow 없이 히트 테스트 정상 작동)
              _GroupBadgeButtons(
                group: group,
                rect: rect,
                viewerSize: viewerSize,
                isVisible: _isHovered,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 뱃지 버튼 컨테이너 ──

/// 패널 그룹 상단 모서리에 표시되는 액션 버튼 (핀/닫기).
///
/// 뷰포트 중심 기준으로 바깥쪽 모서리에 배치.
/// 부모 위젯의 호버 상태([isVisible])로 표시 여부 제어.
class _GroupBadgeButtons extends ConsumerWidget {
  final DockGroup group;
  final Rect rect;
  final Size viewerSize;
  final bool isVisible;

  /// 뱃지 버튼 크기
  static const double _buttonSize = 18.0;
  static const double _iconSize = 12.0;
  static const double _spacing = 2.0;
  static const double _containerPadding = 2.0;

  /// 패널 프레임 옆으로 돌출되는 거리
  static const double _sideOffset = 4.0;

  /// 상단에서의 마진
  static const double _topMargin = 6.0;

  const _GroupBadgeButtons({
    required this.group,
    required this.rect,
    required this.viewerSize,
    required this.isVisible,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 최대화 상태에서는 핀/닫기 뱃지 숨김 — 화면을 거의 덮어 호버 영역이 과도해짐.
    if (group.savedState != null) {
      return const SizedBox.shrink();
    }

    final delegate = DockTheme.of(context).panelDelegate;
    final cs = DockTheme.of(context).colorScheme;
    final panelIds = group.root.collectPanelIds();
    final hasClosable = panelIds.isNotEmpty && panelIds.every(delegate.isClosable);

    // 뷰포트 중심 대비 패널 위치 → 안쪽 방향에 배치
    final panelCenterX = rect.left + rect.width / 2;
    final placeOnRight = panelCenterX < viewerSize.width / 2;

    // 컨테이너 전체 폭 (패딩 + 버튼)
    final containerWidth = _containerPadding * 2 + _buttonSize;

    // 외부 Stack 기준: 패널은 _badgeOverhang만큼 안쪽에서 시작
    // 패널 프레임 바깥에 딱 붙도록 배치
    final overhang = _DockGroupWidgetState._badgeOverhang;

    return Positioned(
      top: _topMargin,
      left: placeOnRight ? null : overhang - containerWidth + _sideOffset,
      right: placeOnRight ? overhang - containerWidth + _sideOffset : null,
      child: IgnorePointer(
        ignoring: !isVisible,
        child: AnimatedOpacity(
          opacity: isVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            padding: const EdgeInsets.all(_containerPadding),
            decoration: BoxDecoration(
              color: cs.bg0.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: cs.border.withValues(alpha: 0.8),
                width: 0.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BadgeButton(
                  icon: group.pinned
                      ? PhosphorIconsFill.pushPin
                      : PhosphorIconsRegular.pushPin,
                  tooltip: group.pinned ? '핀 해제' : '핀 고정',
                  isActive: group.pinned,
                  onPressed: () => ref
                      .read(dockProvider.notifier)
                      .togglePin(group.id),
                  size: _buttonSize,
                  iconSize: _iconSize,
                ),
                if (hasClosable) ...[
                  SizedBox(height: _spacing),
                  _BadgeButton(
                    icon: PhosphorIconsRegular.x,
                    tooltip: '닫기',
                    onPressed: () => ref
                        .read(dockProvider.notifier)
                        .removeGroup(group.id),
                    size: _buttonSize,
                    iconSize: _iconSize,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 뱃지 영역의 소형 액션 버튼.
class _BadgeButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;
  final bool isActive;

  const _BadgeButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.size,
    required this.iconSize,
    this.isActive = false,
  });

  @override
  State<_BadgeButton> createState() => _BadgeButtonState();
}

class _BadgeButtonState extends State<_BadgeButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = DockTheme.of(context).colorScheme;
    final color = widget.isActive
        ? cs.accent
        : _isHovered
            ? cs.textSecondary
            : cs.textHint;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Center(
              child: Icon(icon, size: widget.iconSize, color: color),
            ),
          ),
        ),
      ),
    );
  }

  IconData get icon => widget.icon;
}

// ── 노드 수준 보더 글로우 오버레이 ──

/// 마운트 시 자동으로 보더 글로우 이펙트를 재생하는 오버레이.
///
/// [_DockGroupWidgetState]가 도킹으로 합쳐진 노드 위에 배치하며,
/// 애니메이션 완료 후 부모에서 제거된다.
class _NodeGlowOverlay extends StatefulWidget {
  final Color color;

  const _NodeGlowOverlay({required this.color});

  @override
  State<_NodeGlowOverlay> createState() => _NodeGlowOverlayState();
}

class _NodeGlowOverlayState extends State<_NodeGlowOverlay> {
  final _controller = BorderGlowController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.trigger();
    });
  }

  @override
  Widget build(BuildContext context) {
    return BorderGlowEffect(
      controller: _controller,
      color: widget.color,
      child: const SizedBox.expand(),
    );
  }
}
