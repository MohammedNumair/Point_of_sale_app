// lib/logic/barcode_handlers.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/api_client.dart'; // ApiProvider
import '../providers/cart_model.dart';
import '../api/models.dart';

/// Handle barcode scan: call provider helper and add to cart.
///
/// This version attempts to extract quantity encoded in barcode:
/// - If barcode looks like it encodes a 6-digit value at the end (13+ digits),
///   it will parse the final 6 digits and use qty = int(last6) / 10000.0,
///   then TRUNCATE to 2 decimal places (so 0.2506 -> 0.25).
/// - If not matching, defaults to qty = 1.0
Future<void> handleBarcodeScan(BuildContext context, String rawBarcode) async {
  final barcodeRaw = rawBarcode.trim();
  if (barcodeRaw.isEmpty) return;

  final scaffoldMessenger = ScaffoldMessenger.of(context);
  final apiProv = Provider.of<ApiProvider>(context, listen: false);
  final cart = Provider.of<CartModel>(context, listen: false);

  scaffoldMessenger.showSnackBar(
    SnackBar(content: Text('Scanned: $barcodeRaw'), duration: const Duration(milliseconds: 450)),
  );

  try {
    // 1) compute candidate qty from barcode (best-effort)
    double parsedQty = _extractQtyFromBarcode(barcodeRaw);
    debugPrint('handleBarcodeScan: parsedQty candidate => $parsedQty');

    // 2) lookup item
    final dynamic result = await apiProv.getItemByBarcode(barcodeRaw);
    debugPrint('handleBarcodeScan: raw result => $result');

    if (result == null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('Item not found for barcode: $barcodeRaw'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    Map<String, dynamic>? row;

    // --- interpret result (same robust handling as before) ---
    if (result is Map<String, dynamic>) {
      row = result;
    } else if (result is Map) {
      row = Map<String, dynamic>.from(result);
    } else if (result is String) {
      debugPrint('handleBarcodeScan: provider returned item identifier string: $result');
      try {
        final itemResp = await apiProv.dio.get('/api/resource/Item/$result', queryParameters: {
          'fields': '["name","item_name","image","stock_uom","valuation_rate","rate","standard_rate"]'
        }, options: Options(validateStatus: (_) => true));
        if (itemResp.statusCode == 200 && itemResp.data != null) {
          final idata = itemResp.data;
          if (idata is Map && idata['data'] is Map) {
            row = Map<String, dynamic>.from(idata['data'] as Map);
          } else if (idata is Map && idata['data'] == null) {
            row = Map<String, dynamic>.from(idata);
          }
        }
      } catch (e, st) {
        debugPrint('handleBarcodeScan: fetching Item by identifier failed: $e\n$st');
      }
    } else {
      try {
        final m = result as dynamic;
        if (m != null) {
          if (m is Map && m.containsKey('message')) {
            final msg = m['message'];
            if (msg is Map) row = Map<String, dynamic>.from(msg);
            else if (msg is String) {
              final itemCode = msg;
              try {
                final itemResp = await apiProv.dio.get('/api/resource/Item/$itemCode', queryParameters: {
                  'fields': '["name","item_name","image","stock_uom","valuation_rate","rate","standard_rate"]'
                }, options: Options(validateStatus: (_) => true));
                if (itemResp.statusCode == 200 && itemResp.data != null) {
                  final idata = itemResp.data;
                  if (idata is Map && idata['data'] is Map) row = Map<String, dynamic>.from(idata['data'] as Map);
                }
              } catch (e) {
                debugPrint('handleBarcodeScan: fetch after message-string failed: $e');
              }
            }
          } else if (m is Map && m.containsKey('data')) {
            final dat = m['data'];
            if (dat is Map) row = Map<String, dynamic>.from(dat);
            else if (dat is List && dat.isNotEmpty && dat.first is Map) {
              row = Map<String, dynamic>.from(dat.first);
            }
          } else if (m is List && m.isNotEmpty) {
            final first = m.first;
            if (first is Map) row = Map<String, dynamic>.from(first);
          }
        }
      } catch (e, st) {
        debugPrint('handleBarcodeScan: parsing wrapper result failed: $e\n$st');
      }
    }

    if (row == null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('Item lookup succeeded but result format was unexpected for barcode: $barcodeRaw'),
          backgroundColor: Colors.orange,
        ),
      );
      debugPrint('handleBarcodeScan: unexpected result shape: $result');
      return;
    }

    // ---------- Normalize / sanitize the row before passing to Item.fromJson ----------
    final Map<String, dynamic> sanitized = <String, dynamic>{};

    // Prefer canonical 'name'
    String? nameVal;
    if (row.containsKey('name') && row['name'] != null) {
      nameVal = row['name'].toString();
    } else if (row.containsKey('item_code') && row['item_code'] != null) {
      nameVal = row['item_code'].toString();
    } else if (row.containsKey('code') && row['code'] != null) {
      nameVal = row['code'].toString();
    }
    if (nameVal != null && nameVal.isNotEmpty) sanitized['name'] = nameVal;

    // Item display name
    String? itemNameVal;
    if (row.containsKey('item_name') && row['item_name'] != null) {
      itemNameVal = row['item_name'].toString();
    } else if (row.containsKey('item') && row['item'] != null) {
      itemNameVal = row['item'].toString();
    } else if (row.containsKey('description') && row['description'] != null) {
      itemNameVal = row['description'].toString();
    }
    if (itemNameVal != null && itemNameVal.isNotEmpty) sanitized['item_name'] = itemNameVal;

    // Image
    if (row.containsKey('image') && row['image'] != null) sanitized['image'] = row['image'].toString();

    // stock_uom
    if (row.containsKey('stock_uom') && row['stock_uom'] != null) sanitized['stock_uom'] = row['stock_uom'].toString();

    // valuation_rate / rate / standard_rate -> unify to 'rate'
    double? rate;
    try {
      if (row.containsKey('rate') && row['rate'] != null) {
        rate = _toDouble(row['rate']);
      } else if (row.containsKey('standard_rate') && row['standard_rate'] != null) {
        rate = _toDouble(row['standard_rate']);
      } else if (row.containsKey('valuation_rate') && row['valuation_rate'] != null) {
        rate = _toDouble(row['valuation_rate']);
      } else if (row.containsKey('price') && row['price'] != null) {
        rate = _toDouble(row['price']);
      }
    } catch (e) {
      debugPrint('handleBarcodeScan: error parsing rate: $e');
    }
    if (rate != null) {
      sanitized['rate'] = rate;
      sanitized['standard_rate'] = rate;
    }

    if (!sanitized.containsKey('name') && !sanitized.containsKey('item_name')) {
      debugPrint('handleBarcodeScan: sanitized data missing name/item_name -> $sanitized');
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('Found data but could not interpret item for barcode: $barcodeRaw'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Build Item and add to cart
    late final Item item;
    try {
      item = Item.fromJson(sanitized);
    } catch (e, st) {
      debugPrint('handleBarcodeScan: Item.fromJson failed: $e\n$st\nsanitized=$sanitized');
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('Error parsing item data for barcode: $barcodeRaw'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Final rate numeric
    final double finalRate = (item.rate ?? sanitized['rate'] ?? 0.0) is double
        ? (item.rate ?? sanitized['rate'] ?? 0.0)
        : _toDouble((item.rate ?? sanitized['rate'])) ?? 0.0;

    // Decide final qty: prefer parsedQty if > 0, otherwise 1.0
    final double finalQty = (parsedQty > 0.0) ? parsedQty : 1.0;

    // Add with qty (CartModel.add handles increment for existing items)
    cart.add(item, rate: finalRate, qty: finalQty);

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text('${item.itemName ?? item.name} added — qty ${_fmtQty(finalQty)} — ${finalRate.toStringAsFixed(2)}'),
      ),
    );
  } catch (e, st) {
    debugPrint('handleBarcodeScan error: $e\n$st');
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text('Error processing barcode: $e'), backgroundColor: Colors.red),
    );
  }
}

