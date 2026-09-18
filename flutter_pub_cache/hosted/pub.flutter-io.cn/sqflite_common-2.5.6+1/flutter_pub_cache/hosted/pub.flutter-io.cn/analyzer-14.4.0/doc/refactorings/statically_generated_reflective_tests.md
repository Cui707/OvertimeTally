# Statically Generated Reflective Tests

This document proposes replacing the `dart:mirrors` implementation of `package:test_reflective_loader` with a narrow CFE transformation.

The source-level test model remains unchanged:

```text
@reflectiveTest
class ParserTest {
  void test_emptyInput() {}

  Future<void> test_recordPattern() async {}
}

void main() {
  defineReflectiveTests(ParserTest);
}
```

Adding `test_newBehavior` and immediately running

```text
dart test test/parser_test.dart
```

must discover the new method. There is no separate generation command and no generated file to check in.

The CFE recognizes a direct `defineReflectiveTests(SomeClass)` invocation for an annotated class and lowers it to a descriptor containing an ordinary constructor tear-off and receiver-bound method tear-offs. The runtime loader continues to implement grouping, fresh instances, lifecycle callbacks, expected failures, and integration with `package:test`.

This is a compiler-supported test facility, not a general static-reflection or macro facility.

## 1. Goals

The primary goal is to preserve this development loop:

1. Add an instance method whose name identifies it as a test.
2. Run the test file directly.
3. Run that method in a new instance of its declaring test class.

The complete goals are:

- remove the runtime dependency on `dart:mirrors`
- retain `@reflectiveTest`, `defineReflectiveTests`, and `defineReflectiveSuite` at source level
- discover a newly added test during the ordinary compilation performed by `dart test`
- construct a fresh class instance for every test method
- preserve inherited tests and ordinary overriding
- preserve `setUp`, `tearDown`, `setUpClass`, and `tearDownClass`
- preserve test annotations, name prefixes, and source locations
- preserve direct execution of individual test files and aggregate `test_all.dart` entry points
- avoid checked-in generated files, `build_runner`, and editor-side generation
- add no runtime API for inspecting arbitrary declarations

## 2. Why This Is Smaller Than Macros

General macros can affect declarations that user source subsequently resolves against. That requires a phased language model shared by CFE, analyzer, IDE features, incremental compilation, and every backend.

The generated reflective-test descriptor has no source-visible name and no effect on the interface of the annotated class. CFE runs the transformation after the program has been resolved and typed. The analyzer does not need to model the generated descriptor.

The transformation consumes already known facts:

- the annotated class
- its effective instance members
- the unnamed constructor
- constant annotations
- source URIs and offsets

It produces only runtime plumbing. This is closer to a narrow compiler lowering than to declaration augmentation.

## 3. Current Source Contract

### Test classes

A registered class:

- is annotated with `@reflectiveTest`
- is passed as a type literal to `defineReflectiveTests`
- can be constructed using its unnamed constructor with no arguments

For example:

```text
void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(FileStateTest);
  }, name: 'file state');
}

@reflectiveTest
class FileStateTest extends AbstractFileTest {
  void test_deleted() {}
}
```

### Test methods

The current loader enumerates effective instance members and selects regular methods whose names start with this pattern:

```text
(solo_|fail_|skip_)*test_
```

Thus these are test methods:

```text
void test_plain() {}
void solo_test_focused() {}
void fail_test_knownFailure() {}
void skip_test_disabled() {}
void solo_fail_test_focusedKnownFailure() {}
```

Static methods, getters, setters, constructors, and methods not matching the pattern are not tests.

The full prefix and annotation behavior is specified in Section 7.

### Fresh instances

The current loader performs the equivalent of:

```text
Future<void> runTest(
  ReflectiveTestClass descriptor,
  ReflectiveTestMethod method,
) async {
  var instance = descriptor.create();
  try {
    if (descriptor.setUp case var setUp?) {
      await setUp(instance);
    }
    await Function.apply(method.bind(instance), const []);
  } finally {
    if (descriptor.tearDown case var tearDown?) {
      await tearDown(instance);
    }
  }
}
```

The instance is not shared with another test method.

## 4. Generated Runtime Model

