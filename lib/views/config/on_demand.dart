import 'package:collection/collection.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/on_demand_packages.dart';
import 'package:fl_clash/views/profiles/overwrite/custom/widgets.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

class OnDemandView extends ConsumerStatefulWidget {
  const OnDemandView({super.key});

  @override
  ConsumerState createState() => _OnDemandViewState();
}

class _OnDemandViewState extends ConsumerState<OnDemandView>
    with UniqueKeyStateMixin {
  void _handlePermanentlyDeniedLocationPermission() {
    if (system.isMacOS) {
      final appLocalizations = context.appLocalizations;
      globalState.showMessage(
        title: appLocalizations.locationPermissionRequired,
        cancelable: false,
        message: TextSpan(
          style: context.textTheme.bodyMedium,
          text: appLocalizations.locationPermissionGuide(appName),
        ),
      );
    } else if (system.isAndroid) {
      app?.openAppSettings();
    }
  }

  Future<void> _handleRequestLocationPermission() async {
    final appLocalizations = context.appLocalizations;
    final permission = ref.read(locationPermissionsProvider);
    if (permission == WifiSsidPermission.granted) {
      return;
    }
    if (permission == WifiSsidPermission.permanentlyDenied) {
      _handlePermanentlyDeniedLocationPermission();
      return;
    }
    final res = await wifiSsidManager.requestPermission();
    globalState.container.read(locationPermissionsProvider.notifier).value =
        res;
    if (!mounted && res != WifiSsidPermission.permanentlyDenied) {
      return;
    }
    final needGo = await globalState.showMessage(
      title: appLocalizations.locationPermissionRequired,
      message: TextSpan(text: appLocalizations.locationPermissionDeniedMessage),
      confirmText: appLocalizations.go,
    );
    if (needGo != true) {
      return;
    }
    app?.openAppSettings();
  }

  void _handleOpenAccessibilitySettings() async {
    await app?.openAccessibilitySettings();
  }

  void _handleOpenBatteryOptimizationSettings() {
    final isDisabled = ref.read(batteryOptimizationDisableProvider);
    if (isDisabled) {
      return;
    }
    permissions.needWaitingBatteryOptimizationSettings = true;
    app?.openBatteryOptimizationSettings();
  }

  Future<void> _handleAddOrUpdate([String? ssid]) async {
    final ssids = ref.read(excludeSSIDsProvider);
    final appLocalizations = context.appLocalizations;
    final newSSID = await globalState.showCommonDialog<String>(
      child: InputDialog(
        title: ssid == null
            ? appLocalizations.addSsid
            : appLocalizations.editSsid,
        subtitle: appLocalizations.addSsidDesc,
        value: ssid ?? '',
        maxLength: 32,
        validator: (value) {
          if (value == null || value.isEmpty) {
            return appLocalizations.emptyTip('SSID').trim();
          }
          if (ssids.contains(value) && ssid != value) {
            return appLocalizations.existsTip('SSID').trim();
          }
          return null;
        },
      ),
    );
    if (newSSID == null || ssid == newSSID) {
      return;
    }
    globalState.container.read(excludeSSIDsProvider.notifier).update((state) {
      final newSSIDS = state.toSet();
      if (ssid != null) {
        newSSIDS.remove(ssid);
      }
      return [...newSSIDS, newSSID];
    });
  }

  void _handleDelete() {
    final selectedItems = ref.read(itemsProvider(key));

    globalState.container.read(excludeSSIDsProvider.notifier).update((ssids) {
      return ssids
          .where((item) => !selectedItems.contains("ssid_$item"))
          .toList();
    });

    globalState.container
        .read(onDemandDisconnectVpnPackagesProvider.notifier)
        .update((packages) {
      return packages
          .where((item) => !selectedItems.contains("pkg_$item"))
          .toList();
    });

    ref.read(itemsProvider(key).notifier).value = {};
  }

  void _handleSelectAll(List<String> allIds) {
    ref.read(itemsProvider(key).notifier).update((selected) {
      return selected.length == allIds.length ? {} : allIds.toSet();
    });
  }

  Widget _buildMergedItem({
    required String id,
    required String label,
    String? subtitle,
    Widget? leading,
    required int index,
    required int length,
    required bool isSelected,
    required bool isEditing,
    VoidCallback? onPressed,
  }) {
    final position = ItemPosition.get(index, length);

    return ReorderableDelayedDragStartListener(
      key: ValueKey(id),
      index: index,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ItemPositionProvider(
          position: position,
          child: SelectedDecorationListItem(
            isEditing: isEditing,
            minVerticalPadding: 8,
            leading: leading,
            title: TooltipText(
              text: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            subtitle: subtitle != null
                ? Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodySmall,
                  )
                : null,
            isSelected: isSelected,
            onSelected: () {
              ref.read(itemsProvider(key).notifier).update((state) {
                final newState = Set<dynamic>.from(state)..addOrRemove(id);
                return newState;
              });
            },
            onPressed: onPressed ??
                () {
                  ref.read(itemsProvider(key).notifier).update((state) {
                    final newState = Set<dynamic>.from(state)..addOrRemove(id);
                    return newState;
                  });
                },
          ),
        ),
      ),
    );
  }

  void _handleReorder(
    int oldIndex,
    int newIndex,
    List<String> currentIds,
  ) {
    final id = currentIds[oldIndex];
    if (id.startsWith("pkg_")) {
      final pkgName = id.replaceFirst("pkg_", "");
      final packages =
          List<String>.from(ref.read(onDemandDisconnectVpnPackagesProvider));
      final actualOldIndex = packages.indexOf(pkgName);
      globalState.container
          .read(onDemandDisconnectVpnPackagesProvider.notifier)
          .update((value) => value.copyAndReorder(actualOldIndex, newIndex));
    } else {
      final ssid = id.replaceFirst("ssid_", "");
      final ssids = List<String>.from(ref.read(excludeSSIDsProvider));
      final actualOldIndex = ssids.indexOf(ssid);
      globalState.container
          .read(excludeSSIDsProvider.notifier)
          .update((value) => value.copyAndReorder(actualOldIndex, newIndex));
    }
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final isLoading = ref.watch(
      loadingProvider(LoadingTag.batteryOptimization),
    );
    final batteryOptimizationDisable = ref.watch(
      batteryOptimizationDisableProvider,
    );
    final locationPermissionsGranted = ref.watch(
      locationPermissionsProvider.select(
        (state) => state == WifiSsidPermission.granted,
      ),
    );
    final alwaysOn = ref.watch(alwaysOnProvider);

    final accessibilityServiceEnabled =
        ref.watch(accessibilityServiceEnabledProvider);
    final onDemandPackages = ref.watch(onDemandDisconnectVpnPackagesProvider);
    final excludeSSIDs = ref.watch(excludeSSIDsProvider);
    final packages = ref.watch(packagesProvider);

    final selectedIds = ref.watch(itemsProvider(key));

    final mergedList = [
      ...onDemandPackages.map((p) {
        final package = packages.firstWhereOrNull((pkg) => pkg.packageName == p);
        return (
          id: "pkg_$p",
          label: package?.label ?? p,
          subtitle: p,
          type: 'pkg',
          packageName: p,
          leading: SizedBox.square(
            dimension: 36,
            child: FutureBuilder<ImageProvider?>(
              future: app?.getPackageIcon(p),
              builder: (_, snapshot) {
                if (snapshot.hasData && snapshot.data != null) {
                  return Image(image: snapshot.data!, width: 36, height: 36);
                }
                return const Icon(Icons.android);
              },
            ),
          ),
        );
      }),
      ...excludeSSIDs.map((s) => (
            id: "ssid_$s",
            label: s,
            subtitle: "SSID",
            type: 'ssid',
            packageName: null,
            leading: const SizedBox.square(
              dimension: 36,
              child: Icon(Icons.wifi),
            ),
          )),
    ];

    final allIds = mergedList.map((e) => e.id).toList();

    return CommonScaffold(
      body: CustomScrollView(
        slivers: [
          if (system.isIOS)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(
                child: generateSectionV3(
                  items: [
                    ListItem.toggle(
                      title: Text(appLocalizations.alwaysOn),
                      subtitle: Text(appLocalizations.alwaysOnDesc),
                      value: alwaysOn,
                      onChanged: (value) {
                        ref.read(alwaysOnProvider.notifier).value = value;
                      },
                    ),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: generateSectionV3(
                title: appLocalizations.prerequisites,
                items: [
                  if (system.isAndroid) ...[
                    DecorationListItem(
                      minVerticalPadding: 8,
                      title: Text(appLocalizations.accessibilityService),
                      subtitle: Text(appLocalizations.accessibilityServiceDesc),
                      trailing: CommonMinFilledButtonTheme(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: accessibilityServiceEnabled
                                ? null
                                : context.colorScheme.error,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            minimumSize: const Size(80, 40),
                          ),
                          onPressed: _handleOpenAccessibilitySettings,
                          child: Text(
                            accessibilityServiceEnabled
                                ? appLocalizations.authorized
                                : appLocalizations.tapToAuthorize,
                          ),
                        ),
                      ),
                    ),
                    DecorationListItem(
                      minVerticalPadding: 8,
                      title: Text(appLocalizations.ignoreBatteryOptimization),
                      subtitle: Text(appLocalizations.batteryOptimizationDesc),
                      trailing: isLoading
                          ? const SizedBox(
                              width: 100,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  SizedBox.square(
                                    dimension: 32,
                                    child: CommonCircleLoading(),
                                  ),
                                ],
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              spacing: 8,
                              children: [
                                InfoMessageButton(
                                  message: appLocalizations
                                      .batteryOptimizationStatusTip,
                                ),
                                CommonMinFilledButtonTheme(
                                  child: FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          batteryOptimizationDisable
                                          ? null
                                          : context.colorScheme.error,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      minimumSize: const Size(80, 40),
                                    ),
                                    onPressed:
                                        _handleOpenBatteryOptimizationSettings,
                                    child: Text(
                                      batteryOptimizationDisable
                                          ? appLocalizations.authorized
                                          : appLocalizations.tapToAuthorize,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                  if (system.isAndroid || system.isMacOS)
                    DecorationListItem(
                      minVerticalPadding: 8,
                      title: Text(appLocalizations.locationPermission),
                      subtitle: Text(appLocalizations.locationPermissionDesc),
                      trailing: CommonMinFilledButtonTheme(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: locationPermissionsGranted
                                ? null
                                : context.colorScheme.error,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            minimumSize: const Size(80, 40),
                          ),
                          onPressed: _handleRequestLocationPermission,
                          child: Text(
                            locationPermissionsGranted
                                ? appLocalizations.authorized
                                : appLocalizations.tapToAuthorize,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: ListHeader(
                title: appLocalizations.onDemand,
                subTitle: appLocalizations.onDemandDesc,
                actions: [
                  const SizedBox(width: 8),
                  if (selectedIds.isNotEmpty) ...[
                    CommonMinIconButtonTheme(
                      child: IconButton.filledTonal(
                        tooltip: appLocalizations.delete,
                        onPressed: _handleDelete,
                        icon: const Icon(Icons.delete),
                      ),
                    ),
                    const SizedBox(width: 2),
                    CommonMinFilledButtonTheme(
                      child: FilledButton(
                        onPressed: () => _handleSelectAll(allIds),
                        child: Text(
                          selectedIds.length == allIds.length
                              ? appLocalizations.cancelSelectAll
                              : appLocalizations.selectAll,
                        ),
                      ),
                    ),
                  ] else ...[
                    if (system.isAndroid)
                      CommonMinIconButtonTheme(
                        child: IconButton.filledTonal(
                          tooltip: appLocalizations.onDemandDisconnectPackages,
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) =>
                                    const OnDemandPackagesView(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.add_chart),
                        ),
                      ),
                    const SizedBox(width: 2),
                    CommonMinFilledButtonTheme(
                      child: FilledButton.tonal(
                        onPressed: _handleAddOrUpdate,
                        child: Text(appLocalizations.addSsid),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (mergedList.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
              ).copyWith(top: 12),
              sliver: SliverToBoxAdapter(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 0,
                    vertical: 48,
                  ),
                  child: NullStatus(label: appLocalizations.noData),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(top: 12),
              sliver: SliverReorderableList(
                itemBuilder: (_, index) {
                  final item = mergedList[index];
                  return _buildMergedItem(
                    id: item.id,
                    label: item.label,
                    subtitle: item.subtitle,
                    leading: item.leading,
                    index: index,
                    isSelected: selectedIds.contains(item.id),
                    length: mergedList.length,
                    isEditing: selectedIds.isNotEmpty,
                    onPressed: item.type == 'ssid'
                        ? () => _handleAddOrUpdate(item.label)
                        : null,
                  );
                },
                proxyDecorator: (child, index, animation) {
                  final item = mergedList[index];
                  return commonProxyDecorator(
                    _buildMergedItem(
                      id: item.id,
                      label: item.label,
                      subtitle: item.subtitle,
                      leading: item.leading,
                      index: index,
                      isSelected: selectedIds.contains(item.id),
                      length: mergedList.length,
                      isEditing: selectedIds.isNotEmpty,
                    ),
                    index,
                    animation,
                  );
                },
                itemCount: mergedList.length,
                onReorderItem: (oldIdx, newIdx) =>
                    _handleReorder(oldIdx, newIdx, allIds),
              ),
            ),
        ],
      ),
      title: appLocalizations.onDemand,
    );
  }
}
