import 'dart:convert';

import 'package:http/http.dart' as http;

class BarcodeApi {
  Future<String> getFoodItemByUPC(String upc) async {
    print(upc);
    final httpPackageUrl = Uri.parse(
      "https://world.openfoodfacts.org/api/v0/product/$upc.json",
    );
    final httpPackageInfo = await http.read(httpPackageUrl);
    final httpPackageJson =
        json.decode(httpPackageInfo) as Map<String, dynamic>;
    return httpPackageJson['product']['product_name'];
  }
}