The examples in this section describe the semantic interface. The actual classes can remain private implementation details of `test_reflective_loader`.

```text
final class ReflectiveTestClass<T extends Object> {
  final Type type;
  final String name;
  final TestLocation location;
  final T Function() create;

  final FutureOr<Object?> Function()? setUpClass;
  final FutureOr<Object?> Function()? tearDownClass;
  final FutureOr<Object?> Function(T instance)? setUp;
  final FutureOr<Object?> Function(T instance)? tearDown;

  final bool solo;
  final List<ReflectiveTestMethod<T>> methods;

  const ReflectiveTestClass({
    required this.type,
    required this.name,
    required this.location,
    required this.create,
    required this.setUpClass,
    required this.tearDownClass,
    required this.setUp,
    required this.tearDown,
    required this.solo,
    required this.methods,
  });
}

final class ReflectiveTestMethod<T extends Object> {
  final String name;
  final TestLocation location;
  final Function Function(T instance) bind;

  final bool solo;
  final bool skip;
  final bool failing;
  final bool assertFailing;
  final TestTimeout? timeout;

  const ReflectiveTestMethod({
    required this.name,
    required this.location,
    required this.bind,
    required this.solo,
    required this.skip,
    required this.failing,
    required this.assertFailing,
    required this.timeout,
  });
}
```

The descriptor contains normalized runtime facts. The loader does not inspect names, annotations, class members, or source locations.

`bind(instance)` returns the ordinary tear-off of the selected method on that instance. `Function.apply` invokes it with no arguments, and `await` preserves the current handling of both synchronous and asynchronous return values. No symbolic method lookup occurs at runtime.

## 5. CFE Lowering

### Input

```text
@reflectiveTest
class ConcreteTest extends BaseTest {
  @TestTimeout(Timeout(Duration(seconds: 30)))
  Future<void> test_local() async {}
}

void main() {
  defineReflectiveTests(ConcreteTest);
}
```

Assume `BaseTest` contributes an effective `test_inherited` method and `setUp`.

### Conceptual output

CFE lowers the registration call to the equivalent of:

```text
void main() {
  defineGeneratedReflectiveTests(
    ReflectiveTestClass<ConcreteTest>(
      type: ConcreteTest,
      name: 'ConcreteTest',
      location: TestLocation(
        testFileUri,
        concreteTestLine,
        concreteTestColumn,
      ),
      create: ConcreteTest.new,
      setUpClass: null,
      tearDownClass: null,
      setUp: (instance) => instance.setUp(),
      tearDown: null,
      solo: false,
      methods: [
        ReflectiveTestMethod<ConcreteTest>(
          name: 'test_inherited',
          location: TestLocation(
            baseFileUri,
            inheritedMethodLine,
            inheritedMethodColumn,
          ),
          bind: (instance) => instance.test_inherited,
          solo: false,
          skip: false,
          failing: false,
          assertFailing: false,
          timeout: null,
        ),
        ReflectiveTestMethod<ConcreteTest>(
          name: 'test_local',
          location: TestLocation(
            testFileUri,
            localMethodLine,
            localMethodColumn,
          ),
          bind: (instance) => instance.test_local,
          solo: false,
          skip: false,
          failing: false,
          assertFailing: false,
          timeout: const TestTimeout(
            Timeout(Duration(seconds: 30)),
          ),
        ),
      ],
    ),
  );
}
```

The shown Dart is explanatory. CFE constructs the corresponding Kernel expressions directly. No Dart source file is emitted.

### Why lower the call

A generated table is not discoverable from a runtime `Type` without either:

- mirrors
- a new VM operation that reads synthetic static members
- eager global registration
- rewriting the registration call

Rewriting the call is the narrowest option. It preserves the order and nesting of the original call while passing the generated information explicitly.

It also avoids constructing descriptors for annotated classes that are never registered by the compiled entry point.

### Registration shape

The transform supports a direct static invocation whose argument is a class type literal:

```text
defineReflectiveTests(MyTest);
```

Import prefixes do not matter:

```text
loader.defineReflectiveTests(tests.MyTest);
```

CFE identifies resolved declarations, not source spellings.

Indirect invocations are not supported:

```text
var register = defineReflectiveTests;
register(MyTest);
```

