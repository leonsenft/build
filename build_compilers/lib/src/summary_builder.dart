// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'package:bazel_worker/bazel_worker.dart';
import 'package:build/build.dart';
import 'package:scratch_space/scratch_space.dart';

import 'errors.dart';
import 'modules.dart';
import 'scratch_space.dart';
import 'workers.dart';

final String linkedSummaryExtension = '.linked.sum';
final String unlinkedSummaryExtension = '.unlinked.sum';

/// A builder which can output unlinked summaries!
class UnlinkedSummaryBuilder implements Builder {
  @override
  final buildExtensions = {
    '.dart': [unlinkedSummaryExtension]
  };

  @override
  Future build(BuildStep buildStep) async {
    if (!await buildStep.resolver.isLibrary(buildStep.inputId)) return;

    var library = await buildStep.inputLibrary;
    if (!isPrimary(library)) return;

    var module = new Module.forLibrary(library);
    try {
      await createUnlinkedSummary(module, buildStep);
    } catch (e, s) {
      log.warning('Error creating ${module.unlinkedSummaryId}:\n$e\n$s');
    }
  }
}

/// A builder which can output linked summaries!
class LinkedSummaryBuilder implements Builder {
  @override
  final buildExtensions = {
    '.dart': [linkedSummaryExtension]
  };

  @override
  Future build(BuildStep buildStep) async {
    if (!await buildStep.resolver.isLibrary(buildStep.inputId)) return;

    var library = await buildStep.inputLibrary;
    if (!isPrimary(library)) return;

    var module = new Module.forLibrary(library);
    try {
      await createLinkedSummary(module, buildStep);
    } catch (e, s) {
      log.warning('Error creating ${module.linkedSummaryId}:\n$e\n$s');
    }
  }
}

/// Creates an unlinked summary for [module].
Future createUnlinkedSummary(Module module, BuildStep buildStep,
    {bool isRoot = false}) async {
  var scratchSpace = await buildStep.fetchResource(scratchSpaceResource);
  await scratchSpace.ensureAssets(module.sources, buildStep);

  var summaryOutputFile = scratchSpace.fileFor(module.unlinkedSummaryId);
  var request = new WorkRequest();
  // TODO(jakemac53): Diet parsing results in erroneous errors in later steps,
  // but ideally we would do that (pass '--build-summary-only-diet').
  request.arguments.addAll([
    '--build-summary-only',
    '--build-summary-only-unlinked',
    '--build-summary-output=${summaryOutputFile.path}',
    '--strong',
  ]);
  // Add all the files to include in the unlinked summary bundle.
  request.arguments.addAll(_analyzerSourceArgsForModule(module, scratchSpace));
  var response = await analyzerDriver.doWork(request);
  if (response.exitCode == EXIT_CODE_ERROR) {
    throw new AnalyzerSummaryException(
        module.unlinkedSummaryId, response.output);
  }

  // Copy the output back using the buildStep.
  await scratchSpace.copyOutput(module.unlinkedSummaryId, buildStep);
}

/// Creates a linked summary for [module].
Future createLinkedSummary(Module module, BuildStep buildStep,
    {bool isRoot = false}) async {
  var transitiveDeps =
      await module.computeTransitiveDependencies(buildStep.resolver);
  var transitiveSummaryDeps =
      transitiveDeps.map((id) => id.changeExtension(unlinkedSummaryExtension));
  var scratchSpace = await buildStep.fetchResource(scratchSpaceResource);

  var allAssetIds = new Set<AssetId>()
    ..addAll(module.sources)
    ..addAll(transitiveSummaryDeps);
  await scratchSpace.ensureAssets(allAssetIds, buildStep);
  var summaryOutputFile = scratchSpace.fileFor(module.linkedSummaryId);
  var request = new WorkRequest();
  // TODO(jakemac53): Diet parsing results in erroneous errors in later steps,
  // but ideally we would do that (pass '--build-summary-only-diet').
  request.arguments.addAll([
    '--build-summary-only',
    '--build-summary-output=${summaryOutputFile.path}',
    '--strong',
  ]);
  // Add all the unlinked summaries as build summary inputs.
  request.arguments.addAll(transitiveSummaryDeps.map((id) =>
      '--build-summary-unlinked-input=${scratchSpace.fileFor(id).path}'));
  // Add all the files to include in the linked summary bundle.
  request.arguments.addAll(_analyzerSourceArgsForModule(module, scratchSpace));
  var response = await analyzerDriver.doWork(request);
  if (response.exitCode == EXIT_CODE_ERROR) {
    throw new AnalyzerSummaryException(module.linkedSummaryId, response.output);
  }

  // Copy the output back using the buildStep.
  await scratchSpace.copyOutput(module.linkedSummaryId, buildStep);
}

Iterable<String> _analyzerSourceArgsForModule(
    Module module, ScratchSpace scratchSpace) {
  return module.sources.map((id) {
    var uri = canonicalUriFor(id);
    var file = scratchSpace.fileFor(id);
    if (!uri.startsWith('package:')) {
      uri = file.uri.toString();
    }
    return '$uri|${file.path}';
  });
}
