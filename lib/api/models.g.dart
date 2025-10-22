// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LoginResponse _$LoginResponseFromJson(Map<String, dynamic> json) =>
    LoginResponse(message: json['message']);

Map<String, dynamic> _$LoginResponseToJson(LoginResponse instance) =>
    <String, dynamic>{'message': instance.message};

Item _$ItemFromJson(Map<String, dynamic> json) => Item(
  name: json['name'] as String,
  itemName: json['item_name'] as String?,
  image: json['image'] as String?,
  uom: json['stock_uom'] as String?,
  rate: (json['valuation_rate'] as num?)?.toDouble(),
);

Map<String, dynamic> _$ItemToJson(Item instance) => <String, dynamic>{
  'name': instance.name,
  'item_name': instance.itemName,
  'image': instance.image,
  'stock_uom': instance.uom,
  'valuation_rate': instance.rate,
};

PosInvoiceItem _$PosInvoiceItemFromJson(Map<String, dynamic> json) =>
    PosInvoiceItem(
      itemCode: json['item_code'] as String,
      qty: (json['qty'] as num).toDouble(),
      rate: (json['rate'] as num).toDouble(),
      amount: (json['amount'] as num).toDouble(),
      warehouse: json['warehouse'] as String?,
    );

Map<String, dynamic> _$PosInvoiceItemToJson(PosInvoiceItem instance) =>
    <String, dynamic>{
      'item_code': instance.itemCode,
      'qty': instance.qty,
      'rate': instance.rate,
      'amount': instance.amount,
      'warehouse': instance.warehouse,
    };

PosInvoiceRequest _$PosInvoiceRequestFromJson(Map<String, dynamic> json) =>
    PosInvoiceRequest(
      customer: json['customer'] as String,
      company: json['company'] as String,
      posProfile: json['pos_profile'] as String,
      postingDate: json['posting_date'] as String,
      currency: json['currency'] as String,
      sellingPriceList: json['selling_price_list'] as String,
      items:
          (json['items'] as List<dynamic>)
              .map((e) => PosInvoiceItem.fromJson(e as Map<String, dynamic>))
              .toList(),
      paidAmount: (json['paid_amount'] as num).toDouble(),
    );

Map<String, dynamic> _$PosInvoiceRequestToJson(PosInvoiceRequest instance) =>
    <String, dynamic>{
      'customer': instance.customer,
      'company': instance.company,
      'pos_profile': instance.posProfile,
      'posting_date': instance.postingDate,
      'currency': instance.currency,
      'selling_price_list': instance.sellingPriceList,
      'items': instance.items,
      'paid_amount': instance.paidAmount,
    };
