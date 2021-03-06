library source_gen.generate;

import 'dart:async';
import 'dart:io';

import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:dart_style/src/dart_formatter.dart';
import 'package:path/path.dart' as p;

import 'generated_output.dart';
import 'generator.dart';
import 'io.dart';
import 'utils.dart';

/// Updates generated code for [projectPath] with the provided [generators].
///
/// [changeFilePaths] and [librarySearchPaths] must be relative to
/// [projectPath].
///
/// If [librarySearchPaths] is not provided, `['lib']` is used.
Future<String> generate(String projectPath, List<Generator> generators,
    {List<String> changeFilePaths, List<String> librarySearchPaths}) async {
  if (changeFilePaths == null || changeFilePaths.isEmpty) {
    if (librarySearchPaths != null && librarySearchPaths.isEmpty) {
      return "Can't hang, yo. You give me nothing!";
    }
  }

  if (librarySearchPaths == null) {
    librarySearchPaths = const ['lib'];
  }

  var foundFiles =
      await getDartFiles(projectPath, searchList: librarySearchPaths);

  if (changeFilePaths == null || changeFilePaths.isEmpty) {
    changeFilePaths =
        foundFiles.map((path) => p.relative(path, from: projectPath)).toList();
  }

  var fullPaths = changeFilePaths
      .where(pathToDartFile)
      .where((path) => !isGeneratedFile(path))
      .map((path) => p.join(projectPath, path))
      .where((path) => FileSystemEntity.isFileSync(path));

  var context = await getAnalysisContextForProjectPath(projectPath, foundFiles);

  var libs = getLibraries(context, fullPaths);

  if (libs.isEmpty) {
    return "No libraries found for provided paths:\n"
        "${changeFilePaths.map((p) => "  $p").join(', ')}\n"
        "They may not be in the search path.";
  }

  var messages = <String>[];

  await Future.forEach(libs, (elementLibrary) async {
    var msg =
        await _generateForLibrary(elementLibrary, projectPath, generators);
    messages.add(msg);
  });

  return messages.join('\n');
}

Future<String> _generateForLibrary(LibraryElement library, String projectPath,
    List<Generator> generators) async {
  var generatedOutputs = await _generate(library, generators).toList();

  var genFileName = _getGeterateFilePath(library, projectPath);

  var file = new File(genFileName);

  var exists = await file.exists();

  var relativeName = p.relative(genFileName, from: projectPath);
  if (generatedOutputs.isEmpty) {
    if (exists) {
      await file.delete();
      return "Deleted: '$relativeName'";
    } else {
      return 'Nothing to generate';
    }
  }

  var contentBuffer = new StringBuffer();

  contentBuffer.writeln('part of ${library.name};');
  contentBuffer.writeln();

  for (GeneratedOutput output in generatedOutputs) {
    contentBuffer.writeln('');
    contentBuffer.writeln(_headerLine);
    contentBuffer.writeln('// Generator: ${output.generator}');
    contentBuffer
        .writeln('// Target: ${frieldlyNameForElement(output.sourceMember)}');
    contentBuffer.writeln(_headerLine);
    contentBuffer.writeln('');

    contentBuffer.writeln(output.output);
  }

  var genPartContent = contentBuffer.toString();

  var existingContent = '';

  if (exists) {
    existingContent = findPartOf(await file.readAsString());
  }

  var formatter = new DartFormatter();
  genPartContent = formatter.format(genPartContent);

  if (existingContent == genPartContent) {
    return "No change: '$relativeName'";
  }

  var sink = file.openWrite(mode: FileMode.WRITE)
    ..write(_getHeader())
    ..write(genPartContent);

  await sink.flush();
  sink.close();

  if (exists) {
    return "Updated: '$relativeName'";
  } else {
    return "Created: '$relativeName'";
  }
}

String _getGeterateFilePath(LibraryElement lib, String projectPath) {
  var librarySource = lib.source as FileBasedSource;

  var libraryPath = p.fromUri(librarySource.uri);

  assert(p.isWithin(projectPath, libraryPath));

  var libraryDir = p.dirname(libraryPath);
  var libFileName = p.basename(libraryPath);
  assert(pathToDartFile(libFileName));

  assert(libFileName.indexOf('.') == libFileName.length - 5);

  libFileName = p.basenameWithoutExtension(libFileName);

  return p.join(libraryDir, "${libFileName}${generatedExtension}");
}

String _getHeader() => '''// GENERATED CODE - DO NOT MODIFY BY HAND
// ${new DateTime.now().toUtc().toIso8601String()}

''';

// TODO(kevmoo) using async* when we can
Stream<GeneratedOutput> _generate(
    LibraryElement unit, List<Generator> generators) {
  var controller = new StreamController<GeneratedOutput>();

  Future.forEach(getElementsFromLibraryElement(unit), (element) async {
    return controller.addStream(_processUnitMember(element, generators));
  }).whenComplete(() => controller.close());

  return controller.stream;
}

// TODO(kevmoo) use async* when we can
Stream<GeneratedOutput> _processUnitMember(
    Element element, List<Generator> generators) {
  var controller = new StreamController<GeneratedOutput>();

  Future.forEach(generators, (gen) async {
    try {
      var createdUnit = await gen.generate(element);

      if (createdUnit != null) {
        controller.add(new GeneratedOutput(element, gen, createdUnit));
      }
    } catch (e, stack) {
      controller.add(new GeneratedOutput.fromError(element, gen, e, stack));
    }
  }).whenComplete(() => controller.close());

  return controller.stream;
}

final _headerLine = '// '.padRight(77, '*');
