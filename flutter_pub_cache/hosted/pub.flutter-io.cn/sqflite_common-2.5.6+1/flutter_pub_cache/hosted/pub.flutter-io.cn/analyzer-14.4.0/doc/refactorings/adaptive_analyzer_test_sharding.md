# Parallel and Historically Adaptive Analyzer Test Sharding

This document records an experiment in reducing the wall-clock time of the
analyzer unit test suite, describes the four-shard implementation that resulted
from the experiment, and proposes a historically adaptive system that can
generate balanced shard entry points automatically.

The current implementation is deliberately small and static. Four checked-in
aggregate entry points divide the analyzer tests into measured groups, and a
shell launcher runs the four entry points in separate Dart VM processes. The
proposed design retains the important property of selective imports, but
replaces shard-specific source structure with stable test units, persisted
timings, deterministic planning, and generated entry points.

This work is related to, but independent of,
[`statically_generated_reflective_tests.md`](statically_generated_reflective_tests.md).
That proposal changes how reflective test methods are discovered and invoked.
This document concerns how already registered test suites are partitioned
across processes.

## 1. Motivation

The analyzer package has a canonical aggregate entry point:

```text
dart test/test_all.dart
```

This is efficient because one Dart VM compiles and loads the analyzer test
support code once, then executes all registered tests in one large suite. On
the machine used for this experiment, the complete run took approximately 143
seconds of wall-clock time.

The machine has:

- an AMD Ryzen 9 PRO 8945HS
- 8 physical cores and 16 hardware threads
- 59 GiB of RAM
- approximately 56 GiB available during the experiment

The aggregate runner used approximately one core for most of the run. The goal
was therefore to reduce developer wait time by running a small number of large
aggregate suites in independent Dart VM processes, without incurring the cost
and compatibility problems of treating every `_test.dart` file as a separate
suite.

The optimization target is **wall-clock time**, reported as `real` by the shell
`time` command. This is the time between starting the command and learning
whether the tests passed. Accumulated `user` and `sys` CPU time are useful for
evaluating efficiency, but they are not the primary developer-facing metric.

## 2. Why `package:test` Concurrency Was Not Sufficient

`package:test` supports a concurrency option:

```text
dart test --concurrency=8 test/test_all.dart
```

The concurrency setting controls how many test *suites* can run concurrently.
In this command, `test/test_all.dart` is one suite. It registers tens of
thousands of tests, but the test runner still has only one suite to schedule.
The option is accepted, but it does not split the registered tests into eight
independent workers.

Running the package test runner recursively does expose many suites:

```text
dart test --concurrency=8 test
```

That approach was tested. It clearly used concurrency: approximately 24
minutes and 50 seconds of accumulated CPU time were consumed in approximately
2 minutes and 40 seconds of wall time. However, it had two problems:

1. It was slower than the canonical aggregate runner.
2. It failed 270 tests after only 22,165 successful tests.

The per-file approach repeatedly pays compilation, isolate or process startup,
package loading, and analyzer initialization costs. It also exposes assumptions
in tests that are not exercised when the curated aggregate hierarchy is used.
It is therefore neither a performance replacement nor a compatibility
replacement for `test/test_all.dart`.

The useful middle ground is a small number of large aggregate suites.

## 3. Experiment History

The following measurements were made on the same development machine. Times
vary slightly from run to run, so the table should be read as an empirical
comparison rather than a permanent performance guarantee.

| Configuration | `real` | `user + sys` | Result |
|---|---:|---:|---|
| Canonical `dart test/test_all.dart` | 143.254 s | 156.716 s | 37,665 passed, 10 skipped |
| Recursive `dart test -j8 test` | 160.308 s | 1,490.051 s | 270 failures; incomplete comparison |
| Two aggregate processes | 99.926 s | 225.693 s | 37,665 passed, 10 skipped |
| Four aggregate processes | 67.940 s | 341.321 s | 37,659 passed, 10 skipped |
| Six aggregate processes | 62.474 s | 462.541 s | 37,659 passed, 10 skipped |

The four- and six-process configurations intentionally omitted six physical
file-watcher tests, as described in Section 6.

