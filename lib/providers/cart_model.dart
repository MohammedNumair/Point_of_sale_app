// lib/providers/cart_model.dart
import 'package:flutter/foundation.dart';
import '../api/models.dart';

class CartItem {
  final Item item;
  double qty;
  double rate;

  CartItem({required this.item, this.qty = 1.0, required this.rate});

  double get lineTotal => (rate * qty);
}

class CartModel extends ChangeNotifier {
  final List<CartItem> _items = [];

  List<CartItem> get items => List.unmodifiable(_items);

  /// Add item with optional qty (defaults to 1.0). If item exists, increment its qty.
  void add(Item item, {double? rate, double qty = 1.0}) {
    final existing = _items.where((c) => c.item.name == item.name).toList();
    if (existing.isNotEmpty) {
      existing.first.qty += qty;
    } else {
      _items.add(CartItem(item: item, qty: qty, rate: rate ?? (item.rate ?? 0.0)));
    }
    notifyListeners();
  }

  /// Set quantity for an item (replace).
  void setQty(Item item, double qty) {
    final e = _items.firstWhere((c) => c.item.name == item.name);
    e.qty = qty;
    notifyListeners();
  }

  void remove(Item item) {
    _items.removeWhere((c) => c.item.name == item.name);
    notifyListeners();
  }

  double get total => _items.fold(0.0, (t, e) => t + (e.rate * e.qty));

  void clear() {
    _items.clear();
    notifyListeners();
  }

  int get count => _items.length;

  // convenience used in UI - increment by 1.0
  void increment(Item item) {
    final e = _items.firstWhere((c) => c.item.name == item.name);
    e.qty += 1.0;
    notifyListeners();
  }

  // convenience: decrement by 1.0, remove if <= 0.0
  void decrement(Item item) {
    final e = _items.firstWhere((c) => c.item.name == item.name);
    if (e.qty > 1.0) {
      e.qty -= 1.0;
    } else {
      _items.remove(e);
    }
    notifyListeners();
  }
}
