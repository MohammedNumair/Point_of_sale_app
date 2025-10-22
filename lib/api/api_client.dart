// lib/api/api_client.dart
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'models.dart';
import 'package:retrofit/retrofit.dart';
import '../constants/config.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io' show Directory;

part 'api_client.g.dart';

@RestApi()
abstract class ApiClient {
  factory ApiClient(Dio dio, {String? baseUrl}) = _ApiClient;

  /// Login API
  @POST('/api/method/login')
  @FormUrlEncoded()
  Future<HttpResponse<LoginResponse>> login(
      @Field('usr') String usr,
      @Field('pwd') String pwd,
      );

  /// Explicit endpoints instead of {doctype}

  /// Fetch Customers
  @GET('/api/resource/Customer')
  Future<HttpResponse<dynamic>> getCustomers(@Queries() Map<String, dynamic> queries);

  /// Fetch POS Profiles
  @GET('/api/resource/POS Profile')
  Future<HttpResponse<dynamic>> getPOSProfiles(@Queries() Map<String, dynamic> queries);

  /// Fetch Selling Price Lists
  @GET('/api/resource/Price List')
  Future<HttpResponse<dynamic>> getSellingPriceLists(@Queries() Map<String, dynamic> queries);

  /// Fetch Currencies
  @GET('/api/resource/Currency')
  Future<HttpResponse<dynamic>> getCurrencies(@Queries() Map<String, dynamic> queries);

  /// Fetch Items (keep this)
  @GET('/api/resource/Item')
  Future<HttpResponse<dynamic>> getItems(@Queries() Map<String, dynamic> queries);

  /// Create POS Invoice (sends PosInvoiceRequest.toJson())
  @POST('/api/resource/POS Invoice')
  Future<HttpResponse<dynamic>> createPosInvoice(@Body() PosInvoiceRequest invoice);
}

/// Provider wrapper around Dio + cookie manager + Retrofit client
class ApiProvider {
  final String baseUrl;
  late Dio dio;
  CookieJar? cookieJar;
  late ApiClient client;

  ApiProvider._(this.baseUrl);

  /// Async factory to initialize provider and cookie handling
  static Future<ApiProvider> create({String? base}) async {
    final prov = ApiProvider._(base ?? AppConfig.baseUrl);

    prov.dio = Dio(BaseOptions(
      baseUrl: prov.baseUrl,
      followRedirects: true,
      headers: {'Accept': 'application/json'},
    ));

    if (kIsWeb) {
      try {
        final adapter = prov.dio.httpClientAdapter;
        (adapter as dynamic).withCredentials = true;
      } catch (_) {}
      prov.cookieJar = null;
    } else {
      try {
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        final cookiePath = '${appDocDir.path}/.cookies/';
        prov.cookieJar = PersistCookieJar(storage: FileStorage(cookiePath));
        prov.dio.interceptors.add(CookieManager(prov.cookieJar!));
      } catch (_) {
        prov.cookieJar = CookieJar();
        prov.dio.interceptors.add(CookieManager(prov.cookieJar!));
      }
    }

    prov.client = ApiClient(prov.dio, baseUrl: prov.baseUrl);
    return prov;
  }

  Future<List> getCookies() async {
    if (kIsWeb) return <dynamic>[];
    if (cookieJar == null) return <dynamic>[];
    final uri = Uri.parse(baseUrl);
    return cookieJar!.loadForRequest(uri);
  }

  // ---------------------------
  // Convenience wrapper methods
  // ---------------------------

  Future<List<Map<String, dynamic>>> _mapList(HttpResponse<dynamic> resp) async {
    final data = resp.data;
    if (data is Map && data['data'] is List) {
      return List<Map<String, dynamic>>.from(
        (data['data'] as List).map((e) => Map<String, dynamic>.from(e)),
      );
    }
    return <Map<String, dynamic>>[];
  }

  /// Fetch Customers
  Future<List<Map<String, dynamic>>> getCustomerList() async {
    final resp = await client.getCustomers({
      'fields': '["name","customer_name"]',
      'limit_page_length': '200',
    });
    return _mapList(resp);
  }

  /// Fetch POS Profiles
  Future<List<Map<String, dynamic>>> getPOSProfileList() async {
    final resp = await client.getPOSProfiles({
      'fields': '["name"]',
      'limit_page_length': '200',
    });
    return _mapList(resp);
  }

