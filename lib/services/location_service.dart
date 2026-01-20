import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

class LocationService {
  static Future<Position?> getCurrentLocation() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        final request = await Geolocator.requestPermission();
        if (request == LocationPermission.denied) {
          return null;
        }
      }
      
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      return null;
    }
  }
  
  static Future<String> getAddress(double latitude, double longitude) async {
    try {
      final placemarks = await placemarkFromCoordinates(latitude, longitude);
      if (placemarks.isEmpty) return 'Unknown location';
      
      final place = placemarks.first;
      final parts = [
        if (place.street != null && place.street!.isNotEmpty) place.street,
        if (place.subThoroughfare != null && place.subThoroughfare!.isNotEmpty) 'nr. ${place.subThoroughfare}',
        if (place.subLocality != null && place.subLocality!.isNotEmpty) place.subLocality,
        if (place.locality != null && place.locality!.isNotEmpty) place.locality,
        if (place.country != null && place.country!.isNotEmpty) place.country,
      ];
      
      return parts.join(', ');
    } catch (e) {
      return 'Unknown location';
    }
  }
}
