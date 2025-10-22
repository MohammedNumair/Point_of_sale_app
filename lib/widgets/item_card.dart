// lib/widgets/item_card.dart
import 'package:flutter/material.dart';

class ItemCard extends StatelessWidget {
  final String itemName;
  final String uom;
  final String imageUrl;
  final String priceLabel;
  final VoidCallback onAdd;

  const ItemCard({
    super.key,
    required this.itemName,
    required this.uom,
    required this.imageUrl,
    required this.onAdd,
    required this.priceLabel,
  });

  @override
  Widget build(BuildContext context) {
    // Reduced image height and tighter paddings so cards are smaller
    final lead = (imageUrl.isNotEmpty)
        ? ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        imageUrl,
        width: double.infinity,
        height: 280, // smaller height
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) {
          return Container(
            width: double.infinity,
            height: 280,
            color: Colors.grey.shade200,
            child: const Icon(Icons.image, size: 36, color: Colors.grey),
          );
        },
      ),
    )
        : Container(
      width: double.infinity,
      height: 280,
      decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
      child: const Icon(Icons.inventory, size: 36, color: Colors.grey),
    );

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 0.6,
      child: SizedBox(
        height: 230, // fixed-ish card height to keep layout consistent
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            lead,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6),
              child: Text(itemName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text(uom, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(child: Text(priceLabel, style: const TextStyle(fontWeight: FontWeight.bold))),
                  ElevatedButton(
                    onPressed: onAdd,
                    style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    child: const Text('Add'),
                  )
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}












// // lib/widgets/item_card.dart
// import 'package:flutter/material.dart';
//
// class ItemCard extends StatelessWidget {
//   final String itemName;
//   final String uom;
//   final String imageUrl;
//   final VoidCallback onAdd;
//
//   const ItemCard({super.key, required this.itemName, required this.uom, required this.imageUrl, required this.onAdd});
//
//   @override
//   Widget build(BuildContext context) {
//     final lead = (imageUrl.isNotEmpty)
//         ? Image.network(imageUrl, width: 56, height: 56, fit: BoxFit.cover, errorBuilder: (_,__,___) => const Icon(Icons.image))
//         : const Icon(Icons.inventory, size: 48);
//
//     return Card(
//       child: ListTile(
//         leading: lead,
//         title: Text(itemName),
//         subtitle: Text(uom),
//         trailing: ElevatedButton(onPressed: onAdd, child: const Text('Add')),
//       ),
//     );
//   }
// }
