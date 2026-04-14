import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../models/dock_group.dart';

/// nullable 필드의 copyWith sentinel — 명시적으로 null을 지정할 때 사용.
const _unset = Object();

/// 레이아웃 로드 결과: 그룹 목록 + 패널별 마지막 단독 크기 + 저장 시 뷰포트 높이.
class DockLayoutData {
  final List<DockGroup> groups;
  final Map<String, Size> lastPanelAloneSizes;

  /// 레이아웃이 저장될 당시의 뷰포트 높이.
  ///
  /// 재시작 시 엣지 패널 Split 비율을 현재 뷰포트에 맞게 재조정하는 데 사용.
  final double? savedViewportHeight;

  /// 호스트 앱이 레이아웃과 함께 저장할 임의 데이터.
  ///
  /// JSON 직렬화 가능한 형태여야 한다 (String/num/bool/List/Map).
  /// 레이아웃 JSON 최상위 키로 spread되어 저장되므로 기존 파일 형식과 호환된다.
  final Map<String, dynamic>? extraData;

  const DockLayoutData({
    required this.groups,
    this.lastPanelAloneSizes = const {},
    this.savedViewportHeight,
    this.extraData,
  });

  /// 지정한 필드만 변경한 복사본 생성.
  ///
  /// nullable 필드([savedViewportHeight], [extraData])를 명시적으로 null로
  /// 초기화하려면 [clearSavedViewportHeight] / [clearExtraData]를 true로 전달.
  DockLayoutData copyWith({
    List<DockGroup>? groups,
    Map<String, Size>? lastPanelAloneSizes,
    Object? savedViewportHeight = _unset,
    Object? extraData = _unset,
    bool clearSavedViewportHeight = false,
    bool clearExtraData = false,
  }) {
    return DockLayoutData(
      groups: groups ?? this.groups,
      lastPanelAloneSizes: lastPanelAloneSizes ?? this.lastPanelAloneSizes,
      savedViewportHeight: clearSavedViewportHeight
          ? null
          : (savedViewportHeight == _unset
              ? this.savedViewportHeight
              : savedViewportHeight as double?),
      extraData: clearExtraData
          ? null
          : (extraData == _unset
              ? this.extraData
              : extraData as Map<String, dynamic>?),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DockLayoutData) return false;
    const listEq = ListEquality<DockGroup>();
    const mapEq = MapEquality<String, Size>();
    const deepEq = DeepCollectionEquality();
    return listEq.equals(groups, other.groups) &&
        mapEq.equals(lastPanelAloneSizes, other.lastPanelAloneSizes) &&
        savedViewportHeight == other.savedViewportHeight &&
        deepEq.equals(extraData, other.extraData);
  }

  @override
  int get hashCode {
    const listEq = ListEquality<DockGroup>();
    const mapEq = MapEquality<String, Size>();
    const deepEq = DeepCollectionEquality();
    return Object.hash(
      listEq.hash(groups),
      mapEq.hash(lastPanelAloneSizes),
      savedViewportHeight,
      deepEq.hash(extraData),
    );
  }
}

/// 독 레이아웃 상태를 JSON 파일로 저장·복원하는 서비스.
///
/// 파일 구조:
/// ```json
/// {
///   "version": 1,
///   "currentLayout": { "groups": [...] },
///   "presets": {}
/// }
/// ```
///
/// 순수 Dart — Flutter 위젯 의존성 없음.
class DockLayoutService {
  static const String _fileName = 'dock_layout.json';
  static const int _version = 2;

  final String appDataDir;

  DockLayoutService(this.appDataDir);

  String get _filePath => p.join(appDataDir, _fileName);

  /// 저장된 레이아웃 로드. 그룹 목록 + 패널별 마지막 단독 크기를 반환.
  Future<DockLayoutData?> loadLayout() async {
    try {
      final path = _filePath;
      final file = File(path);
      if (!file.existsSync()) return null;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      final version = json['version'] as int? ?? 0;
      // v1: dockedEdge 없음 → fromJson에서 null로 처리되므로 그대로 로드
      if (version < 1 || version > _version) return null;

      final layout = json['currentLayout'] as Map<String, dynamic>?;
      if (layout == null) return null;

      final groupsJson = layout['groups'] as List?;
      if (groupsJson == null || groupsJson.isEmpty) return null;

      final groups = [
        for (final g in groupsJson)
          DockGroup.fromJson(g as Map<String, dynamic>),
      ];

      // 패널별 마지막 단독 크기 복원
      final sizesJson =
          json['lastPanelAloneSizes'] as Map<String, dynamic>? ?? {};
      final sizes = <String, Size>{};
      for (final entry in sizesJson.entries) {
        final v = entry.value as Map<String, dynamic>;
        sizes[entry.key] = Size(
          (v['width'] as num).toDouble(),
          (v['height'] as num).toDouble(),
        );
      }

      final savedViewportHeight =
          (json['viewportHeight'] as num?)?.toDouble();

      // 서비스가 관리하는 예약 키를 제외한 나머지를 extraData로 반환.
      const reservedKeys = {
        'version',
        'currentLayout',
        'viewportHeight',
        'lastPanelAloneSizes',
        'presets',
      };
      final extra = <String, dynamic>{
        for (final e in json.entries)
          if (!reservedKeys.contains(e.key)) e.key: e.value,
      };

      return DockLayoutData(
        groups: groups,
        lastPanelAloneSizes: sizes,
        savedViewportHeight: savedViewportHeight,
        extraData: extra.isEmpty ? null : extra,
      );
    } catch (e, st) {
      dev.log(
        '레이아웃 로드 실패',
        error: e,
        stackTrace: st,
        name: 'DockLayoutService',
      );
      return null;
    }
  }

  /// 현재 레이아웃(그룹 목록 + 패널별 마지막 단독 크기 + 뷰포트 높이)을 저장.
  ///
  /// [extraData]에 호스트 앱의 임의 데이터를 전달하면 레이아웃 JSON 최상위에
  /// spread되어 저장된다. 예약 키([reservedKeys])는 덮어쓸 수 없다.
  Future<void> saveLayout(
    List<DockGroup> groups, {
    Map<String, Size> lastPanelAloneSizes = const {},
    double? viewportHeight,
    Map<String, dynamic>? extraData,
  }) async {
    const reservedKeys = {
      'version',
      'currentLayout',
      'viewportHeight',
      'lastPanelAloneSizes',
      'presets',
    };

    final path = _filePath;
    final file = File(path);

    // 기존 파일에서 presets 등 다른 데이터 유지
    Map<String, dynamic> existing = {};
    try {
      if (file.existsSync()) {
        existing =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    } catch (e, st) {
      dev.log(
        '기존 레이아웃 파싱 실패, 새로 생성',
        error: e,
        stackTrace: st,
        name: 'DockLayoutService',
      );
    }

    // 호스트 앱의 extraData를 예약 키를 피해 최상위에 merge.
    if (extraData != null) {
      extraData.forEach((k, v) {
        if (!reservedKeys.contains(k)) existing[k] = v;
      });
    }

    existing['version'] = _version;
    existing['currentLayout'] = {
      'groups': [for (final g in groups) g.toJson()],
    };
    if (viewportHeight != null) {
      existing['viewportHeight'] = viewportHeight;
    }
    existing['lastPanelAloneSizes'] = {
      for (final entry in lastPanelAloneSizes.entries)
        entry.key: {
          'width': entry.value.width,
          'height': entry.value.height,
        },
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(existing);
    await file.writeAsString(jsonStr);
  }
}
