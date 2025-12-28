import 'package:flutter/material.dart';

class DiskInfo {
  final String name;
  final String path;
  final IconData icon;
  final String? uuid;
  final String? vendor;
  final String? model;

  DiskInfo({
    required this.name,
    required this.path,
    required this.icon,
    this.uuid,
    this.vendor,
    this.model,
  });

  String get friendlyName {
    if (vendor != null || model != null) {
      return "${vendor ?? ''} ${model ?? ''}".trim();
    }
    return name;
  }
}