Nor is a runtime `Type` value:

```text
Type type = MyTest;
defineReflectiveTests(type);
```

These forms cannot receive a class-specific static descriptor. The migration audit must verify that SDK tests use direct type-literal registrations.

## 6. Class Eligibility

For `defineReflectiveTests(C)` to be lowered:

- `C` is a class
- `C` has `@reflectiveTest`
- `C` is not abstract
- the type literal denotes an instantiable raw or instantiated interface type
- `C` has an unnamed constructor callable with no arguments

The unnamed constructor can be generative, factory, or redirecting.

Private test classes remain supported. The generated invocation is Kernel code associated with a source call that already has access to the type literal. Unlike an external source generator, it does not need to import a private class from another library.

A generic class uses the instantiation represented by the type literal. For a raw type literal, CFE uses the ordinary raw-type instantiation.

After the mirrors fallback is removed, an invalid class produces a compile-time diagnostic at the registration call. This is earlier than the current failure during test discovery or instance construction.

## 7. Method Selection and Metadata

### Effective members

The descriptor is for the registered concrete class, not merely for methods declared directly in that class.

CFE obtains the effective instance dispatch members from `ClassHierarchy`. Consequently:

- inherited tests are included
- an override replaces the inherited method of the same name
- a method is included at most once
- the generated invocation dispatches on the concrete test instance
- mixin application members participate through ordinary class hierarchy rules

The source location and annotations belong to the effective method.

### Eligible signatures

An eligible test member:

- is an instance method
- has a selected test name
- can be invoked with no arguments

Optional positional or named parameters do not prevent zero-argument invocation. A method with a required parameter produces a diagnostic.

Return values retain current behavior. A returned `Future` is awaited; other values are ignored by the test runtime.

### Name selection

Selection preserves the current pattern:

```text
bool isReflectiveTestName(String name) {
  return RegExp(r'^(?:(?:solo|fail|skip)_)*test_').hasMatch(name);
}
```

Selection and flags are intentionally separate. Current behavior computes the flags as follows:

```text
var solo = name.startsWith('solo_') || hasSoloTestAnnotation;

var skip = name.startsWith('skip_') || hasSkippedTestAnnotation;

var failing =
    name.startsWith('fail_') ||
    name.startsWith('solo_fail_') ||
    hasFailingTestAnnotation;

var assertFailing = hasAssertFailingTestAnnotation;
```

This preserves unusual but currently accepted combinations such as `fail_skip_test_x`. Simplifying the prefix grammar is a separate change.

### Annotations

The transform recognizes:

- `@reflectiveTest` on the class
- `@soloTest` on the class or method
- `@skippedTest` and `@SkippedTest(...)` on a method
- `@failingTest` and `@FailingTest(...)` on a method
- `@assertFailingTest` on a method
- `@TestTimeout(...)` on a method

Annotation matching uses the resolved constant annotation class or constant identity, matching the current loader rather than matching source names.

`assertFailing` remains a separate descriptor bit. The runtime combines it with whether assertions are enabled. This avoids making the generated program different merely because the compiler process itself has a different assert configuration.

### Ordering

Class registration and suite order remain exactly the order in which the source program calls `defineReflectiveSuite` and `defineReflectiveTests`.

Within one class group, generated test methods are ordered by method name. The current mirrors API does not provide a useful source-level ordering contract; an explicit name order is deterministic across compiler implementations and incremental recompilations.

Tests must not depend on execution order unless they establish that order through explicit non-reflective grouping.

## 8. Lifecycle Methods

For each registered class, CFE resolves:

- effective instance member `setUp`
- effective instance member `tearDown`
- static member `setUpClass` declared by the registered class
- static member `tearDownClass` declared by the registered class

Absent members produce `null` callbacks.

Ordinary methods are lowered directly:

```text
setUp: (instance) => instance.setUp(),
tearDown: (instance) => instance.tearDown(),
setUpClass: ConcreteTest.setUpClass,
tearDownClass: ConcreteTest.tearDownClass,
```

The current mirror implementation obtains a member value and invokes it only if it is a closure. This also permits a field or getter containing a function. The compatibility implementation can preserve that edge case with generated binders:

```text
setUpValue: (instance) => instance.setUp,
```

