import 'dart:async';

import 'package:hasura_connect/hasura_connect.dart';
import 'package:http/http.dart' as http;

class HasuraConnectX extends HasuraConnect {
  HasuraConnectX(
    String url, {
    required Stream onAuthStateChanged,
    int? reconnectionAttemp,
    List<Interceptor>? interceptors,
    Map<String, String>? headers,
    http.Client Function()? httpClientFactory,
  }) : super(
          url,
          reconnectionAttemp: reconnectionAttemp,
          interceptors: interceptors,
          headers: headers,
          httpClientFactory: httpClientFactory,
        ) {
    authStateSubscription = onAuthStateChanged.skip(1).listen((event) {
      if (currentSnapshots.isNotEmpty) {
        refreshSubscriptions();
      }
    });
  }

  late StreamSubscription authStateSubscription;

  final Map<String, SnapshotX<Object>> currentSnapshots = {};

  Future<SnapshotX<Object>> subscriptionX(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  }) async {
    final snapshot = await super.subscription(
      document,
      key: key,
      variables: variables,
    );
    key = key ?? super.keyGenerator.generateBase(document);

    currentSnapshots[key] = SnapshotX(
      sourceSnapshot: snapshot,
      onClose: () => currentSnapshots.remove(key),
      onMap: (newSnapshotX) => currentSnapshots[key!] = newSnapshotX,
    );

    return currentSnapshots[key]!;
  }

  void refreshSubscriptions() async {
    await disconnect();

    _recreateSnapshots();
  }

  void _recreateSnapshots() {
    for (var key in currentSnapshots.keys) {
      final intermediateSnapshot = currentSnapshots[key]!;
      subscription(
        intermediateSnapshot.document,
        key: intermediateSnapshot.key,
        variables: intermediateSnapshot.variables,
      ).then((newSnapshot) {
        intermediateSnapshot.updateSourceSnapshot(newSnapshot);
      });
    }
  }

  @override
  Future<void> dispose() async {
    await authStateSubscription.cancel();
    return super.dispose();
  }
}

class SnapshotX<T> {
  Snapshot sourceSnapshot;
  final void Function()? onClose;
  final void Function(SnapshotX<T> newSnapshotX)? onMap;

  late StreamController<T> controller;
  late Stream<T> rootStream;

  final String key;
  final String document;
  Map<String, dynamic> variables;

  SnapshotX({
    required this.sourceSnapshot,
    required this.onClose,
    required this.onMap,
    StreamController<T>? controller,
    Stream<T>? rootStream,
  })  : key = sourceSnapshot.query.key!,
        document = sourceSnapshot.query.document,
        variables = sourceSnapshot.query.variables! {
    this.controller = controller ??
        StreamController(
          onListen: _pipe,
          onCancel: _onCancel,
        );
    this.rootStream = rootStream ?? this.controller.stream;
  }

  Future<void> changeVariables(Map<String, dynamic> variables) async {
    this.variables = variables;

    onMap?.call(this);

    await sourceSnapshot.changeVariables(variables);
  }

  void updateSourceSnapshot(Snapshot snapshot) {
    sourceSnapshot = snapshot;

    _sourceSnapshotSubscription?.cancel();

    _pipe();
  }

  StreamSubscription? _sourceSnapshotSubscription;

  dynamic latestEvent;

  void _pipe() {
    _sourceSnapshotSubscription = sourceSnapshot.listen((event) {
      if (latestEvent.toString() == event.toString()) return;
      latestEvent = event;
      controller.add(event);
    });
    _sourceSnapshotSubscription?.onError(controller.addError);
  }

  SnapshotX<S> map<S>(S Function(dynamic event) convert) {
    final newSnapshotX = SnapshotX<S>(
      sourceSnapshot: sourceSnapshot.map<S>(convert),
      rootStream: rootStream.map(convert),
      onClose: onClose,
      onMap: onMap as void Function(SnapshotX),
      controller: controller as StreamController<S>,
    );

    onMap?.call(newSnapshotX as SnapshotX<T>);
    return newSnapshotX;
  }

  void _onCancel() {
    _sourceSnapshotSubscription?.cancel();
  }

  void close() {
    _onCancel();
    sourceSnapshot.close();
    controller.close();
    onClose?.call();
  }

  StreamSubscription<T> listen(
    void Function(T event) onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return rootStream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
