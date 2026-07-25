import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/access.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../enum/enum.dart';

class OnDemandPackagesView extends ConsumerStatefulWidget {
  const OnDemandPackagesView({super.key});

  @override
  ConsumerState<OnDemandPackagesView> createState() =>
      _OnDemandPackagesViewState();
}

class _OnDemandPackagesViewState extends ConsumerState<OnDemandPackagesView> {
  final GlobalKey<CommonScaffoldState> _scaffoldKey = GlobalKey();
  late ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    ref.read(systemActionProvider.notifier).getPackages();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleSearch() {
    _scaffoldKey.currentState?.handleToSearch();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final packages = ref.watch(packagesProvider);
    final selectedPackages = ref.watch(onDemandDisconnectVpnPackagesProvider);
    final query = ref.watch(queryProvider(QueryTag.onDemand));
    final matcher = SearchMatcher(query);

    final viewPackages = packages
        .where(
          (package) =>
              matcher.hasAnyMatch([package.label, package.packageName]),
        )
        .toList();

    return CommonScaffold(
      key: _scaffoldKey,
      title: appLocalizations.onDemandDisconnectPackages,
      searchState: AppBarSearchState(
        onSearch: (value) {
          ref.read(queryProvider(QueryTag.onDemand).notifier).value = value;
        },
        autoAddSearch: false,
      ),
      actions: [
        IconButton(
          onPressed: _handleSearch,
          icon: const Icon(Icons.search),
        ),
      ],
      body: viewPackages.isEmpty
          ? NullStatus(label: appLocalizations.noData)
          : CommonScrollBar(
              controller: _controller,
              child: ListView.builder(
                controller: _controller,
                itemCount: viewPackages.length,
                itemExtent: 72,
                itemBuilder: (_, index) {
                  final package = viewPackages[index];
                  return PackageListItem(
                    key: Key(package.packageName),
                    package: package,
                    value: selectedPackages.contains(package.packageName),
                    onChanged: (value) {
                      final newList = [...selectedPackages];
                      if (value == true) {
                        newList.add(package.packageName);
                      } else {
                        newList.remove(package.packageName);
                      }
                      ref
                          .read(onDemandDisconnectVpnPackagesProvider.notifier)
                          .value = newList;
                    },
                  );
                },
              ),
            ),
    );
  }
}