followed by a runtime `value is Function` check and `Function.apply`. This uses no mirrors. Before choosing the simpler method-only representation, the migration audit must check whether SDK tests use callable lifecycle fields or getters.

Per-test order remains:

```text
construct instance
setUp
test method
tearDown, including when setUp or the test throws
```

Class-wide setup is started at most once for each registered class group. Class-wide teardown runs only if setup was started, and runs after the group's tests. Registering the same class in two groups creates two independent class-lifecycle states, as it does today.

## 9. Expected Failures, Solo Tests, and Skips

The runtime loader retains responsibility for behavior that is not reflection:

- selecting normal or solo groups and tests
- registering `package:test` groups
- applying skip and timeout metadata
- running expected-failure tests in an error zone
- setting `currentTestIsExpectedToFail`
- reporting an unexpected pass

CFE only supplies normalized flags and callbacks.

In particular, the expected-failure implementation continues to distinguish:

- a synchronous exception
- an awaited asynchronous exception
- an unawaited exception delivered to the test zone
- successful completion, which is an unexpected pass

No part of this behavior belongs in the compiler.

## 10. Source Locations

The generated descriptor contains a `package:test` `TestLocation` for:

- the registered class group
- every generated test method

CFE derives each location from the declaration's file URI and file offset using the corresponding Kernel `Source` line starts.

For inherited methods, the location is in the library that declares the effective method, not the library containing the concrete subclass or registration call.

The generated invocation and descriptor nodes retain the registration call's file offset where useful for compiler diagnostics. Runtime test reporting uses the explicit declaration locations in the descriptor.

Migration tests must compare generated locations with the locations produced by `dart:mirrors`, including line and column bases.

## 11. Compiler Integration

### Recognition

The initial implementation recognizes canonical declarations from:

```text
package:test_reflective_loader/test_reflective_loader.dart
```

Specifically:

- the `reflectiveTest` annotation class
- `defineReflectiveTests`
- the private generated-descriptor entry point and descriptor constructors

The current annotation implementation is private. It should become a small public annotation class so that the compiler contract has a stable identity:

```text
const Object reflectiveTest = ReflectiveTest();

final class ReflectiveTest {
  const ReflectiveTest();
}
```

This does not change existing annotation use.

CFE must compare resolved library and declaration identities. It must not trigger for another package that happens to declare functions or annotations with the same names.

A compiler-recognized pragma protocol could remove the canonical package URI from CFE later. That changes how declarations are located, not the generated semantics described here.

### Transformation point

The transformation runs after constant evaluation and class-hierarchy construction. At that point:

- class and method annotations are constants
- effective dispatch members are available
- constructor and method targets are resolved
- source locations are available

The existing CFE pipeline invokes target modular transformations with the `Component`, `ClassHierarchy`, compiled libraries, and incremental `ReferenceFromIndex`. The prototype can use this boundary.

The transform should run before backend optimizations and tree shaking. Generated constructor and method references then participate in reachability normally.

### Scope

Only direct registrations in compiled reachable libraries are transformed.

This handles both execution models:

```text
individual_test.dart main
  -> defineReflectiveTests(IndividualTest)

test_all.dart main
  -> imported_test.main()
     -> defineReflectiveTests(ImportedTest)
```

The imported test library's registration call is part of the same compiled component and is lowered independently.

No entry-point source rewriting or separate package scan is required.

## 12. Incremental and Modular Compilation

The generated descriptor depends on:

- the registered class annotation
- its constructor
- its effective test and lifecycle members
- annotations and source locations on those members
- relevant superclass and mixin interfaces

Incremental compilation must invalidate and regenerate the descriptor when any of these inputs changes.

Required incremental cases include:

```text
add a local test method
remove or rename a local test method
add a test annotation
change a timeout
add an inherited test method
override an inherited test method
remove an override and expose an inherited method
change a lifecycle method
move a declaration and change its source location
```

The inherited-method cases are especially important. The source registration call does not explicitly reference each inherited method, so the transform must participate correctly in CFE's dependency invalidation rather than reuse a stale descriptor from an incremental component.