  /// Fetch Selling Price Lists
  Future<List<Map<String, dynamic>>> getSellingPriceList() async {
    final resp = await client.getSellingPriceLists({
      'fields': '["name"]',
      'limit_page_length': '200',
    });
    return _mapList(resp);
  }

  /// Fetch Currencies
  Future<List<Map<String, dynamic>>> getCurrencyList() async {
    final resp = await client.getCurrencies({
      'fields': '["name"]',
      'limit_page_length': '200',
    });
    return _mapList(resp);
  }

  /// Fetch Items (wrapper) — include child table "barcodes" so we can map barcode -> item locally.
  Future<List<Map<String, dynamic>>> getItemList() async {
    final resp = await client.getItems({
      'fields': '["name","item_name","image","stock_uom","valuation_rate","barcodes","standard_rate"]',
      'limit_page_length': '200',
    });
    return _mapList(resp);
  }

  // ---------------------------
  // Robust getItemByBarcode (calls custom server method first)
  // ---------------------------
  Future<Map<String, dynamic>?> getItemByBarcode(String barcode) async {
    // normalize
    final trimmed = barcode.trim();
    if (trimmed.isEmpty) return null;

    // helper variants
    List<String> _barcodeVariants(String bc) {
      final List<String> out = [];
      final t = bc.trim();
      if (t.isEmpty) return out;
      out.add(t);

      final noLeading = t.replaceFirst(RegExp(r'^0+'), '');
      if (noLeading.isNotEmpty && noLeading != t) out.add(noLeading);

      final digitsOnly = t.replaceAll(RegExp(r'[^0-9]'), '');
      if (digitsOnly.isNotEmpty && digitsOnly != t) out.add(digitsOnly);

      for (final len in [8, 12, 13]) {
        if (t.length < len) out.add(t.padLeft(len, '0'));
      }

      return out.toSet().toList();
    }

    final variants = _barcodeVariants(trimmed);

    // 0) Custom server method (most reliable) — try each variant
    for (final v in variants) {
      try {
        final resp = await dio.get('/api/method/pos_custom.api.barcode.get_item_by_barcode',
            queryParameters: {'barcode': v});
        if (resp.statusCode == 200) {
          final d = resp.data;
          if (d is Map && d['message'] != null) {
            final msg = d['message'];
            if (msg is Map) {
              debugPrint('getItemByBarcode: custom method matched variant "$v"');
              return Map<String, dynamic>.from(msg);
            }
          }
          // Some debug responses return {"message": null, "debug":[...]} - continue
        } else {
          debugPrint('getItemByBarcode: custom method returned ${resp.statusCode}: ${resp.data}');
        }
      } catch (e, st) {
        debugPrint('getItemByBarcode: custom method call failed for "$v": $e\n$st');
      }
    }

    // 1) Try Item Barcode doctype via frappe.client.get_list (if allowed)
    for (final v in variants) {
      try {
        final qp = <String, dynamic>{
          'doctype': 'Item Barcode',
          'fields': '["item_code","barcode"]',
          'filters': jsonEncode([
            ['barcode', '=', v]
          ]),
          'limit_page_length': '1',
        };

        final resp = await dio.get('/api/method/frappe.client.get_list', queryParameters: qp);
        if (resp.statusCode == 200) {
          final d = resp.data;
          if (d is Map && d['message'] is List && (d['message'] as List).isNotEmpty) {
            final Map<String, dynamic> row = Map<String, dynamic>.from((d['message'] as List)[0]);
            final String? itemCode = (row['item_code'] ?? row['item_code'])?.toString();
            if (itemCode != null && itemCode.isNotEmpty) {
              final item = await _fetchItemByNameSafe(itemCode);
              if (item != null) {
                debugPrint('getItemByBarcode: matched Item Barcode doctype for variant "$v" -> $itemCode');
                return item;
              }
            }
          }
        } else {
          debugPrint('getItemByBarcode: get_list returned ${resp.statusCode}: ${resp.data}');
        }
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        debugPrint('get_list attempt for Item Barcode failed (status $status): ${e.message}');
        if (status == 403) {
          // server blocks Item Barcode doctype — break and rely on fallbacks
          break;
        }
      } catch (e, st) {
        debugPrint('get_list attempt failed (Item Barcode): $e\n$st');
      }
    }

    // 2) Try direct Item fetch by item name/code across variants
    for (final v in variants) {
      final item = await _fetchItemByNameSafe(v);
      if (item != null) {
        debugPrint('getItemByBarcode: matched direct Item/{name} for variant "$v"');
        return item;
      }
    }

    // 3) Query /api/resource/Item using single-field filters (default_code, ean, upc, name)
    final searchFields = ['default_code', 'ean', 'upc', 'name'];
    for (final v in variants) {
      for (final field in searchFields) {
        try {
          final filter = jsonEncode([
            [field, '=', v]
          ]);
          final resp = await dio.get('/api/resource/Item', queryParameters: {
            'fields': '["name","item_name","image","stock_uom","valuation_rate","standard_rate"]',
            'filters': filter,
            'limit_page_length': '1'
          });

          if (resp.statusCode == 200) {
            final data = resp.data;
            if (data is Map && data['data'] is List && (data['data'] as List).isNotEmpty) {
              final Map<String, dynamic> row = Map<String, dynamic>.from((data['data'] as List)[0]);
              debugPrint('getItemByBarcode: matched /api/resource/Item where $field="$v"');
              return row;
            }
          } else {
            debugPrint('getItemByBarcode: /api/resource/Item returned ${resp.statusCode}: ${resp.data}');
          }
        } on DioException catch (e) {
          final status = e.response?.statusCode;
          debugPrint('getItemByBarcode: resource Item search for $field="$v" failed (status $status): ${e.message}');
        } catch (e, st) {
          debugPrint('getItemByBarcode: resource Item search for $field="$v" exception: $e\n$st');
        }
      }
    }

    debugPrint('getItemByBarcode: no match for barcode "$barcode" after trying ${variants.length} variants');
    return null;
  }