/// Try to extract qty encoded in barcode.
/// Rules:
/// - Keep only digits.
/// - If digits length >= 13 and we have a last-6 digits pattern, take last 6 digits,
///   parse int and divide by 10000.0 to get quantity.
/// - TRUNCATE to 2 decimal places (floor(qty * 100) / 100).
/// - Otherwise return 0.0 (meaning not parsed).
double _extractQtyFromBarcode(String raw) {
  // keep only digits
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length >= 13) {
    // take last 6 digits as encoded quantity
    final last6 = digits.substring(digits.length - 6);
    try {
      final intVal = int.parse(last6);
      final qty = intVal / 10000.0;
      if (qty <= 0.0) return 0.0;
      // TRUNCATE to 2 decimal places (not round)
      final truncated = (qty * 100).floorToDouble() / 100.0;
      return truncated;
    } catch (_) {
      return 0.0;
    }
  }
  return 0.0;
}

/// Format qty for display: integer without decimals else up to 3 decimals (trim trailing zeros).
String _fmtQty(double q) {
  if (q % 1 == 0) {
    return q.toStringAsFixed(0);
  } else if ((q * 10) % 1 == 0) {
    return q.toStringAsFixed(1);
  } else if ((q * 100) % 1 == 0) {
    return q.toStringAsFixed(2);
  } else {
    return q.toStringAsFixed(3);
  }
}

/// Helper: convert common numeric representations to double (defensive).
double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return null;
    final normalized = s.replaceAll(',', '');
    return double.tryParse(normalized);
  }
  try {
    return double.parse(v.toString());
  } catch (_) {
    return null;
  }
}