The two-process experiment established that aggregate process-level
parallelism was useful. Its two large suites finished their test phases in
approximately 88 and 90 seconds, and wall time fell from approximately 143 to
100 seconds.

The suites were subsequently divided into three, four, five, and six measured
groups. Balancing by test count was not sufficient: analyzer tests differ
greatly in cost. Large areas such as diagnostics, fine analysis, summaries,
and file watching had to be separated using measured execution time.

The six-process configuration reduced wall time by only 5.466 seconds relative
to four processes:

```text
67.940 s -> 62.474 s
```

That is an 8 percent latency improvement, but it required 35.5 percent more
accumulated CPU time. The reporter-visible test phase improved by approximately
10 seconds, while additional VM startup, compilation, and resource contention
consumed about half of that improvement.

The four-process configuration was retained as the better default tradeoff:

- approximately 2.1 times faster than the canonical sequential runner
- approximately 68 seconds of developer wait time
- materially less CPU than six processes
- fewer generated concepts and partition boundaries to maintain
- less interference with other work on the same machine

## 4. Current Four-Shard Implementation

The current checked-in entry points are:

```text
test/test_all_1.dart
test/test_all_2.dart
test/test_all_3.dart
test/test_all_4.dart
```

They are launched by:

```text
tool/test_all_shards.sh
```

The launcher starts each entry point with `dart`, records the process IDs,
waits for every process, and returns a nonzero status if a shard fails.

The measured distribution is approximately:

| Shard | Passed | Skipped | Representative wall time |
|---|---:|---:|---:|
| 1 | 8,278 | 7 | 65.0 s |
| 2 | 5,771 | 0 | 68.4 s |
| 3 | 12,270 | 0 | 64.3 s |
| 4 | 11,340 | 3 | 63.0 s |

The test counts differ significantly, but execution times are close. This is
expected and is one of the principal lessons of the experiment: test count is
not a useful balancing weight for this suite.

### Shard 1

Shard 1 contains a portion of the analysis tests and a large portion of the
diagnostic tests:

```text
analysis.mainShard1()
diagnostics.mainShard1()
```

### Shard 2

Shard 2 contains another analysis portion, micro-analysis tests, and the larger
summary-element portion:

```text
analysis.mainShard2()
micro.main()
summary_elements.mainShard2()
```

### Shard 3

Shard 3 contains many medium and small suites, including generated tests,
non-watcher file-system tests, parser and resolver support, selected analysis
and summary portions, utility suites, and final verification tests.

This shard has the most imports and the highest test count, but many of its
tests are inexpensive.

### Shard 4

Shard 4 contains constant, element, resolution, SDK, and the remaining
diagnostic tests:

```text
constant.main()
element.main()
resolution.mainShard4()
sdk.main()
diagnostics.mainShard4()
```

### Canonical aggregate behavior

The canonical `test/test_all.dart` entry point remains the complete correctness
oracle. Lower-level aggregate files were refactored so their ordinary `main()`
functions register all of their parts. For example, a lower-level canonical
entry point invokes both portions that are assigned to different parallel
shards.

Consequently:

```text
dart test/test_all.dart
```

continues to register all 37,675 test cases: 37,665 pass and 10 are skipped,
including the six passing watcher tests. The shard-specific entry points are an
additional fast path, not a replacement for the canonical hierarchy.

## 5. What the Experiment Taught Us

### Aggregate granularity matters

One giant aggregate leaves cores idle. Thousands of individual suite files pay
too much repeated setup cost. Four large aggregate processes performed much
better than either extreme.

### Selective imports matter

Each shard currently imports only the test code it executes. A common runtime
registry imported by every worker would be easier to schedule dynamically, but
every VM would then compile and load every test. The measurements show that
startup and compilation are already a significant part of wall time, so losing
selective imports would likely erase much of the gain.

### Test count is not execution weight

The final shards range from 5,771 to 12,270 passing tests but finish within a
small time window. Expensive fine-analysis and summary tests dominate much more
than large collections of small utility tests.

### More cores do not imply proportional speedup

The six-process configuration used approximately 7.4 CPU-seconds per second of
wall time, close to saturating the eight physical cores. Additional workers
introduced:

- more Dart VM and frontend compilation work
- more copies of analyzer and test initialization
- more garbage collection and runtime threads
- shared-cache and memory-bandwidth contention
- lower sustained per-core boost frequency

The result was a large increase in CPU consumption for a small wall-time gain.

### Reporter time is not total wait time

The compact reporter starts its visible clock after some startup work. In the
four-process measurement, the slowest reporter time was approximately 59
seconds while shell wall time was approximately 68 seconds. A balancing system
must ultimately optimize process completion time, not only the reporter's test
clock.

### Manual balancing works but does not age well

The current split is based on a snapshot of the test suite and one machine.
New tests, changes in test cost, compiler changes, and machine differences will
gradually make it uneven. Function names such as `mainShard1` also encode a
temporary scheduling decision in source structure.

## 6. Physical Watcher Tests

The fast sharded runner intentionally omits these six tests from
`physical_resource_provider_watch_test.dart`:

- watch file deletion
- watch file modification
- watch folder file creation
- watch folder file deletion
- watch folder file modification
- watch folder modification in a subdirectory

These tests use real file-system notifications and include deliberate delays.
They contributed approximately 20 to 25 seconds to an aggregate containing
them, while the underlying behavior changes infrequently.

An existing `skipPhysicalResourceProviderTests` environment define was
considered but was not used for the final shard implementation. That define
also suppresses ordinary physical file-system tests, not only the six watcher
tests. The shard entry point instead imports the non-watcher file-system suites
explicitly, preserving 106 ordinary physical file-system tests.

The omission is intentionally limited to the fast local path. The canonical
runner still covers the watcher tests. A future launcher should expose this as
an explicit profile or option, for example:

```text
tool/test_all_shards.dart --include-watchers
```

The default and CI policy should be documented rather than inferred from an
environment define.

## 7. Limitations of the Current Design

The static implementation has several known limitations:

1. Shard assignment is encoded directly in imports and function names.
2. Rebalancing requires editing Dart source and repeatedly benchmarking.
3. There is no persisted timing history.
4. New tests can make one shard slower without any automatic signal.
5. The four child processes write compact reporter output to the same terminal,
   so progress lines can interleave.
6. The launcher supports only one checked-in shard count.
7. Coverage is verified by totals and canonical test runs rather than by a
   first-class unit inventory.
8. The assignment is optimized for one local machine and may not be optimal on
   a different machine or under a different runtime configuration.

These limitations motivate an adaptive design, but they also identify
constraints: an adaptive system must preserve selective compilation, canonical
coverage, debuggability, and the direct individual-test workflow.

## 8. Goals for a Historically Adaptive System

The proposed system should:

- minimize developer-visible wall-clock time
- retain a small number of large Dart VM processes
- import only the tests assigned to each process
- derive assignments from historical measured cost, not test count
- adapt when tests are added or become more or less expensive
- produce deterministic, inspectable plans
- guarantee that every enabled test unit is assigned exactly once
- preserve the canonical complete `test/test_all.dart` runner
- support an explicit watcher-test policy
- avoid checked-in generated shard entry points
- avoid changing plans in response to small timing noise
- allow a developer to choose a shard count without editing source

The initial default should remain four shards because that is the measured
latency/CPU/maintenance sweet spot on the development machine.

The proposed system does not need to:

- schedule individual test methods dynamically
- replace `package:test`
- replace the canonical aggregate hierarchy
- make every `_test.dart` file independently runnable
- produce an optimal mathematical partition on every run
- learn from failed or interrupted test executions

## 9. Stable Test Units

Adaptive scheduling needs units that are independent of their current shard.
Names such as `mainShard1` should be replaced with semantic or stable part
names, for example:

```text
diagnosticsAThroughI
diagnosticsJThroughP
diagnosticsQThroughZ
analysisDriver
analysisSearchAndIndex
summaryClasses
summaryOtherElements
resolutionTypeInference
```

A useful unit should generally take between approximately 2 and 10 seconds on
a reference machine:

- smaller units improve balance but increase manifest and registration cost
- larger units reduce overhead but can become unsplittable long poles

Units should follow semantic or stable source boundaries where practical.
Alphabetic ranges are acceptable for very large registries such as
diagnostics, provided additions have an obvious destination.

Some units need metadata:

```text
id
import path
public registration entry point
tags
estimated duration
isolation constraints
supported platforms
enabled profiles
```

The public entry point is necessary because a generated file under
`.dart_tool` cannot invoke a library-private function in a test library.

## 10. Unit Manifest

The scheduler needs one declarative inventory of shardable units. A conceptual
manifest could look like:

```yaml
schema: 1

units:
  - id: diagnostics.a_i
    import: test/src/diagnostics/test_all.dart
    entrypoint: diagnosticsAThroughI

  - id: analysis.search_index
    import: test/src/dart/analysis/test_all.dart
    entrypoint: analysisSearchAndIndex

  - id: file_system.watch
    import: test/file_system/physical_resource_provider_watch_test.dart
    entrypoint: main
    tags: [watcher, slow]

profiles:
  local-fast:
    excludeTags: [watcher]

  complete:
    excludeTags: []
```

YAML is only illustrative. A Dart or JSON representation may integrate better
with existing SDK tooling. The important property is that the manifest be
machine-readable and deterministic.

There are three possible sources of truth:

1. **Manifest as source of truth.** Generate both canonical and shard aggregate
   registrations from it. This gives the strongest coverage guarantee but
   makes the canonical source generated or generator-dependent.
2. **Canonical hierarchy as source of truth.** Parse aggregate Dart files and
   derive units from public registration functions. This avoids duplication
   but requires a deliberately constrained and validated aggregate syntax.
3. **Independent manifest with verification.** Keep the canonical hierarchy
   handwritten, use a manifest for shards, and compare their normalized test
   inventories in a verification test or CI step.

The third option is the least disruptive initial implementation. It preserves
the canonical runner exactly as a safety oracle. If the manifest proves stable,
the project can later consider making it authoritative.

## 11. Generated Selective Entry Points

Before running tests, a planner should generate one Dart file per shard under a
temporary or ignored directory such as:

```text
.dart_tool/analyzer_test_shards/4/test_all_1.dart
```

A generated entry point would contain only the imports for its assigned units:

```text
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../../test/src/diagnostics/test_all.dart' as diagnostics;
import '../../../test/src/dart/analysis/test_all.dart' as analysis;

void main() {
  defineReflectiveSuite(() {
    timedUnit(
      'diagnostics.a_i',
      diagnostics.diagnosticsAThroughI,
    );
    timedUnit(
      'analysis.search_index',
      analysis.analysisSearchAndIndex,
    );
  }, name: 'analyzer shard 1');
}
```

Selective generation is essential. A single common registry imported by every
worker would make runtime selection easy, but every VM would compile every
test library. The experiment demonstrated that duplicated startup and
compilation are already the principal scaling limit.

Generated files should not be checked in. They should be deterministic and
printable through a command such as:

```text
tool/test_all_shards.dart --shards=4 --explain
```

This preserves inspectability without creating source-control churn.

## 12. Timing Collection

The planner needs measured cost per stable unit. One possible registration
wrapper is conceptually:

```text
void timedUnit(String id, void Function() registerTests) {
  group(id, () {
    late Stopwatch stopwatch;

    setUpAll(() {
      stopwatch = Stopwatch()..start();
    });

    registerTests();

    tearDownAll(() {
      stopwatch.stop();
      timingSink.record(id, stopwatch.elapsed);
    });
  });
}
```

Each process should write to a distinct temporary result file. The coordinator
merges results only after all processes terminate. Writes should be atomic so
that interruption cannot corrupt the timing database.

The wrapper introduces a stable group name into reporter output. That is
useful for diagnosis and attribution, but its effect on test-name consumers
must be checked. If adding a group is incompatible, timings can instead be
derived from a machine-readable `package:test` reporter or a small supported
extension in `test_reflective_loader`.

Unit execution timing does not include all compilation and startup cost. The
coordinator should also record:

- process start time
- first reporter event time
- process completion time
- sum of measured unit durations
- exit status

The difference between process wall time and measured unit time is unattributed
overhead. Initially, it can be modeled as a fixed per-shard cost. Later, import
or source-size information can provide an approximate compilation weight.

## 13. Historical Timing Model

Timing data should live under `.dart_tool`, making it local to a checkout and
machine by default. A conceptual record is:

```json
{
  "schema": 1,
  "environment": {
    "os": "linux",
    "architecture": "x64",
    "dartRevision": "..."
  },
  "units": {
    "diagnostics.a_i": {
      "estimateMs": 17200,
      "samples": 14,
      "lastMs": 16840
    }
  }
}
```

The latest sample should not replace the estimate directly. Test duration is
noisy under CPU load, thermal changes, background processes, and filesystem
state. An exponential moving average is sufficient:

```text
new estimate = 0.8 * old estimate + 0.2 * latest sample
```

Possible refinements include:

- normalize samples by the median speed of the whole run
- keep separate profiles for VM options or platforms
- ignore failed, timed-out, or interrupted units
- expire units that no longer exist in the manifest
- initialize unseen units using test count, source size, or the median unit
  duration
- commit optional baseline relative weights while keeping local overlays

Relative weights often transfer across similar machines better than absolute
milliseconds. A committed baseline could therefore store normalized weights,
while local history supplies actual durations.

## 14. Planning Algorithm

The initial planner should use longest-processing-time-first scheduling:

1. Load all enabled units and their estimated weights.
2. Sort units from slowest to fastest.
3. Assign each unit to the currently lightest shard.
4. Apply required placement constraints.
5. Try bounded single-unit moves and pairwise swaps that reduce the predicted
   maximum completion time.
6. Emit a deterministic plan.

For the size of this test suite, this algorithm is inexpensive and generally
close to optimal. An exact partition solver is unnecessary.

The prediction should eventually include:

```text
predicted shard wall time =
    fixed VM startup
  + estimated compilation/import cost
  + sum(unit execution estimates)
```

The objective is to minimize the maximum predicted shard wall time, not to
equalize test count or accumulated CPU.

### Constraints

The planner should support constraints such as:

- a unit must run alone
- two units must be colocated
- two units must not be colocated
- a unit requires a VM define
- a unit is excluded from a profile
- a unit is supported only on certain platforms
- a unit must remain in a stable shard for external tooling

Constraints should be rare and explicit. They must not be inferred from timing
failures.

## 15. Stability and Hysteresis

An adaptive planner should not generate a different assignment after every
minor fluctuation. Plan churn makes failures harder to reproduce and obscures
performance comparisons.

The previous plan should remain in use unless at least one condition is met:

- a unit was added or removed
- the current measured spread exceeds a threshold
- the predicted improvement exceeds a meaningful threshold, such as 3 to 5
  percent or several seconds
- the developer explicitly requests `--rebalance`

The plan, estimates, and explanation should be stored together. A developer
must be able to reproduce a failing assignment or print why a unit was placed
on a shard.

## 16. Coverage Guarantees

Automatic sharding is useful only if omission and duplication are impossible
to miss.

At plan-generation time, validate that:

- every enabled manifest unit is assigned exactly once
- no unknown unit appears in a plan
- every generated import path exists
- every entry point is public and syntactically valid
- excluded units are listed with an explicit reason

At test or CI time, additionally validate that:

- the union of normalized test names from the complete shard profile matches
  the canonical runner
- the local-fast profile differs only by its declared exclusions
- the watcher exclusion accounts for exactly six tests
- aggregate registration functions still invoke every stable part

Comparing only total counts is helpful but insufficient: one omitted test and
one duplicated test can preserve the same count. Test-name inventories provide
the stronger guarantee.

The inventory comparison need not run on every local invocation. It can be a
dedicated verification test or CI task, while static manifest validation runs
every time the plan is generated.

## 17. Launcher Behavior

A future launcher could support:

```text
tool/test_all_shards.dart
tool/test_all_shards.dart --shards=4
tool/test_all_shards.dart --include-watchers
tool/test_all_shards.dart --rebalance
tool/test_all_shards.dart --explain
tool/test_all_shards.dart --dry-run
```

Its lifecycle would be:

1. Parse the requested profile and shard count.
2. Load and validate the unit manifest.
3. Load historical timing estimates.
4. Reuse or compute a plan.
5. Generate selective entry points under `.dart_tool`.
6. Start one Dart VM process per shard.
7. Forward or prefix progress output.
8. Propagate signals and terminate remaining children when appropriate.
9. Wait for every child and combine exit statuses correctly.
10. Merge successful timing samples atomically.
11. Print measured shard durations and the critical path.