For a first implementation, generating the descriptor expression directly at each registration call avoids cross-library synthetic declaration lookup. If code-size measurements justify hoisting descriptors into synthetic top-level fields, those fields must also be emitted into modular outlines and receive stable references through `ReferenceFromIndex`.

Direct call-site generation is the preferred initial design.

## 13. Diagnostics

During migration, unsupported registrations can retain the mirrors path. Before removing mirrors, all such fallback executions must be eliminated.

The final compiler diagnostics are:

- `defineReflectiveTests` argument is not a class type literal
- the class does not have `@reflectiveTest`
- the class is abstract or otherwise not instantiable
- there is no unnamed constructor callable with zero arguments
- a selected test method cannot be invoked with zero arguments
- generated runtime support expected by CFE is missing or has an incompatible ABI

Diagnostics are reported at the registration argument when they concern the class and at the method declaration when they concern a selected method.

If an unlowered `defineReflectiveTests` invocation reaches runtime after mirrors have been removed, the source implementation throws a clear `UnsupportedError`. It must not silently register an empty group.

## 14. Runtime and Compiler Boundary

CFE owns only declaration-derived facts:

```text
class identity and name
constructor callback
effective method callbacks
lifecycle callbacks
constant annotation metadata
source locations
```

`test_reflective_loader` owns test behavior:

```text
suite nesting
class groups
solo selection
package:test registration
fresh-instance execution
lifecycle sequencing
skip and timeout behavior
expected-failure zones
assert-mode behavior
error reporting
```

This boundary keeps compiler-generated code mechanical and keeps policy in a normal Dart package where it is easy to test.

## 15. Migration Strategy

### Phase 1: Descriptor runtime

Add the generated descriptor types and `defineGeneratedReflectiveTests`.

Keep the current mirrors implementation of `defineReflectiveTests`.

Add runtime unit tests that construct descriptors by hand and verify parity for:

- fresh instances
- lifecycle ordering
- async methods
- expected failures
- solo and skipped tests
- timeouts
- nested suites
- source locations

### Phase 2: Gated CFE lowering

Implement the CFE transform behind a temporary development flag.

For lowered calls, invoke the descriptor runtime. For other calls, retain the mirrors path.

Add Kernel golden tests showing the generated callbacks and runtime end-to-end tests using one representative analyzer test class.

### Phase 3: SDK test rollout

Enable lowering for SDK tests and record whether any registration reaches the mirrors fallback.

Run individual test files and aggregate suites in the packages that use `test_reflective_loader`.

Audit and resolve:

- indirect registration calls
- non-type-literal arguments
- invalid constructors
- invalid test signatures
- callable lifecycle fields or getters
- ordering-sensitive tests

### Phase 4: Default lowering

Enable recognition automatically for the canonical loader API, so an ordinary

```text
dart test path/to/file_test.dart
```

requires no flag or wrapper.

Keep the mirrors fallback for one transition period and fail tests if it is used in SDK CI.

### Phase 5: Remove mirrors

Remove:

```text
import 'dart:mirrors';
```

and all `Mirror`, `Symbol`, and reflective invocation logic from `test_reflective_loader`.

The source-facing `defineReflectiveTests(Type)` declaration remains as the compiler-recognized input form. Its body is only an unsupported-compiler failure path.

## 16. Testing

### CFE transformation tests

- annotated class with one local test
- annotated class with no tests
- unannotated registered class
- private registered class
- generic registered class
- generative, factory, and redirecting unnamed constructors
- abstract or non-instantiable class
- test method with required parameters
- sync, async, and arbitrary return types
- every supported name prefix
- every supported annotation
- class and method source locations
- registration through import prefixes
- multiple registrations of the same class
- registration inside nested suite closures

### Hierarchy tests

- inherited test
- overridden inherited test
- inherited non-test overridden by a test
- inherited test overridden by a non-selected method
- tests introduced by mixins
- multiple interface declarations with one effective implementation
- inherited `setUp` and `tearDown`
- local replacement of inherited lifecycle methods
- static class lifecycle methods

### Runtime parity tests

Run the same descriptor once through mirrors and once through generated callbacks, then compare:

- group and test names
- order
- skip, solo, timeout, and failure metadata
- fresh-instance count
- lifecycle event log
- thrown errors and unexpected passes
- test locations

### Workflow tests

