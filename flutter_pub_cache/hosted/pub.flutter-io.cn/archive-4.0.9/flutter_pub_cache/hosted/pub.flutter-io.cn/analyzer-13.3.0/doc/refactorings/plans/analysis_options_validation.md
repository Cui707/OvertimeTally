# Analysis Options Validation Entry Point

This document describes the current analysis-options validation model in analyzer, the problems caused by having several visible validation entry points, and a staged plan for moving to one validation entry point that can be tested and reviewed incrementally.

The goal is to make analysis-options diagnostics behave as one coherent product feature:

```text
analysis options file + source resolution + context inputs
  -> diagnostics for the initial file and included files
```

The proposed direction is to introduce a single entry point for diagnostics, for example:

```dart
final class AnalysisOptionsValidator {
  AnalysisOptionsValidator({
    required SourceFactory sourceFactory,
    required ResourceProvider resourceProvider,
    required String contextRoot,
    VersionConstraint? sdkVersionConstraint,
    AnalysisOptionsCache? analysisOptionsCache,
  });

  List<Diagnostic> validateFile(File file);

  @visibleForTesting
  List<Diagnostic> validateContent({
    required File file,
    required String content,
  });
}
```

Internally, this entry point may still delegate to several small validators. The important distinction is that callers and most tests should not need to know which internal validator owns a particular YAML section or cross-file lint rule check.

The desired long-term split is:

- `AnalysisOptionsProvider`: parse, resolve includes, and merge effective YAML.
- `AnalysisOptionsValidator`: validate analysis-options files and produce diagnostics.
- `AnalysisOptionsImpl.fromYaml`: apply a merged `YamlMap` to actual analyzer behavior.

## Table of Contents