The summary should distinguish reporter time, process wall time, and aggregate
CPU time. The primary headline remains wall-clock time.

## 18. Why Not Dynamic Same-Run Scheduling

A conventional worker queue assigns the next task to whichever worker becomes
idle. That would give excellent balance without historical estimates, but it
conflicts with the performance characteristics of this suite.

### One VM per unit

Launching a new Dart VM for every unit repeats compilation and initialization.
This converges toward the unsuccessful per-file `dart test` experiment.

### Every unit loaded into every worker

A long-lived worker could accept arbitrary units only if every worker compiles
all reachable test code, or if the VM and test runner support loading new test
programs efficiently. Compiling the whole suite in every worker discards
selective-import savings.

### Reusing `package:test` inside a worker

`package:test` is designed around registering a suite and then executing it. A
custom protocol that repeatedly registers and drains independent suites in one
process would depend on internal runner behavior and complicate isolation,
failure handling, and reporting.

For these reasons, a plan chosen before process startup using recent history is
the best fit. The suite changes slowly enough that yesterday's or the previous
run's timings should predict the next run well.

## 19. Proposed Implementation Phases

### Phase 1: Stable units

- Rename shard-number-specific registration functions to stable semantic part
  names.
- Choose unit boundaries with target durations of approximately 2 to 10
  seconds.
- Preserve ordinary lower-level `main()` functions that register all parts.
- Add tests for complete registration.

### Phase 2: Manifest and deterministic generation

- Add the unit manifest.
- Add static validation.
- Generate four selective entry points under `.dart_tool`.
- Reproduce the current checked-in four-shard assignment exactly.
- Compare generated and checked-in results before deleting static entry points.

### Phase 3: Timing instrumentation

- Record per-unit execution durations.
- Record process wall time and unattributed startup overhead.
- Store timing history locally and atomically.
- Add `--explain` output.

### Phase 4: Adaptive planning

- Implement longest-processing-time-first assignment.
- Add bounded move and swap improvement.
- Add moving averages, normalization, and hysteresis.
- Add `--rebalance` and arbitrary shard counts.

### Phase 5: Coverage and CI integration

- Compare normalized canonical and sharded test inventories.
- Add explicit fast and complete profiles.
- Decide when watcher tests run in CI.
- Seed optional baseline weights for clean checkouts.

### Phase 6: Remove static artifacts

- Remove checked-in `test_all_1.dart` through `test_all_4.dart` once generated
  entry points have proven reliable.
- Retain `test/test_all.dart` as the simple, complete, directly runnable
  correctness oracle.

## 20. Open Questions

Several choices should be validated with a prototype:

1. What unit duration gives the best balance without excessive manifest size?
2. Can timing groups be added without disrupting test names or external
   tooling?
3. How much of process startup cost correlates with imported source size?
4. Should baseline weights be checked in, or should every checkout calibrate
   locally?
5. Should plans be machine-specific, or should only timing overlays be local?
6. What improvement threshold justifies changing a plan?
7. Should the launcher stop other shards after the first failure, or finish all
   shards to report the complete failure set?
8. Should watcher tests be included by default in CI but excluded locally?
9. Can the canonical aggregate hierarchy be parsed reliably enough to derive
   the unit manifest, or is an independent manifest plus verification safer?
10. How should a single unit that grows beyond the target duration be detected
    and reported?

## 21. Recommended Direction

The current four-shard implementation should remain the default until an
adaptive prototype reproduces its performance and coverage.

The recommended prototype is intentionally conservative:

1. Keep four worker processes.
2. Introduce stable units and an independent manifest.
3. Generate selective entry points under `.dart_tool`.
4. Measure unit execution time and shard process wall time.
5. Use longest-processing-time-first assignment with a local timing cache.
6. Rebalance only when predicted improvement is material.
7. Verify the generated unit inventory against the canonical runner in CI.

This design preserves the successful part of the experiment—a small number of
selectively compiled aggregate VMs—while removing the manual and temporary
nature of the current shard assignment.
