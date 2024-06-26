// Copyright 2020 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' as io;
import 'dart:convert';

import 'package:http/http.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

import 'src/common.dart';

class ChromeDriverInstaller {
  /// HTTP client used to download Chrome Driver.
  final Client client = Client();

  /// Installation directory for Chrome Driver.
  final io.Directory driverDir = io.Directory('chromedriver');

  static const String versionsWithDowloadsUrl =
      'https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json';

  static const String oldChromeDriverUrl =
      'https://chromedriver.storage.googleapis.com/';

  String chromeDriverVersion;

  String? downloadUrl;

  io.File? driverDownload;

  String get installationPath => path.join(
      driverDir.path, 'chromedriver-${platformName()}', 'chromedriver');

  io.File get installation => io.File(installationPath);

  bool get isInstalled => installation.existsSync();

  ChromeDriverInstaller() : this.chromeDriverVersion = '';

  ChromeDriverInstaller.withVersion(String version)
      : this.chromeDriverVersion = version;

  Future<void> start({bool alwaysInstall = false}) async {
    // Install Chrome Driver.
    try {
      await install(alwaysInstall: alwaysInstall);
      // Start using chromedriver --port=4444
      print('INFO: Starting Chrome Driver on port 4444');
      await runDriver();
    } finally {
      // Only delete if the user is planning to override the installs.
      // Keeping the existing version might make local development easier.
      // Also if a CI build runs multiple felt commands using an existing
      // version speeds up the build.
      if (!alwaysInstall) {
        driverDownload?.deleteSync();
      }
    }
  }

  Future<void> install({bool alwaysInstall = false}) async {
    if (!isInstalled || alwaysInstall) {
      await _installDriver();
    } else {
      print('INFO: Installation skipped. The driver is installed: '
          '$isInstalled. User requested force install: $alwaysInstall');
    }
  }

  Future<void> _installDriver() async {
    // If this method is called, clean the previous installations.
    if (isInstalled) {
      installation.deleteSync(recursive: true);
    }

    // Figure out which driver version to install if it's not given during
    // initialization.
    if (chromeDriverVersion.isEmpty) {
      final int chromeVersion = await _querySystemChromeVersion();

      if (chromeVersion < 74) {
        throw Exception('Unsupported Chrome version: $chromeVersion');
      }

      final YamlMap browserLock = DriverLock.instance.configuration;
      final YamlMap chromeDrivers = browserLock['chrome'];
      final String? chromeDriverVersion = chromeDrivers[chromeVersion];
      if (chromeDriverVersion == null) {
        throw Exception(
          'No known chromedriver version for Chrome version $chromeVersion.\n'
          'Known versions are:\n${chromeDrivers.entries.map((e) => '${e.key}: ${e.value}').join('\n')}',
        );
      } else {
        this.chromeDriverVersion = chromeDriverVersion;
      }
    }

    try {
      downloadUrl = await _downloadUrl();
      driverDownload = await _downloadDriver();
    } catch (e) {
      throw Exception(
          'Failed to download chrome driver $chromeDriverVersion. $e');
    } finally {
      client.close();
    }

    await _uncompress();
  }

  Future<int> _querySystemChromeVersion() async {
    String chromeExecutable = '';
    if (io.Platform.isLinux) {
      chromeExecutable = 'google-chrome';
    } else if (io.Platform.isMacOS) {
      chromeExecutable = await findChromeExecutableOnMac();
    } else {
      throw UnimplementedError('Web installers only work on Linux and Mac.');
    }

    final io.ProcessResult versionResult =
        await io.Process.run('$chromeExecutable', <String>['--version']);

    if (versionResult.exitCode != 0) {
      throw Exception('Failed to locate system Chrome.');
    }
    // The output looks like: Google Chrome 79.0.3945.36.
    final String output = versionResult.stdout as String;

    print('INFO: chrome version in use $output');

    // Version number such as 79.0.3945.36.
    final String versionAsString = output.split(' ')[2];

    final String versionNo = versionAsString.split('.')[0];

    return int.parse(versionNo);
  }

  /// Find Google Chrome App on Mac.
  Future<String> findChromeExecutableOnMac() async {
    io.Directory chromeDirectory = io.Directory('/Applications')
        .listSync()
        .whereType<io.Directory>()
        .firstWhere(
          (d) => path.basename(d.path).endsWith('Chrome.app'),
          orElse: () => throw Exception('Failed to locate system Chrome'),
        );

    final io.File chromeExecutableDir = io.File(
        path.join(chromeDirectory.path, 'Contents', 'MacOS', 'Google Chrome'));

    return chromeExecutableDir.path;
  }

  Future<String?> _downloadUrl() async {
    final Response versionsWithDownloads = await client.get(
      Uri.parse(versionsWithDowloadsUrl),
    );

    var versions = jsonDecode(versionsWithDownloads.body)['versions'];
    for (var version in versions) {
      if (version['version'] == chromeDriverVersion) {
        for (var download in version['downloads']['chromedriver']) {
          if (download['platform'] == platformName()) {
            return download['url'];
          }
        }
        break;
      }
    }

    // Old download url from https://chromedriver.chromium.org/downloads
    return '$oldChromeDriverUrl$chromeDriverVersion/${driverName()}';
  }

  Future<io.File> _downloadDriver() async {
    if (driverDir.existsSync()) {
      driverDir.deleteSync(recursive: true);
    }

    driverDir.createSync(recursive: true);

    print('downloading file from $downloadUrl');

    final StreamedResponse download = await client.send(Request(
      'GET',
      Uri.parse(downloadUrl!),
    ));

    final io.File downloadedFile =
        io.File(path.join(driverDir.path, driverName()));
    await download.stream.pipe(downloadedFile.openWrite());

    return downloadedFile;
  }

  /// Uncompress the downloaded driver file.
  Future<void> _uncompress() async {
    final io.ProcessResult unzipResult = await io.Process.run('unzip', <String>[
      driverDownload!.path,
      '-d',
      driverDir.path,
    ]);

    if (unzipResult.exitCode != 0) {
      throw Exception(
          'Failed to unzip the downloaded Chrome driver ${driverDownload!.path}.\n'
          'With the driver path ${driverDir.path}\n'
          'The unzip process exited with code ${unzipResult.exitCode}.');
    }
  }

  Future<void> runDriver() async {
    await io.Process.run(installationPath, <String>['--port=4444']);
  }

  static String platformName() {
    if (io.Platform.isMacOS) {
      return 'mac64';
    } else if (io.Platform.isLinux) {
      return 'linux64';
    } else if (io.Platform.isWindows) {
      return 'win32';
    } else {
      throw UnimplementedError('Automated testing not supported on this OS.'
          'Platform name: ${io.Platform.operatingSystem}');
    }
  }

  static String driverName() {
    return 'chromedriver_${platformName()}.zip';
  }
}
