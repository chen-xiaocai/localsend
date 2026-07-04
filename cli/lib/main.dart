import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cli/src/config.dart';
import 'package:cli/src/device_discovery.dart';
import 'package:cli/src/multicast.dart';
import 'package:cli/src/peer.dart';
import 'package:cli/src/receiver.dart';
import 'package:cli/src/sender.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:dart_mappable/dart_mappable.dart';

Future<void> main(List<String> arguments) async {
  // FileDto 用自定义 SimpleMapper,不会自动注册,必须手动注册到全局,
  // 否则 PrepareUploadRequestDto.fromJson 解析 files 时找不到 FileDto 解码器而抛错。
  // app 端在 config/init.dart 同样手动注册。
  MapperContainer.globals.use(const FileDtoMapper());

  final parser = ArgParser()
    ..addFlag('help',
        abbr: 'h', negatable: false, help: 'Prints usage information');

  // 每个子命令自带完整选项，避免 args 包「全局选项必须在命令前」的坑
  final receiveParser = parser.addCommand('receive');
  _addCommonOptions(receiveParser);

  final sendParser = parser.addCommand('send');
  _addCommonOptions(sendParser);
  sendParser.addOption('timeout',
      abbr: 't', defaultsTo: '5', help: 'Discovery timeout in seconds');
  sendParser.addOption('to',
      help:
          'Skip discovery, send directly to this IP (e.g. 100.75.58.59 for Tailscale)');
  sendParser.addOption('to-port',
      defaultsTo: '53317', help: 'Port of the target device (used with --to)');

  final devicesParser = parser.addCommand('devices');
  _addCommonOptions(devicesParser);
  devicesParser
    ..addOption('timeout',
        abbr: 't', defaultsTo: '5', help: 'Discovery timeout in seconds')
    ..addFlag('lan',
        defaultsTo: true, help: 'Discover devices via LAN multicast')
    ..addFlag('tailscale',
        defaultsTo: true, help: 'Probe online Tailscale peers')
    ..addFlag('json', negatable: false, help: 'Print machine-readable JSON');

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    _printUsage(parser, error: '$e');
    exit(64);
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    return;
  }

  final command = results.command;
  if (command == null) {
    _printUsage(parser);
    exit(64);
  }

  if (command['help'] as bool) {
    _printCommandUsage(command.name!, parser);
    return;
  }

  final cfg = await loadOrCreateConfig(
    alias: command['alias'] as String?,
    port: command['port'] == null
        ? null
        : int.tryParse(command['port'] as String),
    https: !(command['http'] as bool),
    destinationDir: command['dest'] as String?,
  );

  switch (command.name) {
    case 'receive':
      await _runReceive(cfg);
      break;
    case 'send':
      await _runSend(cfg, command);
      break;
    case 'devices':
      await _runDevices(cfg, command);
      break;
  }
}

void _addCommonOptions(ArgParser p) {
  p
    ..addFlag('help',
        abbr: 'h', negatable: false, help: 'Prints usage information')
    ..addOption('alias', help: 'Device name shown to other devices')
    ..addOption('port',
        abbr: 'p', defaultsTo: '53317', help: 'Port (default 53317)')
    ..addOption('dest', help: 'Receive destination directory')
    ..addFlag('http',
        negatable: false, help: 'Use HTTP instead of HTTPS (not recommended)');
}

Future<void> _runReceive(NodeConfig cfg) async {
  final receiver = ReceiverServer(
    config: cfg,
    onLog: _print,
    onPeerSeen: (peer) => _print('[peer seen] $peer'),
  );

  // 接收模式下同时跑多播监听 + 周期通告，让对端能发现自己
  final discovery = MulticastDiscovery(
    security: cfg.security,
    alias: cfg.alias,
    deviceModel: 'Linux',
    port: cfg.port,
    https: cfg.https,
    onPeer: (_) {},
  );
  await discovery.start();

  final announceTimer = Timer.periodic(const Duration(seconds: 3), (_) {
    unawaited(discovery.announce());
  });
  await discovery.announce();

  ProcessSignal.sigint.watch().listen((_) async {
    _print('\nStopping...');
    announceTimer.cancel();
    await discovery.stop();
    await receiver.stop();
    exit(0);
  });

  await receiver.start(); // 阻塞
}

