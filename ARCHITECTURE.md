# picell_dock — 내부 구조 문서

소스코드 수정 시 빠른 파악을 위한 참조 문서.

---

## 디렉터리 구조

```
lib/src/
├── config/
│   ├── dock_config.dart          # 레이아웃 크기 상수 (const 생성자)
│   └── dock_settings.dart        # 앱별 동작 설정 (호스트 앱에서 주입)
├── models/
│   ├── dock_node.dart            # DockNode sealed class (Leaf/Split/Tabbed) + DockNodeUtils extension
│   └── dock_group.dart           # DockGroup 모델 + 앵커 좌표계
├── providers/
│   ├── dock_state.dart           # DockState, DockPreview, DockEdge 모델
│   ├── dock_node_tree.dart       # 순수 트리 유틸리티 (getNodeAt, replaceNodeAt 등)
│   ├── dock_provider.dart        # DockNotifier 상태 관리 + 도킹 로직
│   ├── dock_settings_provider.dart
│   └── panel_zoom_provider.dart  # 패널별 줌 배율
├── services/
│   └── dock_layout_service.dart  # JSON 레이아웃 저장/복원 (Flutter 무의존)
├── theme/
│   ├── dock_color_scheme.dart    # 색상 집합 (기본값: Gruvbox 다크)
│   └── dock_theme.dart           # InheritedWidget + DockPanelDelegate 등
├── dock/
│   ├── dock_overlay.dart         # 최상위 렌더링 위젯
│   ├── dock_group_widget.dart    # DockGroup → Positioned 박스
│   ├── dock_node_widget.dart     # DockNode 트리 재귀 렌더링 + 공통 위젯
│   ├── dock_tab_bar.dart         # (part) 탭 바 + 탭 드래그/분리 로직
│   ├── dock_headerless_frame.dart # (part) 헤더리스 패널 프레임
│   ├── dock_resize_handle.dart   # 8방향 리사이즈 핸들
│   ├── dock_drag_mixin.dart      # 그룹 드래그 공통 Mixin
│   ├── dock_drop_indicator.dart  # 도킹 대상 하이라이트
│   └── dock_grid_overlay.dart    # 드래그 중 스냅 그리드 시각화
└── widgets/
    ├── border_scan_effect.dart   # 플로팅 전환 시 보더 스캔 이펙트
    ├── edge_dock_effect.dart     # 엣지 도킹 시 글로우 펄스 이펙트
    ├── edge_glow_decoration.dart # 포커스 테두리 글로우 (CustomPainter)
    └── panel_zoom_wrapper.dart   # 패널 줌 래퍼 + PanelScale InheritedWidget
```

---

## 파일 간 의존 관계

```
dock_layout_service ──────────────────────────────────── (Flutter 무의존)
       ↓ uses
dock_provider ← dock_settings_provider
       ↓ uses
dock_node_widget  ←────────────────── dock_drag_mixin
       ↑                                    ↑
dock_group_widget ──────────────────────────┘
       ↑
dock_overlay  (최상위, DockGridOverlay + DockGroupWidget + DockDropIndicator)
```

**핵심 규칙:** `dock_layout_service`는 순수 Dart (Flutter 미사용). `dock_provider`는 Flutter 위젯 없이 Riverpod만 사용.

---

## 상태 관리 (DockState)

### DockState 필드

```dart
class DockState {
  List<DockGroup> groups;           // 모든 그룹 (zOrder 오름차순 저장)
  String? draggingGroupId;          // 드래그 중인 그룹 ID
  String? resizingGroupId;          // 리사이즈 중인 그룹 ID
  DockPreview? dockPreview;         // 도킹 프리뷰 (하이라이트 rect)
  Size viewerSize;                  // 뷰포트 크기
  String? focusedPanelId;           // 포커스 패널 ID
  Map<String, Rect> displayRects;   // 렌더링용 rect (클램핑/회피 후)
}
```

`displayRects`는 `groups`에서 매 `_setState` 호출마다 재계산된다. 위젯은 `groups`가 아닌 **`displayRects`를 읽어 위치를 결정**한다.

### displayRects 계산 3단계

```
1. 엣지 패널
   → left: x=0,          y=0, w=group.width,       h=viewerSize.height
   → right: x=vs.w-w,    y=0, w=group.width,       h=viewerSize.height

2. 뷰포트 클램핑 (플로팅)
   → 그룹이 뷰포트 밖으로 나가지 않도록 이동

3. 자동 회피 (allowAutoAvoidance=true)
   → 같은 앵커 영역 그룹 간 겹침 → 1축으로 밀어내기
```

### 상태 변경 흐름