- [Current Model](#current-model)
  - [AnalysisOptionsFileKeys](#current-keys)
  - [AnalysisOptionsProvider](#current-provider)
  - [OptionsValidator](#current-options-validator)
  - [OptionsFileValidator](#current-options-file-validator)
  - [AnalyzerOptionsValidator](#current-analyzer-options-validator)
  - [LinterRuleOptionsValidator](#current-linter-rule-options-validator)
  - [AnalysisOptionsAnalyzer](#current-analysis-options-analyzer)
  - [AnalysisOptionsImpl](#current-analysis-options-impl)
  - [AnalysisOptionsMap And Context Construction](#current-context-construction)
  - [Tests](#current-tests)
- [Current Data Flow](#current-data-flow)
  - [Production Options Application](#flow-production-application)
  - [Options Diagnostics](#flow-options-diagnostics)
  - [Lint Rule Cross-File Validation](#flow-lint-cross-file)
  - [Test Diagnostics](#flow-test-diagnostics)
- [Problems](#problems)
  - [No Single Validation Surface](#problem-no-single-surface)
  - [Analyzer Is A Misleading Name](#problem-analyzer-name)
  - [Tests Encode Internal Structure](#problem-tests-internals)
  - [Include Handling Is Split Across Components](#problem-include-split)
  - [Validation And Application Boundaries Are Blurry](#problem-validation-application)
  - [Public, Package-Private, And Private Boundaries Are Unclear](#problem-visibility)
  - [Test Organization Is Hard To Interpret](#problem-test-organization)
  - [Provider Documentation Does Not Match Current Behavior](#problem-provider-doc)
- [Design Goals](#design-goals)
- [Non-Goals](#non-goals)
- [Proposed Direction](#proposed-direction)
  - [Single Validation Entry Point](#proposed-entry-point)
  - [Internal Component Validators](#proposed-component-validators)
  - [Provider Remains A Loader](#proposed-provider)
  - [Application Remains Separate](#proposed-application)
  - [Testing Through One Surface](#proposed-testing)
  - [Naming](#proposed-naming)
- [Proposed API Shape](#proposed-api-shape)
  - [Constructor Inputs](#api-constructor-inputs)
  - [Validation Methods](#api-validation-methods)
  - [Result Type](#api-result-type)
  - [Test Helper Shape](#api-test-helper)
- [Migration Plan](#migration-plan)
  - [Stage 0: Document The Current Model](#stage-0)
  - [Stage 1: Tests Only - Introduce One Shared Test Harness](#stage-1)
  - [Stage 2: Tests Only - Move OptionsFileValidator Tests To The Harness](#stage-2)
  - [Stage 3: Tests Only - Move LinterRuleOptionsValidator Tests To The Harness](#stage-3)
  - [Stage 4: Tests Only - Normalize Include Diagnostic Tests](#stage-4)
  - [Stage 5: Implementation Only - Add AnalysisOptionsValidator As A Wrapper](#stage-5)
  - [Stage 6: Tests Only - Switch The Harness To AnalysisOptionsValidator](#stage-6)
  - [Stage 7: Implementation Only - Move Include Walking Behind The New Class](#stage-7)
  - [Stage 8: Implementation Only - Rename Or Retire AnalysisOptionsAnalyzer](#stage-8)
  - [Stage 9: Tests Only - Remove Redundant Direct Validator Tests](#stage-9)
  - [Stage 10: Implementation Only - Narrow Internal Visibility](#stage-10)
  - [Stage 11: Implementation Only - Clarify Provider Documentation](#stage-11)
  - [Stage 12: Optional Implementation - Add Structured Validation Result](#stage-12)
- [Review Strategy](#review-strategy)
- [Suggested CL Boundaries](#suggested-cl-boundaries)
- [Open Questions](#open-questions)

<a name="current-model"></a>
## Current Model

Analysis-options support is currently split across several files and classes. Some pieces are cleanly separated, but their boundaries are not obvious from tests or names.

<a name="current-keys"></a>
### AnalysisOptionsFileKeys

`pkg/analyzer/lib/src/analysis_options/analysis_options_file.dart` contains `AnalysisOptionsFileKeys`.

This class is the vocabulary for the options file. It defines top-level keys such as:

- `analyzer`
- `code-style`
- `formatter`
- `linter`
- `plugins`

It also defines nested keys such as:

- `include`
- `errors`
- `exclude`
- `language`
- `optional-checks`
- `enable-experiment`
- `rules`
- `page_width`
- `trailing_commas`

It is not a parser and not a validator. It is a centralized list of known key strings and small sets of supported option names or supported literal values.

<a name="current-provider"></a>
### AnalysisOptionsProvider

`pkg/analyzer/lib/src/analysis_options/analysis_options_provider.dart` contains `AnalysisOptionsProvider`.

The provider loads analysis-options YAML and produces `YamlMap`s. Its main responsibilities are:

- parse content using `loadYamlNode`,
- return an empty `YamlMap` for non-map YAML content,
- throw `OptionsFormatException` for malformed YAML in string parsing,
- resolve `include` directives through a `SourceFactory`,
- recursively load included files,
- cache loaded `YamlMap`s through `AnalysisOptionsCache`,
- merge included options with the including file,
- rewrite relative plugin path options from included files.

The important semantic point is that the provider is not a diagnostic validator. When an include cannot be resolved, or when an include would repeat a handled source, the provider returns the options it can compute. It does not report `includeFileNotFound`, `recursiveIncludeFile`, or `includedFileWarning`.

The provider's merge behavior is delegated to `Merger` in `pkg/analyzer/lib/src/util/yaml.dart`:

- maps merge recursively,
- lists merge without duplicates,
- list-of-string lint rules can be promoted to map-of-bool lint rules,
- an overriding scalar replaces a default scalar,
- a `null` overriding scalar leaves the default value in place.

This means `AnalysisOptionsProvider` answers "what effective YAML should be used?" It does not answer "what diagnostics should be reported?"

<a name="current-options-validator"></a>
### OptionsValidator

`pkg/analyzer/lib/src/analysis_options/options_validator.dart` defines the small validator interface:

```dart
abstract class OptionsValidator {
  void validate(DiagnosticReporter reporter, YamlMap options);
}
```

Several internal validators implement this shape. The interface is useful, but it is not itself the desired user-facing analysis-options validation entry point. It validates one already-parsed `YamlMap` using a caller-supplied `DiagnosticReporter`.

<a name="current-options-file-validator"></a>
### OptionsFileValidator

`pkg/analyzer/lib/src/analysis_options/options_file_validator.dart` contains `OptionsFileValidator`.

`OptionsFileValidator` is a composite validator for one options YAML map. It does not own parsing and does not own include traversal. It owns a list of component validators:

- `AnalyzerOptionsValidator`
- `_CodeStyleOptionsValidator`
- `_FormatterOptionsValidator`
- `_LinterTopLevelOptionsValidator`
- `LinterRuleOptionsValidator`
- `_PluginsOptionsValidator`

It calls each component validator in order. It is a good internal abstraction: it hides the list of section validators behind one "validate this map" method.

However, it is currently visible enough that tests call it directly. That makes test structure reflect implementation structure rather than product behavior.

<a name="current-analyzer-options-validator"></a>
### AnalyzerOptionsValidator

`AnalyzerOptionsValidator` is another composite validator, scoped to the `analyzer:` section. It delegates to smaller validators such as:

- `_AnalyzerTopLevelOptionsValidator`
- `_StrongModeOptionValueValidator`
- `_ErrorFilterOptionValidator`
- `_EnableExperimentsValidator`
- `_LanguageOptionValidator`
- `_OptionalChecksValueValidator`
- `_CannotIgnoreOptionValidator`

This is a reasonable internal split. The current problem is not that these private validators exist; the problem is that there is no equally clear top-level validation facade for analysis-options diagnostics.

<a name="current-linter-rule-options-validator"></a>
### LinterRuleOptionsValidator

`pkg/analyzer/lib/src/lint/options_rule_validator.dart` contains `LinterRuleOptionsValidator`.

This validator owns lint-rule semantics inside the `linter:` section:

- undefined lint names,
- supported lint values,
- duplicate enabled rules,
- incompatible rules in the same file,
- incompatible rules across included files,
- deprecated lints,
- deprecated lints with replacements,
- removed lints,
- replaced lints.

This validator is special because it reads included options too. It uses `AnalysisOptionsProvider.getOptionsFromFile` to find lint rules from included files so that it can compare the current file's rules with included rules.

That include reading is not the same responsibility as include diagnostic traversal. It is needed to answer lint-rule semantic questions such as "does this file enable a rule that is incompatible with a rule enabled in an included file?"

<a name="current-analysis-options-analyzer"></a>
### AnalysisOptionsAnalyzer

`pkg/analyzer/lib/src/analysis_options/options_file_validator.dart` also contains `AnalysisOptionsAnalyzer`.

Despite the name, this class is the closest thing to the desired diagnostic entry point. It:

- accepts an initial `Source`,
- parses the initial content,
- calls `OptionsFileValidator` for that file,
- finds `include` directives,
- resolves included sources,
- reports missing include diagnostics,
- reports recursive include diagnostics,
- validates included files,
- wraps diagnostics from included files as `includedFileWarning` at the original include location,
- tracks the include chain while walking.

Its public method is:

```dart
List<Diagnostic> walkIncludes({required String content})
```

This is useful but not ideal as the main API:

- the class name says "Analyzer" rather than "Validator",
- the method name describes an implementation detail rather than the operation,
- it takes content for the initial source instead of simply validating a file,
- it has significant mutable traversal state,
- it is in the same file as the component validators,
- tests still bypass it for many cases.

<a name="current-analysis-options-impl"></a>
### AnalysisOptionsImpl

`pkg/analyzer/lib/src/dart/analysis/analysis_options.dart` contains `AnalysisOptionsImpl` and `AnalysisOptionsBuilder`.

`AnalysisOptionsImpl.fromYaml` applies a merged `YamlMap` to the analyzer's runtime behavior. It computes fields such as:

- `errorProcessors`,
- enabled experiments,
- `excludePatterns`,
- language strictness flags,
- optional checks,
- legacy plugin names,
- new plugin configurations,
- linter rule configs and enabled lint rules,
- code-style options,
- formatter options,
- unignorable diagnostic code names.

This step is not diagnostic validation. It intentionally ignores malformed shapes in many places, because validation is expected to have happened through the diagnostic path.

<a name="current-context-construction"></a>
### AnalysisOptionsMap And Context Construction

`ContextBuilder` constructs analysis contexts by:

1. finding an options file for each relevant folder,
2. using `AnalysisOptionsProvider.getOptionsFromFile` to get merged YAML,
3. using `AnalysisOptionsImpl.fromYaml` to build runtime options,
4. storing the result in an `AnalysisOptionsMap`.

`ContextLocator` also uses `AnalysisOptionsProvider` for tasks that need early knowledge of options, such as legacy plugin discovery and excluded glob discovery.

These paths rely on options loading and application. They do not necessarily produce user-facing diagnostics about the options file.

<a name="current-tests"></a>
### Tests

The tests are split across several locations.

`pkg/analyzer/test/source/analysis_options_provider_test.dart` tests provider loading and merge behavior. These tests are appropriately focused on `AnalysisOptionsProvider`.

`pkg/analyzer/test/src/options/analysis_options_test.dart` tests `AnalysisOptionsImpl.fromYaml`, so it is focused on application behavior.

`pkg/analyzer/test/src/options/options_provider_test.dart` uses provider and application APIs to test effective options. It also has some behavior that is close to validation concerns.

`pkg/analyzer/test/src/options/options_file_validator_test.dart` calls `OptionsFileValidator` directly for many section-validation cases. It also has cases that use `AnalysisOptionsAnalyzer` when include traversal is needed.

`pkg/analyzer/test/src/options/options_rule_validator_test.dart` calls `LinterRuleOptionsValidator` directly for many lint-rule semantic cases.

`pkg/analyzer/test/src/diagnostics/analysis_options/*` uses an `AbstractAnalysisOptionsTest` harness that calls `AnalysisOptionsAnalyzer`.

Recent test work converted many of these tests to inline diagnostic expectations. This is a good direction because it makes source ranges and messages reviewable. But the tests still enter through multiple validation paths.

<a name="current-data-flow"></a>
## Current Data Flow

<a name="flow-production-application"></a>
### Production Options Application

Normal context construction applies options roughly as follows:

```text
ContextBuilder
  sourceFactory = workspace.createSourceFactory(...)
  provider = AnalysisOptionsProvider(sourceFactory)

  for each options file:
    optionsMap = provider.getOptionsFromFile(file)
    options = AnalysisOptionsImpl.fromYaml(
      optionsMap: optionsMap,
      file: file,
      resourceProvider: resourceProvider,
    )
    analysisOptionsMap[folder] = options
```

This path needs a merged options map. It does not need to produce validation diagnostics while building `AnalysisOptionsImpl`.

<a name="flow-options-diagnostics"></a>
### Options Diagnostics

Diagnostics for an options file are produced roughly as follows:

```text
AnalysisOptionsAnalyzer.walkIncludes(content)
  options = AnalysisOptionsProvider.getOptionsFromString(content)
  _validate(options)
    OptionsFileValidator.validate(options, reporter)
      AnalyzerOptionsValidator.validate(...)
      _CodeStyleOptionsValidator.validate(...)
      _FormatterOptionsValidator.validate(...)
      _LinterTopLevelOptionsValidator.validate(...)
      LinterRuleOptionsValidator.validate(...)
      _PluginsOptionsValidator.validate(...)

    for each include:
      resolve included source
      report include diagnostics if needed
      parse included content
      temporarily switch reporter/listener/source
      _validate(includedOptions)
      wrap included diagnostics as includedFileWarning
```

This is the behavior that should become the single validation entry point.

<a name="flow-lint-cross-file"></a>
### Lint Rule Cross-File Validation

Lint-rule validation has an additional internal include read:

```text
LinterRuleOptionsValidator.validate(options)
  rules = options['linter']['rules']
  includeNode = options['include']
  _validateRules(rules, reporter, includeNode)
    _processIncludes(includeNode, reporter, disabledRules)
      for each include:
        includedOptions = AnalysisOptionsProvider.getOptionsFromFile(file)
        collect enabled lint rules
        compare included rules with current and previously seen included rules
```

This is why simply saying "include traversal belongs in exactly one place" is too imprecise. There are two include-related questions:

- What files should be validated, and where should diagnostics be reported?
- What effective or included lint rules are relevant to this file's lint semantics?

The first belongs in the top-level validation entry point. The second can remain inside `LinterRuleOptionsValidator`, but should be hidden behind the single entry point for callers and most tests.

<a name="flow-test-diagnostics"></a>
### Test Diagnostics

Inline diagnostic expectation tests now generally do this:

```text
test code with markers
  -> removeDiagnosticExpectations
  -> write marker-free files
  -> run one analyzer/validator path
  -> updateExpectedDiagnosticsForFiles
  -> compare regenerated code with original code
```

The good part is that expected diagnostics are now close to source text. The remaining issue is that different tests choose different analyzer/validator paths before the expectation comparison.

<a name="problems"></a>
## Problems

<a name="problem-no-single-surface"></a>
### No Single Validation Surface

There is no obvious class whose contract is:

```text
validate this analysis options file and return the diagnostics users should see
```

The closest existing class is `AnalysisOptionsAnalyzer`, but its name, location, and method shape do not communicate this role.

As a result, tests and future production callers can reasonably choose several different entry points:

- `AnalysisOptionsAnalyzer`
- `OptionsFileValidator`
- `LinterRuleOptionsValidator`
- direct provider parsing followed by a validator

This increases the chance that a test passes through a lower-level path while the real user-visible path has different include handling, source locations, or diagnostic wrapping.

<a name="problem-analyzer-name"></a>
### Analyzer Is A Misleading Name

`AnalysisOptionsAnalyzer` is doing validation, not Dart code analysis. The name also conflicts with the broader analyzer package, where "analysis" usually means a much larger operation involving contexts, drivers, files, libraries, and resolution.

The method name `walkIncludes` is also implementation-oriented. A caller wants to validate options. Include walking is one detail of how validation is implemented.

<a name="problem-tests-internals"></a>
### Tests Encode Internal Structure

Direct tests of `OptionsFileValidator` and `LinterRuleOptionsValidator` make the internal split sticky. If a future refactoring wants to move lint-rule validation behind a different helper or merge it into another component, many tests must change even if user-visible behavior stays the same.

The test suite should primarily protect observable behavior:

- diagnostic code,
- diagnostic message,
- diagnostic source range,
- context messages,
- which file owns each diagnostic,
- include wrapping behavior.

Those are properties of the top-level validation operation, not of a particular private validator class.

<a name="problem-include-split"></a>
### Include Handling Is Split Across Components

Includes are currently involved in three places:

- `AnalysisOptionsProvider` resolves and merges includes for effective YAML.
- `AnalysisOptionsAnalyzer` walks includes to validate included files and report include diagnostics.
- `LinterRuleOptionsValidator` reads included options to compare lint rules across files.

This split is understandable, but it is hard to explain from the current class names alone. It also makes it easy to test only one part of include behavior.

For example, a direct `LinterRuleOptionsValidator` test can check an incompatible included lint, but it does not necessarily exercise:

- malformed included YAML wrapping,
- missing include diagnostics,
- recursive include diagnostics,
- source span ownership through the first include in a chain,
- validation of non-linter sections in included files.

<a name="problem-validation-application"></a>
### Validation And Application Boundaries Are Blurry

`AnalysisOptionsProvider.getOptionsFromFile` and `AnalysisOptionsImpl.fromYaml` are used in production context construction. `AnalysisOptionsAnalyzer` and validators are used for diagnostics. Tests sometimes cross these concerns.

This can obscure the intended contracts:

- loading and merging should be tolerant and diagnostic-free,
- validation should report malformed or unsupported options,
- application should compute runtime behavior from a `YamlMap`.

A single validation entry point would make this separation easier to state.

<a name="problem-visibility"></a>
### Public, Package-Private, And Private Boundaries Are Unclear

Many validators are private classes, but some important internal classes are package-visible. Tests import and instantiate these classes directly.

This makes it harder to know which classes are intended extension points, stable internal seams, or implementation details.

The current visibility is not necessarily wrong for today's code, but it does not express the desired architecture.

<a name="problem-test-organization"></a>
### Test Organization Is Hard To Interpret

There are tests under both:

- `test/src/options`
- `test/src/diagnostics/analysis_options`

The difference is not obvious. Some tests are about effective options, some are about validation diagnostics, and some are about include behavior. The current directory split makes it easy to confuse:

- provider tests,
- application tests,
- diagnostic tests,
- lower-level validator tests.

The target state should make diagnostic tests use the same validation helper, even if physical files remain split by feature for readability.

<a name="problem-provider-doc"></a>
### Provider Documentation Does Not Match Current Behavior

`AnalysisOptionsProvider.getOptionsFromFile` says that it recursively merges included options and removes any `include` directive from the resulting options map. Current behavior can leave the including file's `include` key in the merged map.

This is not the main refactoring target, but it is a source of confusion when trying to understand which component owns include semantics.

Any cleanup should be staged separately from validation behavior changes.

<a name="design-goals"></a>
## Design Goals

- Provide one obvious analysis-options validation entry point.
- Make the entry point start from an options file or file-like source identity, not from an already-parsed `YamlMap`.
- Keep parsing, include traversal, validation, and diagnostic source ownership inside that entry point.
- Keep section validators as internal implementation details.
- Preserve current diagnostic behavior unless a CL explicitly states and tests a behavior change.
- Make tests for analysis-options diagnostics enter through the same validation surface.
- Keep provider merge tests separate, because merge semantics are a distinct behavior.
- Keep `AnalysisOptionsImpl.fromYaml` application tests separate, because runtime behavior is distinct from diagnostics.
- Allow Gerrit review to proceed in small CLs that mostly change either tests or implementation, not both.
- Make each migration CL have a simple safety story.

<a name="non-goals"></a>
## Non-Goals

- Do not redesign the analysis-options YAML format.
- Do not change merge semantics as part of the validation entry-point refactoring.
- Do not change diagnostic messages, locations, or wrapping behavior unless a dedicated CL explicitly does so.
- Do not remove internal validators just to reduce the number of classes. Private component validators are useful.
- Do not force all analysis-options tests into one physical Dart class if that makes the file too large. The important target is one test entry surface.
- Do not make `AnalysisOptionsImpl.fromYaml` report diagnostics.
- Do not make `AnalysisOptionsProvider` report diagnostics.
- Do not require production context construction to validate options while applying them.
- Do not make analyzer plugin option validation part of this refactoring beyond preserving the current `_PluginsOptionsValidator` behavior.

<a name="proposed-direction"></a>
## Proposed Direction

<a name="proposed-entry-point"></a>
### Single Validation Entry Point

Introduce a class whose name and API express the desired operation:

```dart
final class AnalysisOptionsValidator {
  List<Diagnostic> validateFile(File file);

  @visibleForTesting
  List<Diagnostic> validateContent({
    required File file,
    required String content,
  });
}
```

The exact names can change, but the class should be responsible for:

- initial YAML parsing,
- parse diagnostics for malformed initial YAML,
- section validation for the initial file,
- include resolution,
- missing include diagnostics,
- recursive include diagnostics,
- validation of included files,
- included-file warning wrapping,
- preserving current source ranges and context messages,
- sharing the `AnalysisOptionsCache` used by internal components.

The new class can initially be a wrapper around `AnalysisOptionsAnalyzer`. Later CLs can move or rename the existing implementation.

<a name="proposed-component-validators"></a>
### Internal Component Validators

Keep component validators for local complexity:

- analyzer section validator,
- formatter validator,
- code-style validator,
- linter top-level validator,
- lint-rule validator,
- plugins validator.

These validators should be internal. Tests should usually not instantiate them directly. Direct tests are appropriate only when a component owns behavior that is deliberately independent from the full validation operation and difficult to exercise through a file.

This preserves a deep module shape:

```text
public-ish interface:
  AnalysisOptionsValidator.validateFile(file)

internal implementation:
  include traversal
  composite map validator
  section validators
  lint semantic validator
```

<a name="proposed-provider"></a>
### Provider Remains A Loader

`AnalysisOptionsProvider` should remain focused on loading and merging:

```text
input:  file/source/content
output: YamlMap
```

It should not grow a diagnostic listener. That would mix tolerant loading with user-facing validation and would make production context construction more complicated.

If the provider documentation is inaccurate, fix the documentation or behavior in a dedicated CL after the validation surface is clearer.

<a name="proposed-application"></a>
### Application Remains Separate

`AnalysisOptionsImpl.fromYaml` should remain the application step:

```text
input:  merged YamlMap
output: AnalysisOptionsImpl
```

It should not call `AnalysisOptionsValidator`. Context construction can keep using provider + application. Options diagnostics can keep using validator.

This separation lets clients choose whether they are computing runtime behavior, reporting diagnostics, or both.

<a name="proposed-testing"></a>
### Testing Through One Surface

Analysis-options diagnostic tests should use one shared helper, for example:

```dart
Future<void> assertAnalysisOptionsDiagnosticsInFiles(
  Map<File, String> codeByFile, {
  File? initialFile,
  VersionConstraint? sdkVersionConstraint,
  Map<String, String>? packageDependencies,
});
```

That helper should:

1. strip inline diagnostic expectation markers,
2. write all marker-free files,
3. construct the same `SourceFactory` shape used by current tests,
4. call the single validation entry point,
5. regenerate inline expectations from actual diagnostics,
6. diff regenerated content against expected content.

The physical tests can remain split by feature:

- include diagnostics,
- analyzer section diagnostics,
- formatter diagnostics,
- code-style diagnostics,
- linter rule diagnostics,
- plugin diagnostics.

But all diagnostic tests should enter through the same helper.

Provider merge tests and `AnalysisOptionsImpl.fromYaml` tests should stay separate because they test different behavior.

<a name="proposed-naming"></a>
### Naming

The suggested names are:

- `AnalysisOptionsValidator`: top-level diagnostic entry point.
- `_AnalysisOptionsValidatorWalker` or private methods inside `AnalysisOptionsValidator`: include traversal implementation, if useful.
- `_OptionsFileValidator`: composite validator for one `YamlMap`, if direct external use is removed.
- `_AnalyzerOptionsValidator`: composite validator for `analyzer:`.
- `_LinterRuleOptionsValidator`: lint-rule semantic validator, if it can be made private later.

The exact privacy changes should wait until tests no longer need direct access.

<a name="proposed-api-shape"></a>
## Proposed API Shape

<a name="api-constructor-inputs"></a>
### Constructor Inputs

The validator needs roughly the same inputs as `AnalysisOptionsAnalyzer` today:

```dart
final class AnalysisOptionsValidator {
  AnalysisOptionsValidator({
    required SourceFactory sourceFactory,
    required ResourceProvider resourceProvider,
    required String contextRoot,
    VersionConstraint? sdkVersionConstraint,
    AnalysisOptionsCache? analysisOptionsCache,
  });
}
```

Input meanings:

- `sourceFactory`: resolves `include` URIs, including `package:` includes.
- `resourceProvider`: converts paths and files, and supports linter include comparisons.
- `contextRoot`: used in diagnostics such as `includeFileNotFound`.
- `sdkVersionConstraint`: used by lint-rule lifecycle checks.
- `analysisOptionsCache`: optional shared cache for one atomic validation task.

The cache should remain optional. Tests can usually pass none. Production callers that already have a cache can pass one.

<a name="api-validation-methods"></a>
### Validation Methods

The production-oriented method should validate a file:

```dart
List<Diagnostic> validateFile(File file);
```

This method should read the file contents through the file/source path that matches existing behavior.

Tests benefit from validating synthetic content without requiring a separate write/read cycle for the initial file. However, because inline expectation tests already write files after stripping markers, a content method is optional. If added, it should be explicitly testing-oriented:

```dart
@visibleForTesting
List<Diagnostic> validateContent({
  required File file,
  required String content,
});
```

This method means:

- use `file` as the source identity and base URI,
- use `content` as the initial file's content,
- resolve included files from the file/source identity,
- read included file contents normally.

<a name="api-result-type"></a>
### Result Type

Initially, return `List<Diagnostic>` to preserve existing behavior and reduce the size of the refactor.

A later optional CL can introduce:

```dart
final class AnalysisOptionsValidationResult {
  final List<Diagnostic> diagnostics;
}
```

This gives room for future metadata such as:

- parsed initial options,
- included file graph,
- files read,
- whether validation was incomplete due to parse failure.

That is optional and should not be part of the first migration.

<a name="api-test-helper"></a>
### Test Helper Shape

The test helper should live close to existing analysis-options diagnostic test support. It should hide:

- marker stripping,
- file writes,
- source factory construction,
- validator construction,
- diagnostic-to-marker regeneration.

One possible shape:

```dart
mixin AnalysisOptionsValidationTestSupport
    on ResourceProviderMixin, LintRegistrationMixin {
  late SourceFactory sourceFactory;

  File get analysisOptionsFile => getFile('/analysis_options.yaml');

  Future<void> assertAnalysisOptionsDiagnostics(
    String code, {
    VersionConstraint? sdkVersionConstraint,
  }) async {
    await assertAnalysisOptionsDiagnosticsInFiles({
      analysisOptionsFile: code,
    }, sdkVersionConstraint: sdkVersionConstraint);
  }

  Future<void> assertAnalysisOptionsDiagnosticsInFiles(
    Map<File, String> codeByFile, {
    File? initialFile,
    VersionConstraint? sdkVersionConstraint,
  }) async {
    ...
  }
}
```

The current `AnalysisOptionsDiagnosticExpectationMixin` can either be renamed or kept as the low-level expectation comparison helper.

<a name="migration-plan"></a>
## Migration Plan

The migration should be intentionally boring. Most CLs should change either tests or implementation, not both. When both must change, the implementation change should be a pure wrapper or mechanical relocation with unchanged expectations.

<a name="stage-0"></a>
### Stage 0: Document The Current Model

Type: documentation only.

Create this document.

Purpose:

- establish shared terminology before code movement,
- make clear that multiple internal validators are acceptable,
- define the target as one validation entry surface,
- give reviewers a staged plan.

Expected behavior change:

- none.

Review safety story:

- documentation only.

Possible CL title:

```text
Document analysis options validation refactoring plan
```

<a name="stage-1"></a>
### Stage 1: Tests Only - Introduce One Shared Test Harness

Type: tests only.

Add a shared helper for analysis-options diagnostic tests. Initially, this helper should delegate to the existing `AnalysisOptionsAnalyzer.walkIncludes`.

The helper should be capable of replacing the existing direct calls from:

- `test/src/diagnostics/analysis_options/analysis_options_test_support.dart`
- `test/src/options/options_file_validator_test.dart`
- `test/src/options/options_rule_validator_test.dart`

But this stage should add the helper without migrating many tests.

Detailed changes:

1. Add a helper method such as `assertAnalysisOptionsDiagnosticsInFiles`.
2. Keep the existing inline expectation comparison code.
3. Keep existing `AbstractAnalysisOptionsTest` methods as forwarding wrappers.
4. Add one or two small tests that use the new helper directly.
5. Do not change production code.

The helper should accept:

- a map from `File` to marked source text,
- an optional initial file,
- an optional SDK version constraint,
- optional package dependencies if needed by the existing test support.

Expected behavior change:

- none.

Review safety story:

- The helper calls the same current implementation.
- Existing tests still pass through their old helpers.
- New helper behavior is demonstrated by a small number of tests.

Possible CL title:

```text
Add shared analysis options diagnostic test harness
```

Rollback plan:

- Delete the new helper and the small tests using it.

<a name="stage-2"></a>
### Stage 2: Tests Only - Move OptionsFileValidator Tests To The Harness

Type: tests only.

Migrate diagnostic tests in `options_file_validator_test.dart` from direct `OptionsFileValidator.validate` calls to the shared helper.

This stage exercises the full validation path for section-level diagnostics. It is the first proof that general options-file diagnostics can be tested without directly instantiating `OptionsFileValidator`.

Detailed changes:

1. Replace helper methods named like `validate(...)` so that they call the shared analysis-options diagnostic helper.
2. Preserve existing inline expectations.
3. Preserve test names.
4. Preserve test file organization.
5. Adjust setup only where direct validator construction is no longer needed.
6. Keep any tests that truly require direct validator access temporarily, but mark them with a TODO explaining why.

Important review detail:

- If expected diagnostic locations or messages change, stop and investigate. This stage should not intentionally change expectations.

Expected behavior change:

- none.

Review safety story:

- No production code changes.
- Expected diagnostics are unchanged.
- Tests now cover more realistic include/source behavior because they enter through the top-level path.

Possible CL title:

```text
Run options file validator tests through analysis options harness
```

Rollback plan:

- Restore the old `validate(...)` helper body.

<a name="stage-3"></a>
### Stage 3: Tests Only - Move LinterRuleOptionsValidator Tests To The Harness

Type: tests only.

Migrate diagnostic tests in `options_rule_validator_test.dart` from direct `LinterRuleOptionsValidator.validate` calls to the shared helper.

This stage is more sensitive than Stage 2 because lint-rule validation has cross-file include behavior and SDK-version-dependent lifecycle checks.

Detailed changes:

1. Replace `assertDiagnostics` and `assertRuleDiagnosticsInFiles` helpers so they call the shared analysis-options diagnostic helper.
2. Preserve lint rule registration setup.
3. Preserve package dependency setup for `package:` include tests.
4. Preserve SDK version parameters.
5. Preserve all inline diagnostic expectations.
6. Keep test files physically organized by included-file, rule, and value cases if that remains readable.

If direct validator tests reveal expectations that differ from the full path, handle them deliberately:

- If the full path reports additional diagnostics that users really see, update tests in this stage and call it out in the CL description.
- If the additional diagnostics are noise caused by test setup, adjust setup to preserve existing behavior.
- If a lower-level behavior is intentionally different from full validation, keep a small direct unit test and document why.

Expected behavior change:

- none intended.

Review safety story:

- No production code changes.
- Lint-rule diagnostics are now verified through the user-visible path.
- Inline expectations make any source range or message drift obvious.

Possible CL title:

```text
Run linter options rule tests through analysis options harness
```

Rollback plan:

- Restore the old mixin methods that construct `LinterRuleOptionsValidator`.

<a name="stage-4"></a>
### Stage 4: Tests Only - Normalize Include Diagnostic Tests

Type: tests only.

The diagnostics tests under `test/src/diagnostics/analysis_options` already use `AnalysisOptionsAnalyzer`. This stage should make them use the same shared helper as the `test/src/options` diagnostics tests.

Detailed changes:

1. Update `AbstractAnalysisOptionsTest` to delegate to the shared helper.
2. Remove duplicate expectation-comparison code if it has moved.
3. Keep existing include tests in their current files unless there is an obvious low-risk consolidation.
4. Ensure tests still cover:
   - missing package include,
   - missing relative include,
   - self include,
   - include cycles,
   - diagnostics in included files wrapped as `includedFileWarning`,
   - multiple includes,
   - quoted and unquoted include values.

Expected behavior change:

- none.

Review safety story:

- No production code changes.
- Existing tests still exercise the same implementation.
- All analysis-options diagnostics now share one test surface.

Possible CL title:

```text
Share analysis options diagnostic harness across include tests
```

Rollback plan:

- Restore `AbstractAnalysisOptionsTest` to call `AnalysisOptionsAnalyzer` directly.

<a name="stage-5"></a>
### Stage 5: Implementation Only - Add AnalysisOptionsValidator As A Wrapper

Type: implementation only, with minimal tests if required by analyzer test coverage policy.

Add the new top-level validation class. Initially, it should be a thin wrapper around `AnalysisOptionsAnalyzer`.

Possible location:

```text
pkg/analyzer/lib/src/analysis_options/analysis_options_validator.dart
```

Possible implementation sketch:

```dart
final class AnalysisOptionsValidator {
  final SourceFactory sourceFactory;
  final ResourceProvider resourceProvider;
  final String contextRoot;
  final VersionConstraint? sdkVersionConstraint;
  final AnalysisOptionsCache _analysisOptionsCache;

  AnalysisOptionsValidator({
    required this.sourceFactory,
    required this.resourceProvider,
    required this.contextRoot,
    this.sdkVersionConstraint,
    AnalysisOptionsCache? analysisOptionsCache,
  }) : _analysisOptionsCache = analysisOptionsCache ?? {};

  List<Diagnostic> validateFile(File file) {
    return validateContent(file: file, content: file.readAsStringSync());
  }

  @visibleForTesting
  List<Diagnostic> validateContent({
    required File file,
    required String content,
  }) {
    return AnalysisOptionsAnalyzer(
      initialSource: FileSource(file),
      sourceFactory: sourceFactory,
      contextRoot: contextRoot,
      sdkVersionConstraint: sdkVersionConstraint,
      resourceProvider: resourceProvider,
      analysisOptionsCache: _analysisOptionsCache,
    ).walkIncludes(content: content);
  }
}
```

This stage should not move existing implementation logic. It should not rename `AnalysisOptionsAnalyzer`. It should not change tests to use the new class yet, except perhaps one narrow wrapper test.

Expected behavior change:

- none for existing callers.

Review safety story:

- New wrapper delegates to existing implementation.
- Existing tests keep exercising the old path.
- The CL creates the future API without moving behavior.

Possible CL title:

```text
Add AnalysisOptionsValidator wrapper entry point
```

Rollback plan:

- Delete the new file/class.

<a name="stage-6"></a>
### Stage 6: Tests Only - Switch The Harness To AnalysisOptionsValidator

Type: tests only.

Change the shared test harness from Stage 1 to construct and call `AnalysisOptionsValidator` instead of `AnalysisOptionsAnalyzer`.

Because Stages 2 through 4 moved diagnostic tests behind the shared helper, this should be a small change with broad coverage.

Detailed changes:

1. Update the helper's import.
2. Replace construction of `AnalysisOptionsAnalyzer` with `AnalysisOptionsValidator`.
3. Call `validateContent` or `validateFile`, depending on the helper's shape.
4. Preserve all inline expectations.

Expected behavior change:

- none.

Review safety story:

- Production implementation is unchanged from Stage 5.
- The wrapper is now covered by the full analysis-options diagnostic suite.
- Any wrapper mismatch appears as inline expectation failures.

Possible CL title:

```text
Test analysis options diagnostics through AnalysisOptionsValidator
```

Rollback plan:

- Change the helper back to `AnalysisOptionsAnalyzer`.

<a name="stage-7"></a>
### Stage 7: Implementation Only - Move Include Walking Behind The New Class

Type: implementation only.

Move the include-walking implementation from `AnalysisOptionsAnalyzer` into `AnalysisOptionsValidator`, or into a private helper owned by `analysis_options_validator.dart`.

This is the first structural implementation refactor. It should preserve the same public wrapper methods introduced in Stage 5.

Detailed changes:

1. Copy or move the state currently in `AnalysisOptionsAnalyzer`:
   - initial diagnostic listener/reporter,
   - current diagnostic listener/reporter,
   - source factory,
   - context root,
   - SDK version constraint,
   - resource provider,
   - initial include span,
   - provider,
   - first plugin name,
   - include chain,
   - analysis options cache.
2. Preserve the validation algorithm.
3. Preserve `_IncludedDiagnosticListener` behavior.
4. Keep `AnalysisOptionsAnalyzer` temporarily as a compatibility shim, if needed:

```dart @Deprecated('Use AnalysisOptionsValidator') class AnalysisOptionsAnalyzer {
     ...
} ```

Or keep it package-private until all internal callers move.
5. Do not change expected diagnostics.

Expected behavior change:

- none.

Review safety story:

- The test suite already enters through `AnalysisOptionsValidator`.
- This is a move/rename of code that is already covered by full-path tests.
- Inline expectations should remain unchanged.

Possible CL title:

```text
Move analysis options include validation into AnalysisOptionsValidator
```

Rollback plan:

- Restore wrapper delegation to `AnalysisOptionsAnalyzer`.

<a name="stage-8"></a>
### Stage 8: Implementation Only - Rename Or Retire AnalysisOptionsAnalyzer

Type: implementation only.

Remove the old `AnalysisOptionsAnalyzer` name if no callers remain. If removing it in one CL is too large, first make it private or deprecated, then delete it in a follow-up CL.

Detailed changes:

1. Search for remaining references to `AnalysisOptionsAnalyzer`.
2. Replace them with `AnalysisOptionsValidator`.
3. Delete the old class or convert it to a private implementation detail.
4. Move `_IncludedDiagnosticListener` near the new validation implementation.
5. Keep `OptionsFileValidator` in place as the internal composite validator.

Expected behavior change:

- none.

Review safety story:

- The class being removed has already been replaced by a wrapper and then by migrated tests.
- All diagnostics tests use the new entry point.

Possible CL title:

```text
Remove old AnalysisOptionsAnalyzer validation entry point
```

Rollback plan:

- Reintroduce the shim class delegating to `AnalysisOptionsValidator`.

<a name="stage-9"></a>
### Stage 9: Tests Only - Remove Redundant Direct Validator Tests

Type: tests only.

After tests enter through `AnalysisOptionsValidator`, audit any remaining direct tests of internal validators.

Keep direct tests only when they satisfy one of these conditions:

- They test a pure helper behavior that is intentionally independent from file validation.
- They are much smaller and clearer than the equivalent full-path test.
- They cover an internal invariant that should fail close to the component rather than through a broad integration test.

Remove or convert direct tests that merely duplicate full-path diagnostics.

Detailed changes:

1. Audit direct instantiations of `OptionsFileValidator`.
2. Audit direct instantiations of `LinterRuleOptionsValidator`.
3. Delete redundant test helpers.
4. Preserve test coverage for every diagnostic code currently covered.
5. Consider splitting large files by feature if readability suffers.

Expected behavior change:

- none.

Review safety story:

- No production code changes.
- Removed tests are redundant with full-path tests.
- The CL description should list which old direct test groups are now covered through the shared validation helper.

Possible CL title:

```text
Remove redundant direct analysis options validator tests
```

Rollback plan:

- Restore deleted direct tests.

<a name="stage-10"></a>
### Stage 10: Implementation Only - Narrow Internal Visibility

Type: implementation only.

Once tests no longer instantiate internal validators, narrow the implementation surface.

Possible changes:

- Rename `OptionsFileValidator` to `_OptionsFileValidator` if it has no package-external callers.
- Keep `OptionsValidator` package-visible only if it remains useful across files.
- Move or privatize section validators.
- Move `LinterRuleOptionsValidator` closer to the options validation implementation, or make it private if there are no legitimate external callers.

This stage may need to be split into multiple CLs if visibility changes touch many imports.

Expected behavior change:

- none.

Review safety story:

- Tests have already stopped depending on these internals.
- Public behavior is covered through `AnalysisOptionsValidator`.
- This CL makes code visibility match actual ownership.

Possible CL title:

```text
Hide analysis options component validators
```

Rollback plan:

- Restore class names/visibility without changing behavior.

<a name="stage-11"></a>
### Stage 11: Implementation Only - Clarify Provider Documentation

Type: implementation only, documentation/comments, possibly tests if behavior is corrected.

Clarify `AnalysisOptionsProvider` documentation around include handling.

There are two possible directions:

1. Update the comment to match current behavior:

   - includes are used to load and merge included options,
   - the returned map may still contain the including file's `include` key,
   - consumers should ignore `include` unless they intentionally need it.

2. Change provider behavior to remove `include` from returned maps, if that is the intended contract.

Direction 1 is safer and should be preferred unless there is a strong reason to change behavior.

Expected behavior change:

- none if documentation only.

Review safety story:

- This is separated from validation refactoring.
- It resolves a source of confusion without touching diagnostics.

Possible CL title:

```text
Clarify AnalysisOptionsProvider include merge documentation
```

Rollback plan:

- Restore old comments.

<a name="stage-12"></a>
### Stage 12: Optional Implementation - Add Structured Validation Result

Type: implementation, optional.

After the entry point is stable, consider returning a structured result:

```dart
final class AnalysisOptionsValidationResult {
  final List<Diagnostic> diagnostics;
}
```

This could later expose metadata useful for tooling or tests:

- included files visited,
- files with parse failures,
- whether validation stopped early,
- the initial parsed `YamlMap`,
- the include graph.

This should not be part of the first refactoring because it increases API surface before there is a demonstrated need.

Expected behavior change:

- none if `diagnostics` remains identical.

Review safety story:

- Mechanical return-type wrapper after behavior is stable.
- Existing tests can compare the same diagnostics.

Possible CL title:

```text
Return structured analysis options validation result
```

Rollback plan:

- Return `List<Diagnostic>` directly again.

<a name="review-strategy"></a>
## Review Strategy

Each CL should have one clear claim.

Test-only CLs should say:

```text
This CL changes only how tests reach existing diagnostics. Expected diagnostics
are unchanged.
```

Implementation-only wrapper CLs should say:

```text
This CL introduces a new entry point that delegates to the existing
implementation. Existing callers and tests are unchanged.
```

Implementation move/rename CLs should say:

```text
Tests were already migrated to the new entry point in earlier CLs. This CL
moves the implementation behind that entry point without changing expected
diagnostics.
```

If any CL changes expected diagnostics, it should be deliberately separated and described as a behavior fix, not hidden inside the refactoring.

Useful checks for each stage:

- Run the targeted analysis-options tests.
- Prefer running the whole relevant `test_all.dart` in a directory when that is faster than several individual files.
- Inspect diffs for generated inline diagnostic markers.
- Avoid whole-repository `git status` on the mounted checkout.

<a name="suggested-cl-boundaries"></a>
## Suggested CL Boundaries

The exact staging can change, but this sequence keeps review risk low:

1. Documentation only: add this plan.
2. Tests only: add shared diagnostic harness.
3. Tests only: migrate `options_file_validator_test.dart`.
4. Tests only: migrate `options_rule_validator_test.dart`.
5. Tests only: normalize `test/src/diagnostics/analysis_options` harness use.
6. Implementation only: add `AnalysisOptionsValidator` wrapper.
7. Tests only: switch shared harness to `AnalysisOptionsValidator`.
8. Implementation only: move include walking into `AnalysisOptionsValidator`.
9. Implementation only: retire `AnalysisOptionsAnalyzer`.
10. Tests only: remove redundant direct validator tests.
11. Implementation only: narrow validator visibility.
12. Implementation only: clarify provider include documentation.

It is acceptable to combine adjacent stages if a CL remains small and easy to review. In particular:

- Stages 1 and 4 might combine if the helper is already shared cleanly.
- Stages 5 and 6 can combine only if the implementation is a pure wrapper and the test diff is small.
- Stages 7 and 8 should probably remain separate if the move is non-trivial.

<a name="open-questions"></a>
## Open Questions

### Should `AnalysisOptionsValidator` Be Public API?

The first version should probably live under `lib/src`. It can be promoted only after there is evidence that external clients need this diagnostic entry point.

### Should `validateContent` Exist?

Tests can write marker-free content to files and call `validateFile`, so a content method is not strictly necessary. But keeping a testing-only content method makes the wrapper match current `AnalysisOptionsAnalyzer.walkIncludes` behavior and can reduce file-system reads in tests.

If added, it should be marked `@visibleForTesting` unless production callers need it.

### Should Component Validators Become Private?

Eventually, yes, if there are no legitimate package-internal callers. But this should happen only after tests use the single entry point.

### Should Diagnostic Tests Live In One File?

Probably not literally. One enormous test class would be harder to navigate. The better target is one diagnostic test surface:

```text
all analysis-options diagnostic tests -> shared helper -> AnalysisOptionsValidator
```

Physical files can remain split by feature.

### Should `AnalysisOptionsProvider` Remove `include` From Merged Maps?

The provider documentation says includes are removed, but current behavior can leave them. Changing this could affect consumers, especially `LinterRuleOptionsValidator`, which intentionally looks at include nodes.

Prefer documenting current behavior first. If removal is desired, do it as a separate behavior CL with focused tests.

### Should Lint Cross-File Rule Checks Use The Include Walker's Parsed Maps?

Today `LinterRuleOptionsValidator` reads included options through `AnalysisOptionsProvider`. The top-level include walker also parses included files. That can duplicate work.

Long term, the validator could pass already parsed included options to the lint rule validator. This is not necessary for the entry-point refactoring and would make the initial migration riskier. Keep it as a possible later optimization.

### Should Validation Produce Effective Options Too?

No, not initially. Combining validation diagnostics with effective runtime options would blur the provider/application/validator boundary. If a future client needs both, it can call provider/application and validator explicitly, or a higher-level orchestration API can compose them.