Future<void> _runSend(NodeConfig cfg, ArgResults sendArgs) async {
  final filesArg = sendArgs.rest;
  if (filesArg.isEmpty) {
    stderr.writeln(
        'Usage: localsend send [--to <ip>] [--timeout 5] [--alias <name>] <file1> [file2 ...]');
    exit(64);
  }

  final files = <File>[];
  for (final p in filesArg) {
    final f = File(p);
    if (!await f.exists()) {
      stderr.writeln('File not found: $p');
      exit(66);
    }
    files.add(f);
  }

  final sender = SendClient(config: cfg, onLog: _print);
  final targetIp = (sendArgs['to'] as String?)?.trim();

  // 直连模式：指定 --to <ip> 时跳过多播发现（Tailscale 等非多播网络用）
  if (targetIp != null && targetIp.isNotEmpty) {
    final targetPort = int.tryParse(sendArgs['to-port'] as String) ?? cfg.port;
    final peer = DiscoveredPeer(
      ip: targetIp,
      port: targetPort,
      https: cfg.https,
      alias: '(manual)',
      fingerprint: '',
      source: PeerDiscoverySource.manual,
    );
    _print('Alias: ${cfg.alias}');
    _print(
        'Direct send to ${peer.ip}:${peer.port} (${cfg.https ? 'https' : 'http'}) — ${files.length} file(s)');
    final ok = await sender.sendTo(peer, files);
    exit(ok ? 0 : 1);
  }

  // 多播发现模式
  final timeoutSec = int.tryParse(sendArgs['timeout'] as String) ?? 5;
  _print('Alias: ${cfg.alias}');
  _print('Discovering nearby devices (timeout ${timeoutSec}s)...');
  final peers = await sender.discover(timeout: Duration(seconds: timeoutSec));

  if (peers.isEmpty) {
    stderr.writeln(
        'No devices found. Use --to <ip> for non-multicast networks (e.g. Tailscale).');
    exit(1);
  }

  _print('Found ${peers.length} device(s):');
  for (var i = 0; i < peers.length; i++) {
    _print('  [$i] ${peers[i]}');
  }

  stdout.write('Send to [0-${peers.length - 1}]: ');
  await stdout.flush();
  final input = stdin.readLineSync()?.trim() ?? '';
  final idx = int.tryParse(input);
  if (idx == null || idx < 0 || idx >= peers.length) {
    stderr.writeln('Invalid selection.');
    exit(64);
  }

  final ok = await sender.sendTo(peers[idx], files);
  exit(ok ? 0 : 1);
}

Future<void> _runDevices(NodeConfig cfg, ArgResults devicesArgs) async {
  final timeoutSec = int.tryParse(devicesArgs['timeout'] as String) ?? 5;
  final includeLan = devicesArgs['lan'] as bool;
  final includeTailscale = devicesArgs['tailscale'] as bool;
  final jsonOutput = devicesArgs['json'] as bool;

  if (!includeLan && !includeTailscale) {
    stderr
        .writeln('Enable at least one discovery source: --lan or --tailscale.');
    exit(64);
  }

  final client = DeviceDiscoveryClient(config: cfg);
  final peers = await client.discover(
    timeout: Duration(seconds: timeoutSec),
    includeLan: includeLan,
    includeTailscale: includeTailscale,
  );

  if (jsonOutput) {
    print(const JsonEncoder.withIndent('  ')
        .convert(peers.map(_peerToJson).toList()));
    return;
  }

  if (peers.isEmpty) {
    print('No online LocalSend devices found.');
    print(
        'Tip: Tailscale peers must be online and LocalSend must be running on port ${cfg.port}.');
    return;
  }

  _printDevicesTable(peers);
}

void _print(String line) => print(line);

Map<String, dynamic> _peerToJson(DiscoveredPeer peer) => {
      'alias': peer.alias,
      'ip': peer.ip,
      'port': peer.port,
      'protocol': peer.protocol,
      'system': peer.systemLabel,
      'deviceType': peer.deviceType.name,
      'deviceModel': peer.deviceModel,
      'source': _sourceLabel(peer.source),
      'fingerprint': peer.fingerprint,
    };

void _printDevicesTable(List<DiscoveredPeer> peers) {
  final rows = <List<String>>[
    ['Alias', 'IP', 'System', 'Source', 'Protocol'],
    for (final peer in peers)
      [
        peer.alias,
        '${peer.ip}:${peer.port}',
        peer.systemLabel,
        _sourceLabel(peer.source),
        peer.protocol,
      ],
  ];

  final widths = <int>[];
  for (var col = 0; col < rows.first.length; col++) {
    widths.add(
        rows.map((row) => row[col].length).reduce((a, b) => a > b ? a : b));
  }

  for (var row = 0; row < rows.length; row++) {
    final line = [
      for (var col = 0; col < rows[row].length; col++)
        rows[row][col].padRight(widths[col]),
    ].join('  ');
    print(line);
    if (row == 0) {
      print(widths.map((width) => '-' * width).join('  '));
    }
  }
}

String _sourceLabel(PeerDiscoverySource source) {
  switch (source) {
    case PeerDiscoverySource.lan:
      return 'lan';
    case PeerDiscoverySource.tailscale:
      return 'tailscale';
    case PeerDiscoverySource.manual:
      return 'manual';
  }
}

void _printUsage(ArgParser parser, {String? error}) {
  if (error != null) print('Error: $error\n');
  print('LocalSend headless CLI — receive/send files over LAN without GUI.');
  print('');
  print('Usage: localsend <command> [options]');
  print('');
  print('Commands:');
  print(
      '  receive              Start a receiver (QuickSave, auto-accept all incoming files).');
  print(
      '  send <files...>      Discover devices and send files to a chosen one.');
  print(
      '  devices              List online devices, including Tailscale peers.');
  print('');
  print('Run "localsend <command> -h" for command-specific options.');
}

void _printCommandUsage(String name, ArgParser root) {
  final cmd = root.commands[name]!;
  print('localsend $name [options]');
  print('');
  print('Options:');
  print(cmd.usage);
}