```
위젯 제스처 이벤트
    │
    ▼
dockProvider.notifier.someMethod()
    │
    ▼
DockNotifier._setState(newState)
    ├─ _computeDisplayRects() 재계산
    └─ state = DockState(..., displayRects: rects)
    │
    ▼
ref.watch(dockProvider) 구독 위젯 리빌드
    │
    ▼
레이아웃 변경 감지 → _onLayoutChanged()
    └─ 500ms 디바운스 → DockLayoutService.saveLayout()
```

---

## DockNotifier 주요 메서드

### 드래그

| 메서드 | 설명 |
|---|---|
| `startDrag(groupId)` | displayRect → group에 커밋, draggingGroupId 설정 |
| `updateDrag(groupId, pos, vs, cursorInStack)` | 위치 업데이트 + 뷰포트 엣지/패널 간 도킹 감지 |
| `endDrag()` | 스냅 그리드 적용 + 앵커 재계산 + draggingGroupId 해제 |

### 리사이즈

| 메서드 | 설명 |
|---|---|
| `startResize(groupId)` | resizingGroupId 설정 (엣지 패널은 displayRect 커밋 스킵) |
| `resizeGroup(groupId, left, top, w, h)` | 플로팅 그룹 크기·위치 업데이트 |
| `resizeEdgePanel(groupId, newSize)` | 엣지 패널 너비 변경 |
| `resizeSplit(groupId, nodePath, separatorIndex, delta, totalSize)` | Split 비율 조정 |
| `endResize(groupId)` | 최소 크기 클램핑 + 앵커 재계산 |

### 도킹

| 메서드 | 설명 |
|---|---|
| `dockToViewportEdge(groupId, edge)` | 그룹 → 뷰포트 좌/우 고정 |
| `undockFromViewportEdge(groupId)` | 엣지 → 플로팅 전환 |
| `performTabDock(srcId, dstId, nodePath)` | 두 그룹을 Tabbed로 합치기 |
| `performEdgeDock(srcId, dstId, edge, nodePath)` | 특정 방향으로 Split 생성 |
| `undockTab(srcGroupId, nodePath, tabIndex, cursor?)` | 탭 분리 → 새 그룹 반환 |
| `undockNode(srcGroupId, nodePath, cursor?)` | Split 노드 분리 → 새 그룹 반환 |

### 탭

| 메서드 | 설명 |
|---|---|
| `switchTab(groupId, nodePath, tabIndex)` | 활성 탭 변경 |
| `reorderTab(groupId, nodePath, oldIndex, newIndex)` | 탭 순서 변경 |

### 고스트 도킹 (탭 드래그 분리 중 도킹 감지)

| 메서드 | 설명 |
|---|---|
| `updateGhostDockPreview(cursorInStack, ghostSize, excludeGroupId)` | 고스트 위치로 도킹 감지 |
| `clearGhostDockPreview()` | 프리뷰 초기화 |

---

## DockNode 트리 렌더링

### 노드 타입별 렌더링

```
DockLeaf(panelId)
└─ _buildLeaf()
   └─ DockLeaf를 Tabbed 1개로 래핑 → _buildTabbed([panelId], 0)
      └─ Column(
           tabBar(height: headerHeight + tabBarHeight),
           Expanded(panelDelegate.buildPanel(panelId))
         )

DockSplit(axis, children, ratios)
└─ _buildSplit()
   └─ Flex(
        DockNodeWidget(children[0], nodePath=[0]),
        _DraggableSplitSeparator(separatorIndex=0),
        DockNodeWidget(children[1], nodePath=[1]),
        ...
      )
      (재귀 — nodePath로 트리 경로 추적)

DockTabbed(tabIds, activeIndex)
└─ _buildTabbed()
   └─ Column(
        _DraggableTabBar(탭 드래그 + 오버레이),
        Expanded(panelDelegate.buildPanel(tabIds[activeIndex]))
      )
```

Leaf는 항상 Tabbed로 래핑해 렌더링하므로 `_buildTabbed`가 유일한 패널 표시 진입점이다.

### _DraggableTabBar 드래그 3모드

```
커서가 탭 바 안쪽
└─ 리오더 모드: _dragDeltaX로 탭 이동 표현 + reorderTab()

커서가 탭 바 밖으로 이탈 (undockPending = true)
└─ 고스트 모드:
   ├─ _showGhost() → Overlay 위에 반투명 패널 표시
   ├─ updateGhostDockPreview() 루프 (도킹 감지)
   └─ 커서가 탭 바로 복귀 → 리오더 모드 복원

마우스 업 (undockPending=true)
└─ undockTab() 또는 undockNode()
   └─ preview != null → performTabDock() / performEdgeDock() 자동 실행
```

