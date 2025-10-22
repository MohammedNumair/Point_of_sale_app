// lib/api/models.dart
import 'package:json_annotation/json_annotation.dart';

part 'models.g.dart';

/// Helper: convert dynamic (num or numeric string) -> double?
double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is int) return v.toDouble();
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  // remove common thousands separators if present
  final cleaned = s.replaceAll(',', '');
  return double.tryParse(cleaned);
}

/// Helper: convert double? -> dynamic (preserve null)
dynamic _doubleToJson(double? v) => v;

@JsonSerializable()
class LoginResponse {
  final dynamic message;

  LoginResponse({this.message});

  factory LoginResponse.fromJson(Map<String, dynamic> json) => _$LoginResponseFromJson(json);
  Map<String, dynamic> toJson() => _$LoginResponseToJson(this);
}

@JsonSerializable()
class Item {
  final String name;

  @JsonKey(name: 'item_name')
  final String? itemName;

  final String? image;

  @JsonKey(name: 'stock_uom')
  final String? uom;

  /// cost/valuation field returned by some endpoints
  @JsonKey(name: 'valuation_rate', fromJson: _toDouble, toJson: _doubleToJson)
  final double? valuationRate;

  /// sometimes ERPNext returns 'rate'
  @JsonKey(name: 'rate', fromJson: _toDouble, toJson: _doubleToJson)
  final double? rate;

  /// selling price commonly in 'standard_rate'
  @JsonKey(name: 'standard_rate', fromJson: _toDouble, toJson: _doubleToJson)
  final double? standardRate;

  Item({
    required this.name,
    this.itemName,
    this.image,
    this.uom,
    this.valuationRate,
    this.rate,
    this.standardRate,
  });

  factory Item.fromJson(Map<String, dynamic> json) => _$ItemFromJson(json);
  Map<String, dynamic> toJson() => _$ItemToJson(this);

  /// Prefer selling price (standard_rate), then rate, then valuation_rate.
  double? get displayRate => standardRate ?? rate ?? valuationRate;
}

/// POS Invoice Item payload (child table)
@JsonSerializable()
class PosInvoiceItem {
  @JsonKey(name: 'item_code')
  final String itemCode;

  @JsonKey(fromJson: _toDouble, toJson: _doubleToJson)
  final double qty;

  @JsonKey(fromJson: _toDouble, toJson: _doubleToJson)
  final double rate;

  @JsonKey(fromJson: _toDouble, toJson: _doubleToJson)
  final double amount;

  /// Optional: warehouse if ERPNext requires it
  final String? warehouse;

  PosInvoiceItem({
    required this.itemCode,
    required this.qty,
    required this.rate,
    required this.amount,
    this.warehouse,
  });

  factory PosInvoiceItem.fromJson(Map<String, dynamic> json) => _$PosInvoiceItemFromJson(json);
  Map<String, dynamic> toJson() => _$PosInvoiceItemToJson(this);
}

/// POS Invoice main payload
@JsonSerializable()
class PosInvoiceRequest {
  /// Customer name (string)
  final String customer;

  /// Company (must match ERPNext Company)
  final String company;

  /// POS Profile name
  @JsonKey(name: 'pos_profile')
  final String posProfile;

  /// Posting date (YYYY-MM-DD)
  @JsonKey(name: 'posting_date')
  final String postingDate;

  final String currency;

  /// Selling price list name
  @JsonKey(name: 'selling_price_list')
  final String sellingPriceList;

  /// Items child table
  final List<PosInvoiceItem> items;

  /// Paid amount (snake case used by ERPNext)
  @JsonKey(name: 'paid_amount', fromJson: _toDouble, toJson: _doubleToJson)
  final double paidAmount;

  PosInvoiceRequest({
    required this.customer,
    required this.company,
    required this.posProfile,
    required this.postingDate,
    required this.currency,
    required this.sellingPriceList,
    required this.items,
    required this.paidAmount,
  });

  factory PosInvoiceRequest.fromJson(Map<String, dynamic> json) => _$PosInvoiceRequestFromJson(json);
  Map<String, dynamic> toJson() => _$PosInvoiceRequestToJson(this);
}



// // lib/api/models.dart
// import 'package:json_annotation/json_annotation.dart';
//
// part 'models.g.dart';
//
// @JsonSerializable()
// class LoginResponse {
//   final dynamic message;
//
//   LoginResponse({this.message});
//
//   factory LoginResponse.fromJson(Map<String, dynamic> json) => _$LoginResponseFromJson(json);
//   Map<String, dynamic> toJson() => _$LoginResponseToJson(this);
// }
//
// @JsonSerializable()
// class Item {
//   final String name;
//
//   @JsonKey(name: 'item_name')
//   final String? itemName;
//
//   final String? image;
//
//   @JsonKey(name: 'stock_uom')
//   final String? uom;
//
//   @JsonKey(name: 'valuation_rate')
//   final double? rate;
//
//   Item({
//     required this.name,
//     this.itemName,
//     this.image,
//     this.uom,
//     this.rate,
//   });
//
//   factory Item.fromJson(Map<String, dynamic> json) => _$ItemFromJson(json);
//   Map<String, dynamic> toJson() => _$ItemToJson(this);
// }
//
// /// POS Invoice Item payload (child table)
// @JsonSerializable()
// class PosInvoiceItem {
//   @JsonKey(name: 'item_code')
//   final String itemCode;
//
//   final double qty;
//   final double rate;
//   final double amount;
//
//   /// Optional: warehouse if ERPNext requires it
//   final String? warehouse;
//
//   PosInvoiceItem({
//     required this.itemCode,
//     required this.qty,
//     required this.rate,
//     required this.amount,
//     this.warehouse,
//   });
//
//   factory PosInvoiceItem.fromJson(Map<String, dynamic> json) => _$PosInvoiceItemFromJson(json);
//   Map<String, dynamic> toJson() => _$PosInvoiceItemToJson(this);
// }
//
// /// POS Invoice main payload
// @JsonSerializable()
// class PosInvoiceRequest {
//   /// Customer name (string)
//   final String customer;
//
//   /// Company (must match ERPNext Company)
//   final String company;
//
//   /// POS Profile name
//   @JsonKey(name: 'pos_profile')
//   final String posProfile;
//
//   /// Posting date (YYYY-MM-DD)
//   @JsonKey(name: 'posting_date')
//   final String postingDate;
//
//   final String currency;
//
//   /// Selling price list name
//   @JsonKey(name: 'selling_price_list')
//   final String sellingPriceList;
//
//   /// Items child table
//   final List<PosInvoiceItem> items;
//
//   /// Paid amount (snake case used by ERPNext)
//   @JsonKey(name: 'paid_amount')
//   final double paidAmount;
//
//   PosInvoiceRequest({
//     required this.customer,
//     required this.company,
//     required this.posProfile,
//     required this.postingDate,
//     required this.currency,
//     required this.sellingPriceList,
//     required this.items,
//     required this.paidAmount,
//   });
//
//   factory PosInvoiceRequest.fromJson(Map<String, dynamic> json) => _$PosInvoiceRequestFromJson(json);
//   Map<String, dynamic> toJson() => _$PosInvoiceRequestToJson(this);
// }
