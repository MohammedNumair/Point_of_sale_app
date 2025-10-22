// lib/main.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants/config.dart';
import 'api/api_client.dart';
import 'providers/cart_model.dart';
import 'screens/login_screen.dart';
import 'screens/item_list_screen.dart';
import 'screens/checkout_screen.dart';
import 'screens/invoice_result_screen.dart'; // optional route if you want to navigate by name

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Try to load saved base URL from SharedPreferences (if login previously stored it)
  String base = AppConfig.baseUrl;
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('last_base_url');
    if (saved != null && saved.isNotEmpty) base = saved;
  } catch (_) {
    // ignore
  }

  AppConfig.baseUrl = base;

  // Initialize ApiProvider from api/api_client.dart using the base (may be changed later by login)
  final apiProvider = await ApiProvider.create(base: AppConfig.baseUrl);

  runApp(MyApp(apiProvider: apiProvider));
}

class MyApp extends StatelessWidget {
  final ApiProvider apiProvider;

  const MyApp({super.key, required this.apiProvider});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Provide the ApiProvider instance created above
        Provider<ApiProvider>.value(value: apiProvider),

        // CartModel: holds POS cart items
        ChangeNotifierProvider<CartModel>(create: (_) => CartModel()),
      ],
      child: MaterialApp(
        title: 'ERPNext POS',
        theme: ThemeData(primarySwatch: Colors.blue),
        debugShowCheckedModeBanner: false,
        initialRoute: '/',
        routes: {
          '/': (ctx) => const LoginScreen(),
          '/items': (ctx) => const ItemListScreen(),
          '/checkout': (ctx) => const CheckoutScreen(),
          // optional: if you ever want to pushNamed to invoice result
          '/invoice_result': (ctx) => InvoiceResultScreen(
            invoiceName: 'DUMMY', // when using named route you'll need to pass real args differently
            cartSnapshot: const []
          ),
        },
      ),
    );
  }
}




// // lib/main.dart
// import 'package:flutter/material.dart';
// import 'package:provider/provider.dart';
// import 'package:shared_preferences/shared_preferences.dart';
//
// import 'constants/config.dart';
// import 'api/api_client.dart';        // <- use ApiProvider from here
// import 'providers/cart_model.dart';
// import 'screens/login_screen.dart';
// import 'screens/item_list_screen.dart';
// import 'screens/checkout_screen.dart';
//
// Future<void> main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//
//   // Try to load saved base URL from SharedPreferences (if login previously stored it)
//   String base = AppConfig.baseUrl;
//   try {
//     final prefs = await SharedPreferences.getInstance();
//     final saved = prefs.getString('last_base_url');
//     if (saved != null && saved.isNotEmpty) base = saved;
//   } catch (_) {
//     // ignore
//   }
//
//   AppConfig.baseUrl = base;
//
//   // Initialize ApiProvider from api/api_client.dart using the base (may be changed later by login)
//   final apiProvider = await ApiProvider.create(base: AppConfig.baseUrl);
//
//   runApp(MyApp(apiProvider: apiProvider));
// }
//
// class MyApp extends StatelessWidget {
//   final ApiProvider apiProvider;
//
//   const MyApp({super.key, required this.apiProvider});
//
//   @override
//   Widget build(BuildContext context) {
//     return MultiProvider(
//       providers: [
//         // Provide the ApiProvider instance created above
//         Provider<ApiProvider>.value(value: apiProvider),
//
//         // CartModel: holds POS cart items
//         ChangeNotifierProvider<CartModel>(create: (_) => CartModel()),
//       ],
//       child: MaterialApp(
//         title: 'ERPNext POS',
//         theme: ThemeData(primarySwatch: Colors.blue),
//         debugShowCheckedModeBanner: false,
//         initialRoute: '/',
//         routes: {
//           '/': (ctx) => const LoginScreen(),
//           '/items': (ctx) => const ItemListScreen(),
//           '/checkout': (ctx) => const CheckoutScreen(),
//         },
//       ),
//     );
//   }
// }
