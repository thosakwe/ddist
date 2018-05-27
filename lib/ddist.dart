import 'dart:async';
import 'dart:io' hide gzip;
import 'dart:isolate';
import 'package:dart2_constant/convert.dart';
import 'package:dart2_constant/io.dart';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:args/args.dart';
import 'package:cli_util/cli_util.dart';
import 'package:glob/glob.dart';
import 'package:io/ansi.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:system_info/system_info.dart';
import 'package:yaml/yaml.dart' as yaml;

final ArgParser argParser = new ArgParser(allowTrailingOptions: true)
  ..addFlag('build-runner',
      defaultsTo: true,
      help: 'Invoke `pub run build_runner build` before packaging.')
  ..addFlag('dry-run',
      defaultsTo: false,
      negatable: false,
      help: 'Do not actually create the tarball on disk.')
  ..addFlag('gzip',
      defaultsTo: true, help: 'Apply GZIP compression to the created tarball.')
  ..addFlag('help',
      abbr: 'h', negatable: false, help: 'Print this usage information.')
  ..addFlag('test',
      defaultsTo: true, help: 'Invoke `pub run test` before packaging.')
  ..addFlag('version-file',
      defaultsTo: true, help: 'Add a VERSION file to the output tarball.')
  ..addFlag('verbose', defaultsTo: false, help: 'Enable verbose output.')
  ..addOption('dir',
      abbr: 'd',
      help: 'The directory to save the tarball in.',
      defaultsTo: 'dist')
  ..addOption('name',
      defaultsTo: 'bin/main.dart',
      help: 'The file path to install <filename> to.')
  ..addOption('pubspec',
      defaultsTo: 'pubspec.yaml', help: 'The path to `pubspec.yaml`.')
  ..addMultiOption('copy',
      abbr: 'c',
      help: 'Globs to copy. Append `:<path>` to copy into <path>. ',
      defaultsTo: ['README.md', 'LICENSE'])
  ..addMultiOption('execute',
      abbr: 'x', help: 'Dart script(s) to be invoked before running.')
  ..addMultiOption('sdk',
      defaultsTo: [
        '_http',
        '_internal',
        'async',
        'collection',
        'convert',
        'core',
        'internal',
        'io',
        'isolate',
        'math',
        'typed_data'
      ],
      help: 'Standard Dart libraries to be bundled with the tarball.');

