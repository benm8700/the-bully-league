import 'package:flutter/material.dart';

import '../../core/services/prize_service.dart';

/// Where a prize winner tells us where to send their non-cash prize. One
/// submission, no back-and-forth: the details save to the prize record (server
/// only) and the admin ships from the dashboard. Reached from the Home prize
/// banner (and, after a tap, from the prize-won push).
class PrizeClaimScreen extends StatefulWidget {
  const PrizeClaimScreen({super.key, required this.prize, this.service});

  final OwedPrize prize;
  final PrizeService? service;

  @override
  State<PrizeClaimScreen> createState() => _PrizeClaimScreenState();
}

class _PrizeClaimScreenState extends State<PrizeClaimScreen> {
  late final PrizeService _service = widget.service ?? PrizeService();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  bool _submitting = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final address = _address.text.trim();
    if (name.isEmpty || address.isEmpty) {
      setState(() => _error = 'Name and address are required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _service.submitClaim(
        fulfillmentId: widget.prize.id,
        name: name,
        address: address,
        phone: _phone.text.trim(),
      );
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Couldn't submit — try again.");
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('Claim your prize')),
      body: _done
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_shipping_outlined,
                        size: 56, color: scheme.primary),
                    const SizedBox(height: 16),
                    Text('You’re all set', style: text.headlineSmall),
                    const SizedBox(height: 8),
                    Text(
                      'We’ve got your details and will send ${widget.prize.prize}. '
                      'Keep an eye on your email/phone.',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
              children: [
                Text('🎉 You won ${widget.prize.prize}!',
                    style: text.titleLarge),
                const SizedBox(height: 6),
                Text(
                  'Tell us where to send it. We only use this to ship your '
                  'prize, and only you and the organizer can see it.',
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _address,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Shipping address',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone (for delivery)',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Send my prize'),
                ),
              ],
            ),
    );
  }
}
