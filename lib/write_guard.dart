import 'package:flutter/material.dart';

import 'sync/log.dart';

/// 予期した時計上限だけを案内する。他の不具合は握りつぶさない。
bool guardWrite(BuildContext context, void Function() write) {
  try {
    write();
    return true;
  } on ClockExhaustedException catch (error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.message)));
    return false;
  }
}