  /// Helper: fetch /api/resource/Item/{name} but handle 404/403 and return null on failures
  Future<Map<String, dynamic>?> _fetchItemByNameSafe(String name) async {
    const itemFields = '["name","item_name","image","stock_uom","valuation_rate","rate","standard_rate"]';
    try {
      final itemResp = await dio.get('/api/resource/Item/$name', queryParameters: {'fields': itemFields});
      if (itemResp.statusCode == 200) {
        final idata = itemResp.data;
        if (idata is Map && idata['data'] is Map) {
          return Map<String, dynamic>.from(idata['data']);
        }
        if (idata is Map && idata['data'] == null && idata is Map<String, dynamic>) {
          return Map<String, dynamic>.from(idata);
        }
      } else {
        debugPrint('_fetchItemByNameSafe: returned ${itemResp.statusCode}: ${itemResp.data}');
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      debugPrint('_fetchItemByNameSafe failed (status $status): ${e.message}');
    } catch (e, st) {
      debugPrint('_fetchItemByNameSafe exception: $e\n$st');
    }
    return null;
  }

  /// Create POS Invoice (returns Dio Response)
  Future<Response> createPosInvoiceRaw(PosInvoiceRequest invoice) async {
    final httpResp = await client.createPosInvoice(invoice);
    return httpResp.response;
  }
}














// // lib/api/api_client.dart
// import 'package:flutter/foundation.dart' show kIsWeb;
// import 'package:dio/dio.dart';
// import 'package:dio_cookie_manager/dio_cookie_manager.dart';
// import 'package:cookie_jar/cookie_jar.dart';
// import 'models.dart';
// import 'package:retrofit/retrofit.dart';
// import '../constants/config.dart';
// import 'package:path_provider/path_provider.dart';
// import 'dart:io' show Directory;
//
// part 'api_client.g.dart';
//
// @RestApi()
// abstract class ApiClient {
//   factory ApiClient(Dio dio, {String? baseUrl}) = _ApiClient;
//
//   /// Login API
//   @POST('/api/method/login')
//   @FormUrlEncoded()
//   Future<HttpResponse<LoginResponse>> login(
//       @Field('usr') String usr,
//       @Field('pwd') String pwd,
//       );
//
//   /// Explicit endpoints instead of {doctype}
//
//   /// Fetch Customers
//   @GET('/api/resource/Customer')
//   Future<HttpResponse<dynamic>> getCustomers(@Queries() Map<String, dynamic> queries);
//
//   /// Fetch POS Profiles
//   @GET('/api/resource/POS Profile')
//   Future<HttpResponse<dynamic>> getPOSProfiles(@Queries() Map<String, dynamic> queries);
//
//   /// Fetch Selling Price Lists
//   @GET('/api/resource/Price List')
//   Future<HttpResponse<dynamic>> getSellingPriceLists(@Queries() Map<String, dynamic> queries);
//
//   /// Fetch Currencies
//   @GET('/api/resource/Currency')
//   Future<HttpResponse<dynamic>> getCurrencies(@Queries() Map<String, dynamic> queries);
//
//   /// Fetch Items (keep this)
//   @GET('/api/resource/Item')
//   Future<HttpResponse<dynamic>> getItems(@Queries() Map<String, dynamic> queries);
//
//   /// Create POS Invoice (sends PosInvoiceRequest.toJson())
//   @POST('/api/resource/POS Invoice')
//   Future<HttpResponse<dynamic>> createPosInvoice(@Body() PosInvoiceRequest invoice);
// }
//
// /// Provider wrapper around Dio + cookie manager + Retrofit client
// class ApiProvider {
//   final String baseUrl;
//   late Dio dio;
//   CookieJar? cookieJar;
//   late ApiClient client;
//
//   ApiProvider._(this.baseUrl);
//
//   /// Async factory to initialize provider and cookie handling
//   static Future<ApiProvider> create({String? base}) async {
//     final prov = ApiProvider._(base ?? AppConfig.baseUrl);
//
//     prov.dio = Dio(BaseOptions(
//       baseUrl: prov.baseUrl,
//       followRedirects: true,
//       headers: {'Accept': 'application/json'},
//     ));
//
//     if (kIsWeb) {
//       try {
//         final adapter = prov.dio.httpClientAdapter;
//         (adapter as dynamic).withCredentials = true;
//       } catch (_) {}
//       prov.cookieJar = null;
//     } else {
//       try {
//         final Directory appDocDir = await getApplicationDocumentsDirectory();
//         final cookiePath = '${appDocDir.path}/.cookies/';
//         prov.cookieJar = PersistCookieJar(storage: FileStorage(cookiePath));
//         prov.dio.interceptors.add(CookieManager(prov.cookieJar!));
//       } catch (_) {
//         prov.cookieJar = CookieJar();
//         prov.dio.interceptors.add(CookieManager(prov.cookieJar!));
//       }
//     }
//
//     prov.client = ApiClient(prov.dio, baseUrl: prov.baseUrl);
//     return prov;
//   }
//
//   Future<List> getCookies() async {
//     if (kIsWeb) return <dynamic>[];
//     if (cookieJar == null) return <dynamic>[];
//     final uri = Uri.parse(baseUrl);
//     return cookieJar!.loadForRequest(uri);
//   }
//
//   // ---------------------------
//   // Convenience wrapper methods
//   // ---------------------------
//
//   Future<List<Map<String, dynamic>>> _mapList(HttpResponse<dynamic> resp) async {
//     final data = resp.data;
//     if (data is Map && data['data'] is List) {
//       return List<Map<String, dynamic>>.from(
//           (data['data'] as List).map((e) => Map<String, dynamic>.from(e)));
//     }
//     return <Map<String, dynamic>>[];
//   }
//
//   /// Fetch Customers
//   Future<List<Map<String, dynamic>>> getCustomerList() async {
//     final resp = await client.getCustomers({
//       'fields': '["name","customer_name"]',
//       'limit_page_length': '200',
//     });
//     return _mapList(resp);
//   }
//
//   /// Fetch POS Profiles
//   Future<List<Map<String, dynamic>>> getPOSProfileList() async {
//     final resp = await client.getPOSProfiles({
//       'fields': '["name"]',
//       'limit_page_length': '200',
//     });
//     return _mapList(resp);
//   }
//
//   /// Fetch Selling Price Lists
//   Future<List<Map<String, dynamic>>> getSellingPriceList() async {
//     final resp = await client.getSellingPriceLists({
//       'fields': '["name"]',
//       'limit_page_length': '200',
//     });
//     return _mapList(resp);
//   }
//
//   /// Fetch Currencies
//   Future<List<Map<String, dynamic>>> getCurrencyList() async {
//     final resp = await client.getCurrencies({
//       'fields': '["name"]',
//       'limit_page_length': '200',
//     });
//     return _mapList(resp);
//   }
//
//   /// Fetch Items (wrapper)
//   Future<List<Map<String, dynamic>>> getItemList() async {
//     final resp = await client.getItems({
//       'fields': '["name","item_name","image","stock_uom","valuation_rate"]',
//       'limit_page_length': '200',
//     });
//     return _mapList(resp);
//   }
//
//   /// Create POS Invoice (returns Dio Response)
//   Future<Response> createPosInvoiceRaw(PosInvoiceRequest invoice) async {
//     final httpResp = await client.createPosInvoice(invoice);
//     return httpResp.response;
//   }
// }
