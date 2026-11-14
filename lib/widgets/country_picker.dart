import 'package:flutter/material.dart';

import '../core/countries.dart';
import 'neon_dialog.dart';

/// A searchable list of countries in a neon sheet. Returns the picked ISO
/// code, or null if dismissed.
Future<String?> pickCountry(BuildContext context, {String? selected}) {
  return showNeonSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CountrySheet(selected: selected),
  );
}

/// The country as a tappable field ("Choose your country" until picked).
class CountryField extends StatelessWidget {
  const CountryField({super.key, required this.code, required this.onPicked});
  final String? code;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    final name = countryName(code);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final picked = await pickCountry(context, selected: code);
        if (picked != null) onPicked(picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(
          suffixIcon: Icon(Icons.expand_more_rounded),
        ),
        child: Text(
          name ?? 'Choose your country',
          style: name == null
              ? TextStyle(color: Theme.of(context).hintColor)
              : null,
        ),
      ),
    );
  }
}

class _CountrySheet extends StatefulWidget {
  const _CountrySheet({this.selected});
  final String? selected;

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final rows = sortedCountries
        .where((e) => q.isEmpty || e.value.toLowerCase().contains(q))
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search countries',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final e = rows[i];
                return ListTile(
                  title: Text(e.value),
                  trailing: e.key == widget.selected
                      ? Icon(
                          Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(context).pop(e.key),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
