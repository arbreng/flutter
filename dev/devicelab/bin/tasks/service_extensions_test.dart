// Copyright (c) 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_devicelab/framework/adb.dart';
import 'package:flutter_devicelab/framework/framework.dart';
import 'package:flutter_devicelab/framework/utils.dart';
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

void main() {
  task(() async {
    int vmServicePort;

    final Device device = await devices.workingDevice;
    await device.unlock();
    final Directory appDir = dir(path.join(flutterDirectory.path, 'dev/integration_tests/ui'));
    await inDirectory(appDir, () async {
      final Completer<void> ready = Completer<void>();
      bool ok;
      print('run: starting...');
      final Process run = await startProcess(
        path.join(flutterDirectory.path, 'bin', 'flutter'),
        <String>['run', '--verbose', '--disable-service-auth-codes', '-d', device.deviceId, 'lib/main.dart'],
      );
      run.stdout
          .transform<String>(utf8.decoder)
          .transform<String>(const LineSplitter())
          .listen((String line) {
        print('run:stdout: $line');
        if (vmServicePort == null) {
          vmServicePort = parseServicePort(line);
          if (vmServicePort != null) {
            print('service protocol connection available at port $vmServicePort');
            print('run: ready!');
            ready.complete();
            ok ??= true;
          }
        }
      });
      run.stderr
          .transform<String>(utf8.decoder)
          .transform<String>(const LineSplitter())
          .listen((String line) {
        stderr.writeln('run:stderr: $line');
      });
      run.exitCode.then<void>((int exitCode) { ok = false; });
      await Future.any<dynamic>(<Future<dynamic>>[ ready.future, run.exitCode ]);
      if (!ok)
        throw 'Failed to run test app.';

      final VmService client = await vmServiceConnectUri('ws://localhost:$vmServicePort/ws');
      final VM vm = await client.getVM();
      final IsolateRef isolateRef = vm.isolates.first;

      client.streamListen(EventStreams.kExtension);

      final StreamController<Event> frameEventsController = StreamController<Event>();
      final StreamController<Event> navigationEventsController = StreamController<Event>();
      client.onExtensionEvent.listen((Event event) {
        if (event.extensionKind == 'Flutter.Frame') {
          frameEventsController.add(event);
        } else if (event.extensionKind == 'Flutter.Navigation') {
          navigationEventsController.add(event);
        }
      });

      final Stream<Event> frameEvents = frameEventsController.stream;
      final Stream<Event> navigationEvents = navigationEventsController.stream;

      print('reassembling app...');
      final Future<Event> frameFuture = frameEvents.first;
      await client.callServiceExtension('ext.flutter.reassemble', isolateId: isolateRef.id);

      // ensure we get an event
      final Event event = await frameFuture;
      print('${event.extensionKind}: ${event.extensionData}');

      final Map<String, dynamic> eventData = event.extensionData.data.cast<String, dynamic>();

      // validate the fields
      // {number: 8, startTime: 0, elapsed: 1437, build: 600, raster: 800}
      expect(eventData['number'] is int);
      expect(eventData['number'] >= 0);
      expect(eventData['startTime'] is int);
      expect(eventData['startTime'] >= 0);
      expect(eventData['elapsed'] is int);
      expect(eventData['elapsed'] >= 0);
      expect(eventData['build'] is int);
      expect(eventData['build'] >= 0);
      expect(eventData['raster'] is int);
      expect(eventData['raster'] >= 0);

      final Future<Event> navigationFuture = navigationEvents.first;
      // This tap triggers a navigation event.
      device.tap(100, 200);

      final Event navigationEvent = await navigationFuture;
      // validate the fields
      expect(navigationEvent.extensionData.data['route'] is Map<dynamic, dynamic>);
      final Map<dynamic, dynamic> route = navigationEvent.extensionData.data['route'];
      expect(route['description'] is String);
      expect(route['settings'] is Map<dynamic, dynamic>);
      final Map<dynamic, dynamic> settings = route['settings'];
      expect(settings.containsKey('name'));
      expect(settings['isInitialRoute'] is bool);

      run.stdin.write('q');
      final int result = await run.exitCode;
      if (result != 0)
        throw 'Received unexpected exit code $result from run process.';
    });
    return TaskResult.success(null);
  });
}

void expect(bool value) {
  if (!value)
    throw 'failed assertion in service extensions test';
}