1. Run one test file.
2. Add `test_added`.
3. Run the same command without another tool.
4. Verify that `test_added` runs.

Repeat for:

- a method added to the concrete class
- a method added to a superclass
- a method added by a mixin
- a method removed or renamed
- a changed annotation
- an aggregate `test_all.dart`
- incremental Kernel compilation
- native executable compilation if supported by the test runner

### Performance measurements

Measure:

- cold compilation time for one representative test
- incremental compilation after adding one method
- compilation time for an analyzer `test_all.dart`
- generated Kernel size
- AOT snapshot size where applicable

The transform should avoid a second parse or analysis of the test source. It uses the Kernel and class hierarchy CFE already produced.

## 17. Alternatives

### `package:reflectable`

`reflectable` provides general generated reflection, but introduces a separate generation workflow, generated imports and initialization, private-declaration limitations, and an analyzer dependency in its builder.

The proposed CFE lowering generates only the data this loader needs and runs as part of ordinary test compilation.

### Checked-in generated registries

Checked-in registries can contain the required constructor and method callbacks, but adding a method leaves the registry stale until another command updates it.

That violates the primary development-loop requirement.

### Generate a temporary bootstrap before CFE

`package:test` already generates a temporary bootstrap. It could run a source generator first and import generated registrations.

This requires parsing and resolving test source separately from CFE, adds a generator dependency to the test launcher, and has difficulty accessing private declarations. It is a viable fallback if compiler support is rejected, but it is not the preferred design.

### Generate an interface on every test class

CFE could make each annotated class implement a synthetic descriptor interface. The loader would still need either a constructor factory or a disposable instance before it could discover method names. Passing a factory would change the source registration API, and constructing a discovery instance would add observable constructor execution.

Direct call lowering avoids both problems.

### Eager global registration

CFE could generate top-level calls that register `Type` objects in a global map. Dart top-level initializers are lazy, and introducing eager library-load behavior would be broader than the test problem. It would also make registration order less explicit.

The existing source calls already express the desired order. Lowering them is simpler.

### New VM static-reflection operation

The VM could expose a way to retrieve a synthetic table from a `Type`. That would add runtime reflection machinery and would not naturally serve other CFE backends.

Passing the descriptor explicitly needs no runtime change.

### Restore general macros

General macros solve a much larger problem and require analyzer-visible generated declarations. Reflective-test descriptors do not justify that language and tooling surface.

The proposed post-type-checking transform supplies the useful part for this case without exposing a macro system.

### Change tests to explicit top-level `test(...)` calls

Explicit registration removes reflection, but requires every new method to be listed separately and changes thousands of existing test declarations.

It gives up the source workflow this proposal is intended to preserve.

## 18. Risks

### CFE knows about a package-level facility

Recognizing a package URI and private runtime ABI from CFE is unusual. The scope is nevertheless small and mechanically testable.

A reserved pragma protocol can reduce direct package-name coupling if needed, but it does not remove the fact that the compiler implements this particular descriptor shape.

### Incremental descriptors can become stale

Descriptors contain facts not explicitly referenced in source. Inherited method changes must invalidate the registration lowering.

Dedicated incremental tests are required before enabling the transform by default.

### Runtime behavior can drift

The mirrors implementation contains edge behavior around prefixes, annotations, callable lifecycle properties, expected failures, and locations. Removing mirrors before running parity tests would risk silent changes to test selection.

The migration keeps both implementations available until generated descriptors demonstrate parity.

### Compiler API stability

The generated runtime constructors form a private ABI between CFE and `test_reflective_loader`. CFE must diagnose an incompatible or missing ABI rather than generating invalid Kernel.

The ABI should be versioned if the loader can vary independently from the SDK compiler.

## 19. Non-Goals

This proposal does not:

- provide general runtime or static reflection
- let arbitrary packages request arbitrary compiler-generated code
- add source-visible members to annotated classes
- discover classes that are not explicitly registered
- replace `package:test`
- change the semantics of `defineReflectiveSuite`
- simplify existing test name prefixes or annotations
- guarantee meaningful test execution order beyond the specified registration and deterministic method ordering
- make generated descriptors visible to analyzer clients

The proposal is specifically a static implementation of the existing reflective test-class convention.
