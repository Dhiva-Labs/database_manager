// Minimal FFI bindings for liblmdb (needs the system library, e.g.
// `sudo apt install liblmdb0` on Debian/Ubuntu).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---- constants (lmdb.h) ----
const int mdbRdonly = 0x20000;
const int mdbNosubdir = 0x4000;
const int mdbCreate = 0x40000;
const int mdbCpCompact = 0x01;
const int mdbNotfound = -30798;

// cursor ops
const int mdbFirst = 0;
const int mdbNextOp = 8;
const int mdbSetRange = 17;

final class MDBVal extends Struct {
  @Size()
  external int mvSize;
  external Pointer<Void> mvData;
}

class Lmdb {
  final DynamicLibrary _lib;

  Lmdb._(this._lib) {
    envCreate = _lib.lookupFunction<Int32 Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)>('mdb_env_create');
    envOpen = _lib.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32, Uint32),
        int Function(
            Pointer<Void>, Pointer<Utf8>, int, int)>('mdb_env_open');
    envClose = _lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('mdb_env_close');
    envSetMaxdbs = _lib.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)>('mdb_env_set_maxdbs');
    envSetMapsize = _lib.lookupFunction<Int32 Function(Pointer<Void>, Size),
        int Function(Pointer<Void>, int)>('mdb_env_set_mapsize');
    envCopy2 = _lib.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32),
        int Function(Pointer<Void>, Pointer<Utf8>, int)>('mdb_env_copy2');
    txnBegin = _lib.lookupFunction<
        Int32 Function(
            Pointer<Void>, Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Void>, int,
            Pointer<Pointer<Void>>)>('mdb_txn_begin');
    txnCommit = _lib.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('mdb_txn_commit');
    txnAbort = _lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('mdb_txn_abort');
    dbiOpen = _lib.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Utf8>, int,
            Pointer<Uint32>)>('mdb_dbi_open');
    put = _lib.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<MDBVal>,
            Pointer<MDBVal>, Uint32),
        int Function(Pointer<Void>, int, Pointer<MDBVal>, Pointer<MDBVal>,
            int)>('mdb_put');
    del = _lib.lookupFunction<
        Int32 Function(
            Pointer<Void>, Uint32, Pointer<MDBVal>, Pointer<MDBVal>),
        int Function(Pointer<Void>, int, Pointer<MDBVal>,
            Pointer<MDBVal>)>('mdb_del');
    cursorOpen = _lib.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(
            Pointer<Void>, int, Pointer<Pointer<Void>>)>('mdb_cursor_open');
    cursorGet = _lib.lookupFunction<
        Int32 Function(
            Pointer<Void>, Pointer<MDBVal>, Pointer<MDBVal>, Int32),
        int Function(Pointer<Void>, Pointer<MDBVal>, Pointer<MDBVal>,
            int)>('mdb_cursor_get');
    cursorClose = _lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('mdb_cursor_close');
    strerror = _lib.lookupFunction<Pointer<Utf8> Function(Int32),
        Pointer<Utf8> Function(int)>('mdb_strerror');
  }

  late final int Function(Pointer<Pointer<Void>>) envCreate;
  late final int Function(Pointer<Void>, Pointer<Utf8>, int, int) envOpen;
  late final void Function(Pointer<Void>) envClose;
  late final int Function(Pointer<Void>, int) envSetMaxdbs;
  late final int Function(Pointer<Void>, int) envSetMapsize;
  late final int Function(Pointer<Void>, Pointer<Utf8>, int) envCopy2;
  late final int Function(
      Pointer<Void>, Pointer<Void>, int, Pointer<Pointer<Void>>) txnBegin;
  late final int Function(Pointer<Void>) txnCommit;
  late final void Function(Pointer<Void>) txnAbort;
  late final int Function(
      Pointer<Void>, Pointer<Utf8>, int, Pointer<Uint32>) dbiOpen;
  late final int Function(
      Pointer<Void>, int, Pointer<MDBVal>, Pointer<MDBVal>, int) put;
  late final int Function(
      Pointer<Void>, int, Pointer<MDBVal>, Pointer<MDBVal>) del;
  late final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      cursorOpen;
  late final int Function(
      Pointer<Void>, Pointer<MDBVal>, Pointer<MDBVal>, int) cursorGet;
  late final void Function(Pointer<Void>) cursorClose;
  late final Pointer<Utf8> Function(int) strerror;

  String errText(int rc) => strerror(rc).toDartString();

  static Lmdb? _instance;

  static Lmdb open() {
    if (_instance != null) return _instance!;
    final candidates = Platform.isWindows
        ? ['lmdb.dll', 'liblmdb.dll']
        : [
            'liblmdb.so',
            'liblmdb.so.0',
            '/usr/lib/x86_64-linux-gnu/liblmdb.so.0',
            '/usr/lib/liblmdb.so',
            'liblmdb.dylib',
          ];
    for (final c in candidates) {
      try {
        return _instance = Lmdb._(DynamicLibrary.open(c));
      } catch (_) {/* try next */}
    }
    throw Exception(
        'liblmdb not found. Install it first (Ubuntu/Debian: sudo apt install liblmdb0).');
  }
}

/// Copies [bytes] into a natively allocated MDBVal. Caller frees both.
Pointer<MDBVal> mdbValFrom(Uint8List bytes) {
  final data = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  data.asTypedList(bytes.isEmpty ? 1 : bytes.length).setAll(0, bytes.isEmpty ? [0] : bytes);
  final val = malloc<MDBVal>();
  val.ref.mvSize = bytes.length;
  val.ref.mvData = data.cast();
  return val;
}

Uint8List mdbValBytes(Pointer<MDBVal> val) {
  final size = val.ref.mvSize;
  if (size == 0) return Uint8List(0);
  return Uint8List.fromList(
      val.ref.mvData.cast<Uint8>().asTypedList(size));
}