### 헤더리스 프레임

`DockSettings.isHeaderless(panelId) == true` + `nodePath.isEmpty` + 그룹이 단일 노드일 때,
`_buildLeaf()`는 탭 바 없이 `_HeaderlessFrame`으로 렌더링한다.
전체 프레임이 드래그 핸들이 되고, 호버 시 오버레이 버튼이 나타난다.

---

## 레이아웃 저장·복원

### 저장 흐름

```
endDrag() / endResize() / performTabDock() / ...
    └─ _onLayoutChanged()
       └─ 500ms 디바운스
          └─ DockLayoutService.saveLayout(groups)
             ├─ getApplicationSupportDirectory()
             ├─ 기존 JSON 로드 (presets 보존)
             └─ groups 직렬화 → 덮어쓰기
```

### 복원 흐름

```
DockNotifier.build()
    ├─ DockSettings.defaultLayout?.call() → 초기 상태 설정
    └─ _loadSavedLayout() (비동기)
       └─ DockLayoutService.loadLayout()
          ├─ JSON 역직렬화
          ├─ version 검증 (v1~v2)
          └─ List<DockGroup> 반환 → state 교체
```

### JSON 스키마 (version 2)

```json
{
  "version": 2,
  "currentLayout": {
    "groups": [
      {
        "id": "group_0",
        "root": { "type": "leaf", "panelId": "thumbnail" },
        "anchorX": "left",
        "anchorY": "top",
        "offsetX": 8.0, "offsetY": 8.0,
        "width": 300.0, "height": 500.0,
        "zOrder": 0,
        "dockedEdge": null,
        "pinned": false,
        "headerless": false
      }
    ]
  }
}
```

> **스키마 변경 시:** `DockLayoutService`의 `_kCurrentVersion` 상수를 올리고
> 구 버전 마이그레이션 분기를 추가할 것. version 불일치 데이터는 무시하고
> `defaultLayout`으로 폴백한다.

---

## 앵커 좌표계

뷰포트를 3×3 존으로 나눠 창 크기 변경 시 패널이 앵커 기준으로 재배치된다.

```
AnchorX: left | center | right
AnchorY: top  | center | bottom

절대좌표 계산:
  x = anchorX == left   ? offsetX
    : anchorX == center ? viewerWidth/2  + offsetX
    : /* right */         viewerWidth    - offsetX - width

  y = (동일 패턴, anchorY 기준)
```

`endDrag()` / `endResize()` 호출 시 현재 절대좌표에서 역산해 `anchorX/Y`, `offsetX/Y`를 갱신한다.
패널 중심이 어느 존에 있느냐로 앵커가 자동 결정된다.

---

## 이펙트 위젯

| 위젯 | 트리거 | 동작 |
|---|---|---|
| `BorderScanEffect` | 엣지 → 플로팅 전환 | 테두리를 따라 광선이 한 바퀴 스캔 |
| `EdgeDockEffect` | 플로팅 → 엣지 도킹 | 도킹 방향 테두리 글로우 펄스 |
| `EdgeGlowDecoration` | `showFocusHighlight=true` + 포커스 | 테두리 전체 글로우 오버레이 |
| `DockGridOverlay` | `isInteracting=true` (드래그/리사이즈 중) | 도트 그리드 + 앵커 구역 선 |

`BorderScanEffect`와 `EdgeDockEffect`는 각각 `BorderScanController`, `EdgeDockEffectController`로 트리거하며, `DockGroupWidget.didUpdateWidget`에서 `dockedEdge` 변경을 감지해 호출한다.

---

## 새 기능 추가 체크리스트

### 새 드래그 동작 추가

1. `DockNotifier`에 `startXxx` / `updateXxx` / `endXxx` 메서드 추가
2. `DockState`에 관련 필드 추가 (필요 시)
3. `_computeDisplayRects()`에 영향 여부 확인
4. `_onLayoutChanged()` 호출 여부 결정 (상태 변경이 저장 대상인지)
5. 위젯에서 GestureDetector로 메서드 연결

### 새 패널 타입 추가 (호스트 앱)

1. `DockPanelDelegate.buildPanel`에 panelId 분기 추가
2. `DockPanelDelegate.labelOf`에 표시 이름 추가
3. `DockSettings.isHeaderless`에 해당 여부 추가 (필요 시)
4. `DockSettings.defaultLayout`에 초기 그룹에 포함 (필요 시)

### 테마 색상 변경

`DockTheme(colorScheme: DockColorScheme(...))` 한 곳만 수정.
패키지 내부 코드는 모두 `DockTheme.of(context).colorScheme.xxx`를 참조하므로
개별 위젯 수정 불필요.