main(List<String> args) async {
  try {
    var argResults = argParser.parse(args);

    if (argResults['help']) {
      printUsage(stdout);
      return;
    }

    if (argResults.rest.isEmpty) throw new ArgParserException('no input file');

    hierarchicalLoggingEnabled = true;
    var logger = new Logger('ddist');
    logger.onRecord.listen((record) {
      if (record.level == Level.WARNING)
        stdout.writeln(yellow.wrap(record.toString()));
      else if (record.level == Level.SEVERE)
        stdout.writeln(red.wrap(record.toString()));
      else if (record.level == Level.SHOUT)
        stdout.writeln(blue.wrap(record.toString()));
      else
        stdout.writeln(record.toString());

      if (record.error != null)
        stdout.writeln(red.wrap(record.error.toString()));
    });

    var zone = Zone.current.fork(
        specification: new ZoneSpecification(
      print: (self, parent, zone, msg) {
        logger.info(msg);
      },
      handleUncaughtError: (self, parent, zone, error, stackTrace) {
        logger.severe('fatal error', error);
        parent.handleUncaughtError(zone, error, stackTrace);
      },
    ));

    await zone.run(() async {
      if (argResults['verbose']) logger.level = Level.FINEST;

      if (!Platform.version.startsWith('2'))
        logger.warning(
            'This package is only fully supported on Dart 2. Do not be surprised if your build breaks.');

      // Run build-runner, test, any tool scripts.
      if (argResults['build-runner'])
        await pubRun(logger, ['run', 'build_runner', 'build']);

      if (argResults['test'])
        await pubRun(logger,
            ['run', 'test', '-j', Platform.numberOfProcessors.toString()]);

      for (var script in argResults['execute']) {
        logger.config('Running "$script"...');
        var c = new Completer();
        var onExit = new ReceivePort()..listen(c.complete),
            onError = new ReceivePort()
              ..listen((list) => c.completeError(list[0], list[1]));
        var isolate = await Isolate.spawnUri(
            p.toUri(p.absolute(script)), [], null,
            onExit: onExit.sendPort, onError: onError.sendPort);
        await c.future;
        isolate.kill();
      }
    });

    // Configure the target triplet.
    var pubspec = new File(argResults['pubspec']);
    var pubspecMap = new Map<String, dynamic>.from(
        yaml.loadYaml(await pubspec.readAsString()));
    var name = pubspecMap['name'] ??=
        throw "Missing `name` field in '${argResults["pubspec"]}'.";
    var version = pubspecMap['version'] ??=
        throw "Missing `version` field in '${argResults["pubspec"]}'.";
    var platform = SysInfo.kernelName.toLowerCase().replaceAll(' ', '_');
    var arch = SysInfo.kernelArchitecture;
    var target = '$name-$version-$platform-$arch';
    var outName = p.normalize(
      p.absolute(
        p.join(argResults['dir'], target + '.tar'),
      ),
    );

    // Create the tarball.
    var archive = new Archive();

    Map<String, String> copy = {
      argResults.rest[0]: argResults['name'],
      Platform.executable: 'bin/' + (Platform.isWindows ? 'dart.exe' : 'dart'),
    };

    for (String path in argResults['copy']) {
      var glob = new Glob(path, recursive: true);
      var list = await glob.list().toList();

      if (list.length == 1) {
        if (!path.contains(':')) {
          copy[path] = path;
        } else {
          var split =
              path.split(':').where((s) => s.trim().isNotEmpty).toList();
          if (split.length < 1)
            throw 'Malformed `copy` string: "$path". Missing a path after the `:`.';
          copy[split[0].trim()] = split[1].trim();
        }
      } else {
        for (var entity in list) {
          if (entity is File) {
            if (!path.contains(':')) {
              copy[entity.path] = entity.path;
            } else {
              var split =
                  path.split(':').where((s) => s.trim().isNotEmpty).toList();
              if (split.length < 1)
                throw 'Malformed `copy` string: "$path". Missing a path after the `:`.';
              copy[entity.path] = p.join(split[1].trim(), entity.path);
            }
          }
        }
      }
    }

    if (argResults['version-file']) {
      logger.fine('Adding "VERSION" file with contents "$version"...');
      var archiveFile =
          new ArchiveFile('VERSION', version.length, utf8.encode(version))
            ..mode = 664
            ..lastModTime = new DateTime.now().millisecondsSinceEpoch;
      archive.addFile(archiveFile);
    }

    for (String sdkPath in argResults['sdk']) {
      var libPath = p.join(getSdkPath(), 'lib', sdkPath);

      await for (var entity in new Directory(libPath).list(recursive: true)) {
        if (entity is File) {
          var parts = ['dart-sdk', 'lib', sdkPath];
          copy[entity.path] = p.joinAll(
              parts..addAll(p.split(p.relative(entity.path, from: libPath))));
        }
      }
    }

    if (argResults['gzip']) outName = p.setExtension(outName, '.tar.gz');
    logger.config('Build target name: $target');
    logger.config('Output file: $outName');

    for (var path in copy.keys) {
      var to = copy[path];
      var ioFile = new File(path);
      var stat = await ioFile.stat();
      logger.fine('Copying "$path" into  archive "@ $to"...');

      if (!argResults['dry-run']) {
        var archiveFile = new ArchiveFile(
            to, await ioFile.length(), await ioFile.readAsBytes())
          ..mode = stat.mode
          ..lastModTime = stat.modified.millisecondsSinceEpoch;
        archive.addFile(archiveFile);
      }
    }

    if (argResults['dry-run']) {
      logger.info(
          'Option `dry-run` was passed. Not generating any tarball file.');
      exit(0);
      return;
    }

    logger.config('Tar-ing files...');
    var tarball = new TarEncoder().encode(archive);

    if (argResults['gzip']) {
      logger.fine('Gzipping archive...');
      tarball = gzip.encode(tarball);
    }

    var file = new File(outName);
    await file.createSync(recursive: true);
    await file.writeAsBytes(tarball);

    logger.clearListeners();
    exit(0);
  } on ArgParserException catch (e) {
    stderr..writeln('fatal error: $e')..writeln();
    printUsage(stderr);
    exit(1);
  } on String catch (e) {
    stderr.writeln('fatal error: $e');
    exit(1);
  }
}

void printUsage(IOSink sink) {
  sink
    ..writeln('ddist - dart executable packaging tool')
    ..writeln()
    ..writeln('© Tobechukwu Osakwe 2018. All rights reserved.')
    ..writeln()
    ..writeln('usage: ddist [options...] <filename>')
    ..writeln()
    ..writeln('Options:')
    ..writeln(argParser.usage);
}

Future pubRun(Logger logger, List<String> args) async {
  var pubPath =
      p.join(getSdkPath(), 'bin', Platform.isWindows ? 'pub.bat' : 'pub');
  logger.config('Path to `pub`: $pubPath');
  logger.info('Running $pubPath with $args...');
  // TODO: Eventually remove `INHERIT_STDIO`, replace with `inheritStdio`.
  var pub =
      await Process.start(pubPath, args, mode: ProcessStartMode.INHERIT_STDIO);
  var code = await pub.exitCode;
  if (code != 0) throw '`pub` with $args terminated with exit code $code.';
}
