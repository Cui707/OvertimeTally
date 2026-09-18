# AST Expressions and Assignment Targets: Detailed V2 Design

This document is the detailed working design for analyzer V2 expressions, assignment targets, and their adjacent source roles and resolution models. It continues [AST Expressions in Analyzer, Front End, and Kernel: Exploration 01](ast_expressions_01.md), which inventories the current analyzer, front-end, and kernel representations and records broad possible directions. For the compact code-first decision surface, see the [V2 design summary](ast_expressions_and_assignment_targets_summary.md). This remains a design discussion rather than an accepted specification, and names used in API sketches are provisional.

The central working idea is that a source node should implement `Expression` when the source occurrence produces a value. Names, selectors, namespace qualifiers, assignment targets, and other reference-bearing constructs should not implement `Expression` merely because they are currently represented using `SimpleIdentifier`, `PrefixedIdentifier`, `PropertyAccess`, or `IndexExpression`. A narrow resolved-AST exception permits no-token semantic adaptation expressions when the language context transforms one produced value into another; these nodes wrap a value-producing operand rather than pretending that a qualifier or target is itself a value.

The design should preserve source structure and convenient resolved APIs. It should not turn the analyzer AST into kernel-like lowered operations, but it may use neutral parser-only chains followed by controlled source-role lowering where the parser cannot determine the final interpretation, most notably for a token sequence such as `foo.bar`, and sparse resolver-inserted adaptations for language-defined contextual transformations such as implicit `call` tear-off and generic function instantiation.

## 1. Starting Example: `x;`

Consider:

```dart
<top-level-declarations>
void f(<formal-parameters>) {
  <local-declarations>
  x;
}
```

Syntactically, `x` is an unqualified name used in a value-producing position. Its resolved meaning can be any of several things.

| Declaration or lookup result for `x` | Meaning of `x;` |
| --- | --- |
| Formal parameter | Read the parameter |
| Local variable or pattern variable | Read the variable |
| Local function | Produce a function tear-off |
| Top-level variable | Invoke its getter |
| Top-level getter | Invoke the getter |
| Top-level function | Produce a function tear-off |
| Class, mixin, enum, extension type, or type alias | Produce a `Type` object |
| `dynamic`, `Never`, and similar built-in type names | Produce a `Type` object |
| Import prefix | Resolve the prefix name, but report that it cannot be used as a value |
| Named extension | Resolve the extension name, but report that it cannot be used as a value |
| Setter-only declaration | Report an invalid read |
| Ambiguous import | Report an invalid read while retaining the candidates |
| No declaration | Report an unresolved reference |

Unprefixed imported declarations behave like the corresponding top-level declarations. Because `f` is top-level in this example, `x` cannot be an implicit instance member. If the same occurrence were inside an instance member, additional possibilities would include implicit-`this` fields, getters, methods, extension members, extension-type members, and record fields.

A function-valued variable is still a variable read rather than a function tear-off. A type alias to a function type is still a type literal rather than a function reference. A class name such as `C` denotes the `Type` object in this position; it does not denote the unnamed constructor, whose tear-off syntax is `C.new`.

The source AST should not have separate node kinds such as `LocalVariableExpression`, `FormalParameterExpression`, `TopLevelGetterExpression`, and `FunctionTearOffExpression`. Those are resolution meanings of one source role. The working source node is instead something like:

```dart
sealed class NameExpression implements Expression {
  Token get name;

  /// Null before resolution or when receiver evaluation prevents the access.
  /// An executed invalid access has an InvalidNamedReadResolution.
  NamedReadResolution? get resolution;
}

abstract final class UnqualifiedNameExpression implements NameExpression {}
```

The node is an `Expression` because this particular occurrence of the name is in a value-producing position. The node's source identity and topology do not depend on whether lookup later finds a variable, getter, function, type, invalid declaration, or nothing.

## 2. Expression Means a Value-Producing Occurrence

The proposed semantic boundary is:

```dart
Expression
  is normally a source occurrence whose evaluation produces a value
  can narrowly be a no-token semantic adaptation from one value to another
  can narrowly be a no-token invalid recovery container when a complete non-value receiver must fill an expression slot
  has precedence where applicable
  has a static type after resolution
```

For an unresolved AST, `staticType` can remain nullable. In a resolved AST, every actual expression should have a non-null type, using `InvalidType` for invalid value expressions rather than using `null` to mean that the node was not really an expression. A semantic adaptation has no independent tokens and delegates its source range to its operand, but it performs an actual language-defined value transformation and has its own resulting static type; it is not merely a resolution label on the operand. The only accepted non-value recovery exception is likewise explicit and no-token: `InvalidExtensionOverrideExpression` or `InvalidSuperExpression` contains the complete typed non-expression source role, supplies `InvalidType`, and exists only because invalid parser recovery must satisfy an expression-typed parent slot.

This excludes selector names, import prefixes, type qualifiers used for static lookup, constructor selectors, declaration names, labels, combinator names, plain write targets, explicit extension overrides, and `super` references used to force superclass dispatch. It also eliminates the need to assign pseudo-expression static types merely because a source construct happens to be represented by an expression class today.

This design does not imply that every source construct that participates in evaluation is an `Expression`. An assignment target can cause receiver and index expressions to be evaluated, can perform a getter read as part of compound assignment, and can invoke a setter, but the target itself does not produce one value with one static type. An explicit extension override evaluates its argument and changes dispatch without producing a wrapper value, while `super` changes dispatch for the implicit current instance without itself being evaluated.

### 2.1 Function expressions and function declarations

The same value-producing boundary applies to function syntax. In the current analyzer, a top-level or local named function declaration contains a `FunctionExpression`, and a local declaration is additionally wrapped in `FunctionDeclarationStatement`:

```dart
FunctionDeclarationStatement
  functionDeclaration: FunctionDeclaration
    returnType: int
    name: local
    functionExpression: FunctionExpression
      parameters: (int value)
      body: => value
      staticType: int Function(int)
```

The nested `FunctionExpression` is not a value-producing occurrence. The declaration introduces the name `local`; a later read of that name produces a function value. Giving the declaration's suffix an expression node and a static type violates the same source-role rule that excludes declaration names and assignment targets from `Expression`. The current element binder also assigns the same fragment to both the declaration and its nested function expression, exposing duplicated semantic ownership created only by the AST shape.

Canonical V2 should reserve `FunctionExpression` for a written anonymous function that actually produces a function value:

```dart
var identity = <T>(T value) => value;

VariableDeclaration(identity)
  initializer:
    FunctionExpression
      typeParameters: <T>
      formalParameterList: (T value)
      body:
        ExpressionFunctionBody
          expression: UnqualifiedNameExpression(value)
      declaredFragment: anonymous LocalFunctionFragment
      staticType: T Function<T>(T)
```

Its formal parameter list is required by function-expression syntax; parser recovery can synthesize missing delimiters without making the canonical property nullable. The anonymous `LocalFunctionFragment` remains useful because the current element model represents closures as local functions and uses the fragment as the owner of type parameters, formal parameters, body scope, and inferred executable type. No `FunctionExpressionResolution` is needed: `staticType` is the inferred function type, `declaredFragment` supplies the executable declaration model, the parameter and type-parameter nodes own their declarations, and the body contains its ordinary resolved expressions and references. Whether a downward function context was supplied can remain internal inference bookkeeping rather than public resolution metadata.

```dart
abstract final class FunctionExpression implements Expression {
  TypeParameterList? get typeParameters;
  FormalParameterList get formalParameterList;
  FunctionBody get body;
  LocalFunctionFragment? get declaredFragment;
}
```

Named declarations should directly own the syntax that is currently hidden inside `functionExpression`. Top-level and local functions are different source roles: the former is a compilation-unit member, while the latter directly occupies a statement slot. Once they are separate concrete nodes, a tokenless `FunctionDeclarationStatement` containing a one-child declaration is unnecessary.

```dart
sealed interface class FunctionDeclaration implements AstNode {
  NodeList<Annotation> get metadata;
  TypeAnnotation? get returnType;
  Token get name;
  TypeParameterList? get typeParameters;
  FormalParameterList? get formalParameterList;
  FunctionBody get body;
  ExecutableFragment? get declaredFragment;
}

abstract final class TopLevelFunctionDeclaration
    implements CompilationUnitMember, FunctionDeclaration {
  Token? get augmentKeyword;
  Token? get externalKeyword;
  Token? get propertyKeyword;
  bool get isGetter;
  bool get isSetter;
  bool get isComplete;
}

abstract final class LocalFunctionDeclaration
    implements Statement, FunctionDeclaration {
  @override
  FormalParameterList get formalParameterList;

  @override
  LocalFunctionFragment? get declaredFragment;
}
```

The common `FunctionDeclaration` is an API capability rather than the single visitor superclass of both concrete nodes. `TopLevelFunctionDeclaration` naturally generalizes to `CompilationUnitMember`, while `LocalFunctionDeclaration` naturally generalizes to `Statement`; tooling that needs their shared declaration children can test the capability without forcing the local node into the compilation-unit-member hierarchy or giving it two competing general visitor parents. Metadata is shared because annotations are valid on local functions. Top-level-only modifiers and getter/setter classification remain on the top-level node. The common formal parameter list is nullable because the top-level node still includes getters, while the local override is non-null because valid local function syntax always has a formal parameter list.

```dart
void top() {
  int local(int value) => value;
}

TopLevelFunctionDeclaration
  returnType: void
  name: top
  formalParameterList: ()
  body:
    BlockFunctionBody
      statements:
        LocalFunctionDeclaration
          returnType: int
          name: local
          formalParameterList: (int value)
          body:
            ExpressionFunctionBody
              expression: UnqualifiedNameExpression(value)
          declaredFragment: local
```

The declaration nodes have no `staticType`. Their selected executable fragments expose their declared function types, and a later `UnqualifiedNameExpression(local)` with `ExecutableTearOffResolution` is the expression that produces the function value. Illegal local modifiers such as `external` or `static` still need token-preserving recovery, but they should not acquire normal-looking valid properties on `LocalFunctionDeclaration` merely because the old shared node had top-level modifier fields; a general invalid-modifier recovery representation is preferable. Splitting top-level getters, setters, and ordinary functions further could remove the remaining nullable formal-parameter-list state, but that is a declaration-hierarchy question independent of making `FunctionExpression` genuine.

### 2.2 Expressions as contextual argument, collection-element, and record-field roles

The value-producing expression hierarchy and the contextual roles in which an expression can occur are deliberately not disjoint taxonomies. An ordinary expression can directly be a positional argument, an ordinary collection element, or a positional record-literal field without acquiring a tokenless wrapper that merely repeats the expression's range, parent slot, and value type:

```dart
abstract final class Expression
    implements Argument, CollectionElement, RecordLiteralField {
  DartType? get staticType;
}
```

These are contextual source roles rather than claims that every implementation has the same evaluation shape. A direct expression is one argument value, one ordinary list or set element, or one positional record field. Other implementations own additional written syntax and can have different evaluation behavior:

```dart
sealed interface class Argument implements AstNode {
  Expression get argumentExpression;
  FormalParameterElement? get correspondingParameter;
}

abstract final class NamedArgument implements Argument {
  Token get name;
  Token get colon;
  Expression get argumentExpression;
}

sealed interface class CollectionElement implements AstNode {}

abstract final class MapLiteralEntry implements CollectionElement {
  Token? get keyQuestion;
  Expression get key;
  Token get separator;
  Token? get valueQuestion;
  Expression get value;
}

abstract final class NullAwareElement implements CollectionElement {
  Token get question;
  Expression get value;
}

abstract final class SpreadElement implements CollectionElement {
  Token get spreadOperator;
  Expression get expression;
}

abstract final class IfElement implements CollectionElement {}
abstract final class ForElement implements CollectionElement {}

sealed interface class RecordLiteralField implements AstNode {}

abstract final class RecordLiteralNamedField implements RecordLiteralField {
  Token get name;
  Token get colon;
  Expression get fieldExpression;
}
```

The existing names of the syntax-bearing variants should be retained unless a stronger reason than marginal wording improvement appears. A named argument deserves a node because its name and colon are written syntax and the name is a reference to the corresponding formal parameter. A map entry, null-aware element, spread, collection `if`, collection `for`, and named record field likewise own tokens, scopes, or control behavior not supplied by their contained expression. A hypothetical `PositionalArgument`, `ExpressionCollectionElement`, or `PositionalRecordLiteralField` would own no corresponding syntax or independently useful resolution and would add an allocation and visitor level to very common tree positions.

The uniform established `Argument.argumentExpression` API remains convenient: an ordinary expression returns itself, while a named argument returns its contained value expression. `RecordLiteralField.fieldExpression` follows the same rule for direct and named fields. `Argument.correspondingParameter` describes only matching of an explicit argument occurrence to a formal parameter. It must not make an operand of `a + b`, `a[b]`, `a[b] = value`, or `++a` pretend to be an explicit argument merely because the selected operator method has formal parameters; those relationships belong to the operator-owning node, `IndexReadResolution`, `IndexWriteResolution`, and the corresponding write resolution.

`CollectionElement` should remain a sealed union of valid literal children without a common resolution payload. Collection inference, constant context, and set-versus-map interpretation belong to the enclosing literal and resolver. `MapLiteralEntry` owns the distinct key and value expressions and the independently optional question tokens of `?key: value`, `key: ?value`, and `?key: ?value`; `NullAwareElement` owns the leading question token of `?value`; `SpreadElement` owns its spread and optional null-aware syntax; and collection `if` and `for` nodes own their conditions, loops, declarations, scopes, and nested elements. A null-aware element or map part conditionally contributes its value but does not itself produce a value usable by surrounding expression syntax, so it has no `staticType` or operation-resolution object. A collection `if` or `for` can contribute zero or multiple runtime entries, so the contextual role does not itself imply one produced value or a `staticType`.

The same reasoning applies to record literals. A positional field is already exactly the expression whose value and static type become that field, while a named field needs a syntax-bearing node for its label and colon. The record literal owns the resulting record type and field ordering; no `RecordLiteralFieldResolution` is needed.

The implementation should preserve convenient exhaustive switching over the public contextual variants even if implementation reuse requires mixins. Losing a sealed implementation superclass is a generator and implementation-organization cost of the direct-role design, not a reason to expose wrapper nodes in the canonical AST. Visitors that traverse the primary syntactic hierarchy still visit the contained expression normally, while role-oriented clients can distinguish a direct `Expression` from the finite syntax-bearing alternatives.

### 2.3 Literal hierarchy

The current literal hierarchy is semantically sound and can remain in canonical V2:

```dart
Literal
  BooleanLiteral
  DoubleLiteral
  IntegerLiteral
  NullLiteral
  RecordLiteral
  SymbolLiteral
  StringLiteral
    AdjacentStrings
    SingleStringLiteral
      SimpleStringLiteral
      StringInterpolation
  TypedLiteral
    ListLiteral
    SetOrMapLiteral
```

Unlike the removed identifier hierarchy, every implementation of `Literal` is genuinely a value-producing `Expression`, and the sealed category corresponds to written literal syntax. Although `Literal` has no additional common properties, it supplies a useful visitor fallback and permits exhaustive classification of literal forms. It must not imply that every literal is a constant expression: a string interpolation, record, list, set, or map can contain non-constant expressions, and constant context is not an intrinsic property of the broad literal category.

`TypedLiteral` has a concrete shared source contract rather than serving only as a taxonomy:

```dart
sealed class TypedLiteral implements Literal {
  Token? get constKeyword;
  bool get isConst;
  TypeArgumentList? get typeArguments;
}
```

Only list and set-or-map literals share that exact syntax. Record literals do not have type arguments, so a broader const-capable-literal interface would weaken the contract without a demonstrated client need. `SetOrMapLiteral` retains its existing context- and element-dependent set-versus-map interpretation; that ambiguity belongs to the enclosing literal and does not require changing `CollectionElement` or introducing a literal-resolution hierarchy.

The string subhierarchies likewise provide useful APIs. `StringLiteral` covers simple, adjacent, and interpolated strings and exposes the optional compile-time `stringValue`. `SingleStringLiteral` distinguishes one lexically delimited string from an adjacent group and provides the common content offsets, multiline, raw, and quote-style properties shared by `SimpleStringLiteral` and `StringInterpolation`:

```dart
sealed class StringLiteral implements Literal {
  String? get stringValue;
}

sealed class SingleStringLiteral implements StringLiteral {
  int get contentsOffset;
  int get contentsEnd;
  bool get isMultiline;
  bool get isRaw;
  bool get isSingleQuoted;
}
```

Literal resolution needs no separate result hierarchy. `IntegerLiteral.staticType` records contextual selection of `int` or `double`; other primitive literals expose their ordinary static types; collection and record literals expose their inferred aggregate static types; and constant evaluation remains a separate operation. String interpolation conversion is intrinsic to interpolation evaluation rather than a selected source reference or no-token value adaptation that surrounding inference can observe.

### 2.4 `staticType` rather than `type`

The base `Expression` API retains the established `staticType` name:

```dart
abstract final class Expression {
  DartType? get staticType;
}
```

The shorter `type` would be ambiguous and conflicts directly with structural children already owned by expression nodes. `AsExpression.type` and `IsExpression.type` are written `TypeAnnotation` children, while `TypeLiteral.type` is the `NamedType` syntax denoting the type object produced by the expression. Renaming all of those source children merely to free the broad name on `Expression` would create substantial churn without improving the model.

The qualifier also states the intended fact: `staticType` is the statically computed type of the value produced by this expression occurrence, not a written type annotation, a declaration's type, the type represented by a `TypeLiteral`, or the value's runtime type. For example:

```dart
TypeLiteral
  type: NamedType(C<int>)
    type: C<int>
  staticType: Type

AsExpression
  expression: value
  type: NamedType(num)
  staticType: num
```

Resolution-result interfaces can continue to use the shorter `type` because their narrow operation-specific owner supplies the subject: `NamedReadResolution.type`, `IndexReadResolution.type`, and `InvocationResolution.type` describe the result of that operation if it executes. Null shortening can make the enclosing expression's `staticType` nullable without changing the executed-path operation type. Operators instead expose their selected `element` directly. Compound-assignment and increment-or-decrement nodes use the explicit `operatorResultType` name for the intermediate operator result because those nodes also have an outer `Expression.staticType` that can differ.

### 2.5 Base `Expression` API

After removing target and identifier responsibilities, the canonical base expression contract remains small:

```dart
abstract final class Expression
    implements Argument, CollectionElement, RecordLiteralField {
  DartType? get staticType;
  Precedence get precedence;
  bool get inConstantContext;
  Expression get unParenthesized;
  AttemptedConstantEvaluationResult? computeConstantValue();
}
```

`precedence` is intrinsic source information used by printers and transformations to determine when parentheses are required. A no-token semantic adaptation delegates precedence to its operand because it introduces no written operator; the two no-token invalid receiver-expression wrappers derive precedence from their contained source spelling for the same syntactic reason. `inConstantContext` is parent-sensitive but expresses a language-defined condition meaningful for every expression, so it remains a computed convenience rather than stored resolution state. `unParenthesized` is likewise a derived convenience that strips all immediately nested `ParenthesizedExpression` layers and otherwise returns the receiver; an invalid receiver-expression wrapper returns itself because it is not a parenthesis-elision layer. `computeConstantValue()` remains a potentially expensive operation on a resolved expression rather than a stored property; returning no result for a non-constant expression does not require a constant-resolution hierarchy.

The current `isAssignable` getter is removed. Assignment capability is represented structurally by `AssignmentTarget`, and parser logic constructs or rejects a target rather than asking a value expression whether it could occur on the left of an assignment.

The current `canBeConst` getter is also removed from `Expression`. It does not ask whether an arbitrary expression is constant; it asks approximately whether an explicit `const` keyword can be inserted before one of a few eligible source forms without producing constant-evaluation errors. Its current implementations exist only on constructor invocations, dot-shorthand constructor invocations, and typed collection literals and can temporarily mutate the AST with a synthetic keyword while running constant verification. This is lint and fix analysis, not an intrinsic property of every expression. An analyzer service such as `ConstAnalysis.canAddConst(Expression)` can provide the operation, while a V1 compatibility getter can delegate to that service if required.

Direct expressions also implement the established contextual-role APIs inherited from `Argument` and `RecordLiteralField`: `argumentExpression` and `fieldExpression` return the expression itself, and `correspondingParameter` is non-null only when the expression directly occupies a matched `ArgumentList` slot. `CollectionElement` contributes no common property.

## 3. Assignment Targets Are Not Expressions

The clearest counterexample to the current hierarchy is:

```dart
x = 0;
```

The occurrence `x` is not read and has no static type. The whole assignment is an expression and has a static type, but its left side identifies where the value is written.

Assignments have three different evaluation protocols, so the outer hierarchy should make those protocols structural rather than leaving clients to classify one general node from its token:

```dart
sealed interface class AssignmentExpression implements Expression {
  AssignmentTarget get target;
  Token get operator;
  Expression get value;
}

final class DirectAssignment
    implements AssignmentExpression {}

final class IfNullAssignment
    implements AssignmentExpression {}

final class CompoundAssignment
    implements AssignmentExpression {
  BinaryOperator get binaryOperator;
  MethodElement? get element;
  DartType? get operatorResultType;
}
```

Migration note: the analyzer currently exposes the common V2 interface as `AssignmentExpression2` because the unsuffixed name is still the V1 node. `DirectAssignment`, `IfNullAssignment`, and `CompoundAssignment` are canonical for bare-name, property, ordinary index, and indexed-cascade targets. The current receiver-supplied property and index target names remain `PropertyAssignmentTarget` and `IndexAssignmentTarget`; the proposed hierarchy renames them to `ReceiverPropertyAssignmentTarget` and `ReceiverIndexAssignmentTarget` under common property/index target categories. The four increment/decrement nodes use the same canonical non-cascade target forms; increment and decrement are not cascade-section grammar. Name-led property access is represented through the current property-target recovery path; property and invocation cascade starts and invocation-led ambiguous chains remain on their transitional shapes. The `2` suffix is temporary; the final hierarchy keeps the unsuffixed name shown above.

When the target has a write operation, `DirectAssignment` owns `=` and performs only the target write after evaluating its value. `IfNullAssignment` owns `??=`, reads the target and conditionally evaluates the value and performs the write, but does not invoke an overloadable operator. `CompoundAssignment` owns every other assignment operator such as `+=`, reads the target, applies the corresponding overloadable binary operator to that value and the right operand, and writes the result back. Its required `binaryOperator` is derived from the assignment token, so `+=` exposes `BinaryOperator.add` while the node retains the actual `+=` token for source ownership. `element` is the statically selected operator method, or null before resolution or when no method is selected. `operatorResultType` is null before resolution and otherwise records the intermediate operator result, using `dynamic`, `Never`, or `InvalidType` for the corresponding non-method outcomes. If receiver evaluation prevents any target read or write from executing, both target operations are null and the value, implicit operator, and write are skipped together.

The operator facts belong to the compound assignment rather than to its `AssignmentTarget`. They depend on the assignment operator and right operand, while a structurally valid target's non-null read and write results describe only the destination's operations. A compound assignment therefore does not synthesize a nested `BinaryOperatorInvocation`: the outer `CompoundAssignment` owns the operator token, selected `element`, and `operatorResultType` directly. When the target write is non-null, `operatorResultType` is checked against its `acceptedType`; the enclosing assignment's `staticType` describes the value produced by the complete assignment, including any null shortening. A target whose receiver prevents the read and write from executing has no write resolution or accepted-type check, while a structurally invalid target records invalid read and write resolutions independently of the outer node's recovered operator facts.

```dart
x = y
  DirectAssignment
    target: UnqualifiedNameAssignmentTarget(x)
    operator: =
    value: UnqualifiedNameExpression(y)

x ??= y
  IfNullAssignment
    target: UnqualifiedNameAssignmentTarget(x)
    operator: ??=
    value: UnqualifiedNameExpression(y)

x += y
  CompoundAssignment
    target: UnqualifiedNameAssignmentTarget(x)
    operator: +=
    binaryOperator: add
    value: UnqualifiedNameExpression(y)
    element: ...
    operatorResultType: ...
```

The target hierarchy is separate from `Expression`:

```dart
sealed class AssignmentTarget implements AstNode {
  bool get hasRead;
  ReadResolution? get read;
  WriteResolution? get write;
}

final class UnqualifiedNameAssignmentTarget
    implements AssignmentTarget {
  Token get name;
  NamedReadResolution? get read;
  NamedWriteResolution? get write;
}
```

The exact class name is provisional. `NameAssignmentTarget`, `UnqualifiedNameTarget`, and `AssignableName` are alternatives. The important point is that the node denotes where the enclosing assignment writes its computed value; it does not implement `Expression` or expose `staticType`. A write can store a value in a variable or invoke a property setter or `operator []=`. Assignments that need the destination's current value describe that read separately on the target.

The assignment expression still produces a value and therefore remains an `Expression`. When `x = e` has a target write, its type is based on the value assigned according to the language rules. In compound and if-null assignments, the whole expression's result type follows the corresponding language semantics and is distinct from both the target read type and write accepted type. In a resolved AST, a target with null read and write instead records that no target access executes; the outer assignment determines the resulting control-flow type without inventing either operation type.

### 3.1 Target read and write resolution

`AssignmentTarget` exposes its operations through two small shared interfaces:

```dart
abstract final class ReadResolution {
  Element? get element;
  DartType get type;
}

abstract final class WriteResolution {
  DartType get acceptedType;
  Element? get element;
}
```

`NamedReadResolution` and `IndexReadResolution` implement `ReadResolution`; their write counterparts implement `WriteResolution`. Concrete targets covariantly retain their named or indexed getter types. Consumers can inspect `target.read?.type`, `target.write?.acceptedType`, or match a specific resolution subtype without first enumerating syntactic target families. Invocation signatures, index parameters, candidates, and recovery remain on specialized interfaces. The shared interfaces introduce no wrapper or duplicated storage.

Unsuccessful resolution is a second classification, shared across target shapes:

```dart
abstract final class InvalidReadResolution implements ReadResolution {
  // type is InvalidType.
}

abstract final class InvalidWriteResolution implements WriteResolution {
  // acceptedType is InvalidType.
}
```

`InvalidNamedReadResolution` implements both `NamedReadResolution` and `InvalidReadResolution`; `InvalidIndexReadResolution` implements both `IndexReadResolution` and `InvalidReadResolution`. Their write counterparts implement `InvalidWriteResolution` alongside their named or indexed interface. Thus `read is InvalidReadResolution` recognizes all unsuccessful read kinds without discarding specialized candidates or recovery. Structural invalidity remains a property of `InvalidAssignmentTarget`, not a separate meaning of the common resolution interface.

The internal hierarchy expresses the same subtype relationships while retaining the existing implementation superclasses:

```dart
final class InvalidNamedReadResolutionImpl extends NamedReadResolutionImpl
    implements InvalidReadResolutionImpl, InvalidNamedReadResolution {
  // Recovery element and canonical InvalidType implementation.
}

final class InvalidIndexReadResolutionImpl extends IndexReadResolutionImpl
    implements InvalidReadResolutionImpl, InvalidIndexReadResolution {
  // Recovery element, guarded indexContextType, and canonical InvalidType.
}
```

Invalid named and indexed writes similarly implement `InvalidWriteResolutionImpl` while extending their respective write-family base classes. `implements` establishes the shared classification without inheriting the generic implementation's getter. The const, stateless `InvalidReadResolutionImpl` and `InvalidWriteResolutionImpl` remain directly constructible for structurally invalid targets.

Both interfaces expose the selected declaration through `element`, including any substitution at this occurrence. It is null for dynamic access, record-field reads, function-`call` tear-offs, and invalid resolutions, including invalid resolutions with recovery or candidates. A null element does not imply invalid resolution. Consumers that inspect declaration metadata can use `checkUsage(target.write?.element, target)` or the corresponding read query; recovery-aware consumers must explicitly request recovery.

`IfNullAssignment` delegates element-usage checks to the shared assignment-target helper unconditionally. The helper checks the selected read and write declarations and chooses the diagnostic range from the target shape. This includes receiver-property and cascade-property targets, so deprecated getters and setters are checked for `(a).x ??= value` and `a..x ??= value` as well as `a.x ??= value`.

Named operations that resolve to a specific declaration retain interfaces that narrow the getter to non-null:

```dart
abstract final class NamedReadResolutionWithElement
    implements NamedReadResolution {
  @override
  Element get element;
}

abstract final class NamedWriteResolutionWithElement
    implements NamedWriteResolution {
  @override
  Element get element;
}
```

The named interfaces constrain factory results and recovery fields to operations with a selected declaration. Method-index resolutions directly narrow `element` to non-null `MethodElement`. Generic consumers use the nullable root getters; there is no additional shared element-bearing interface. Named and indexed implementation families keep their existing base classes. Parameter lookup and invocation analysis still distinguish the concrete operations.

The internal `ReadResolutionImpl` and `WriteResolutionImpl` roots provide `element => null` defaults. Element-free results inherit them; declaration-bearing results supply their existing element fields. Their non-null interface getters prevent a concrete declaration-bearing implementation from accidentally inheriting the nullable default. Public interfaces remain abstract.

Dynamic and invalid resolutions do not implement the `WithElement` interfaces. An invalid resolution may contain a recovery object that does. The non-null guarantee does not assert that the entire source construct is free of diagnostics.

`hasRead` is syntactic: false for direct assignment and true for compound assignment, `??=`, and increment or decrement, including unresolved and invalid targets. It must not be implemented as `read != null`. Resolution data describes the selected static operations, not a promise of runtime execution: for example, `??=` has a write resolution even though its write is conditional.

A structurally valid assignment destination can have only a write operation, both a read and a write operation, or neither operation when no target access can execute. Named and property targets directly expose the same `NamedReadResolution` used by value-producing name and property expressions together with the parallel `NamedWriteResolution`:

```dart
sealed interface class PropertyAssignmentTarget
    implements AssignmentTarget {
  Token get propertyName;
  NamedReadResolution? get read;
  NamedWriteResolution? get write;
}
```

Before resolution, the target's `read` and `write` can both be null. In a resolved AST, `write != null` means that the assignment has a valid or invalid write operation. `read == null` with a non-null write means that the assignment performs no read, as in plain `=`; compound assignment, `??=`, and increment or decrement instead contain a non-null valid or invalid read result. Invalid lookup is represented by non-null invalid read or write results, not by omitting the operation. Whether semantic properties are available is a contract of the analysis phase that produced the `CompilationUnit`, just as it is for expression `staticType`; individual target nodes do not carry a separate resolvedness marker.

In a resolved AST, `write == null` means that receiver evaluation cannot complete because its type is `Never`, or that the non-null branch of an exact-null null-aware target is statically impossible. In either case no target access executes: there is no getter read, setter write, or write `acceptedType`, and `read` is also null. This state concerns execution of the target access, not flow analysis reachability of the surrounding source. The analyzer maintains the producer invariant `write != null || read == null`; the public API does not introduce subclasses solely to make the impossible `read != null && write == null` combination unrepresentable. A resolved unqualified-name or import-prefixed target always has a non-null valid or invalid `write`, because neither source form has a receiver whose evaluation can prevent the protocol.

The target itself still has no `staticType`: a non-null `read.type` is the type produced by the implicit read occurrence, while a non-null `write.acceptedType` is the type against which the value written back is checked. Index targets directly expose the parallel specialized `IndexReadResolution` and `IndexWriteResolution` results with the same state invariant. There is no generic `AccessResolution` erasing the materially different payloads of named lookup, `operator []`, and `operator []=`.

The target read/write states are:

| State or syntax | Target read | Target write |
| --- | --: | --: |
| Unresolved AST | Null | Null |
| `x = e` | Null | Non-null |
| `x += e` and other ordinary compound assignments | Non-null | Non-null |
| `x ??= e` | Non-null | Non-null |
| `++x` or `x++` | Non-null | Non-null |
| Resolved structurally invalid target in `=` | Null | Invalid write |
| Resolved structurally invalid target in compound assignment, `??=`, or update | Invalid read | Invalid write |
| No target access executes | Null | Null |

For compound assignment, the read type and write accepted type can be different. For example:

```dart
void f(num x) {
  if (x is int) {
    x += 1;
  }
}
```

The read type of the target is `int`, the write accepted type is `num`, and the static type of the whole assignment expression is determined from the operator result. A single `staticType` on the occurrence `x` cannot represent these facts.

The implicit read in a compound assignment is resolution data on the target; it is not represented by inserting a synthetic `UnqualifiedNameExpression` child. Similarly, the write-back is not represented as a second source target. One source target directly exposes both operation results.

### 3.2 Prefix and postfix increment and decrement

Prefix and postfix increment and decrement remain expressions because the whole construct produces a value. Their operand becomes an `AssignmentTarget`. Four concrete nodes make both the token position and the selected increment-or-decrement operation part of the source structure:

```dart
sealed interface class IncrementOrDecrementExpression
    implements Expression {
  AssignmentTarget get target;
  Token get operator;
  MethodElement? get element;
  DartType? get operatorResultType;
}

final class PrefixIncrement
    implements IncrementOrDecrementExpression {}

final class PrefixDecrement
    implements IncrementOrDecrementExpression {}

final class PostfixIncrement
    implements IncrementOrDecrementExpression {}

final class PostfixDecrement
    implements IncrementOrDecrementExpression {}
```

The concrete type fixes the owned token and the implicit operator invocation: `PrefixIncrement` and `PostfixIncrement` own `++` and select `operator +`, while `PrefixDecrement` and `PostfixDecrement` own `--` and select `operator -`. No token-derived operator enum duplicates that identity. All four nodes implement `IncrementOrDecrementExpression` because they perform the same read-operator-write protocol and expose the same data. When the target protocol starts, a structurally valid target has both a read and a write, while the enclosing expression's `element` records the method selected for the implicit `+` or `-` invocation between those operations. `operatorResultType` is null before resolution and otherwise is the new value type checked against a valid target write. It can be computed from the target read, selected element, and numeric refinement rules rather than stored independently. A prefix increment or decrement normally produces that new value, while a postfix increment or decrement produces the old target-read value, so `PostfixIncrement.staticType` and `PostfixDecrement.staticType` can differ essentially from `operatorResultType`. Null shortening can also make the complete expression type nullable while `operatorResultType` describes the executed non-null path. If receiver evaluation prevents the protocol, the target has null read and write. A structurally invalid target records invalid read and write resolutions, while the enclosing expression can retain recovered operator facts based on its typed child. These nodes are not grouped with non-increment-or-decrement prefix and postfix operations because those operations require value or receiver operands rather than assignment targets.

`PrefixIncrement`, `PrefixDecrement`, `PostfixIncrement`, and `PostfixDecrement` follow the concise naming rule used by concrete expression operations such as `LogicalNot`, `LogicalAnd`, `LogicalOr`, `IfNull`, and `NullAssertion`. Their `Expression` supertype already identifies the AST domain, so an `Expression` suffix would add no distinction. The common `IncrementOrDecrementExpression` is an abstract taxonomic interface rather than one concrete operation, so its explicit `Expression` suffix supplies the head noun and distinguishes the AST family from an operator or semantic-result category. Other abstract taxonomic interfaces such as `AssignmentExpression` and `BinaryExpression`, and names that need the word to identify or disambiguate the source construct such as `ParenthesizedExpression` and `FunctionExpression`, likewise retain the suffix.

Clients that need the common read-operator-write data can match `IncrementOrDecrementExpression(:var target, :var element, :var operatorResultType)`. Orthogonal groupings need no additional public prefix, postfix, increment, or decrement interfaces: `PrefixIncrement() || PrefixDecrement()` selects the prefix forms, `PostfixIncrement() || PostfixDecrement()` selects the postfix forms, `PrefixIncrement() || PostfixIncrement()` selects increment, and `PrefixDecrement() || PostfixDecrement()` selects decrement. Exhaustive object and logical-or patterns therefore preserve cheap common processing while the leaf type remains self-describing.

### 3.3 Invalid targets

Invalid write resolution does not by itself require an invalid target node. Source that has an honest assignment-target shape retains that concrete target even when the selected declaration cannot be written:

```dart
final int x = 0;
x = 1;

object.method = 1;

C = value;
```

The first and last writes remain `UnqualifiedNameAssignmentTarget`, while the member write remains `ReceiverPropertyAssignmentTarget`; their invalid write resolutions explain the final variable, method-without-setter, or type-name failure. The same rule applies when a bare name resolves to a function or method: plain `=` has only an invalid write, while `??=` or compound assignment additionally has an `ExecutableTearOffResolution` for its implicit read. `InvalidAssignmentTarget` is reserved for source that cannot honestly become any storage-location role, including invocation, literal, binary, extension-override, and bare-`super` forms:

```dart
f() = 0;
42 = 0;
(a + b)++;
E(value) = 0;
super = 0;
```

The three structurally different recovery payloads use concrete typed variants:

```dart
sealed class InvalidAssignmentTarget implements AssignmentTarget {
  InvalidReadResolution? get read;
  InvalidWriteResolution? get write;
}

final class InvalidExpressionAssignmentTarget
    implements InvalidAssignmentTarget {
  Expression get expression;
}

final class InvalidExtensionOverrideAssignmentTarget
    implements InvalidAssignmentTarget {
  ExtensionOverride get extensionOverride;
}

final class InvalidSuperAssignmentTarget
    implements InvalidAssignmentTarget {
  SuperReference get superReference;
}
```

```dart
f() = 0
  DirectAssignment
    target:
      InvalidExpressionAssignmentTarget
        read: null
        write: InvalidWriteResolution(acceptedType: InvalidType)
        expression: CallInvocation(f())
    value: IntegerLiteral(0)

E(value) += increment
  CompoundAssignment
    target:
      InvalidExtensionOverrideAssignmentTarget
        read: InvalidReadResolution(type: InvalidType)
        write: InvalidWriteResolution(acceptedType: InvalidType)
        extensionOverride: ExtensionOverride(E(value))
    value: UnqualifiedNameExpression(increment)
    element: ...
    operatorResultType: ...

super++
  PostfixIncrement
    target:
      InvalidSuperAssignmentTarget
        read: InvalidReadResolution(type: InvalidType)
        write: InvalidWriteResolution(acceptedType: InvalidType)
        superReference: SuperReference(super)
    element: ...
    operatorResultType: ...
```

Before resolution, invalid targets have null `read` and `write`. Resolution records an `InvalidWriteResolution` and, when `hasRead` is true, an `InvalidReadResolution`. These results describe unsuccessful operations: their `acceptedType` and `type` are `InvalidType`, and they select no declaration. Structural failure is identified by `InvalidAssignmentTarget`; the common invalid-resolution interfaces also classify named and indexed lookup failures.

The typed child remains fully resolved for diagnostics, references, navigation, and recovery. `InvalidExpressionAssignmentTarget.expression` retains its own `staticType`; the extension override retains its selected extension and extended type; and the super reference retains the superclass-dispatch source role. The enclosing compound-assignment or increment-or-decrement expression can independently retain a recovered operator `element` and `operatorResultType` based on that child. Neither the child's type nor its evaluation becomes a successful target read, and V1 projections retain their existing recovery types.

Implementation status (2026-09-09): `InvalidExpressionAssignmentTargetImpl` stores nullable `InvalidReadResolutionImpl` and `InvalidWriteResolutionImpl` fields. The assignment and update resolvers set the appropriate fields after resolving the expression. There is no `_isResolved` flag, and resolution availability is not inferred from the child's `staticType`: a resolved extension override can have a null type in the transitional AST. The separate extension-override and super target variants remain part of the proposed design.

Summary serialization preserves the two fields with `writeOptionalObject` and `readOptionalObject`. The stateless invalid results need only presence markers, with no object payload. Resolved AST dumps show each present invalid operation and its type. Constant-initializer coverage uses separate full element-model text dumps for direct assignment, if-null assignment, prefix increment, and postfix increment, exercised both with retained linking data and after deserialization.

All three children currently implement `InstanceReceiver`, so an implementation resolving `f() += value`, `E(value) += value`, or `super++` can use a private switch to obtain a receiver for operator-recovery lookup. This is an accidental overlap rather than the structural contract of invalid assignment recovery. `InstanceReceiver` answers which roles can receive indexing, invocation, or supported overloadable operators; `InvalidAssignmentTarget` answers which non-location source structure was placed before an assignment or increment/decrement operator. Adding a receiver capability must not automatically broaden invalid-target syntax, and adding another recovery payload must not require pretending that it supports instance operations. The public hierarchy therefore exposes the three typed children instead of one `InstanceReceiver attemptedTarget` or untyped `AstNode` child.

The parser can construct `InvalidExpressionAssignmentTarget` directly for syntactically non-target-shaped expressions. When an invocation-shaped parsed chain such as `E(value)` is followed by an assignment or increment/decrement operator, parser-only recovery may initially preserve it as an invalid expression target or as an unresolved target chain according to implementation convenience; resolution must replace that provisional form with `InvalidExpressionAssignmentTarget` when it denotes an invocation value or with `InvalidExtensionOverrideAssignmentTarget` when it denotes an extension override. Bare `super` directly selects `InvalidSuperAssignmentTarget`. None of these target nodes contains `InvalidExtensionOverrideExpression` or `InvalidSuperExpression`, because those wrappers exist only to fill `Expression` slots and would add a false, stacked recovery layer inside an assignment-target slot.

### 3.4 Existing-variable for-in writes

Existing-variable for-in syntax is a write-only occurrence adjacent to assignment targets, but its grammar admits only an identifier:

```dart
forLoopParts:
  identifier 'in' expression
```

Property and index forms such as `for (object.field in values)` and `for (list[index] in values)` are not general existing-variable for-in targets. Canonical V2 should therefore not broaden this source role to `AssignmentTarget` or wrap the identifier in `UnqualifiedNameAssignmentTarget`. `ForEachPartsWithIdentifier` already owns the only written name and can expose its write operation directly:

```dart
abstract final class ForEachPartsWithIdentifier
    implements ForEachParts {
  Token get identifier;
  NamedWriteResolution? get write;
  Token get inKeyword;
  Expression get iterable;
}
```

The class name can remain even though canonical V2 removes the reusable `Identifier` and `SimpleIdentifier` node hierarchies: here “identifier” describes the grammar token, and the existing property becomes a `Token` rather than an identifier AST child. Before resolution, `write` is null. In a resolved AST, a non-null valid or invalid `NamedWriteResolution` identifies a local or formal variable, an implicit-receiver setter, a top-level setter, or the corresponding failed write and exposes the type accepted by that repeated assignment. There is no `NamedReadResolution` or `staticType` on the occurrence.

For example:

```dart
T g<T>() => throw 0;

set x(int value) {}

void f() {
  for (x in g()) {}
}
```

the `x` token has a setter `NamedWriteResolution` whose `acceptedType` is `int`. That accepted type contributes `Iterable<int>` as the context for the synchronous iterable expression, so `g()` is inferred accordingly; an `await for` analog uses the corresponding asynchronous iterable context. The element type obtained from the resolved iterable is then written to the selected variable or setter on each iteration and drives the ordinary assignment compatibility check and flow-analysis write. A final local can still select `VariableWriteResolution` and fail assignment legality checks. A missing setter, type name, or unresolved name remains the same source node with `InvalidNamedWriteResolution`; it does not become an invalid structural `AssignmentTarget`.

`ForEachPartsWithDeclaration` and `ForEachPartsWithPattern` remain declaration- and pattern-specific source roles. They create or bind loop variables rather than referring to one existing named write destination, so this change does not route them through either `AssignmentTarget` or `NamedWriteResolution`. V1 projection can synthesize the current `SimpleIdentifier` child from the V2 token and write resolution, including the legacy element and type-like compatibility properties, while V2 visitors operate directly on `ForEachPartsWithIdentifier`.

### 3.5 Constructor field initialization

A constructor field initializer contains another write-like name occurrence that should not become an `AssignmentTarget`:

```dart
class A {
  final int field;

  A(int value) : field = value;
}
```

The initializer writes the storage of a field belonging to the object under construction. It does not evaluate an assignment-target expression, invoke a setter, or perform ordinary variable-versus-setter lookup; it can initialize a final field precisely because it is constructor initialization rather than assignment. Lookup is restricted by constructor-initializer rules, and duplicate initialization, inherited or static fields, and other invalid cases are diagnosed as initialization errors. The source owner can expose the only useful selected declaration directly:

```dart
abstract final class ConstructorFieldInitializer
    implements ConstructorInitializer {
  Token? get thisKeyword;
  Token? get period;
  Token get fieldName;
  FieldElement? get fieldElement;
  Token get equals;
  Expression get expression;
}
```

The optional `thisKeyword` and `period` preserve the two written forms `field = value` and `this.field = value`. `fieldName` becomes a token rather than a `SimpleIdentifier` child, and the occurrence has no `staticType`. `fieldElement` is the selected field, while `null` preserves the established unresolved-or-invalid convention. A separate `FieldInitializationResolution` hierarchy is unnecessary until an invalid initializer has concrete candidate or recovery information that a client needs independently of the diagnostic.

The initializer expression is analyzed with the selected field type as its context when available. This contextual relationship does not make the expression an assignment argument and does not require `NamedWriteResolution.acceptedType`: `fieldElement.type` already supplies the exact storage type. `AssignmentTarget`, `NamedReadResolution`, `NamedWriteResolution`, `IndexReadResolution`, and `IndexWriteResolution` remain reserved for ordinary assignable locations and their variable, getter, setter, or index protocols.

V1 projection can synthesize the current `SimpleIdentifier fieldName`, delegate its element to `fieldElement`, and preserve its legacy null `staticType`. Canonical V2 parser, resolver, indexing, and visitor code operate on the initializer's direct token and field element. Field-formal parameters such as `A(this.field)` are related but remain a separate parameter-declaration source role because they both declare a parameter and initialize a field.

### 3.6 Field-formal parameters

A field-formal parameter both declares a constructor parameter and associates that parameter with field initialization:

```dart
class A {
  final int field;

  A(this.field);
}
```

The current token-based V2 source shape is already appropriate:

```dart
abstract final class FieldFormalParameter
    implements FormalParameter {
  Token get thisKeyword;
  Token get period;
  Token get name;
  FieldFormalParameterFragment? get declaredFragment;
}
```

The written name token participates in two related but distinct semantic relationships. `declaredFragment.element` is the `FieldFormalParameterElement` declared in the constructor signature, while `declaredFragment.element.field` is the nullable associated `FieldElement` whose storage is initialized. The parameter element owns the parameter type, kind, default-value and invocation-signature participation, declaring-parameter state, private-name information, and field association. The field element owns the field declaration and storage type. An invalid or absent field is represented by the parameter element's nullable `field` without turning the parameter into an invalid assignment target.

This separation is important when the formal binding name, written field name, and augmentation-signature name do not coincide, including private named parameters, wildcards, primary declaring constructors, and augmentations. The AST preserves the written `name` token; the formal-parameter element model records any effective parameter name and original private name; and its `field` records the selected field. An AST-level `fieldElement` convenience getter would merely delegate the same relationship and is unnecessary without a concrete client requirement.

`FieldFormalParameter` is neither an `Expression` nor an `AssignmentTarget` and has no named read or write resolution. It declares a parameter and participates in constructor-specific field initialization rather than selecting a variable or invoking a setter. Unlike `ConstructorFieldInitializer`, it needs no new direct field-element property because its declared `FieldFormalParameterElement` already carries the association. The existing direct token API also means that removing `SimpleIdentifier` requires no V1 projection change for this node.

### 3.7 Super-formal parameters

A super-formal parameter declares a parameter in the current constructor and forwards its value to a parameter of the selected superclass constructor:

```dart
class A {
  A(int value);
}

class B extends A {
  B(super.value);
}
```

The current direct-token source shape should remain:

```dart
abstract final class SuperFormalParameter
    implements FormalParameter {
  Token get superKeyword;
  Token get period;
  Token get name;
  SuperFormalParameterFragment? get declaredFragment;
}
```

`superKeyword` is a grammatical marker in this parameter form, not a `SuperReference` receiver. The node declares a parameter and does not independently evaluate a value, select an assignable location, or invoke the superclass constructor. It therefore has no `Expression`, `AssignmentTarget`, `NamedWriteResolution`, or `InvocationResolution` role.

The two semantic relationships remain on the element model. `declaredFragment.element` is the declared `SuperFormalParameterElement`, while `declaredFragment.element.superConstructorParameter` is the nullable associated parameter of the superclass constructor selected by the enclosing constructor. Named super formals normally associate by name, while positional super formals associate by position and therefore cannot in general derive the forwarded declaration from the written local name alone. The enclosing constructor's constructor-selection fact determines which superclass signature supplies that association.

An omitted parameter type, an inherited default value, and forwarding compatibility are computed using the associated superclass parameter. Invalid placement, a missing superclass constructor, or a missing corresponding parameter leaves `superConstructorParameter` null while preserving the declared parameter and source tokens for diagnostics. An AST-level forwarding-parameter getter would merely duplicate the element relationship and is unnecessary without a concrete client requirement.

Like `FieldFormalParameter`, `SuperFormalParameter` already owns its name as a token, so removing `SimpleIdentifier` requires no source-shape or V1-projection change here. Together with existing-variable for-in writes, constructor field initializers, and field-formal parameters, this completes the nearby audit of write-like or initialization-like name occurrences that might otherwise have been overgeneralized as expressions or assignment targets.

## 4. Property Extraction and Property Assignment

Most property receivers are expressions, but explicit extension overrides, `super`, and static qualifiers show that the receiver of a named access is wider than "value-producing expression." Different operations accept different subsets of these receiver forms, so the AST should use small capability interfaces rather than either one unrestricted `AstNode` slot or one receiver type that implies instance dispatch:

```dart
/// A source node accepted before a named property or method selection.
sealed interface class NamedReceiver implements AstNode {}

sealed interface class InstanceReceiver implements NamedReceiver {}

abstract final class Expression implements
    AstNode,
    InstanceReceiver {
  DartType? get staticType;
}

final class ExtensionOverride implements InstanceReceiver {
  ImportPrefixReference? get importPrefix;
  Token get name;
  TypeArgumentList? get typeArguments;
  ArgumentList get argumentList;
  ExtensionElement get element;
  DartType? get extendedType;
  List<DartType>? get typeArgumentTypes;
}

final class SuperReference implements InstanceReceiver {
  Token get superKeyword;
}

final class StaticQualifier implements NamedReceiver {
  Element? get element;
  ImportPrefixReference? get importPrefix;
  Token get name;
}
```

These are sealed source-node roles rather than semantic receiver objects computed by resolution. An ordinary expression evaluates to the object used for dispatch. An `ExtensionOverride` evaluates its argument and fixes extension dispatch but does not produce a wrapper value. A `SuperReference` uses the implicit current instance while forcing superclass dispatch. A `StaticQualifier` permits named selection but does not provide a value and cannot be indexed or used as an operator operand. `ImportPrefixReference` is not a receiver: it represents the grouped namespace qualifier `prefix.` and is used by dedicated import-prefixed access nodes.

Property selection has a common operation category and separate receiver-supplied and cascade-supplied forms:

```dart
sealed interface class PropertyExtraction implements NameExpression {}

final class ReceiverPropertyExtraction implements PropertyExtraction {
  NamedReceiver get receiver;
  Token get operator;
}

sealed interface class PropertyAssignmentTarget
    implements AssignmentTarget {
  Token get propertyName;
  NamedReadResolution? get read;
  NamedWriteResolution? get write;
}

final class ReceiverPropertyAssignmentTarget
    implements PropertyAssignmentTarget {
  NamedReceiver get receiver;
  Token get operator;
}
```

For a receiver-supplied extraction, `operator` is `.` or `?.`. The Dart language specification calls this source construct a property extraction: it either invokes a getter and produces its result or closurizes a method and produces the resulting function object. `PropertyExtraction` therefore names the common source and evaluation role, while `ReceiverPropertyExtraction` identifies how this occurrence obtains its receiver. `PropertyReadExpression` would instead import the broader analyzer `NamedReadResolution` terminology into the source hierarchy, even though an executable tear-off is not colloquially a property read and analogous value nodes remain `UnqualifiedNameExpression`, `ImportPrefixedNameExpression`, and `IndexExpression`. The `Expression` supertype already identifies the AST category, so an `Expression` suffix is unnecessary, as it is for `ConstructorTearOff`, `FunctionInstantiation`, and `LogicalNot`.

In:

```dart
a.x = 0;
```

`a` is an expression and has a static type. `a.x` is an assignment target and has a write resolution. In:

```dart
a.x += 1;
```

the same target has both a getter read and a setter write. In:

```dart
a?.x = 0;
```

the `?.` token is source structure on the assignment target. It controls conditional evaluation of the setter and right-hand side and affects the type of the whole assignment expression. The target still does not acquire a `staticType`.

An unqualified instance member remains an `UnqualifiedNameExpression` or `UnqualifiedNameAssignmentTarget`; the AST does not insert a synthetic `this` expression. Resolution can record implicit-instance dispatch where it is needed internally. An explicit ordinary receiver remains an `Expression` child through the `NamedReceiver` API.

Implementation status (2026-08-13): plain, if-null, and compound assignment with a structurally unambiguous ordinary explicit expression receiver and `.` or `?.` use `ReceiverPropertyAssignmentTarget`. It and `CascadePropertyAssignmentTarget` implement the common `PropertyAssignmentTarget` category and share the common property name and typed read/write storage. Supported roots are literals, parenthesized expressions, explicit instance creation, explicit `this`, ordinary index expressions, and recursively supported property chains. Direct assignment records the write. If-null and compound assignment record independent getter, executable tear-off, record-field, dynamic, or invalid read resolution and setter, dynamic, or invalid write resolution; compound assignment additionally records the selected operator and its intermediate result type. A `Never` receiver prevents both target operations. For `?.`, an exact-`Null` receiver likewise records no read or write, and the enclosing assignment has type `Never?`; otherwise lookup uses the promoted non-null receiver type and the enclosing assignment supplies the nullable result. Summary serialization and the V1 `PropertyAccess` projection preserve both canonical and compatibility views. Constructor-initializer `this.field = value` remains `ConstructorFieldInitializer`. The wider `NamedReceiver` surface and invocation-led chains whose receiver role requires resolution stay separate migration work.

Implementation status (2026-08-13): value-producing ordinary `.` and `?.` selection uses `ReceiverPropertyExtraction` for the same positive explicit-expression receiver boundary. It and `CascadePropertyExtraction` implement the common `PropertyExtraction` category and share the common property name and typed read-resolution storage. Supported roots are literals, parenthesized expressions, explicit instance creation, explicit `this`, ordinary index expressions, and recursively supported extraction chains. The node stores a typed `NamedReadResolution`, including getter invocation, executable tear-off, record-field, dynamic, and invalid reads, and projects to a V1 `PropertyAccess`. Summary serialization, indexing, search, diagnostics, constant evaluation, and other expression consumers use the canonical node. When an ordinary receiver has type `Never`, no property-read operation occurs, so the resolution is null while the expression retains static type `Never`. For `?.`, an exact-`Null` receiver likewise has null resolution and type `Never?`; otherwise the resolution type describes the executed non-null path and the enclosing extraction has the corresponding nullable static type. Ordinary explicit `.call`, older language versions without constructor tear-offs, and name-led or invocation-led ambiguous chains remain on their existing AST shapes for later slices. Cascade-start property extraction is covered separately in section 7 and already includes the `..call` form.

### 4.1 Explicit extension overrides

In:

```dart
E(foo).bar
```

`E` references the extension declaration, `foo` is an expression that is evaluated, and `E(foo)` specifies the object and extension used for dispatch. `E(foo)` is not itself a value. The complete property extraction is:

```dart
ReceiverPropertyExtraction
  receiver: ExtensionOverride
    importPrefix: null
    name: E
    typeArguments: null
    argumentList: (UnqualifiedNameExpression(foo))
    element: ExtensionElement(E)
    extendedType: ...
  operator: .
  name: bar
  resolution: ...
```

The extension override retains `typeArguments` because explicit generic extension application such as `E<int>(foo).bar` is meaningful. `extendedType` and `typeArgumentTypes` are resolution facts about dispatch, not an expression `staticType`.

The same `ExtensionOverride` receiver can be used by property reads and targets, index reads and targets, named function invocation, `CallInvocation`, explicit `call` access, and supported operators. A standalone `E(foo);` is invalid because an extension override can only be used to access an instance member. Recovery for that case should not force `ExtensionOverride` to implement `Expression`; lowering uses the precise `InvalidExtensionOverrideExpression` described below.

The extension name has different source roles in:

```dart
E.staticMember
  E: StaticQualifier

E(foo).member
  E(foo): ExtensionOverride
```

### 4.2 `super`

`super` also does not produce a value. It means to use the implicit current instance while beginning lookup and dispatch at the superclass implementation:

```dart
ReceiverPropertyExtraction
  receiver: SuperReference
    superKeyword: super
  operator: .
  name: foo
  resolution: ...
```

`super.foo = value` uses a `ReceiverPropertyAssignmentTarget` with the same `SuperReference` receiver. Compound assignment records the getter read and setter write on that target. `super.foo()`, `super()`, `super[index]`, `super[index] = value`, and `super + value` likewise place `SuperReference` in the restricted receiver or left-operation slot accepted by the enclosing source node. In particular, expression-context `super()` is a `CallInvocation` that resolves the inherited `call` method; it is distinct from the `SuperConstructorInvocation` allowed in a constructor initializer.

### 4.3 Non-value receivers in expression slots

Three superficially similar invalid source forms require two different recovery strategies:

```dart
E;
E(foo);
super;
```

A bare extension name is syntactically a name occurrence attempting to produce a value. It remains source-shaped rather than acquiring a wrapper:

```dart
UnqualifiedNameExpression
  name: E
  resolution: InvalidNamedReadResolution
    recoveryElement: ExtensionElement(E)
    type: InvalidType
  staticType: InvalidType
```

The same strategy applies to a bare import prefix: `UnqualifiedNameExpression` describes the attempted value-position occurrence, while `InvalidNamedReadResolution` retains the successfully bound non-value declaration for diagnostics, indexing, and navigation. There is no successfully selected `ExtensionOverride` or `ImportPrefixReference` source structure in either bare form.

In contrast, resolution of `E(foo)` successfully selects the complete non-expression extension-override structure, and parsing of bare `super` already selects `SuperReference`. When an enclosing slot requires an `Expression`, lowering uses two precise recovery nodes:

```dart
final class InvalidExtensionOverrideExpression
    implements Expression {
  ExtensionOverride get extensionOverride;
}

final class InvalidSuperExpression
    implements Expression {
  SuperReference get superReference;
}
```

```dart
E(foo);
  ExpressionStatement
    expression:
      InvalidExtensionOverrideExpression
        extensionOverride:
          ExtensionOverride
            name: E
            argumentList: (foo)
            element: ExtensionElement(E)
        staticType: InvalidType

super;
  ExpressionStatement
    expression:
      InvalidSuperExpression
        superReference:
          SuperReference
            superKeyword: super
        staticType: InvalidType
```

These wrappers own no tokens, add no resolution object, and are not semantic adaptations. Their child contains the successfully resolved extension override or super reference and its references; the wrapper only satisfies the parser-known expression slot and supplies canonical `InvalidType`. Source range and precedence are derived from the child spelling, while `unParenthesized` returns the wrapper itself. A stable enclosing value operation retains its ordinary node and receives the precise invalid expression as its operand, so `!E(foo)`, `E(foo)!`, `!super`, and `super!` remain `LogicalNot` or `NullAssertion` around the corresponding recovery wrapper.

A common public `InvalidExpression` hierarchy is unnecessary. Only these two receiver structures that do not produce values currently need a wrapper, their typed children are useful, and an untyped `AstNode` child or another public union would weaken the API solely for invalid code. Other invalid value occurrences should remain on their ordinary source-shaped expressions with invalid resolution whenever that source role is honest, as for `E`, an import prefix used as a value, `prefix?.foo`, an unresolved property access, or an invalid index operation.

The receiver capabilities should be used according to the source slot. `InstanceReceiver` refines `NamedReceiver`: every instance receiver can precede named property or function selection, while the broader named-selection capability additionally admits static qualification. `CallInvocation`, index access, and supported operator syntax accept `InstanceReceiver`, excluding static qualifiers. Import namespace qualification remains a separate source role rather than either receiver capability. Neither capability should replace every `Expression` child indiscriminately: ordinary argument expressions, index expressions, right operands, and assigned values still require actual value-producing expressions. The exact set of source slots accepting each capability needs an explicit grammar audit.

## 5. Index Expressions and Index Assignment

Indexing uses the same common-operation and receiver-provision split:

```dart
sealed interface class IndexExpression implements Expression {
  Token get leftBracket;
  Expression get index;
  Token get rightBracket;
  IndexReadResolution? get resolution;
}

final class ReceiverIndexExpression implements IndexExpression {
  InstanceReceiver get receiver;
  Token? get question;
}

sealed interface class IndexAssignmentTarget
    implements AssignmentTarget {
  Token get leftBracket;
  Expression get index;
  Token get rightBracket;
  IndexReadResolution? get read;
  IndexWriteResolution? get write;
}

final class ReceiverIndexAssignmentTarget
    implements IndexAssignmentTarget {
  InstanceReceiver get receiver;
  Token? get question;
}
```

The common value category retains the established conceptual name `IndexExpression`. During migration its V2 public API name is `IndexExpression2`, because `IndexExpression` is already the V1 interface and remains the projection type. The receiver-supplied concrete form is `ReceiverIndexExpression`; `CascadeIndexExpression` is its receiver-less sibling. Because implementing `Expression` already says that the complete occurrence produces a value, `IndexAccessExpression` adds little and makes the source-node name appear inconsistent with the semantic word `read`. `IndexReadExpression` would move operation terminology into the source hierarchy even though analogous value nodes are not named `VariableReadExpression` or `GetterInvocationExpression`.

An index read has its own semantic-result hierarchy. Its common `type` is the type produced if this particular read operation executes:

```dart
sealed interface class IndexReadResolution implements ReadResolution {}

sealed interface class ValidIndexReadResolution
    implements IndexReadResolution {}

final class MethodIndexReadResolution
    implements ValidIndexReadResolution {
  MethodElement get element;
  DartType get type;
}

final class DynamicIndexReadResolution
    implements ValidIndexReadResolution {
  DartType get type;
}

final class InvalidIndexReadResolution
    implements IndexReadResolution, InvalidReadResolution {
  DartType get type;
  MethodElement? get recoveryElement;
}
```

`MethodIndexReadResolution` records the selected substituted `operator []` method. Its `type` is the result produced if the invocation executes and is derived from `element.returnType`; the index context is likewise available from the method's sole formal parameter, so a separate `invokeType` repeats `element.type` without adding semantic information. A wrong index-argument type does not undo successful method selection: the node retains `MethodIndexReadResolution` and additionally has an argument diagnostic. `DynamicIndexReadResolution` represents runtime lookup and dispatch. `InvalidIndexReadResolution` represents completed but unsuccessful resolution and has canonical `InvalidType`. `resolution == null` means either that the AST has not been resolved or that receiver evaluation prevents the index operation, as for a receiver of type `Never` or the non-null path of exact-null `null?[index]`. An invalid read retains an optional substituted `recoveryElement`, including methods with malformed parameter lists. Its first parameter supplies the index context when present, otherwise the context is unknown. Navigation and argument checking use the recovery element without changing the invalid read's type or treating it as a selected operation.

On a `ReceiverIndexExpression`, a non-null `resolution.type` describes the indexed read on the executed path, while `staticType` describes the value produced by the expression as a whole. They are equal when null shortening does not change the expression result, but null shortening can make only `staticType` nullable. For `A? a`, if `A.operator []` has invoke type `String Function(int)`, standalone `a?[0]` has `MethodIndexReadResolution.type == String` and `ReceiverIndexExpression.staticType == String?`. The owned `question` token marks where null shortening starts; the enclosing expression structure determines where it finishes, so completion of a null-shorting region must not rewrite the already resolved operation type. For `null?[0]`, the non-null dispatch path is unreachable and the resolution is null. The receiver type and owned `question` token distinguish this valid exact-null case from a non-null-aware operation on a `Never` receiver; the complete expression's `staticType` records its result type in either case.

The word `read` is important because method, dynamic, and invalid index-read results also occur inside compound-assignment and increment-or-decrement targets whose write is non-null rather than belonging only to `IndexExpression`. A value expression or assignment target whose index protocol cannot execute has a null read resolution; the assignment target also has a null write resolution. The write side has the parallel operation-specific hierarchy:

```dart
sealed interface class IndexWriteResolution implements WriteResolution {}

sealed interface class ValidIndexWriteResolution
    implements IndexWriteResolution {}

final class MethodIndexWriteResolution
    implements ValidIndexWriteResolution {
  MethodElement get element;
  DartType get acceptedType;
}

final class DynamicIndexWriteResolution
    implements ValidIndexWriteResolution {
  DartType get acceptedType;
}

final class InvalidIndexWriteResolution
    implements IndexWriteResolution, InvalidWriteResolution {
  DartType get acceptedType;
  MethodElement? get recoveryElement;
}
```

`MethodIndexWriteResolution` records the selected substituted `operator []=` method and exposes the type accepted for the written value through the common `acceptedType` API. The accepted type and index context are derived from the method's formal parameters, so a separate `invokeType` would only repeat `element.type`. `DynamicIndexWriteResolution` represents runtime `[]=` dispatch and has `acceptedType == dynamic`, because no static parameter type constrains the written value. An invalid write has canonical `InvalidType` and an optional substituted `recoveryElement`. Recovery can retain a method with a malformed parameter list; its first parameter supplies the index context when present, otherwise the context is unknown. Navigation and argument checking can use this element without treating the write as successfully resolved.

On a resolved `ReceiverIndexAssignmentTarget`, `write == null` means that receiver evaluation cannot complete or that an exact-null null-aware target skips the whole index protocol; `read` is then also null. There is no `IndexReadResolution`, `IndexWriteResolution`, or fabricated `acceptedType`, because neither `[]` nor `[]=` can execute. The target has no `staticType`, and the enclosing assignment or increment-or-decrement expression owns its result type. Thus `IndexExpression` names the value-producing source form, while `IndexReadResolution` names an operation shared by that form and by a read-modify-write target whose write is non-null. Calling the resolution `IndexAccessResolution` would obscure whether it denotes `[]` or `[]=`.

In:

```dart
a[i] = value;
```

the receiver `a` and the index expression `i` are evaluated and have static types. The `ReceiverIndexAssignmentTarget` has no static type; its write resolution identifies `operator []=` and the accepted value type. In:

```dart
a[i] += value;
```

the read resolution identifies `operator []`, while the write resolution identifies `operator []=`.

For a null-aware compound target such as `a?[i] += value`, the target read describes the operation on the executed non-null path, so `read.type` is the result of `operator []` if it executes; null shortening contributes to the enclosing assignment expression's type instead. A value-producing `a?[i]` uses the same rule: its read resolution carries the executed-path result, while its `ReceiverIndexExpression.staticType` includes null shortening when that expression terminates the shorting region. The same resolution interface is reusable because `type` always describes the operation if it executes, independently of whether its owner is a value expression or an assignment target.

`E(a)[i]` uses an `ExtensionOverride` receiver, while `super[i]` uses a `SuperReference` receiver. In both cases `i` remains an ordinary expression. The complete `ReceiverIndexExpression` produces a value; the restricted receiver does not.

The question token in `a?[i]` belongs to the ordinary index access or assignment target. It is distinct from the `?..` token that begins a null-aware cascade.

Implementation status (2026-08-10): ordinary non-cascade value reads, including null-aware `receiver?[index]`, use the receiver-supplied form under the transitional public name `IndexExpression2`; the proposed `ReceiverIndexExpression` name and common V2 `IndexExpression2` category are not yet implemented. Their V1 projection remains `IndexExpression`. A method read derives its executed-path `type` from `element.returnType`; null shortening changes only the complete expression's `staticType`. Method read and write results expose only the selected substituted element plus their common derived `type` or `acceptedType`, without a redundant `invokeType`. An exact-null receiver has null resolution because no index operation executes. Ordinary non-cascade assignments and updates use the receiver-supplied target under the transitional name `IndexAssignmentTarget`; the proposed `ReceiverIndexAssignmentTarget` name and common `IndexAssignmentTarget` category are not yet implemented. The target records method, dynamic, invalid, or skipped read/write resolutions, owns the optional question token, and supplies index context and argument checking for `operator []` and `operator []=`. The outer expression owns null shortening, operator resolution or conditional flow, and result typing. Summary serialization and the V1 `IndexExpression` projection preserve the question token and both operations. Indexed cascade sections use the receiver-less `CascadeIndexExpression` and `CascadeIndexAssignmentTarget` forms described in section 7; they reuse the same index-resolution families while receiving the once-evaluated cascade target from private resolver context.

### 5.1 Type names and extension names before an index

`StaticQualifier` deliberately does not implement `InstanceReceiver`. Bracket syntax cannot perform static lookup, so a declaration name before `[` must either produce a value or be diagnosed as an invalid attempted expression.

For:

```dart
C[0]
```

the parser initially sees a neutral name head in an instance-operation receiver slot:

```dart
ReceiverIndexExpression
  receiver: ParsedExpressionChain
    head: ParsedNameHead(C)
  index: IntegerLiteral(0)
```

If `C` resolves to a class or another declaration that denotes a runtime type object, resolution lowers the parsed head to the value-producing interpretation rather than `StaticQualifier`:

```dart
ReceiverIndexExpression
  receiver: TypeLiteral
    reference: C
    staticType: Type
  index: IntegerLiteral(0)
  resolution: InvalidIndexReadResolution
    type: InvalidType
  staticType: InvalidType
```

The index expression is normally invalid because `Type` does not declare `operator []`, but it can be valid when an applicable extension on `Type` supplies that operator; that case instead has `MethodIndexReadResolution` containing the selected substituted extension method. The corresponding `prefix.C[0]` uses a type-literal receiver containing the import-prefixed type reference. If `C` resolves to a variable or getter, the receiver remains the appropriate value expression.

A named extension does not denote a runtime `Type` object. For:

```dart
extension on Type {
  int operator [](_) => 42;
}

extension E on int {}

void main() {
  print(E[0]);
}
```

the anonymous extension on `Type` is not applicable because the name `E` produces no receiver value. The resolved tree should retain the attempted value-position name and its navigation element:

```dart
ReceiverIndexExpression
  receiver: UnqualifiedNameExpression(E)
    resolution: InvalidNamedReadResolution
      type: InvalidType
      recoveryElement: ExtensionElement(E)
    staticType: InvalidType
  index: IntegerLiteral(0)
  resolution: InvalidIndexReadResolution
    type: InvalidType
  staticType: InvalidType
```

Resolution reports `extensionAsExpression`. The invalid name occurrence does not need a separate `InvalidExpression` wrapper: `UnqualifiedNameExpression` describes the source role attempted by this occurrence, and its `NamedReadResolution` can state that the referenced extension is not a value. The current analyzer instead assigns a pseudo-expression type of `dynamic`; the V2 design should retain the `ExtensionElement` for navigation while using `InvalidType` and suppressing secondary operator diagnostics as appropriate.

The same declaration name can therefore receive different final source roles according to its enclosing syntax:

| Declaration found for `E` | `E.foo` | `E[0]` |
| --- | --- | --- |
| Class or other reified type declaration | `StaticQualifier(E)` when `foo` is selected statically | `TypeLiteral(E)` followed by instance `[]` lookup on `Type` |
| Named extension | `StaticQualifier(E)` when selecting a static extension member | Invalid `UnqualifiedNameExpression(E)` |
| Variable or getter | Value expression receiver | Value expression receiver |

### 5.2 `TypeLiteral` and `NamedType`

The existing analyzer `TypeLiteral` is the canonical value-producing representation of type syntax:

```dart
abstract final class TypeLiteral implements Expression {
  /// The syntax denoting the type represented by this literal.
  NamedType get type;
}
```

Reusing `NamedType` is preferable to introducing another type-reference child. It already owns an optional `ImportPrefixReference`, the name token, written type arguments, the resolved declaration, the represented `DartType`, deferred-prefix information, source range, and navigation behavior:

```dart
prefix.C<int>
  TypeLiteral
    type: NamedType
      importPrefix: ImportPrefixReference(prefix.)
      name: C
      typeArguments: <int>
      element: C
      type: C<int>
    staticType: Type
```

The wrapper and child expose two different types. `TypeLiteral.staticType` is the type of the produced runtime value and is `Type` in a resolved valid or recoverable type literal. `TypeLiteral.type.type` is the type represented by that value, such as `C<int>`. The getter returns syntax rather than a `DartType`, so its documentation should say that it is the syntax denoting the represented type; the older wording “the type represented” and any reference to a nonexistent `typeName` getter are misleading. The mildly repetitive `type.type` is not by itself enough reason to replace the conventional AST child name.

`NamedType` admits more states than a valid type-literal expression, so `TypeLiteral` establishes parent-specific invariants. In valid code its `question` token is absent, its element denotes a declaration or special type that can be used as a type literal, and its resolved `type` is non-null. A named extension or an import prefix alone cannot become a type literal. Invalid written type arguments can remain in the `NamedType` and receive diagnostics while the source role remains `TypeLiteral`; unresolved or role-ambiguous syntax does not become a `TypeLiteral` merely for recovery. Tooling that needs to distinguish a type annotation from a type-literal reference can inspect the `NamedType` parent, while both uses retain the ordinary reference to the type declaration.

`TypeLiteral` needs no `NamedReadResolution` and there is no `TypeObjectResolution`. Its concrete node kind already states that the source evaluates type syntax to a runtime `Type` object, while `NamedType.element`, `NamedType.type`, and `ImportPrefixReference` provide declaration, represented-type, and prefix resolution. This structural exception also keeps type-object selection out of the named-read hierarchy.

The parser cannot generally construct `TypeLiteral` from the first name token because the surrounding chain can select another source role. Resolution lowers the complete ambiguous chain:

```dart
C                 TypeLiteral(type: NamedType(C))
C<int>            TypeLiteral(type: NamedType(C<int>))
prefix.C<int>     TypeLiteral(type: NamedType(prefix.C<int>))

C.staticProperty  ReceiverPropertyExtraction(receiver: StaticQualifier(C))
C<int>.named      ConstructorTearOff(typeReference: C<int>, selector: named)
C[0]              ReceiverIndexExpression(receiver: TypeLiteral(type: NamedType(C)))
(C).hashCode      ReceiverPropertyExtraction(receiver: TypeLiteral(type: NamedType(C)))
```

In particular, a following plain member selector can commit the name to static qualification or constructor syntax before any type-literal node exists. Bracket and binary operator syntax instead require a runtime receiver and therefore can lower the type name to `TypeLiteral`. Lowering must transfer or reconstruct the `NamedType` atomically while preserving tokens, comments, reference identities, parents, and V1 projections; a `NamedType` instance is never shared between a `TypeLiteral`, `ConstructorTypeReference`, or another parent.

## 6. Reference Sites Are Broader Than Names

Canonical V2 removes the current `Identifier`, `SimpleIdentifier`, and `PrefixedIdentifier` hierarchy. `Identifier` incorrectly treats every identifier occurrence as an expression, while its concrete nodes are reused for declaration names, selectors, type names, prefixes, labels, assignment targets, documentation references, and other occurrences that do not produce values. `PrefixedIdentifier` additionally collapses several source roles whose lookup and evaluation differ.

The source-role owner directly owns each written name token. `NameExpression` groups value-producing named accesses, including property extractions, while a general `ReferenceName`, `NameOccurrence`, or other interface spanning unrelated name roles still requires a concrete client requirement:

```dart
UnqualifiedNameExpression.name
UnqualifiedNameAssignmentTarget.name
ReceiverPropertyExtraction.name
ReceiverPropertyAssignmentTarget.propertyName
NamedArgument.name
NamedType.name
ConstructorSelector.name
CommentReferenceName.name
```

`NameExpression` is a sealed common superclass for `UnqualifiedNameExpression` (`x`), `ImportPrefixedNameExpression` (`prefix.x`), `DotShorthandNameExpression` (`.x`), and `PropertyExtraction`, whose concrete forms are `ReceiverPropertyExtraction` (`receiver.x`) and `CascadePropertyExtraction` (`..x`). Its contract is a value-producing named access: `Token name` and `NamedReadResolution? resolution`, plus the inherited `Expression` APIs. An import prefix supplies a namespace, dot shorthand obtains one from context, and an unqualified name uses lexical lookup, potentially selecting an implicit instance member. Property extractions obtain their receiver from a written child or the active cascade target. Each concrete node retains its qualification syntax, lookup rules, and evaluation protocol. `DotShorthandNameExpression` also implements `DotShorthandExpression`.

The inherited `name` replaces `PropertyExtraction.propertyName` in the canonical API and its receiver and cascade forms. Property assignment targets retain `propertyName`; they are outside this value-producing hierarchy. The common `resolution` is null before resolution or when receiver evaluation prevents the access. An access that executes but is invalid instead has `InvalidNamedReadResolution`. A null resolution therefore does not imply that the enclosing expression itself is unresolved.

There are concrete clients for this common type. `BestPracticesVerifier` and `ConstArgumentsVerifier` currently distinguish unqualified and import-prefixed name expressions only to obtain the same resolution, while Wolf's `_nameExpression` accepts their name and resolution separately. Clients inspecting the selected named operation can use the common contract across property extractions as well. Shared information does not imply a shared evaluation procedure: Wolf must still establish the written receiver, active cascade target, or implicit instance before emitting the operation. Its existing `_nameExpression` implementation cannot accept every subtype unchanged. Deferred-import restrictions and shorthand context likewise remain specific to the concrete source role.

Assignment targets remain separate because they expose read and write operations without producing a value. Type literals, declarations, selectors, and documentation names do not enter the hierarchy merely because they contain names; they do not expose this named-read contract. No common `element` getter is added; the typed resolution describes the selected operation. This superclass adds no wrapper or generic identifier leaf, and token ownership stays on the existing concrete nodes.

A resolved value-producing bare name is an `UnqualifiedNameExpression`; a write occurrence is an `UnqualifiedNameAssignmentTarget`. Qualified syntax lowers to the precise property, import-prefixed, static-qualifier, constructor, type, invocation, or documentation-reference structure selected for that occurrence. `ParsedNameHead` owns its token directly until resolver lowering chooses one of those final source roles. Resolution data belongs to the owning node or its operation-specific resolution rather than to a generic identifier leaf.

V1 compatibility can synthesize and cache `SimpleIdentifier` and `PrefixedIdentifier` projections where the old tree requires them. Canonical V2 visitors, replacement, serialization, parent links, and covering-node behavior operate on the source-role owner and its token. If token-only covering later proves insufficient, that concrete API requirement can justify a new leaf or adapter then; speculative uniformity is not enough.

Index access demonstrates that indexing cannot be organized only around names. An index read refers to `operator []`, an index write refers to `operator []=`, and a compound index target refers to both at one source site, even though there is no identifier token. A more general tooling abstraction is:

```dart
abstract interface class ReferenceSite {
  SourceRange get referenceRange;
  Iterable<ResolvedReference> get references;
}

final class ResolvedReference {
  ReferenceRole get role;
  Element? get target;
  Element? get navigationTarget;
}
```

The source range can be the name token for a name or property, and the bracket range or left bracket for an index operator. A compound target can expose two references at the same site. Invalid resolution can retain recovery targets or candidate targets for navigation.

Whether `ReferenceSite` is a public AST interface, an internal indexing adapter, or a separate resolved API remains open. The important design constraint is that indexers and navigation code should not need a large switch over every expression and assignment-target class merely to extract reference occurrences.

### 6.1 Documentation comment references

The current `CommentReferableExpression` hierarchy does not describe value-producing expressions despite its name and superclass. `ResolverVisitor.visitCommentReference` deliberately does not visit the contained node as an expression. A specialized comment-reference resolver suppresses ordinary diagnostics, performs documentation-specific lookup, and assigns elements to selected identifiers without type analysis, flow analysis, ordinary property resolution, or a `staticType`. Constructor and property rewrites are also disabled under `CommentReference`, so the expression-shaped nodes primarily reuse parser and element-bearing infrastructure.

A canonical V2 documentation reference should therefore be a separate non-expression source model. It produces no value, has no type, and needs only the written reference structure and resolved elements that higher-level tooling can use when choosing navigation behavior. `CommentReference` does not need to wrap a second `CommentReferenceTarget`; the outer node can directly own the complete reference syntax:

```dart
abstract final class CommentReference implements AstNode {
  Token? get newKeyword;
  NodeList<CommentReferenceComponent> get components;

  /// The element selected by the complete reference, if resolution found one.
  Element? get element;
}

sealed interface class CommentReferenceComponent implements AstNode {
  /// The period immediately preceding this component, absent on the first.
  Token? get period;

  /// The element denoted by this component, if resolution found one.
  Element? get element;
}

abstract final class CommentReferenceName
    implements CommentReferenceComponent {
  Token get name;
}

abstract final class CommentReferenceOperator
    implements CommentReferenceComponent {
  Token? get operatorKeyword;
  Token get operator;
}
```

The exact component names and whether names and operators need separate public classes remain provisional, but the absence of an expression or target wrapper is the substantive decision. A component is not an empty positional wrapper: it owns a name or operator token, an optional preceding period, an independently useful source range, and the element found for that component. The complete reference's `element` can delegate to the final component.

```dart
[foo]
  CommentReference
    components:
      CommentReferenceName(foo)
        element: foo
    element: foo

[prefix.C.named]
  CommentReference
    components:
      CommentReferenceName(prefix)
        element: PrefixElement
      CommentReferenceName(.C)
        element: InterfaceElement(C)
      CommentReferenceName(.named)
        element: ConstructorElement(C.named)
    element: ConstructorElement(C.named)

[C.operator +]
  CommentReference
    components:
      CommentReferenceName(C)
        element: InterfaceElement(C)
      CommentReferenceOperator(.operator +)
        element: MethodElement(operator +)
    element: MethodElement(operator +)
```

The current analyzer parser accepts only one identifier or user-definable operator, two identifiers separated by a period, or three identifiers separated by periods, with an optional leading `new` and an optional final `operator` spelling. It constructs only `SimpleIdentifier`, `PrefixedIdentifier`, or `PropertyAccess` shapes for these references. It requires the token after the final name or operator to be EOF, so a documentation fragment such as `My [List<int>] values` does not produce a `CommentReference`; the `<` after `List` causes comment-reference parsing to fail and the bracketed text remains ordinary documentation text. The current specialized resolver likewise directly handles only simple identifiers, prefixed identifiers, and property accesses. The broader documented `CommentReferableExpression` alternatives such as `FunctionReference`, `ConstructorTearOff`, and `TypeLiteral` therefore overstate what parser-produced comment references use.

The new model need not admit type arguments merely for compatibility with the current analyzer. If documentation-reference syntax is expanded later, a type-argument component or typed name component can be added without turning the reference into an expression or introducing a `DartType` for the complete reference. Nullable component elements are sufficient for the current navigation-oriented contract: unresolved AST and unsuccessful documentation lookup both provide no element, and neither state participates in value evaluation.

## 7. Cascades

Cascades require an explicit section boundary because `..` and `?..` are not ordinary property operators. They select the original cascade target and begin a new section. By contrast, `.` and `?.` continue an ordinary access chain from the immediately preceding value.

The canonical outer structure is:

```dart
final class CascadeExpression implements Expression {
  InstanceReceiver get target;
  NodeList<CascadeSection> get sections;
}

final class CascadeSection implements AstNode {
  Token get operator;
  Expression get body;
}
```

The target slot uses `InstanceReceiver` to preserve parse-to-resolution rewriting in invalid code while excluding static qualifiers and import prefixes structurally. The stronger semantic invariant is that, in a valid resolved cascade, `target is Expression`, because a cascade produces the original target value. If resolution selects an `ExtensionOverride` or another non-expression instance receiver, the cascade is invalid and its static type is `InvalidType`; broadening the structural slot does not make that source semantically valid.

### 7.1 Parse-to-resolution recovery for an extension override

For:

```dart
E(3)..member
```

the parser cannot know that `E` is an extension. It initially produces a tree shaped like:

```dart
CascadeExpression
  target: ParsedExpressionChain
    head: ParsedNameHead(E)
    components:
      ParsedArguments((3))
  sections:
    CascadeSection
      operator: ..
      body: CascadePropertyExtraction(member)
```

The parser-only `ParsedExpressionChain` is an `Expression` and therefore also an `InstanceReceiver`. During lowering, lookup can discover that `E` is an extension and replace the chain directly:

```dart
CascadeExpression
  target: ExtensionOverride
    name: E
    argumentList: (3)
    element: ExtensionElement(E)
    extendedType: int
  sections:
    CascadeSection
      operator: ..
      body: CascadePropertyExtraction(member)
  staticType: InvalidType
```

Resolution reports `extensionOverrideWithCascade` because the selected target has no value for the cascade expression to return. It can nevertheless resolve `member` using the extension override for recovery, preserving useful navigation and diagnostics. The current analyzer performs essentially this rewrite because its `ExtensionOverride` still implements `Expression`, assigns it a pseudo-expression type of `dynamic`, and recovers by treating the section like ordinary extension-override access. In the proposed V2 model, `ExtensionOverride` has no `staticType`; the enclosing invalid `CascadeExpression` owns `InvalidType`.

Typing the target as `Expression` would prevent this direct replacement. Retaining the parsed chain in the resolved tree would lose the resolved extension-override API, while wrapping the override in `InvalidExtensionOverrideExpression` would introduce an unnecessary recovery layer in a slot that already accepts the receiver and would make extension-member recovery less direct. An `InstanceReceiver` target plus the valid-code invariant `target is Expression` preserves both the honest receiver hierarchy and convenient invalid-code resolution.

The section operator is `..` or `?..`. The section body is evaluated for its effects, but its value is discarded; the `CascadeExpression` produces the original target value according to cascade and null-aware cascade semantics. Making `CascadeSection` an explicit non-expression node provides a natural boundary for flow analysis and null shorting.

One `Expression body` covers every section form without section subclasses. A read uses a cascade-start read expression, a direct method call uses `CascadeMethodInvocation`, a simple or compound write uses the corresponding assignment expression around a cascade-start assignment target, and increment or decrement uses one of the four concrete increment-or-decrement expressions around that target. The body expression preserves the section-local result for ordinary selectors that continue within the same section, while `CascadeSection` states that the final body value is discarded by the enclosing cascade. Distinct read, invocation, assignment, increment, and decrement section nodes would duplicate structure already expressed by their body nodes.

The first access in a section receives its target from the enclosing cascade rather than from an expression child. It therefore uses explicit cascade-start nodes:

```dart
final class CascadePropertyExtraction implements PropertyExtraction {}

final class CascadePropertyAssignmentTarget
    implements PropertyAssignmentTarget {}

final class CascadeIndexExpression implements IndexExpression {}

final class CascadeIndexAssignmentTarget
    implements IndexAssignmentTarget {}

// CascadeMethodInvocation is declared with the invocation hierarchy in 9.1.
```

Cascade-start nodes reuse the common property/index categories and ordinary operation-resolution families exactly. `CascadePropertyExtraction` and `ReceiverPropertyExtraction` implement `PropertyExtraction`; their assignment counterparts implement `PropertyAssignmentTarget`. `CascadeIndexExpression` and `ReceiverIndexExpression` implement `IndexExpression`; their assignment counterparts implement `IndexAssignmentTarget`. Cascade syntax changes how the once-evaluated receiver is supplied and where the body result is discarded; it does not create a different getter, setter, index, or invocation protocol. There are consequently no `CascadeNamedReadResolution`, `CascadeIndexReadResolution`, or `CascadeInvocationResolution` families.

Implementation status (2026-08-09): `CascadeExpression.sections` now contains explicit `CascadeSection` nodes that own `..` or `?..` for canonical index and property section starts. A section-start index read is a receiver-less `CascadeIndexExpression`, while direct, if-null, and compound assignments use `CascadeIndexAssignmentTarget`; both reuse the ordinary typed index-resolution families. A section-start property read is a receiver-less `CascadePropertyExtraction`, while the three assignment protocols use `CascadePropertyAssignmentTarget`; both reuse the ordinary typed named-resolution families. This includes `..call` on a function-valued cascade target: an exact function type uses `FunctionCallTearOffResolution`, while core `Function` uses `FunctionInterfaceCallTearOffResolution`; neither invents an executable declaration element. The resolver supplies the active cascade target privately, and V1 projects these nodes as the established target-less cascaded `IndexExpression` and `PropertyAccess` shapes. Postfix increment and decrement are not valid cascade sections. Invocation section starts remain transitional legacy bodies and will complete the remaining shared section/operator ownership in their corresponding migration slice.

The resolution and `staticType` of a cascade-start value node describe its section-local operation on the executed path. For `target?..x.y`, `CascadePropertyExtraction(x).resolution.type` equals that node's section-local `staticType`, and the ordinary `.y` access consumes that type; the section's `?..` determines whether the body executes and the `CascadeExpression` still produces the original target value. Similarly, `target..x += value` uses `CompoundAssignment` around `CascadePropertyAssignmentTarget`: the target's `read` and `write` supply the ordinary named operation results, and the outer compound assignment supplies the intervening operator `element` and `operatorResultType`. If the once-evaluated cascade target cannot produce a value, the cascade-start assignment target has null `read` and `write`. Null-aware cascade control and discarded section results do not belong in cascade-specific operation-result variants.

The `..` or `?..` token belongs to `CascadeSection`, not to these property, index, or method-invocation nodes. The resolver supplies the active once-evaluated cascade target to cascade-start nodes through private resolution context, so these nodes need neither a receiver child nor a public `cascadeTarget` convenience getter. A client that genuinely needs the written source target can inspect the enclosing `CascadeExpression`; semantic clients normally use the cascade-start node's named-read, index-read, target, or invocation resolution directly. This is preferable to using a nullable local target or making semantic resolution depend on ancestor search through `realTarget`.

In particular, `CascadeIndexExpression` is intentionally distinct from `ReceiverIndexExpression`. `ReceiverIndexExpression` owns an explicitly written receiver whose evaluation and source range are part of that index occurrence. A cascade-start index occurrence owns only `[index]`; its receiver was already evaluated by `CascadeExpression`, and its section operator is owned by `CascadeSection`. Reusing `ReceiverIndexExpression` would either duplicate the cascade target as a child and falsely model repeated evaluation, or make its required receiver contract conditional and ancestor-dependent. The distinction is structural rather than semantic: both nodes reuse `IndexReadResolution`, and their assignment-target counterparts likewise reuse `IndexReadResolution` and `IndexWriteResolution`.

### 7.2 Multiple sections versus one access chain

For:

```dart
target..x = 0..y = 1
```

the proposed tree is:

```dart
CascadeExpression
  target: UnqualifiedNameExpression(target)
  sections:
    CascadeSection
      operator: ..
      body: DirectAssignment
        target: CascadePropertyAssignmentTarget(x)
        operator: =
        value: IntegerLiteral(0)
    CascadeSection
      operator: ..
      body: DirectAssignment
        target: CascadePropertyAssignmentTarget(y)
        operator: =
        value: IntegerLiteral(1)
```

Both setters use the same evaluated cascade target.

For:

```dart
target..x..y
```

there are two independent getter reads:

```dart
CascadeExpression
  target: UnqualifiedNameExpression(target)
  sections:
    CascadeSection
      operator: ..
      body: CascadePropertyExtraction(x)
    CascadeSection
      operator: ..
      body: CascadePropertyExtraction(y)
```

For:

```dart
target..x.y
```

there is one section, and `y` is selected on the value of `target.x`:

```dart
CascadeSection
  operator: ..
  body: ReceiverPropertyExtraction
    receiver: CascadePropertyExtraction(x)
    operator: .
    name: y
```

Indexing follows the same distinction:

```dart
target..[i]..[j]
```

has two sections that both index the original target, while:

```dart
target..[i][j]
```

has one section in which the second indexing operation applies to the value of `target[i]`.

An assignment such as:

```dart
target..[i] += value
```

uses a `CompoundAssignment` whose target is `CascadeIndexAssignmentTarget`; the target directly exposes a read of `[]` and a write through `[]=`, while the outer assignment contains `BinaryOperator.add` and the resolution of the intervening `+` invocation.

### 7.3 Null-aware cascade boundaries

The design must distinguish:

```dart
a?[i]
a?..[i]
a..x?[i]
```

In `a?[i]`, the question token belongs to an ordinary index expression or assignment target. In `a?..[i]`, the `?..` belongs to the cascade section and can skip the entire cascade when `a` is null. In `a..x?[i]`, the `..` begins the section while `?[` null-shorts only the nested access chain within that section.

Similarly:

```dart
target?..x?.y..z
```

has two levels of null shorting. If `target` is null, the entire cascade is skipped. If `target` is non-null but `target.x` is null, only the remainder of the first section is skipped; the `..z` section still runs against the original target. The explicit `CascadeSection` node gives flow analysis the boundary at which section-local null shorting ends.

## 8. Import Prefixes and the `foo.bar` Ambiguity

The token sequence:

```dart
foo.bar
```

cannot always be classified by the parser. The left name can denote a value receiver, an import prefix, a type or type alias used for static lookup, an extension-related qualifier, or an unresolved name. The same source can also participate in constructor-reference and type-literal interpretations.

Using a fully generic node with two `AstNode` children would preserve syntax but would lose the convenient resolved API of `ReceiverPropertyExtraction`. Treating `foo` as an `Expression` in every case is also incorrect because an import prefix and a type qualifier are not evaluated values.

This appears to justify a neutral parser representation for the ambiguous portion followed by controlled lowering to canonical resolved nodes.

### 8.1 Import-prefixed access and named receiver access

`ImportPrefixReference` currently represents the complete grouped qualifier `prefix.`, not merely the prefix-name token:

```dart
abstract final class ImportPrefixReference implements AstNode {
  Element? get element;
  Token get name;
  Token get period;
}
```

This ownership works well when the node is embedded in `NamedType`, `ConstructorTypeReference`, `ExtensionOverride`, or `StaticQualifier`: the prefix reference owns `prefix.`, while its parent owns the following declaration name. Making it the receiver of `ReceiverPropertyExtraction` would give the same period two API roles, as both `ImportPrefixReference.period` and `ReceiverPropertyExtraction.operator`, and would make child traversal and replacement conditional on the receiver kind.

The cleaner boundary is to keep dedicated import-prefixed value and target nodes:

```dart
final class ImportPrefixedNameExpression implements NameExpression {
  ImportPrefixReference get importPrefix;
}

final class ImportPrefixedAssignmentTarget
    implements AssignmentTarget {
  ImportPrefixReference get importPrefix;
  Token get name;
  NamedReadResolution? get read;
  NamedWriteResolution? get write;
}
```

For:

```dart
prefix.foo
ImportPrefixedNameExpression
  importPrefix: ImportPrefixReference
    name: prefix
    period: .
  name: foo
```

there is one structural owner for each token and no delegated operator special case. For `prefix.foo += value`, the prefix reference identifies the `PrefixElement`, while the target's `read` and `write` independently record the imported getter and setter operations for `foo`. An imported top-level function used as `prefix.f` produces a tear-off. An imported type used as `prefix.C` in a value context produces `TypeLiteral`; its `NamedType` child owns the `ImportPrefixReference`, name, and any written type arguments.

Value, explicit-extension, superclass, and static named access continue to share the ordinary property nodes:

```dart
final class ReceiverPropertyExtraction implements PropertyExtraction {
  NamedReceiver get receiver;
  Token get operator;
}

final class ReceiverPropertyAssignmentTarget
    implements PropertyAssignmentTarget {
  NamedReceiver get receiver;
  Token get operator;
  Token get propertyName;
  NamedReadResolution? get read;
  NamedWriteResolution? get write;
}
```

Representative resolved trees are:

```dart
object.x
  receiver: UnqualifiedNameExpression(object)

E(object).x
  receiver: ExtensionOverride(E(object))

super.x
  receiver: SuperReference(super)

C.x
  receiver: StaticQualifier(C)
```

The shared outer property access or assignment target remains convenient for indexing, navigation, visitors, and fixes in these receiver-based cases. Static versus instance getter/setter/invocation meaning belongs in `NamedReadResolution` or `NamedWriteResolution`, while the sealed receiver variant records how the left side participates in lookup and evaluation. Import-prefixed nodes can share higher-level tooling interfaces such as `ReferenceSite` or a possible named-value-access interface without pretending that `prefix.` is a receiver.

### 8.2 Invalid null-aware access on an import prefix

The spelling:

```dart
prefix?.foo
```

cannot be import namespace qualification because `ImportPrefixReference` requires a prefix name immediately followed by plain `.`. The parser does not yet know what `prefix` denotes and therefore produces an ordinary null-aware property access:

```dart
ReceiverPropertyExtraction
  receiver: UnqualifiedNameExpression(prefix)
  operator: ?.
  name: foo
```

If `prefix` resolves to a nullable value, this shape is valid and remains unchanged. If it resolves to a `PrefixElement`, resolution must not construct either `ImportPrefixReference` or `ImportPrefixedNameExpression`: there is no plain period token for the prefix reference to own. The source remains an attempted value-receiver access:

```dart
ReceiverPropertyExtraction
  receiver: UnqualifiedNameExpression(prefix)
    resolution: InvalidNamedReadResolution
      type: InvalidType
      recoveryElement: PrefixElement(prefix)
    staticType: InvalidType
  operator: ?.
  name: foo
  resolution: InvalidNamedReadResolution
    type: InvalidType
    recoveryElement: GetterElement(imported foo)
  staticType: InvalidType
```

Resolution reports `prefixIdentifierNotFollowedByDot`. It should still look up `foo` in the import-prefix namespace as recovery so that navigation, rename, completion, and follow-on analysis retain the intended imported declaration. The imported getter, setter, or function and its type are recovery information; they do not make the source a valid null-aware access on a runtime prefix value. The current analyzer already performs this useful namespace lookup and, for an invocation such as `prefix?.foo()`, can assign the recovered function's normal result type to the invocation. The stricter V2 model should instead give the invalid expression canonical `InvalidType` while exposing the recovered element and type separately.

The two spellings therefore have intentionally different final shapes:

```dart
prefix.foo
  -> ImportPrefixedNameExpression
     importPrefix owns prefix.

prefix?.foo
  -> ReceiverPropertyExtraction
     receiver is an invalid attempted UnqualifiedNameExpression
     operator owns ?.
```

The assignment form follows the same rule. `prefix?.foo = value` remains a `ReceiverPropertyAssignmentTarget` with an invalid value receiver and an imported setter as recovery resolution; it does not become `ImportPrefixedAssignmentTarget`.

### 8.3 Static qualification and constructor syntax

`StaticQualifier` remains useful as a non-expression receiver variant:

```dart
final class StaticQualifier implements NamedReceiver {
  Element? get element;
  ImportPrefixReference? get importPrefix;
  Token get name;
}
```

It is deliberately named for its source role rather than for the declaration kind found by resolution. It can resolve to a class, enum, mixin, extension type, type alias where permitted, named extension, or a recovery element. It does not need separate type and extension subclasses. A top-level function is not a static qualifier: in `f.x`, `f` is evaluated to a function value, so the receiver remains an `UnqualifiedNameExpression`.

The qualifier contains no `typeArguments` and implements `NamedReceiver`, not `InstanceReceiver`. In valid static access the forms are `C.x`, `prefix.C.x`, `E.x`, and `prefix.E.x`, where `E` can be a named extension. `C` and `prefix.C` in these forms are not expressions and have no static type, but the enclosing `ReceiverPropertyExtraction` produces a value. `C.x = value` and compound variants use `ReceiverPropertyAssignmentTarget` with a `StaticQualifier` receiver and separate read/write resolution.

`ConstructorTypeReference` remains a distinct and useful node. Its source role permits type arguments and identifies the type defining a constructor; `StaticQualifier` identifies the declaration before ordinary named selection. Their shared fields do not by themselves justify a wider concrete node such as `NamedDeclarationReference`, because that name would also appear to include top-level functions and other named declarations that are evaluated as values in dotted access.

The presence of type arguments commits a dotted form to constructor syntax:

```dart
C<int>.x
prefix.C<int>.x
```

These are constructor tear-off forms, not static-member accesses. The final tree is shaped like:

```dart
ConstructorTearOff
  typeReference: ConstructorTypeReference
    importPrefix: ImportPrefixReference(prefix.)?
    name: C
    typeArguments: <int>
  selector: ConstructorSelector
    period: .
    name: x
```

If `x` is not a named constructor, constructor resolution is invalid even if a static getter, field, or method named `x` exists; resolution does not fall back to `ReceiverPropertyExtraction` with a `StaticQualifier` receiver. Similarly, `C<int>.x()` is a constructor invocation for the named constructor `x`, potentially invalid, rather than a static method invocation. Parse-time ambiguity or recovery nodes preserve the tokens until this interpretation is selected, so invalid `C<int>.x` does not require adding `typeArguments` to `StaticQualifier`.

### 8.4 Parsed expression and assignment-target chains

The parser should not guess a final semantic source role for the portions of a postfix chain whose structure depends on name resolution. Instead, it can preserve the ambiguous portion in a small neutral parser representation:

```dart
final class ParsedExpressionChain implements Expression {
  ParsedExpressionChainHead get head;
  NodeList<ParsedExpressionChainComponent> get components;
}

final class ParsedAssignmentTargetChain
    implements AssignmentTarget {
  ParsedExpressionChainHead get head;
  NodeList<ParsedExpressionChainComponent> get components;
}

final class ParsedDotShorthandExpression
    implements Expression {
  Expression get expression;
}

sealed class ParsedExpressionChainHead implements AstNode {}

final class ParsedNameHead
    implements ParsedExpressionChainHead {
  Token get name;
}

final class ParsedValueHead
    implements ParsedExpressionChainHead {
  Expression get expression;
}

final class ParsedSuperHead
    implements ParsedExpressionChainHead {
  SuperReference get superReference;
}

final class ParsedDotShorthandHead
    implements ParsedExpressionChainHead {
  Token? get constKeyword;
  Token get period;
  Token get name;
}

sealed class ParsedExpressionChainComponent implements AstNode {}

final class ParsedNameAccess
    implements ParsedExpressionChainComponent {
  Token get operator;
  Token get name;
}

final class ParsedTypeArguments
    implements ParsedExpressionChainComponent {
  TypeArgumentList get typeArguments;
}

final class ParsedArguments
    implements ParsedExpressionChainComponent {
  ArgumentList get argumentList;
}
```

`Parsed` describes the node's phase provenance rather than semantic failure. Both valid and invalid parsed units can contain these chains and the dot-shorthand wrapper, but both valid and invalid resolved units must eliminate them in favor of canonical expression, assignment-target, receiver, constructor, extension-override, or invalid-recovery nodes. The name `ParsedExpressionChain` is preferable to `UnresolvedExpressionChain` because "unresolved" can also mean that resolution was attempted but failed, and preferable to `ParsedExpression` because only a bounded chain-shaped portion of expression syntax uses this representation.

Having `ParsedExpressionChain` implement `Expression` is a deliberate parser-phase accommodation so that it can occupy expression statements, arguments, operands, and other parser-known expression slots. It has no meaningful `staticType` and does not weaken the resolved invariant that every canonical `Expression` produces a value, either directly from its source occurrence or through a narrowly defined semantic adaptation. If lowering selects a complete `ExtensionOverride` or bare `SuperReference` in an expression-only slot, it replaces the chain with `InvalidExtensionOverrideExpression` or `InvalidSuperExpression`; an invalid bare non-value name instead becomes its ordinary source-shaped name expression with `InvalidNamedReadResolution`. If the parent slot accepts `NamedReceiver` or `InstanceReceiver`, it can install the selected non-expression receiver directly.

`ParsedDotShorthandExpression` is a different kind of parser-only accommodation. Its one structural child is the ordinarily parsed expression formed from the shorthand head and the complete following selector chain. Somewhere on that child's leading receiver path is exactly one `ParsedExpressionChain` whose head is `ParsedDotShorthandHead`; no second public child or convenience AST edge points directly to that head. The wrapper records the exact `<staticMemberShorthand>` grammar boundary so that contextual inference, including the immediate-right-operand rule for `==` and `!=`, can recognize the whole construct, while the inner head records the one operation that uses the context-supplied static namespace. The wrapper has no meaningful `staticType` and is removed after its child has been lowered and installed in the wrapper's former parent slot.

The head owns the optional `const` keyword together with the leading period and name, while a following type-argument or argument list remains an ordinary parsed-chain component when its grouping is resolution-dependent. This intentionally normalizes the grammar production `const .name(arguments)`, which grammatically includes the arguments in the shorthand head, into `ParsedDotShorthandHead(const, ., name)` followed immediately by `ParsedArguments(arguments)`. The parser enforces that valid `const` shorthand has that immediate argument component and constructor interpretation, while the same topology can retain malformed `const .name` for deterministic recovery without adding a second const-specific head class.

For:

```dart
foo.bar<T>(arguments)
```

the parser can produce:

```dart
ParsedExpressionChain
  head: ParsedNameHead(foo)
  components:
    ParsedNameAccess
      operator: .
      name: bar
    ParsedTypeArguments(<T>)
    ParsedArguments(arguments)
```

The components are grammatical and ordered, not an arbitrary token list. “Component” is preferable to “section” here because section already denotes a cascade section, and `ParsedExpressionChainComponent` remains the right name because every component belongs to one of the small ambiguous expression or assignment-target chain islands. The component hierarchy is not expanded merely to describe every postfix selector: index access, null assertion, parentheses, an outer call on an already grouped result, and other structurally known operations continue to use their ordinary AST nodes. A head that is already unambiguously value-producing is wrapped by `ParsedValueHead`, while a bare name is represented by `ParsedNameHead` because even the source role of that first token can depend on the following operation. `ParsedSuperHead` contains the already known non-expression `SuperReference` when a following invocation-shaped named selection remains ambiguous. In `foo.bar`, lookup can make `foo` an ordinary value expression, a `StaticQualifier` for a type-like declaration or named extension, or an `ImportPrefixReference`; lookup of `bar` can additionally select a constructor-specific interpretation. Calling `foo` an `UnqualifiedNameExpression` before making those choices would temporarily assert a value-producing role that need not survive lowering. `ParsedNameHead` is not a general replacement for name expressions and is not resolution data: it is a narrowly parser-only owner for a name occurrence whose source role is still ambiguous.

For example, parentheses commit their contents to a value-producing expression. The `foo` inside `(foo)` is still a `ParsedExpressionChain` until resolution determines whether it is an ordinary name read, a type literal, or an invalid value use, but the surrounding `ParenthesizedExpression` is structurally stable. A plain `(foo).bar` can therefore be parsed directly as `ReceiverPropertyExtraction(ParenthesizedExpression(ParsedExpressionChain(foo)), .bar)`. The invocation-shaped `(foo).bar()` instead needs a new ambiguous island with `ParsedValueHead(ParenthesizedExpression(ParsedExpressionChain(foo)))`, `ParsedNameAccess(.bar)`, and `ParsedArguments(())`, because resolution must still choose direct method invocation or property read followed by `CallInvocation`. `ParsedValueHead` does not make its expression provisional; it only lets an otherwise stable value become the receiver at the beginning of a newly ambiguous invocation-shaped chain.

`super` is already a precise non-value receiver, so most following operations are structurally stable during parsing: `super.foo` is `ReceiverPropertyExtraction` with `SuperReference`, `super[index]` is `ReceiverIndexExpression`, and `super()` is `CallInvocation`. The invocation-shaped named selection remains resolution-dependent:

```dart
super.foo()
  ParsedExpressionChain
    head: ParsedSuperHead
      superReference: SuperReference(super)
    components:
      ParsedNameAccess(.foo)
      ParsedArguments(())
```

```dart
foo is a superclass method
  -> ReceiverMethodInvocation
     receiver: SuperReference(super)
     name: foo
     argumentList: ()

foo is a superclass getter whose result is invoked
  -> CallInvocation
     receiver:
       ReceiverPropertyExtraction
         receiver: SuperReference(super)
         name: foo
     argumentList: ()
```

If bare `super` reaches an expression-only boundary instead of a supported receiver operation, the parser or lowering materializes `InvalidSuperExpression`; no parsed chain survives merely to preserve that invalid placement. The same `ParsedSuperHead` is available to `ParsedAssignmentTargetChain` when invocation-shaped recovery precedes an assignment or increment/decrement operation, although valid direct `super.foo = value` is already a structurally stable `ReceiverPropertyAssignmentTarget`.

Stable constructs remain ordinary AST nodes outside the smallest ambiguous island. For example:

```dart
foo[0]
  ReceiverIndexExpression
    receiver: ParsedExpressionChain
      head: ParsedNameHead(foo)
    index: 0

foo.bar[0]
  ReceiverIndexExpression
    receiver: ParsedExpressionChain
      head: ParsedNameHead(foo)
      components:
        ParsedNameAccess(.bar)
    index: 0

foo.bar!
  NullAssertion
    operand: ParsedExpressionChain
      head: ParsedNameHead(foo)
      components:
        ParsedNameAccess(.bar)

foo.bar + value
  BinaryOperatorInvocation
    leftOperand: ParsedExpressionChain(foo, .bar)
    operator: +
    rightOperand: ParsedExpressionChain(value)
```

The outer index, null assertion, and binary operation are structurally known during parsing. Resolution only replaces each parsed operand with a canonical interpretation accepted by that slot. In particular, the receiver of `foo[0]` cannot be prematurely constructed as `UnqualifiedNameExpression(foo)`: a variable makes it that expression, a class makes it `TypeLiteral(foo)`, while a named extension or import prefix produces canonical invalid value recovery. An actual extension override such as `E(value)[0]` instead has a parsed chain containing `ParsedArguments((value))`, which can lower to `ExtensionOverride(E(value))` in the index receiver slot. Parentheses, cascade boundaries, and other structurally determined operations likewise remain ordinary AST nodes around any ambiguous chain.

An argument list immediately following an ambiguous name chain remains a component because it participates in semantic grouping:

```dart
foo.bar()
  ParsedExpressionChain
    head: ParsedNameHead(foo)
    components:
      ParsedNameAccess(.bar)
      ParsedArguments(())

foo.bar()()
  CallInvocation
    receiver: ParsedExpressionChain
      head: ParsedNameHead(foo)
      components:
        ParsedNameAccess(.bar)
        ParsedArguments(())
    argumentList: ()
```

The first form can become `ReceiverMethodInvocation`, `CallInvocation(ReceiverPropertyExtraction(...))`, `ImportPrefixedFunctionInvocation`, `ConstructorInvocation`, or another role selected by resolution. In the second form, the first invocation remains ambiguous, but the second argument list necessarily invokes the result of the first operation or performs supported `call` dispatch on a selected `ExtensionOverride` or `SuperReference`, so the outer `CallInvocation` is structurally stable. The same principle keeps an initial `ParsedArguments` inside `E(value)` while allowing a following index or argument list in `E(value)[index]` or `E(value)()` to be an ordinary stable outer operation.

Assignment and increment/decrement syntax needs a separate neutral node because the occurrence is known to have a target role by the end of parsing:

```dart
foo.bar = value
  DirectAssignment
    target: ParsedAssignmentTargetChain
      head: ParsedNameHead(foo)
      components:
        ParsedNameAccess(.bar)
    operator: =
    value: ParsedExpressionChain
      head: ParsedNameHead(value)

foo.bar++
  PostfixIncrement
    target: ParsedAssignmentTargetChain
      head: ParsedNameHead(foo)
      components:
        ParsedNameAccess(.bar)
    operator: ++

foo[0] = value
  DirectAssignment
    target: ReceiverIndexAssignmentTarget
      receiver: ParsedExpressionChain
        head: ParsedNameHead(foo)
      index: 0
    operator: =
    value: ParsedExpressionChain
      head: ParsedNameHead(value)
```

The parser should preferably accumulate the head and components in a temporary non-AST builder and materialize either `ParsedExpressionChain` or `ParsedAssignmentTargetChain` only after an assignment or increment/decrement operator, another structurally stable operation, or the end of the enclosing expression determines the source role. Children can remain briefly unparented while this local parser builder is active; this is preferable to constructing and parenting a `ParsedExpressionChain` and then moving all of its children into a target node. An implementation can initially perform the latter conversion if parser architecture requires it, but this is an implementation compromise rather than the desired ownership model.

The same parsed target node supports plain, compound, null-aware, increment, and decrement targets. The eventual canonical assignment target directly records an optional read and write. A non-null write denotes the target protocol selected by the enclosing operation, while null read and write record that receiver evaluation prevents the protocol entirely. A single parsed node should not implement both `Expression` and `AssignmentTarget`, because doing so would restore parent-sensitive read-versus-write classification and allow a write-only occurrence to expose expression APIs. Unambiguous targets do not need a parsed target chain. A bare `x = value` directly uses `UnqualifiedNameAssignmentTarget`, because variable-versus-setter selection does not change that source role, while `foo[0] = value` directly uses `ReceiverIndexAssignmentTarget` whose receiver remains a parsed expression chain. A property target whose receiver is already structurally value-producing can likewise be constructed directly; the neutral target chain is required only while namespace, static, constructor, extension-override, or value interpretation can still change the canonical structure.

### 8.5 Resolution-dependent lowering

Resolution consumes a parsed chain and constructs the convenient canonical source nodes selected by its head, components, and parent slot. For a parsed `foo.bar` expression chain:

```dart
foo is a value
  -> ReceiverPropertyExtraction
     receiver: UnqualifiedNameExpression(foo)

foo is an import prefix
  -> ImportPrefixedNameExpression
     importPrefix: ImportPrefixReference(foo.)

foo is a type-like declaration or named extension used for static lookup
  -> ReceiverPropertyExtraction
     receiver: StaticQualifier(foo)

invalid value read
  -> source-shaped ReceiverPropertyExtraction
     resolution: InvalidNamedReadResolution
```

Lowering must therefore interpret a name-led chain as a unit rather than first finalizing its head as a value expression and then resolving each suffix. The parent supplies a required structural role, not merely a static type context. The implementation should use role-specific entry points rather than return an untyped `AstNode`:

```dart
Expression lowerExpressionChain(
  ParsedExpressionChain chain,
)

AssignmentTarget lowerAssignmentTargetChain(
  ParsedAssignmentTargetChain chain,
)

NamedReceiver lowerNamedReceiverChain(
  ParsedExpressionChain chain,
)

InstanceReceiver lowerInstanceReceiverChain(
  ParsedExpressionChain chain,
)

Expression lowerDotShorthandExpression(
  ParsedDotShorthandExpression expression,
  TypeSchema shorthandContext,
)
```

The dot-shorthand entry point lowers the wrapper's ordinarily structured `expression` child while carrying a distinct shorthand context to the unique `ParsedDotShorthandHead`; it does not reinterpret that context as the ordinary downward context of every intermediate selector. It returns the retained or reconstructed child root after the head and any other ambiguous islands have been lowered, and the caller installs that root in the wrapper's former parent slot. The same parsed spelling can consequently lower to a value expression in an expression slot, to `StaticQualifier` in a named-receiver slot, to `ExtensionOverride` in an instance-receiver slot, or to canonical invalid recovery when the selected role is not admitted by the parent. A bare non-value name still lowers to an ordinary name or import-prefixed expression with `InvalidNamedReadResolution`; a complete `ExtensionOverride` selected in an expression slot lowers to `InvalidExtensionOverrideExpression`; and `ParsedSuperHead` at an expression-only boundary lowers to `InvalidSuperExpression`. This parent-sensitive classification is confined to parser-only syntax and disappears from the resolved AST; it does not reintroduce parent-sensitive semantics into canonical `Expression` or `AssignmentTarget`.

In particular, a plain period after a type declaration commits the occurrence to static-member or constructor lookup:

```dart
int
  -> TypeLiteral(int)

int.bar
  -> ReceiverPropertyExtraction
     receiver: StaticQualifier(int)
     operator: .
     name: bar

int.method()
  -> ReceiverMethodInvocation
     receiver: StaticQualifier(int)
     name: method
     argumentList: ()

int[0]
  -> ReceiverIndexExpression
     receiver: TypeLiteral(int)
     index: 0
```

The first three occurrences do not establish a general rule that a type name is always or never an expression. The enclosing source operation selects its role. A standalone type name is a value-producing `TypeLiteral`. A plain named selection uses it as a static qualifier and reports an unresolved static member if lookup fails; it does not fall back to treating the qualifier as a runtime `Type` object and performing instance or extension lookup on `Type`. Bracket syntax cannot perform static lookup, so in `int[0]` the name is instead lowered to `TypeLiteral` and ordinary instance operation lookup applies, including a matching extension operator on `Type`. This is also why the parser can build the structurally stable outer `ReceiverIndexExpression` immediately while still allowing resolution to replace its provisional name receiver.

The corresponding `ParsedAssignmentTargetChain` lowers to `ReceiverPropertyAssignmentTarget`, `ImportPrefixedAssignmentTarget`, one of the three concrete `InvalidAssignmentTarget` variants, or another canonical target, with `StaticQualifier` used as the receiver of the ordinary property target when static lookup is selected. An invocation-shaped non-location becomes `InvalidExpressionAssignmentTarget` when it produces a value and `InvalidExtensionOverrideAssignmentTarget` when it selects an extension override; bare `super` in a target slot becomes `InvalidSuperAssignmentTarget`. Constructor tear-offs and constructor invocations lower to their constructor-specific expression nodes when used as values and become `InvalidExpressionAssignmentTarget` children when placed directly before assignment or increment/decrement syntax. `ParsedTypeArguments` can become part of a type literal, a `ConstructorTypeReference`, a direct invocation, or a `FunctionInstantiation` depending on the surrounding components and resolved role.

Invocation lowering follows the concrete hierarchy described below:

```dart
f()
  declared function or method
    -> UnqualifiedFunctionInvocation
  variable, getter, or field
    -> CallInvocation(UnqualifiedNameExpression(f))
  class or constructor type
    -> ConstructorInvocation
  extension name used as a receiver
    -> ExtensionOverride

foo.bar()
  direct member method
    -> ReceiverMethodInvocation
  getter or field followed by call
    -> CallInvocation(ReceiverPropertyExtraction(foo.bar))
  import prefix plus imported function
    -> ImportPrefixedFunctionInvocation
  constructor type plus selector
    -> ConstructorInvocation
```

Invalid resolution does not permit a parsed chain to remain, but it also does not by itself justify a generic invalid-expression node. Lowering chooses the canonical node for the operation established by syntax, a selected declaration, or a distinguished recovery declaration, and places the failure in that node's resolution. A unique getter or field candidate therefore selects `CallInvocation` even when the produced value is not callable, while a unique constructor candidate selects `ConstructorInvocation` even when its arguments are invalid. When no candidate establishes a more specific interpretation, lowering uses a deterministic syntax-biased attempted operation rather than an arbitrary candidate. For `C.missing()` where `C` is a type and `missing` is neither a named constructor nor a static getter, field, or method, the result is:

```dart
ReceiverMethodInvocation
  receiver:
    StaticQualifier(C)
  name: missing
  argumentList: ()
  resolution: InvalidInvocationResolution
```

`ReceiverMethodInvocation` in this invalid case means an attempted direct named invocation; it does not assert that a method element exists. Conversely, `ConstructorInvocation` means that the source occurrence has selected the constructor interpretation, but it does not require a non-null constructor element in every erroneous program. Explicit `new` or `const`, constructor-owned type arguments such as `C<int>.missing()`, the reserved `C.new()` selector, an unnamed invocation of a name resolved as a constructor type, or an actual or distinguished recovery constructor can commit to constructor topology. A keywordless and otherwise ambiguous `C.missing()` does not become `ConstructorInvocation` merely because `C` is a type.

Import namespace qualification requires plain `.`, so `prefix?.x` is not ambiguous import qualification and can be parsed directly as `ReceiverPropertyExtraction` whose parse-only receiver is `ParsedExpressionChain(ParsedNameHead(prefix))`. The null-aware operator forces that head through value-expression lowering rather than namespace lowering. If the name resolves to `PrefixElement`, it follows the invalid receiver and recovery-lookup model described above.

Chains are lowered from the inside out. For example, `prefix.value.x` becomes a `ReceiverPropertyExtraction` whose receiver is `ImportPrefixedNameExpression(prefix.value)`, while `variable.value.x` becomes nested value-receiver property accesses. If `C` in `prefix.C.x` is an imported type or another valid static qualifier, the final outer property access uses `StaticQualifier` containing `ImportPrefixReference(prefix.)` and name `C`; if imported `C` is instead a variable or getter, `ImportPrefixedNameExpression(prefix.C)` becomes the value-producing receiver of the outer access.

If a parsed chain selects a complete `ExtensionOverride` in a slot that requires an `Expression`, resolution produces `InvalidExtensionOverrideExpression` rather than installing the non-expression receiver directly. A bare `super` in such a slot becomes `InvalidSuperExpression`. Static qualifiers and import prefixes do not automatically use either wrapper: lowering normally has an honest source-shaped value interpretation or invalid named-read occurrence such as `TypeLiteral(C)`, invalid `UnqualifiedNameExpression(E)`, invalid `UnqualifiedNameExpression(prefix)`, or invalid `ReceiverPropertyExtraction(prefix?.name)`. A receiver slot typed as `NamedReceiver` or `InstanceReceiver` can instead accept the selected non-expression role directly.

#### 8.5.1 Exhaustive lowering table for the minimal name chain

The following tables are exhaustive over the binding categories that change the canonical node structure for the minimal spellings `foo`, `foo.bar`, and `foo.bar()`. Element kinds that use the same source node and differ only in their concrete resolution subtype are grouped. Invalid ordinary name, property, import-prefixed, and index occurrences retain those source-shaped expressions with invalid resolution. The phrase “invalid expression preserving that override” refers specifically to `InvalidExtensionOverrideExpression`; bare `super` analogously uses `InvalidSuperExpression`. When lookup is unresolved or multiply defined, a uniquely selected recovery candidate can choose the same structure as a valid binding; otherwise the table states the deterministic value-shaped default so that lowering never leaves a `Parsed*` node in the resolved tree.

The parser initially represents the three spellings without committing either name to a value role:

```dart
foo
  ParsedExpressionChain
    head: ParsedNameHead(foo)

foo.bar
  ParsedExpressionChain
    head: ParsedNameHead(foo)
    components:
      ParsedNameAccess(.bar)

foo.bar()
  ParsedExpressionChain
    head: ParsedNameHead(foo)
    components:
      ParsedNameAccess(.bar)
      ParsedArguments(())
```

For bare `foo`:

| Binding of `foo` | Canonical resolved node | Resolution or recovery |
| --- | --- | --- |
| Local variable, formal parameter, pattern variable, or another directly read value declaration | `UnqualifiedNameExpression(foo)` | `VariableReadResolution` |
| Field, top-level variable, static variable, declared getter, or another declaration whose unqualified use invokes a getter | `UnqualifiedNameExpression(foo)` | `GetterInvocationResolution` |
| Top-level function, local function, instance method through implicit `this`, static method, or another executable used as a tear-off | `UnqualifiedNameExpression(foo)` | `ExecutableTearOffResolution` |
| Class, enum, mixin, extension type, type parameter, or another declaration admitted by type-literal syntax, including an admissible type alias | `TypeLiteral(NamedType(foo))` | `NamedType` owns the declaration and represented type; `TypeLiteral.staticType` is `Type` |
| Named extension | `UnqualifiedNameExpression(foo)` | `InvalidNamedReadResolution`, `InvalidType`, and the extension candidate preserve the attempted value-position reference; only `foo(arguments)` in a receiver-capability slot can become `ExtensionOverride` |
| Import prefix | `UnqualifiedNameExpression(foo)` | `InvalidNamedReadResolution`, `InvalidType`, and the prefix candidate preserve the attempted value-position reference; bare `foo` has no following period that can belong to `ImportPrefixReference` |
| Unresolved name with no distinguished recovery candidate | `UnqualifiedNameExpression(foo)` | `InvalidNamedReadResolution` and `InvalidType` |
| Multiply defined name | Structure selected by a distinguished recovery candidate; otherwise `UnqualifiedNameExpression(foo)` | Invalid resolution records ambiguity and candidates according to the eventual recovery payload design |

For `foo.bar`:

| Binding of `foo` | Binding or lookup result for `bar` | Canonical resolved node | Resolution or recovery |
| --- | --- | --- | --- |
| Value-producing declaration or expression | Field, getter, or another readable property | `ReceiverPropertyExtraction(UnqualifiedNameExpression(foo), .bar)` | The outer read normally has `GetterInvocationResolution`; the receiver retains its own named-read resolution |
| Value-producing declaration or expression | Instance or extension method used as a tear-off | `ReceiverPropertyExtraction(UnqualifiedNameExpression(foo), .bar)` | `ExecutableTearOffResolution` |
| Value of type `dynamic` | Any named read | `ReceiverPropertyExtraction(UnqualifiedNameExpression(foo), .bar)` | Dynamic named-read resolution |
| Value-producing declaration or expression | Missing, inaccessible, or ambiguous property | `ReceiverPropertyExtraction(UnqualifiedNameExpression(foo), .bar)` | Invalid named-read resolution; a selected recovery getter, field, or method can supply more specific recovery data without changing the source node |
| Import prefix | Imported variable, getter, constant, function, or another imported value declaration | `ImportPrefixedNameExpression(ImportPrefixReference(foo.), bar)` | `VariableReadResolution`, `GetterInvocationResolution`, or `ExecutableTearOffResolution` according to the imported declaration |
| Import prefix | Imported class, enum, mixin, extension type, or admissible type alias | `TypeLiteral(NamedType(foo.bar))` | The `NamedType` contains `ImportPrefixReference(foo.)` and owns `bar` |
| Import prefix | Imported named extension | `ImportPrefixedNameExpression(ImportPrefixReference(foo.), bar)` | `InvalidNamedReadResolution`, `InvalidType`, and the extension candidate preserve the attempted value-position reference; a following argument list can instead participate in an `ExtensionOverride` |
| Import prefix | Missing, hidden, ambiguous, or otherwise invalid imported name | `ImportPrefixedNameExpression(ImportPrefixReference(foo.), bar)` | Invalid named-read resolution; the grouped prefix remains canonical because `foo` is known to be an import namespace |
| Type-like declaration | Static field, getter, or constant | `ReceiverPropertyExtraction(StaticQualifier(foo), .bar)` | Getter or variable read resolution for the selected static declaration |
| Type-like declaration | Static method used as a tear-off | `ReceiverPropertyExtraction(StaticQualifier(foo), .bar)` | `ExecutableTearOffResolution` |
| Type-like declaration | Named constructor | `ConstructorTearOff(ConstructorTypeReference(foo), ConstructorSelector(.bar))` | The selected substituted constructor is exposed through constructor selection |
| Type-like declaration | Missing, inaccessible, or ambiguous static member or constructor | `ReceiverPropertyExtraction(StaticQualifier(foo), .bar)` unless a distinguished constructor recovery candidate selects `ConstructorTearOff` | Invalid static named-read resolution; lowering does not fall back to invoking `bar` on the runtime `Type` object |
| Named extension | Static field, getter, constant, or static method | `ReceiverPropertyExtraction(StaticQualifier(foo), .bar)` | Ordinary static named-read or executable-tear-off resolution; declaration kind is carried by the qualifier and resolution rather than by a separate extension-reference expression |
| Named extension | Missing, inaccessible, or ambiguous static member | `ReceiverPropertyExtraction(StaticQualifier(foo), .bar)` | Invalid static named-read resolution |
| Unresolved or multiply defined `foo` without a distinguished namespace, type, or extension recovery candidate | Any `bar` | `ReceiverPropertyExtraction(UnqualifiedNameExpression(foo), .bar)` | The receiver and outer read have invalid resolution as necessary; value-receiver property access is the deterministic default |

For `foo.bar()`:

| Binding of `foo` | Binding or lookup result for `bar` | Canonical resolved node | Resolution or recovery |
| --- | --- | --- | --- |
| Value-producing declaration or expression | Instance, extension, or extension-type method selected for direct invocation | `ReceiverMethodInvocation(UnqualifiedNameExpression(foo), .bar, ())` | `ExecutableInvocationResolution` |
| Value-producing declaration or expression with a function type or core `Function` type | `bar` is the language-defined `call` method | `ReceiverMethodInvocation(UnqualifiedNameExpression(foo), .call, ())` | `FunctionCallInvocationResolution` when the exact function signature is known; `FunctionInterfaceInvocationResolution` for core `Function`, with no `invokeType` |
| Value-producing declaration or expression | Field or getter whose resulting value is invoked, including a function-valued field or callable object | `CallInvocation(ReceiverPropertyExtraction(UnqualifiedNameExpression(foo), .bar), ())` | The property read has its ordinary `NamedReadResolution`; the outer call has function-type, executable, dynamic, or invalid invocation resolution as appropriate |
| Value of type `dynamic` | Any named invocation | `ReceiverMethodInvocation(UnqualifiedNameExpression(foo), .bar, ())` | `DynamicInvocationResolution`; direct named invocation is the source-shaped dynamic interpretation |
| Value-producing declaration or expression | Missing, inaccessible, or ambiguous member with no distinguished getter or field recovery candidate | `ReceiverMethodInvocation(UnqualifiedNameExpression(foo), .bar, ())` | `InvalidInvocationResolution`; a distinguished getter or field recovery candidate instead selects `CallInvocation` |
| Import prefix | Imported top-level function | `ImportPrefixedFunctionInvocation(ImportPrefixReference(foo.), bar, ())` | `ExecutableInvocationResolution` |
| Import prefix | Imported variable, getter, or constant whose value is invoked | `CallInvocation(ImportPrefixedNameExpression(ImportPrefixReference(foo.), bar), ())` | The imported read and outer call have their separate resolutions |
| Import prefix | Imported class, enum, extension type, or admissible type alias denoting an unnamed constructor namespace | `ConstructorInvocation(ConstructorReference2(ConstructorTypeReference(foo.bar), selector: null), ())` | Constructor selection exposes the selected substituted unnamed constructor |
| Import prefix | Imported named extension | `ExtensionOverride(foo.bar(...))` when the parent slot accepts a named or instance-operation receiver; otherwise `InvalidExtensionOverrideExpression(ExtensionOverride(foo.bar(...)))` | The argument list belongs to the extension override and does not denote a function invocation |
| Import prefix | Missing, hidden, or ambiguous imported declaration with no distinguished value, type, or extension recovery candidate | `ImportPrefixedFunctionInvocation(ImportPrefixReference(foo.), bar, ())` | Invalid invocation resolution; direct imported-function invocation is the deterministic default |
| Type-like declaration | Named constructor | `ConstructorInvocation(ConstructorReference2(ConstructorTypeReference(foo), ConstructorSelector(.bar)), ())` | Constructor selection exposes the selected substituted constructor |
| Type-like declaration | Static method | `ReceiverMethodInvocation(StaticQualifier(foo), .bar, ())` | `ExecutableInvocationResolution` |
| Type-like declaration | Static field or getter whose value is invoked | `CallInvocation(ReceiverPropertyExtraction(StaticQualifier(foo), .bar), ())` | The static property read and outer call have separate resolutions |
| Type-like declaration | Missing, inaccessible, or ambiguous member with no distinguished constructor, getter, or field recovery candidate | `ReceiverMethodInvocation(StaticQualifier(foo), .bar, ())` | `InvalidInvocationResolution`; a distinguished constructor candidate selects `ConstructorInvocation`, while a getter or field candidate selects `CallInvocation` |
| Named extension | Static method | `ReceiverMethodInvocation(StaticQualifier(foo), .bar, ())` | `ExecutableInvocationResolution` |
| Named extension | Static field or getter whose value is invoked | `CallInvocation(ReceiverPropertyExtraction(StaticQualifier(foo), .bar), ())` | The static read and outer call have separate resolutions |
| Named extension | Missing, inaccessible, or ambiguous static member with no distinguished getter or field recovery candidate | `ReceiverMethodInvocation(StaticQualifier(foo), .bar, ())` | `InvalidInvocationResolution`; a getter or field recovery candidate instead selects `CallInvocation` |
| Unresolved or multiply defined `foo` without a distinguished namespace, type, extension, or value recovery candidate | Any `bar` | `ReceiverMethodInvocation(UnqualifiedNameExpression(foo), .bar, ())` | Invalid receiver read and invocation resolutions; direct value-receiver method invocation is the deterministic default |

These tables classify plain-period syntax. A written `?.` removes import-namespace, static-qualifier, constructor, and extension-override interpretations at that boundary because those roles do not own a null-aware period. For `foo?.bar` the head must therefore lower through a value-expression interpretation, with invalid value recovery if `foo` actually denotes an import prefix or another non-value declaration. For `foo?.bar()` the remaining choice is direct null-aware method invocation versus a null-shortened property read followed by `CallInvocation`; the parsed chain must retain the name access and arguments together until that choice is made.

The type-like `foo.bar()` rows deliberately distinguish constructor selection from absence of a constructor. A selected or distinguished recovery named constructor produces `ConstructorInvocation`; a selected static getter or field produces `CallInvocation`; a selected static method produces `ReceiverMethodInvocation`; and no candidate produces `ReceiverMethodInvocation` with `InvalidInvocationResolution`. This default is stable under candidate iteration order and matches the operation the resolver attempts after constructor and callable-value interpretations have failed. Explicitly constructor-shaped syntax follows the separate constructor rule and can remain `ConstructorInvocation` with a null selected element.

### 8.6 Lowering discipline

This design intentionally uses a parser-only representation whose identity is not part of the resolved AST. Lowering is resolution-driven but structurally committed once per parsed-chain root. It cannot be a separate whole-unit pass before resolution because selecting a direct method invocation versus a property read followed by `CallInvocation`, a runtime value versus a static or import namespace, or a constructor interpretation requires lookup and sometimes the resolved type of an earlier receiver. Conversely, ordinary resolver visitors should not incrementally replace one parsed component after another with provisional public AST nodes. The resolver may interleave lookup, contextual inference, and construction internally, but it should replace the parsed-chain root with one complete canonical topology once that topology has been selected.

The lowerer should inspect selector-shaped groups rather than naively fold one component at a time. In `foo.bar<T>(argument)`, `.bar`, `<T>`, and `(argument)` jointly select among a direct `ReceiverMethodInvocation`, a `CallInvocation` whose receiver is `ReceiverPropertyExtraction`, an import-prefixed invocation, a constructor invocation, an extension override, and recovery forms. Constructing `ReceiverPropertyExtraction(foo.bar)` before considering the following components would temporarily assert the getter-or-value interpretation and then require another structural rewrite if `bar` is a directly invoked method or constructor. The flat parser component list can remain the lossless source representation, while the lowerer groups adjacent name access, type arguments, and arguments as one semantic selector window.

The implementation can use a private resolver-only accumulator whose alternatives are deliberately wider than any public child slot:

```dart
sealed class _ParsedChainState {}

final class _ValueState implements _ParsedChainState {
  Expression expression;
}

final class _ImportPrefixState implements _ParsedChainState {
  ImportPrefixReference prefix;
}

final class _StaticQualifierState implements _ParsedChainState {
  StaticQualifier qualifier;
}

final class _ConstructorState implements _ParsedChainState {
  ConstructorTypeReference typeReference;
}

final class _ExtensionOverrideState implements _ParsedChainState {
  ExtensionOverride extensionOverride;
}
```

This is temporary resolver state, not another public AST hierarchy. The entry and result types remain role-specific:

```dart
Expression lowerExpressionChain(
  ParsedExpressionChain chain,
  TypeSchema contextType,
)

AssignmentTarget lowerAssignmentTargetChain(
  ParsedAssignmentTargetChain chain,
  TargetAccessMode accessMode,
)
```

Additional private helpers can finish an intermediate chain state as a `NamedReceiver` or `InstanceReceiver` while consuming a larger chain, but the resolver should not expose a general `AstNode lowerChain(...)` API. Assignment-target lowering happens before analysis of an assigned value when the selected variable, setter, or index write supplies that value's context type. Compound assignments and increment/decrement expressions additionally resolve the target read before the operator, but no flow or resolution fact is attached to the discarded parsed-target node.

Lowering should obey the following constraints:

- Every `ParsedExpressionChain`, `ParsedAssignmentTargetChain`, and `ParsedDotShorthandExpression` is eliminated before a resolved unit, including a unit containing invalid code, is exposed to clients.
- The final resolved V2 tree contains convenient, semantically honest source nodes rather than generic ambiguous wrappers.
- Original tokens, source ranges, comments, and reference occurrences are reused.
- The parsed root is replaced exactly once; no semantic resolution, static type, reference binding, or flow-analysis information is recorded on that root or on a component container that will be discarded.
- Parent links and covering-node behavior are repaired as part of installing the selected canonical root. The implementation saves the parsed root's old parent before constructors move surviving children and then replaces the old root through that typed parent slot.
- Parse-only V2 clients see the neutral parsed chain; resolved V2 clients see the selected canonical nodes.
- V1 parse projections reproduce the legacy expression-shaped parse tree where compatibility requires it, while V1 resolved projections follow the selected canonical V2 interpretation.
- A resolver pipeline must not create or cache a V1 projection from a parsed chain before lowering. A standalone parse result may synthesize its legacy parse projection, but a resolved result creates projections only from the final canonical V2 nodes.
- Lowering selects among source interpretations and does not transform the construct into kernel-like getter calls, setter calls, temporaries, or namespace operations.

Producing convenient final concrete classes makes AST replacement during resolution unavoidable: one Dart object cannot change from `ParsedExpressionChain` into `TypeLiteral`, `ConstructorInvocation`, or `ReceiverMethodInvocation`. This replacement is an internal phase transition rather than a public node-identity promise between a standalone parse result and a separately obtained resolved result. Original tokens, existing expressions held by `ParsedValueHead`, `TypeArgumentList`, `ArgumentList`, their descendants, and structurally stable outer nodes are retained. The parsed chain root, its head container, and its component containers are intentionally discarded. For `foo.bar[0]`, the existing outer `ReceiverIndexExpression`, index expression, and source tokens retain identity while its receiver changes from `ParsedExpressionChain(foo.bar)` to the selected canonical expression or instance-operation receiver. For `.values[0]`, the same index node initially occurs beneath `ParsedDotShorthandExpression`; resolution replaces its parsed receiver and then reparents the retained index root into the wrapper's former parent slot.

The current resolver rewrite stack demonstrates the mechanics for expression-to-expression replacement, but canonical V2 also rewrites `AssignmentTarget` and typed receiver roles. The implementation should add role-specific lowering and replacement paths rather than widen all rewriting to an untyped `AstNode` stack. A generated parent slot can still perform the final `replaceChild` operation because both the provisional and final nodes satisfy that slot's declared role. If constructing the final node reparents children taken from the parsed chain, the lowerer must retain the old parent explicitly instead of consulting the provisional node's possibly disturbed parent afterward.

V1 projection has a strict phase boundary. A standalone parse tree may lazily synthesize and cache a legacy guessed topology from a parsed chain because that tree will not later become a resolved result. A tree in the resolution pipeline must assert that no such projection has been materialized before lowering; after lowering, canonical V2 nodes lazily produce the resolved V1 topology. The implementation should not attempt to mutate, invalidate, or synchronize a V1 projection that was created from a provisional parsed chain.

Resolved-tree verification should assert after both successful and erroneous resolution that no parsed chain, component, dot-shorthand head, or dot-shorthand wrapper remains, every child and `parent2` relationship is reciprocal, no child is reachable through two canonical parents, the replacement root has the same first and last source tokens as the parsed root or wrapper, discarded nodes are absent from flow and resolution maps, and no V1 projection was created on the resolution side of the lowering boundary. Parse and resolution tests should separately cover V2 and V1 trees, covering-node results, stable outer-node identity, corresponding-parameter data on reused arguments, null shortening across the replacement, dot-shorthand context routing, immediate equality operands, parentheses boundaries, and deterministic invalid recovery. Lowering is idempotent by construction because the lowering entry points accept only a parsed chain, parsed target chain, or parsed dot-shorthand wrapper, and a resolved-tree verifier rejects every provisional kind.

The final distinction keeps the analyzer source-shaped. `ReceiverPropertyExtraction` preserves the written `.bar` operation for value, static, extension-override, and `super` receivers, while `ImportPrefixedNameExpression` preserves the grouped namespace qualifier `prefix.` and following name. None of these nodes encode compiler lowering.

The neutral parsed chain centralizes ambiguity without becoming a generic final AST. Resolved clients retain the convenient property, import-prefix, function-invocation, constructor, extension-override, and assignment-target APIs, while parser and compatibility layers have one explicit place to preserve source that cannot yet be classified.

## 9. Invocations

An ordinary function invocation produces a value and therefore is an `Expression`, but the source immediately before the argument list is not uniformly an expression. It can directly identify a named function or method, evaluate a value, or provide a special non-value receiver such as `super` or an extension override. The last case means that a node named `ValueInvocation` with an `Expression` child is too narrow.

`FunctionInvocation` is the generic expression category:

```dart
abstract final class FunctionInvocation implements Expression {
  ArgumentList get argumentList;
  TypeArgumentList? get typeArguments;
  InvocationResolution? get resolution;
}
```

This replaces rather than extends the current `InvocationExpression` contract. The current common `function` getter fabricates an expression-shaped function child for direct method invocation even though the written method name is a selector, while `staticInvokeType` and `typeArgumentTypes` are nullable resolution payloads rather than source children. Its membership is also inconsistent: it includes dot-shorthand constructor invocation while excluding ordinary constructor invocation. Canonical V2 retains the genuinely common function-invocation syntax and resolution through `FunctionInvocation`, but it has no common `function` child and does not include constructor or anonymous-method forms. Concrete function-invocation nodes expose their actual name, receiver, import prefix, cascade position, or value-producing call receiver.

The concrete names do not need an `Expression` suffix because the hierarchy already establishes that they are expressions. This follows the current V2 naming style of `ConstructorInvocation` and `AnonymousMethodInvocation`. Constructor invocation remains directly under `Expression`, with constructor type arguments structurally owned by `ConstructorTypeReference` and constructor-specific resolution rather than being forced into the function-invocation hierarchy.

### 9.1 Named function invocation

`NamedFunctionInvocation` represents direct invocation of a function or method identified by a written name. Here "function" includes top-level and local functions, instance and static methods, extension methods, superclass methods, imported functions, and dynamically dispatched named members:

```dart
abstract final class NamedFunctionInvocation
    implements FunctionInvocation {
  Token get name;
}

abstract final class UnqualifiedFunctionInvocation
    implements NamedFunctionInvocation {}

abstract final class ReceiverMethodInvocation
    implements NamedFunctionInvocation {
  NamedReceiver get receiver;
  Token get operator;
}

abstract final class ImportPrefixedFunctionInvocation
    implements NamedFunctionInvocation {
  ImportPrefixReference get importPrefix;
}

abstract final class CascadeMethodInvocation
    implements NamedFunctionInvocation {}

abstract final class DotShorthandMethodInvocation
    implements NamedFunctionInvocation, DotShorthandExpression {
  Token get period;
}
```

```dart
f()
  UnqualifiedFunctionInvocation
    name: f

object.m()
  ReceiverMethodInvocation
    receiver: UnqualifiedNameExpression(object)
    operator: .
    name: m

super.m()
  ReceiverMethodInvocation
    receiver: SuperReference
    operator: .
    name: m

E(object).m()
  ReceiverMethodInvocation
    receiver: ExtensionOverride(E(object))
    operator: .
    name: m

C.m()
  ReceiverMethodInvocation
    receiver: StaticQualifier(C)
    operator: .
    name: m

prefix.f()
  ImportPrefixedFunctionInvocation
    importPrefix: ImportPrefixReference(prefix.)
    name: f

target..m()
  CascadeSection
    operator: ..
    body: CascadeMethodInvocation
      name: m
```

The complete dot-shorthand invocation examples and their context analysis are in section 9.5. The concrete names distinguish forms that can select functions from forms that always perform direct method dispatch after lowering. `ReceiverMethodInvocation` covers ordinary instance, extension, superclass, static, and dynamic named method dispatch through its sealed receiver and resolution data; it does not split into one class for each dispatch mechanism. `CascadeMethodInvocation` and `DotShorthandMethodInvocation` are likewise method-specific because getter or field values followed by arguments lower to `CallInvocation`. `UnqualifiedFunctionInvocation` remains broader because it can select a top-level or local function or an implicit-receiver method, while `ImportPrefixedFunctionInvocation` selects an imported top-level function.

Every written token has one structural owner. `ReceiverMethodInvocation` owns `.m` or `?.m`. `ImportPrefixReference` owns `prefix.`, while `ImportPrefixedFunctionInvocation` owns `f`. `CascadeSection` owns `..` or `?..`, while `CascadeMethodInvocation` owns `m`. `DotShorthandMethodInvocation` owns its leading period and name. Common clients use `NamedFunctionInvocation.name`, `FunctionInvocation.typeArguments`, `FunctionInvocation.argumentList`, and `FunctionInvocation.resolution`; only clients concerned with qualification, direct method dispatch, or source shape need to switch over the concrete invocation kind. No intermediate sealed target wrapper or untyped `AstNode` target is introduced.

### 9.2 Call invocation

`CallInvocation` applies an argument list to an `InstanceReceiver` without owning a written function or member name:

```dart
abstract final class CallInvocation implements FunctionInvocation {
  InstanceReceiver get receiver;
}
```

The accepted receiver variants are exactly the roles already allowed to participate in supported instance operations:

```dart
Expression
ExtensionOverride
SuperReference
  implement InstanceReceiver
```

This covers ordinary function values, callable objects, explicit extension dispatch, and superclass `call` dispatch:

```dart
(f)()
list[index]()
(object.m)()
callableObject()
E(object)()
super()
```

The distinction determines the resolved trees for direct methods, getter reads, tear-offs, and special dispatch:

```dart
object.method();
(object.method)();
object.getter();
super();
```

```dart
object.method()
  ReceiverMethodInvocation
    name: method
    resolution: ExecutableInvocationResolution
      element: MethodElement(method)
      invokeType: ...
      type: ...

(object.method)()
  CallInvocation
    receiver: ParenthesizedExpression
      ReceiverPropertyExtraction
        name: method
        resolution: ExecutableTearOffResolution
    resolution: FunctionTypeInvocationResolution
      invokeType: ...
      type: ...

object.getter()
  CallInvocation
    receiver: ReceiverPropertyExtraction
      receiver: UnqualifiedNameExpression(object)
      operator: .
      name: getter
      resolution: GetterInvocationResolution

super()
  CallInvocation
    receiver: SuperReference
    resolution: ExecutableInvocationResolution
      element: superclass call method
      invokeType: ...
      type: ...
```

A function-valued field, a top-level or static getter, and an imported getter follow the same `CallInvocation` model. If the receiver expression has an exact function type, the outer invocation has `FunctionTypeInvocationResolution`: it applies that function type without selecting another declaration at the invocation site. If its static type is only core `Function`, the outer invocation instead has `FunctionInterfaceInvocationResolution`, whose result is `dynamic` and which has no `invokeType`. If the receiver evaluates to an object with a declared `call` method, the outer invocation has `ExecutableInvocationResolution` containing that implicitly selected method. A getter returning `dynamic` still produces a getter read followed by `DynamicInvocationResolution`.

`super()` is valid in an expression context and invokes the inherited `call` method with superclass dispatch. It is not a superclass-constructor invocation, which uses the same token spelling only in a constructor initializer. `super` does not produce a value, so representing this source as an invocation of an `Expression` would be dishonest. `ExtensionOverride` has the same property in `E(object)()`: it selects extension dispatch without producing an intermediate value. Typing `CallInvocation.receiver` as `InstanceReceiver` represents both forms directly.

```dart
class A {
  int call() => 42;
}

class B extends A {
  void foo() {
    print(super());
  }
}
```

Here the `CallInvocation` for `super()` has `ExecutableInvocationResolution` selecting `A.call`, invoke type `int Function()`, and type `int`, equal to the invocation's static type.

The explicit and implicit superclass forms intentionally contribute different source references:

```dart
super.call()
  ReceiverMethodInvocation
    receiver: SuperReference
    name: call
    // The call token references the selected method.

super()
  CallInvocation
    receiver: SuperReference
    // The implicit call operation references the selected method.
    // There is no member-name token.
```

This is another reason reference sites cannot be restricted to names.

The language-defined `call` member of a function type creates a second element-free named-invocation case. Direct invocation and property extraction remain distinct exactly as they do for declared methods:

The [main language specification](../../../../language_repository/specification/dartLangSpec.tex) supplies all three parts of this classification: a function-type-bounded type is considered to have a method named `call` with the function signature; property extraction of a method performs instance-method closurization; and an invocation whose function part is an unparenthesized property extraction is treated as an ordinary method invocation rather than as a tear-off followed by a function-value call. The [generic function instantiation feature](../../../../language_repository/accepted/2.15/constructor-tearoffs/feature-specification.md) likewise defines explicit instantiation of a function-typed value in terms of the instantiated method tear-off `e.call<T>`. Consequently, the written `call` token is a real named tear-off or invocation site even though no declaration element exists.

```dart
int Function(int) typed = ...;
Function untyped = ...;

typed.call(0)
  ReceiverMethodInvocation
    receiver: UnqualifiedNameExpression(typed)
    name: call
    argumentList: (0)
    resolution: FunctionCallInvocationResolution
      invokeType: int Function(int)
      type: int

untyped.call(0)
  ReceiverMethodInvocation
    receiver: UnqualifiedNameExpression(untyped)
    name: call
    argumentList: (0)
    resolution: FunctionInterfaceInvocationResolution
      type: dynamic
```

`typed.call(0)` is a direct invocation of the special named `call` method, not a `ReceiverPropertyExtraction` followed by `CallInvocation`. In contrast, `(typed.call)(0)` contains a `ReceiverPropertyExtraction` with `FunctionCallTearOffResolution` inside the parenthesized call receiver, followed by a `CallInvocation` with `FunctionTypeInvocationResolution`. The core `Function` interface admits both `untyped.call` and `untyped.call(0)` without exposing a parameter signature: the tear-off uses `FunctionInterfaceCallTearOffResolution`, while the invocation uses `FunctionInterfaceInvocationResolution` and has no `element` or `invokeType`. The same resolution distinction applies to an implicit-receiver `call` read or invocation and to cascade-start `..call`; the existing concrete nodes retain those source shapes without adding function-call-specific AST nodes.

The parser cannot know whether `f()` names a declared function or reads a callable variable, or whether `object.name()` selects a method or a getter. It preserves either spelling as `ParsedExpressionChain`. Lowering produces `UnqualifiedFunctionInvocation` for a direct unqualified function or implicit-receiver method, `ReceiverMethodInvocation` for direct receiver-qualified method dispatch, and `CallInvocation` containing the corresponding name or property expression for a selected variable, getter, or field. The current analyzer already performs an analogous semantic rewrite from `MethodInvocation` to `FunctionExpressionInvocation`; the V2 model moves the ambiguity into an explicit parser-only chain and generalizes the eventual `CallInvocation` receiver from `Expression` to `InstanceReceiver` so that `super()` and `E(object)()` fit without pretending that their receivers produce values.

Dynamic `object.name()` lowers to `ReceiverMethodInvocation` with `DynamicInvocationResolution` because it is a dynamically dispatched named method invocation with a written receiver, not a statically known getter read followed by an implicit call. Invalid code also eliminates the parsed chain, selecting an `InvalidInvocationResolution` with any direct valid recovery rather than retaining parser-only syntax in the resolved tree.

### 9.3 Invocation resolution

Invocation resolution uses a sealed hierarchy so that a selected executable, application of an exact function type, direct invocation of its language-defined named `call` method, invocation through core `Function` without a known signature, dynamic dispatch, and invalid resolution do not share nullable element, `invokeType`, and recovery fields:

```dart
sealed interface class InvocationResolution {
  DartType get type;
}

sealed interface class ValidInvocationResolution
    implements InvocationResolution {}

sealed interface class StaticInvocationResolution
    implements ValidInvocationResolution {
  FunctionType get invokeType;
}

final class ExecutableInvocationResolution
    implements StaticInvocationResolution {
  ExecutableElement get element;
  FunctionType get invokeType;
  DartType get type;
}

final class FunctionTypeInvocationResolution
    implements StaticInvocationResolution {
  FunctionType get invokeType;
  DartType get type;
}

final class FunctionCallInvocationResolution
    implements StaticInvocationResolution {
  FunctionType get invokeType;
  DartType get type;
}

final class FunctionInterfaceInvocationResolution
    implements ValidInvocationResolution {
  DartType get type;
}

final class DynamicInvocationResolution
    implements ValidInvocationResolution {
  DartType get type;
}

final class InvalidInvocationResolution
    implements InvocationResolution {
  DartType get type;
  List<Element> get candidates;
  ValidInvocationResolution? get recovery;
}
```

`ExecutableInvocationResolution` means that lookup selected an executable at this invocation site. For a `NamedFunctionInvocation`, its element is the directly invoked function or method. For a `CallInvocation` on a callable object, `super`, or an extension override, it is the implicitly selected `call` method. Whether that executable has a written name is determined by the enclosing source node and reference site rather than by another resolution subtype.

`FunctionTypeInvocationResolution` means that a `CallInvocation` applies an argument list directly to an already function-typed value without selecting a written or implicit named member at the invocation site. This is not specifically a function-literal or closure case. The value can come from a parameter, variable, getter, conditional expression, tear-off, or any other expression with a function type. The receiver expression's own resolution records how the function value was obtained, while the outer invocation has no executable element of its own:

```dart
int f(int value) => value;
int g(int value) => -value;

void use(bool condition, int Function(int) parameter) {
  parameter(0);

  var selected = condition ? f : g;
  selected(1);

  (f)(2);
}
```

```dart
parameter(0)
  CallInvocation
    receiver:
      UnqualifiedNameExpression(parameter)
        resolution:
          VariableReadResolution
            element: parameter
            type: int Function(int)
        staticType: int Function(int)
    argumentList: (0)
    resolution:
      FunctionTypeInvocationResolution
        invokeType: int Function(int)
        type: int
    staticType: int

(f)(2)
  CallInvocation
    receiver:
      ParenthesizedExpression
        expression:
          UnqualifiedNameExpression(f)
            resolution:
              ExecutableTearOffResolution
                element: f
                type: int Function(int)
            staticType: int Function(int)
    argumentList: (2)
    resolution:
      FunctionTypeInvocationResolution
        invokeType: int Function(int)
        type: int
    staticType: int
```

In contrast, unparenthesized `f(2)` lowers directly to `UnqualifiedFunctionInvocation` with `ExecutableInvocationResolution` containing `f`. The parenthesized form first produces the tear-off value whose reference belongs to the inner name expression, then applies its function type; the outer invocation does not create a second reference to `f`. A conditional value such as `selected` makes the need for an element-free invocation result still clearer because there may be no unique executable behind the value at runtime.

`FunctionCallInvocationResolution` instead means that a concrete `NamedFunctionInvocation` directly invokes the language-defined `call` method of a receiver whose promoted static type is a function type. The source node owns the written or unqualified `call` name, while the resolution has no executable element because the function type's `call` method has a signature but no declaration. Its required `invokeType` is the effective function signature after applying explicit or inferred type arguments, and `type` is the result if the invocation executes. This result is used by `ReceiverMethodInvocation` for `typed.call(arguments)`, by `UnqualifiedFunctionInvocation` for `call(arguments)` on an implicit function-typed receiver, and by `CascadeMethodInvocation` for `target..call(arguments)` when the cascade target has a function type.

`FunctionInterfaceInvocationResolution` means that invocation is permitted through the core `Function` interface, or a type resolved to that bound, but no statically known function signature exists. It implements `ValidInvocationResolution` directly rather than `StaticInvocationResolution`, exposes no `element` or `invokeType`, and has `type == dynamic`. Both `untyped(arguments)` and `untyped.call(arguments)` use this result; their `CallInvocation` and `ReceiverMethodInvocation` nodes preserve whether `call` was written. This is distinct from `DynamicInvocationResolution`, where the relevant receiver or invoked value is `dynamic` and lookup or dispatch itself is dynamic.

`FunctionInterfaceInvocationResolution.type` and `DynamicInvocationResolution.type` are `dynamic`, while `InvalidInvocationResolution.type` is canonical `InvalidType`. The two dynamic-result leaves remain distinct because invocation through the statically known core `Function` interface is a valid special language operation rather than dynamic member lookup. An invalid result can retain lookup candidates and point directly to a complete hypothetical `ValidInvocationResolution`, whose own `invokeType` where applicable and `type` describe recovered argument checking and the result that the recovered invocation would produce if it executed. Separate `recoveryElement` and `recoveryInvokeType` fields are unnecessary.

On a `FunctionInvocation`, a non-null valid executable, function-type, function-`call`, function-interface, or dynamic `resolution.type` describes the result if that invocation executes, while the invocation expression's `staticType` describes the complete expression result. They are equal when null shortening does not change the expression result. For `object?.method()` whose selected method has invoke type `R Function()`, `ExecutableInvocationResolution.invokeType` describes the executed-path call signature, `ExecutableInvocationResolution.type` is `R`, and the outer expression's `staticType` is `R?`. The same distinction applies when `object?.getter()` lowers to a null-shortened `CallInvocation`: its `FunctionTypeInvocationResolution` or implicitly selected executable result carries the result of the call if it executes, while the `CallInvocation.staticType` incorporates null shortening. `FunctionInterfaceInvocationResolution` and `InvalidInvocationResolution` retain their canonical `dynamic` and `InvalidType` outcomes; null shortening does not turn an invocation-resolution type into a nullable complete-expression type.

If evaluation of the invoked value or receiver cannot complete because its type is `Never`, no invocation operation occurs and `resolution` is null, while the invocation expression retains `staticType == Never`. This is the same absence-of-operation state used by property and index reads whose receiver cannot complete. It is distinct from invoking a selected executable or function type whose result type is `Never`: that invocation does execute and retains its ordinary non-null resolution with `type == Never`. A null resolution can also mean that semantic data has not yet been produced; the analysis phase of the containing compilation unit distinguishes unresolved data from a resolved operation that cannot occur.

This composition also gives indexing and navigation the correct reference sites. In `object.method()`, the written name references the selected method. In `object.getter()`, the written name belongs to the child `ReceiverPropertyExtraction` and references the getter; an implicit `call` method selected for the returned object has no written name token. In `(object.method)()`, the property name is a tear-off reference and the outer call invocation is a separate operation. In `typed.call()` and `typed.call`, the written `call` token remains a named invocation or tear-off reference site even though `FunctionCallInvocationResolution` and `FunctionCallTearOffResolution` have no declaration element; the corresponding core-`Function` results are likewise element-free. In `super()` and `E(object)()`, the implicit `call` reference belongs to the invocation operation rather than to a synthetic name.

### 9.4 Constructors, import prefixes, null shortening, and cascades

Constructor invocation remains a distinct source role:

```dart
C()
C.named()
prefix.C()
```

These forms resolve to `ConstructorInvocation` containing `ConstructorReference2`, whose `ConstructorTypeReference` is required and whose `ConstructorSelector` is optional; they do not first produce a type object or constructor tear-off value. The optional selector represents valid source, not merely recovery: `C()` invokes the unnamed constructor without an explicit `.new`, and `factory F() = C;` redirects to the same unnamed-constructor reference. Invoking an explicitly obtained constructor tear-off, such as `(C.new)()`, is instead a `CallInvocation`.

`ConstructorInvocation` represents a source occurrence for which syntax or resolution selected constructor application; it does not promise that selection found a constructor element. `new C.missing()` and `const C.missing()` are unambiguously constructor applications and remain `ConstructorInvocation` with a null selected element when the constructor is absent. Constructor-owned type arguments such as `C<int>.missing()` likewise commit to constructor syntax and do not fall back to static access. In contrast, keywordless `C.missing()` is ambiguous between a named constructor, a static method invocation, and a static getter or field followed by `CallInvocation`. It becomes `ConstructorInvocation` only when an actual or distinguished recovery constructor establishes that interpretation; with no applicable candidate it becomes `ReceiverMethodInvocation(StaticQualifier(C), missing, ())` with `InvalidInvocationResolution`. Thus nullable `constructorElement` supports invalid constructor-shaped source without making every unresolved type-qualified invocation constructor-shaped.

The current reuse of `ConstructorReference2` by `ConstructorInvocation.constructorReference` and `ConstructorDeclaration.factoryRedirectionTarget` is structurally sound. Both sites contain the same written constructor designator, consisting of a type reference followed by an optional constructor selector. The surrounding node determines whether that designator is applied to an argument list or merely names a factory redirection target. `ConstructorReference2` should eventually lose its migration suffix, but `ConstructorReference` should continue to mean this specific written structure rather than any AST occurrence that happens to resolve to a constructor.

`ConstructorTearOff` should remain a separate expression with a required `ConstructorTypeReference` and required `ConstructorSelector`. Valid standalone tear-off syntax is `C.new` or `C.named`; bare `C` is a `TypeLiteral`, not a constructor tear-off. Making `ConstructorTearOff` contain the optional-selector `ConstructorReference2` merely to reuse fields would admit a structurally invalid tear-off state and add a wrapper that is not present in the source. Dot shorthand has a third source shape: `.new(arguments)` or `.named(arguments)` has no written type reference, because the shorthand context supplies the static namespace, and its required period and name token already form the complete written selector. It should therefore neither contain `ConstructorReference2` nor manufacture a `ConstructorSelector`; the enclosing `DotShorthandConstructorInvocation` directly owns its period, required name token, optional type arguments, and argument list.

The useful common resolved fact is the selected substituted `ConstructorElement`, and at present that fact does not justify either `ConstructorSelectionResolution` or `ConstructorInvocationResolution`. A valid selection wrapper containing only an element adds indirection, while its proposed invalid subtype adds speculative candidate and recovery data without a concrete client. The established nullable-element convention is sufficient until invalid constructor references need observably richer behavior: the element is the final substituted constructor when resolution succeeds and is `null` before resolution or when selection fails.

For `C<int>(0)`, the useful element is the constructor view whose parameter type is `int` and whose return type is `C<int>`, while indexing, navigation, and declaration identity use `element.baseElement`. This follows the current `ConstructorReference2.element` contract and avoids making every type-sensitive client reconstruct the substitution. Although lookup initially finds a base declaration, the exposed element is the final resolved meaning after explicit or inferred type arguments rather than a transient pre-inference element.

Constructor application currently contributes no additional reusable fact beyond that substituted element. `constructorElement.type` is the effective `FunctionType` used to resolve the argument list, argument-to-parameter correspondence belongs to `ArgumentList`, and argument-count or argument-type diagnostics do not change which constructor was selected. `ConstructorInvocation` and `DotShorthandConstructorInvocation` expose the resulting constructed value through `staticType`; `SuperConstructorInvocation`, `RedirectingConstructorInvocation`, annotations, and enum constants are not expressions and deliberately have no static type. A constructor resolution object should be introduced later only if a concrete case requires independently useful candidates, recovery selection, or an application signature that demonstrably differs from `constructorElement.type`.

The directly represented constructor-application sites are:

```dart
ConstructorInvocation
DotShorthandConstructorInvocation
SuperConstructorInvocation
RedirectingConstructorInvocation
constructor-form Annotation
EnumConstantDeclaration
```

All six should expose the same final substituted-constructor fact even though their source children differ. `ConstructorInvocation` writes a type reference and optional selector. Dot shorthand obtains its type namespace from context and always writes a name after the period. `SuperConstructorInvocation` searches the instantiated superclass and has an optional selector. `RedirectingConstructorInvocation` searches the current instantiated class and has an optional selector. A constructor-form annotation writes an annotation constructor designation and is subject to constant-expression restrictions. An enum constant obtains its enclosing enum type implicitly, has an optional written selector and argument suffix, and supplies the language-defined implicit leading `index` and `name` arguments. Constness, redirect-cycle checks, superclass restrictions, and enum-specific implicit arguments remain responsibilities of the enclosing source roles rather than different constructor resolution payloads.

The selected enum constructor must belong to `EnumConstantDeclaration`, not to `EnumConstantArguments`, because the argument suffix is optional while the invocation is not:

```dart
enum E {
  first,
  second.named(0);

  const E();
  const E.named(int value);
}
```

Both `first` and `second.named(0)` invoke constructors, but only the latter necessarily has an `EnumConstantArguments` child. `EnumConstantDeclaration.constructorElement` contains the substituted enum constructor, whose type is the effective invocation signature; the optional child preserves only the written type arguments, selector, and explicit argument list. The current analyzer already derives this element from a synthetic `ConstructorInvocation` stored as the enum field's constant initializer, so keeping it on the source declaration makes an existing semantic relationship directly available instead of requiring clients to navigate through synthetic element-model state.

`Annotation` is currently a union-like source node because it can represent both a constant reference such as `@someConstant` and a constructor application such as `@C.named(0)`. If that structure remains, a typed nullable `constructorElement` getter can expose the substituted constructor only for the constructor form, while its existing broader element result continues to represent constant references. A future split into `ConstantReferenceAnnotation` and `ConstructorInvocationAnnotation` would let the latter participate directly in a common constructor-invocation-site API.

A small shared capability may be useful for semantic clients without pretending that the six source nodes share an argument-list or constructor-reference topology:

```dart
abstract interface class ConstructorInvocationSite
    implements AstNode {
  ConstructorElement? get constructorElement;
}
```

For ordinary `ConstructorInvocation`, `constructorElement` can be a convenience getter delegating to `constructorReference.element`; dot shorthand, `super`, `this`, annotations, and enum declarations can expose the element they already resolve at their own source site. Whether this interface is public AST API, an internal indexing adapter, or unnecessary once the general reference-site service exists remains open. In particular, a union-like `Annotation` might not implement it until annotations are structurally split. An omitted implicit `super()` has no source AST node and should continue to be represented in the constructor element model rather than causing insertion of a synthetic constructor-invocation AST node.

Direct `prefix.f()` uses `ImportPrefixedFunctionInvocation`: the `ImportPrefixReference` owns `prefix.`, while the invocation owns `f`, optional type arguments, and the argument list. In contrast, an imported getter used as `prefix.getter()` resolves to `CallInvocation` whose receiver is an `ImportPrefixedNameExpression`.

Null shortening applies to the whole selector chain. In `object?.getter()`, resolution lowers the getter read followed by arguments to a `CallInvocation`, and the existing null-shorting resolver protocol continues through the call receiver so that a null receiver skips both the getter and the call rather than producing null and then attempting to invoke it. Canonical V2 needs no `NullShortingExpression` and no invocation-resolution metadata for this fact: resolver calls that analyze receiver-like children with null shorting continued already delimit the guarded chain and assign the nullable result type when the chain terminates. Lowering only has to route those existing calls through the new property, invocation, index, target, increment/decrement, and cascade child roles without accidentally terminating the active region. Invalid `prefix?.f()` cannot create `ImportPrefixReference`; it retains an invalid expression receiver, reports `prefixIdentifierNotFollowedByDot`, preserves the imported function only as recovery data, and has canonical `InvalidType`.

Cascade invocation uses `CascadeMethodInvocation`, corresponding to the proposed cascade property and index nodes. In `target..m()`, the cascade section owns `..`, the invocation owns `m`, the name is resolved against the cascade target, and the section performs direct method invocation without inventing a repeated `target` expression. A chain such as `target..getter()()` has a cascade-start getter read followed by one or more `CallInvocation` nodes inside the same section. Anonymous methods use the corresponding ordinary-versus-cascade structural split described in Section 9.9.

### 9.5 Dot shorthand

A dot shorthand omits the declaration that supplies a static namespace. In `Color color = .red`, the contextual type `Color` supplies the missing `Color` in `Color.red`; this is not an implicit receiver object and does not mean `color.red`. The shorthand context belongs to the entire maximal shorthand selector chain, so in `int value = .parse(input).abs()` the context `int` selects `int.parse` at the head even though the head invocation itself already returns `int` and the chain continues through the ordinary instance method `abs`.

Resolution can be understood as four steps. First, determine the shorthand context for the maximal selector chain using the surrounding assignment, argument, return, operator, or other context rules. Second, normalize that context to the usable interface type whose static namespace is searched; nullable and other supported context forms may require language-specified normalization, while a missing, dynamic, type-variable, function, record, or otherwise unusable context produces a diagnostic. Third, resolve the leading `.name`, optional type arguments, and optional arguments against that static namespace and lower the parser-neutral head to a name expression, function invocation, or constructor invocation. Fourth, analyze every selector after that leading operation as an ordinary selector on the value produced so far. This division is important because only the first operation uses the normalized lookup type's static namespace.

The resolved leading operation has three possible structural forms:

```dart
sealed interface class DotShorthandExpression
    implements Expression {
  Token get period;
  Token get name; // Includes the new token.
  DotShorthandContextResolution? get shorthandContext;
}

final class DotShorthandNameExpression
    implements NameExpression, DotShorthandExpression {}

// DotShorthandMethodInvocation, declared in 9.1, is the invocation form.

final class DotShorthandConstructorInvocation
    implements DotShorthandExpression {
  Token? get constKeyword;
  TypeArgumentList? get typeArguments;
  ArgumentList get argumentList;
  ConstructorElement? get constructorElement;
}

sealed interface class DotShorthandContextResolution {}

final class ValidDotShorthandContextResolution
    implements DotShorthandContextResolution {
  DartType get contextType;
  InterfaceType get lookupType;
}

final class InvalidDotShorthandContextResolution
    implements DotShorthandContextResolution {
  DartType? get contextType;
}
```

Implementation status (2026-08-15): the three resolved leading operations now
have canonical V2 nodes. `DotShorthandNameExpression` covers a bare shorthand
name, getter read, method tear-off, or constructor tear-off and projects to V1
`DotShorthandPropertyAccess`. `DotShorthandMethodInvocation` covers direct
static method invocation and projects to V1 `DotShorthandInvocation`. Direct
constructor invocation uses the transitional public name
`DotShorthandConstructorInvocation2` because V1 still occupies the unsuffixed
name; it owns the constructor-name token and selected substituted constructor
and projects to V1 `DotShorthandConstructorInvocation`. The parser still builds
the legacy constructor shape transiently before resolution replaces it, and
shorthand context still uses the existing resolver stack and `isDotShorthand`
marker. The common `DotShorthandExpression` interface, explicit context
resolution, and parser-neutral `ParsedDotShorthandExpression` lowering remain
later migration work.

`ValidDotShorthandContextResolution.contextType` records the type supplied at the maximal shorthand boundary before dot-shorthand-specific normalization. Its `lookupType` is the usable interface type whose static namespace is searched. For example, a `FutureOr<C>` context has `contextType: FutureOr<C>` and `lookupType: C`. The namespace declaration is derivable as `lookupType.element` and is not duplicated in the resolution API. `InvalidDotShorthandContextResolution` represents a resolved missing or unusable context and retains the supplied `DartType` when one exists; a null `contextType` means that no context type was available. No public failure enum is needed without a client that must distinguish invalid-context causes independently of diagnostics.

A valid context whose namespace lacks the requested member is not an invalid context resolution. It retains `ValidDotShorthandContextResolution` and records the failed member selection in the ordinary named-read or invocation resolution, or as a null constructor element until constructor selection acquires a richer invalid result. The selected field, getter, or method remains in the ordinary named-read or invocation resolution of the concrete source node, while `DotShorthandConstructorInvocation.constructorElement` directly exposes a selected substituted constructor. A bare `.name` or `.new` always uses `DotShorthandNameExpression`; its `NamedReadResolution` distinguishes a direct value read, getter invocation, static method tear-off, and constructor tear-off without changing the source node kind.

The simplest value example is an enum constant:

```dart
enum Color { red, blue }

void main() {
  Color color = .red;
  print(color);
}
```

The initializer context is `Color`, so the shorthand context declaration is the enum `Color`. Lookup of `red` in its static namespace selects the enum constant, and the leading operation lowers to `DotShorthandNameExpression` with `GetterInvocationResolution` for `Color.red` and static type `Color`:

```dart
DotShorthandNameExpression
  period: .
  name: red
  shorthandContext:
    ValidDotShorthandContextResolution
      contextType: Color
      lookupType: Color
  resolution: GetterInvocationResolution
    element: Color.red
    invokeType: Color Function()
    type: Color
  staticType: Color
```

The same node covers a static field or getter read, a static method tear-off, and a constructor tear-off. `GetterInvocationResolution` and `ExecutableTearOffResolution` distinguish the operations, while the selected executable distinguishes a method from a constructor; the AST does not need one dot-shorthand class per selected declaration kind.

Here is a complete non-generic static method tear-off example:

```dart
void main() {
  int value = .parse.call('42');
  print(value);
}
```

The maximal selector chain has context `int`, which supplies the static namespace of `int`. Because no argument list occurs immediately after `parse`, the head reads the tear-off of `int.parse` using `DotShorthandNameExpression` with `ExecutableTearOffResolution`. The following `.call('42')` is an ordinary receiver-qualified invocation on that function value and gives the whole chain type `int`:

```dart
ReceiverMethodInvocation
  receiver:
    DotShorthandNameExpression
      period: .
      name: parse
      shorthandContext:
        ValidDotShorthandContextResolution
          contextType: int
          lookupType: int
      resolution: ExecutableTearOffResolution
        element: int.parse
        type: int Function(String, {int? radix})
      staticType: int Function(String, {int? radix})
  operator: .
  name: call
  argumentList: ('42')
  staticType: int
```

This is primarily a structural example; `int value = .parse('42')` is clearer and instead lowers directly to `DotShorthandMethodInvocation`. The later `.identity<Functions>.call(Functions())` example is the generic counterpart: method tear-off, `FunctionInstantiation`, and then ordinary invocation.

A direct static method invocation has its own invocation node:

```dart
class Point {
  final int x;
  final int y;

  const Point(this.x, this.y);

  static Point origin() => const Point(0, 0);
}

void main() {
  Point point = .origin();
  print(point.x);
}
```

The initializer supplies context `Point`, lookup selects the static method `Point.origin`, and the written arguments belong directly to `DotShorthandMethodInvocation`:

```dart
DotShorthandMethodInvocation
  period: .
  name: origin
  argumentList: ()
  shorthandContext:
    ValidDotShorthandContextResolution
      contextType: Point
      lookupType: Point
  resolution: ExecutableInvocationResolution
    element: Point.origin
    invokeType: Point Function()
    type: Point
  staticType: Point
```

Constructors use constructor-specific nodes rather than static function invocation:

```dart
class Point {
  final int x;
  final int y;

  const Point(this.x, this.y);
  const Point.origin() : this(0, 0);
}

void main() {
  Point a = .new(1, 2);
  Point b = .origin();
  print(a.x + b.x);
}
```

Both initializers have shorthand context `Point`. Lookup of `new` selects the unnamed constructor and lookup of `origin` selects the named constructor, so both heads become `DotShorthandConstructorInvocation`; the `new` token is simply the constructor name token owned by the first node:

```dart
DotShorthandConstructorInvocation
  period: .
  name: origin
  argumentList: ()
  shorthandContext:
    ValidDotShorthandContextResolution
      contextType: Point
      lookupType: Point
  resolution:
    element: Point.origin
  staticType: Point
```

A bare constructor name produces a constructor tear-off, but this is a completeness case rather than a motivating dot-shorthand use case. The tear-off normally has a function type rather than the contextual class type, so a useful well-typed chain must consume it or otherwise transform it back to the contextual result:

```dart
class Point {
  final int x;

  const Point.named(this.x);
}

void main() {
  Point point = .named.call(0);
  print(point.x);
}
```

The context of the entire maximal selector chain is `Point`, so lookup of `named` selects `Point.named`. There is no argument list immediately after `named`, so `DotShorthandNameExpression` has `ExecutableTearOffResolution`, a `ConstructorElement`, and static type `Point Function(int)`. The following ordinary `.call(0)` invokes that function and gives the entire chain static type `Point`. Writing `.named(0)` would of course be clearer; this example exists only to show that constructor tear-off is a reachable resolution of the same bare shorthand name syntax used by fields, getters, and static method tear-offs:

```dart
ReceiverMethodInvocation
  receiver:
    DotShorthandNameExpression
      period: .
      name: named
      shorthandContext:
        ValidDotShorthandContextResolution
          contextType: Point
          lookupType: Point
      resolution: ExecutableTearOffResolution
        element: Point.named
        type: Point Function(int)
      staticType: Point Function(int)
  operator: .
  name: call
  argumentList: (0)
  staticType: Point
```

An argument list after the shorthand name does not by itself imply direct static invocation. If lookup selects a getter or field whose value is callable, the analyzer first represents that value read and then invokes it:

```dart
class CallablePoint {
  final int x;

  const CallablePoint(this.x);

  static CallablePoint get origin => const CallablePoint(0);

  CallablePoint call() => this;
}

void main() {
  CallablePoint point = .origin();
  print(point.x);
}
```

The context still selects the static namespace of `CallablePoint`, but `origin` is a getter rather than a method or constructor. The head therefore becomes `DotShorthandNameExpression`, and the argument list belongs to an outer `CallInvocation` that resolves `CallablePoint.call`:

```dart
CallInvocation
  receiver:
    DotShorthandNameExpression
      period: .
      name: origin
      shorthandContext:
        ValidDotShorthandContextResolution
          contextType: CallablePoint
          lookupType: CallablePoint
      resolution: GetterInvocationResolution
        element: CallablePoint.origin
        invokeType: CallablePoint Function()
        type: CallablePoint
      staticType: CallablePoint
  argumentList: ()
  resolution: ExecutableInvocationResolution
    element: CallablePoint.call
    invokeType: CallablePoint Function()
    type: CallablePoint
  staticType: CallablePoint
```

A standalone type-argument selector similarly applies to the function value produced by the head:

```dart
class Functions {
  static T identity<T>(T value) => value;
}

void main() {
  Functions value = .identity<Functions>.call(Functions());
  print(value);
}
```

The context of the maximal selector chain is `Functions`, so the head reads the static method tear-off `Functions.identity` using `DotShorthandNameExpression` with `ExecutableTearOffResolution`. The written `<Functions>` belongs to an outer `FunctionInstantiation`, and the following ordinary `.call(Functions())` invokes the instantiated function and produces the `Functions` required by the initializer:

```dart
ReceiverMethodInvocation
  receiver:
    FunctionInstantiation
      operand:
        DotShorthandNameExpression
          period: .
          name: identity
          shorthandContext:
            ValidDotShorthandContextResolution
              contextType: Functions
              lookupType: Functions
          resolution: ExecutableTearOffResolution
            element: Functions.identity
            type: T Function<T>(T)
          staticType: T Function<T>(T)
      typeArguments: <Functions>
      staticType: Functions Function(Functions)
  operator: .
  name: call
  argumentList: (Functions())
  staticType: Functions
```

When type arguments are immediately followed by arguments, a selected static function instead keeps both lists in the direct invocation:

```dart
class Factory {
  static Factory make<T>(T value) => Factory();
}

void main() {
  Factory factory = .make<int>(0);
  print(factory);
}
```

This becomes one `DotShorthandMethodInvocation` with `typeArguments: <int>` and `argumentList: (0)`. A selected getter or field would instead produce `CallInvocation` with both lists, following the same direct-invocation versus callable-value distinction used without dot shorthand.

Constructor syntax deliberately has different precedence. The following complete program is invalid:

```dart
class C {
  const C();
  const C.named();
}

void main() {
  C a = .new<int>();
  C b = .named<int>();
  C c = .new<int>.call();
  C d = .named<int>.call();
  print((a, b, c, d));
}
```

The first two heads resolve as constructor invocations and report `wrong_number_of_type_arguments_constructor`; they are not reinterpreted as function instantiation followed by invocation. In the last two initializers, the maximal chain context `C` selects constructor tear-offs at `.new<int>` and `.named<int>`, after which `.call()` is an ordinary selector. The current analyzer reports `wrong_number_of_type_arguments_function` because the selected constructor functions have no type parameters. `DotShorthandConstructorInvocation.typeArguments` preserves the invalid written tokens in the invocation cases. The exact canonical recovery owner for invalid standalone `.new<int>` and `.named<int>` remains open.

Selectors after the leading operation use ordinary canonical nodes. The following program demonstrates an ordinary method selector after the shorthand invocation:

```dart
void main() {
  int value = .parse('-3').abs();
  print(value);
}
```

The context of the entire maximal chain is `int`, so the head lookup selects the static method `int.parse` and lowers `.parse('-3')` to `DotShorthandMethodInvocation`. Its result has type `int`; `.abs()` is then analyzed normally as `ReceiverMethodInvocation` on that result. The outer invocation does not carry an `isDotShorthand` flag:

```dart
ReceiverMethodInvocation
  receiver:
    DotShorthandMethodInvocation
      period: .
      name: parse
      argumentList: ('-3')
      shorthandContext:
        ValidDotShorthandContextResolution
          contextType: int
          lookupType: int
      resolution: ExecutableInvocationResolution
        element: int.parse
        invokeType: int Function(String, {int? radix})
        type: int
      staticType: int
  operator: .
  name: abs
  argumentList: ()
  resolution: ExecutableInvocationResolution
    element: int.abs
    invokeType: int Function()
    type: int
  staticType: int
```

Indexing, cascades, and null-aware access follow the same rule:

```dart
class Box {
  static final zero = Box();

  Box operator [](int index) => this;
}

class Builder {
  int value = 0;

  void setValue(int value) {
    this.value = value;
  }
}

class Link {
  final Link? next;

  const Link(this.next);

  static Link? get nullable => null;
}

void main() {
  Box box = .zero[0];
  Builder builder = .new()..setValue(3);
  Link? link = .nullable?.next;
  print((box, builder.value, link));
}
```

For `Box box = .zero[0]`, the maximal chain context `Box` selects the static field `Box.zero`, producing `DotShorthandNameExpression`, and `[0]` becomes an ordinary `ReceiverIndexExpression`. For `Builder builder = .new()..setValue(3)`, context `Builder` selects its unnamed constructor, producing `DotShorthandConstructorInvocation`, which is the ordinary target of `CascadeExpression`. For `Link? link = .nullable?.next`, the supported nullable context identifies the `Link` declaration, the head reads `Link.nullable`, and the following `?.next` is an ordinary null-shortened property access. None of the outer index, cascade, or property nodes needs dot-shorthand metadata; a syntax-oriented helper can find the explicit inner `DotShorthandExpression`.

The maximal-chain rule creates boundaries that are not obvious from the first token. These are complete valid examples:

```dart
class C {
  const C();

  static const zero = C();

  C operator +(C other) => this;
}

void main() {
  C a = (.zero);
  int b = .parse('-3').abs();
  bool c = const C() == .zero;
  C d = const C() + .zero;
  print((a, b, c, d));
}
```

In `C a = (.zero)`, parentheses wrap the entire shorthand chain and ordinary downward context reaches `.zero`; under the analyzer package options this line also produces the style lint `unnecessary_parenthesis`, but it is semantically valid and is retained solely to demonstrate the context boundary. In the `int` initializer, the context applies to the entire `.parse(...).abs()` chain and reaches its shorthand head. In the equality, the special rule gives context `C` only to the immediate shorthand right operand. In the addition, the selected `C.operator+` parameter supplies context `C` to the right operand.

The superficially similar forms in the following complete program are invalid:

```dart
class C {
  const C();

  static const zero = C();

  C get next => this;

  C operator +(C other) => this;
}

void main() {
  C a = (.zero).next;
  int b = (.parse('-3')).abs();
  bool c = const C() == (.zero);
  bool d = .zero == const C();
  C e = .zero + const C();
  print((a, b, c, d, e));
}
```

In `(.zero).next`, the parentheses end the shorthand selector chain before `.next`, so the outer initializer context does not select the namespace for `.zero`; the analyzer reports `dot_shorthand_missing_context`. In `(.parse('-3')).abs()`, the parenthesized head is analyzed with an unknown `_` context rather than the outer `int` chain context, so current analysis reports `dot_shorthand_undefined_member` for `parse` on `_`. In `const C() == (.zero)`, the immediate equality right operand is `ParenthesizedExpression`, not the shorthand, so the special equality context rule does not apply and analysis reports `dot_shorthand_missing_context`. The equality rule is asymmetric, so the shorthand left operand in `.zero == const C()` also lacks context. Finally, the result context of `.zero + const C()` does not flow into the binary left operand, which likewise reports `dot_shorthand_missing_context`.

The parser cannot know whether `.name(arguments)` selects a static method, a constructor, or a getter or field followed by `call`, and it cannot know whether bare `.name` is a value read, method tear-off, or constructor tear-off. This is another controlled use of parser-only neutral syntax, but it has a larger contextual boundary than its ambiguous island. The parser wraps the complete `<staticMemberShorthand>` production in `ParsedDotShorthandExpression`; its `expression` child is built using ordinary structurally known nodes around the same small `ParsedExpressionChain` islands used elsewhere, and the leading island has `ParsedDotShorthandHead`. Resolution receives the shorthand context for the wrapper, routes it through the ordinarily structured selector expression to that head, selects and lowers the leading operation into one of the three canonical nodes, preserves the original tokens, ranges, and stable outer-node identities, installs the resolved child in the wrapper's former parent slot, and eliminates the wrapper and every parsed-chain node before exposing the resolved AST. Bare value, getter, method-tear-off, and constructor-tear-off interpretations all lower to `DotShorthandNameExpression`; only the resolution payload changes.

For example, the stable index in the following complete program does not acquire a parsed counterpart:

```dart
class C {
  static List<int> get values => [1, 2, 3];
}

void main() {
  int value = .values[0];
  print(value);
}
```

The parse-time V2 tree is:

```dart
ParsedDotShorthandExpression
  expression:
    ReceiverIndexExpression
      receiver:
        ParsedExpressionChain
          head:
            ParsedDotShorthandHead
              period: .
              name: values
      index: IntegerLiteral(0)
```

The initializer context belongs to the outer `ParsedDotShorthandExpression`, while `ParsedDotShorthandHead` identifies where that context supplies the omitted static namespace. Resolution replaces the inner one-head chain with `DotShorthandNameExpression`, retains the existing `ReceiverIndexExpression` and index literal, and then removes the outer wrapper:

```dart
ReceiverIndexExpression
  receiver:
    DotShorthandNameExpression
      period: .
      name: values
      shorthandContext:
        ValidDotShorthandContextResolution
          contextType: int
          lookupType: int
      resolution: InvalidNamedReadResolution
  index: IntegerLiteral(0)
```

This particular program is invalid because the shorthand context is `int`, so lookup attempts `int.values`; the final index result being expected to have type `int` does not instead select `C.values`. The tree deliberately demonstrates both maximal-chain context routing and preservation of an unambiguous index node. A corresponding valid example uses a declaration whose static namespace is denoted by the final context:

```dart
class C {
  static List<C> get values => const [];
}

void main() {
  C value = .values[0];
  print(value);
}
```

Here the same parse topology lowers to `ReceiverIndexExpression(DotShorthandNameExpression(.values), 0)`, with shorthand context `C` and a getter resolution selecting `C.values`.

A no-token `StaticQualifier` should not be inserted. The omitted namespace is context-derived resolution information rather than a written qualifier occurrence, and the dedicated shorthand node already owns the leading period and name. Keeping `StaticQualifier` source-shaped avoids creating navigation or source ranges for a qualifier that the user did not write.

Dot shorthand has no valid assignment-target form. This complete program is invalid:

```dart
class C {
  const C();

  static const zero = C();

  C get next => this;
  set next(C value) {}

  C operator [](int index) => this;
  void operator []=(int index, C value) {}
}

void write(C value) {
  .zero = value;
  .zero.next = value;
  .zero[0] = value;
}

void main() {
  write(const C());
}
```

The direct assignment reports `dot_shorthand_missing_context`, `illegal_assignment_to_non_assignable`, and `missing_assignable_selector`: the shorthand head itself is not an assignment target. The property and index forms can be parsed as ordinary outer targets, but assignment-target context does not supply a shorthand context to their `.zero` receiver, so each reports `dot_shorthand_missing_context`. Recovery can use an ordinary `ReceiverPropertyAssignmentTarget` or `ReceiverIndexAssignmentTarget` containing a canonical invalid shorthand receiver; there is no `DotShorthandAssignmentTarget`.

### 9.6 Ordinary function and method tear-offs

An ordinary function or method tear-off does not need a general `FunctionTearOff` node. The same name or property source form can instead produce a variable value, invoke a getter, tear off an executable, or be invalid, so the selected operation belongs in `NamedReadResolution`. A type declaration selected in a value-producing role instead lowers to the structurally distinct `TypeLiteral` described in section 5.2:

```dart
f
  UnqualifiedNameExpression
    resolution: ExecutableTearOffResolution
      element: FunctionElement(f)
      type: ...

object.method
  ReceiverPropertyExtraction
    receiver: UnqualifiedNameExpression(object)
    name: method
    resolution: ExecutableTearOffResolution
      element: MethodElement(method)
      type: ...

C.method
  ReceiverPropertyExtraction
    receiver: StaticQualifier(C)
    name: method
    resolution: ExecutableTearOffResolution
      type: ...

prefix.f
  ImportPrefixedNameExpression
    resolution: ExecutableTearOffResolution
      type: ...
```

This keeps the distinction between `object.method`, which has `ExecutableTearOffResolution`, `object.getter`, which has `GetterInvocationResolution` and may return a function value, and `variable`, which has `VariableReadResolution` and may contain a function value. All three expressions can have function types, but their concrete named-read resolutions expose different operations and payloads. Unqualified instance methods, extension methods, extension-type methods, static methods, imported functions, `super.method`, and `E(object).method` follow the same source-shaped rule with the receiver and lookup differences represented by their enclosing node and resolution. Ordinary constructor tear-offs remain a concrete structural exception because `C.new`, `C.named`, and their qualified and instantiated variants contain `ConstructorTypeReference` and `ConstructorSelector`. Dot shorthand has neither child: `.named` already owns its only name token, so a constructor selected there remains `DotShorthandNameExpression` with `ExecutableTearOffResolution`.

The current analyzer name `FunctionReference` obscures this distinction. A plain non-generic tear-off normally remains a `SimpleIdentifier`, `PrefixedIdentifier`, or `PropertyAccess`; the parser creates `FunctionReference` for a standalone `<typeArguments>` selector, and resolution can additionally insert one with no written type arguments for context-induced generic function instantiation. V2 should not preserve that name for ordinary tear-offs merely because the current API documentation describes it broadly.

### 9.7 Explicit function instantiation

The constructor-tear-offs feature specification treats a standalone `<typeArguments>` as a postfix selector and permits it to instantiate arbitrary generic function values, not only tear-offs of declarations. The canonical V2 node should therefore describe the operation rather than a reference:

```dart
final class FunctionInstantiation implements Expression {
  Expression get operand;
  TypeArgumentList get typeArguments;
  List<DartType>? get typeArgumentTypes;
}
```

`FunctionInstantiation` is the current preferred name; `GenericFunctionInstantiation` remains a possible more explicit alternative. It does not need an `Expression` suffix. Its `typeArguments` is required because this canonical node represents a written instantiation selector. After resolution its operand is the function-valued expression being instantiated, and the operand's `staticType` is the uninstantiated generic function type while the outer node's `staticType` is the instantiated result. If the written operand is an ordinary callable object rather than already a function value, resolution inserts the no-token `ImplicitCallTearOff` adaptation described below between the object expression and `FunctionInstantiation`. Standalone `super<int>` and `E(object)<int>` are invalid; invalid parsed chains still need canonical recovery that preserves the type-argument tokens without broadening the valid operand contract.

```dart
f<int>
  FunctionInstantiation
    operand: UnqualifiedNameExpression(f)
    typeArguments: <int>
    typeArgumentTypes: [int]

object.method<int>
  FunctionInstantiation
    operand: ReceiverPropertyExtraction(object.method)
    typeArguments: <int>
    typeArgumentTypes: [int]

(functionExpression)<int>
  FunctionInstantiation
    operand: ParenthesizedExpression(functionExpression)
    typeArguments: <int>
    typeArgumentTypes: [int]

callableObject<int>
  FunctionInstantiation
    operand: ImplicitCallTearOff
      operand: UnqualifiedNameExpression(callableObject)
      element: MethodElement(call)
    typeArguments: <int>
    typeArgumentTypes: [int]
```

The operand owns any written reference that produced its value. In `f<int>`, the name occurrence references `f`, while the outer instantiation introduces no second named reference. In `callableObject<int>`, `ImplicitCallTearOff` records the selected `call` method because that reference has no written member-name token. The nested structure makes a separate `FunctionInstantiationKind`, `uninstantiatedType`, or optional `implicitCallElement` unnecessary: the operand type, adaptation node, resolved actual types, and outer static type expose those facts directly. Invalid and recovery details remain provisional.

The same token shape does not always produce this node. If `F` denotes a class, mixin, or type alias, standalone `F<int>` lowers to `TypeLiteral` containing `NamedType(F<int>)`; if `f` denotes a function or function-valued expression, `f<int>` lowers to `FunctionInstantiation`. A following constructor selector instead incorporates the type arguments into `ConstructorTypeReference`. This is another case where the parser must retain `ParsedTypeArguments` until name resolution selects the source role.

When a type-argument selector is immediately followed by an argument list, the language chooses direct invocation rather than function instantiation followed by invocation. The invocation node owns both lists:

```dart
f<int>
  FunctionInstantiation

f<int>()
  UnqualifiedFunctionInvocation or CallInvocation
    typeArguments: <int>
    argumentList: ()

(f<int>)()
  CallInvocation
    receiver: ParenthesizedExpression
      FunctionInstantiation(f<int>)
    argumentList: ()

object.method<int>()
  ReceiverMethodInvocation
    typeArguments: <int>
    argumentList: ()

object.getter<int>()
  CallInvocation
    receiver: ReceiverPropertyExtraction(object.getter)
    typeArguments: <int>
    argumentList: ()
```

Constructor syntax has additional deliberate precedence rules:

```dart
C<int>.named
  ConstructorTearOff
    typeReference owns <int>

C.named<int>
  invalid constructor-reference instantiation

(C.named)<int>
  FunctionInstantiation
    operand: ParenthesizedExpression(ConstructorTearOff)

C.named<int>(arguments)
  invalid ConstructorInvocation

(C.named)<int>(arguments)
  CallInvocation
    receiver: ParenthesizedExpression(ConstructorTearOff)
    typeArguments: <int>
    argumentList: (arguments)
```

`C.named<int>` is not interpreted as instantiating the generic function value produced by the constructor tear-off; the syntax is reserved for possible generic constructors, and parentheses are required to select ordinary function-value instantiation. Similarly, `C.named<int>(arguments)` remains a constructor invocation with invalid constructor type arguments rather than being reinterpreted as tear-off, instantiation, and call. These rules complement the earlier rule that `C<int>.named` places the type arguments in `ConstructorTypeReference`.

Cascades can contain explicit instantiation selectors. For `receiver..method<int>`, the cascade section begins with its ordinary `..method` property extraction and a `FunctionInstantiation` applies to the resulting cascade-start expression; `<int>` cannot itself begin a cascade section. Null-shortened forms such as `receiver?.method<int>` keep the instantiation within the existing resolver-managed null-shorting region by continuing that region through the instantiation operand; no additional AST container or resolution payload is required.

### 9.8 No-token semantic adaptations

Context-induced generic function instantiation and implicit `call` tear-off should use sparse resolver-inserted semantic adaptation expressions rather than almost-always-null contextual metadata on every expression:

```dart
T id<T>(T value) => value;

int Function(int) a = id;
int Function(int) b = someGenericFunctionValue;
int Function(int) c = CallableObject();
```

```dart
sealed interface class SemanticAdaptation implements Expression {
  Expression get operand;
}

final class ImplicitCallTearOff
    implements SemanticAdaptation {
  Expression get operand;
  MethodElement get element;
}

final class ImplicitFunctionInstantiation
    implements SemanticAdaptation {
  Expression get operand;
  List<DartType> get typeArgumentTypes;
}
```

`SemanticAdaptation` is a possible internal common marker rather than necessarily a public abstraction. The important API is in the two concrete operations. They are resolution-only `Expression` nodes with no tokens of their own, delegate their source range to the operand, and are inserted only when the corresponding language operation occurs. They are not subclasses for each declaration or lookup result: ordinary local, top-level, static, instance, extension, and extension-type tear-offs remain source-shaped expressions with resolution data. These two nodes instead represent distinct value transformations that can compose and that have different types, elements, reference behavior, and evaluation semantics.

For the examples above, assuming `CallableObject.call` is generic, the resolved trees are:

```dart
int Function(int) a = id

ImplicitFunctionInstantiation
  operand: UnqualifiedNameExpression(id)
    resolution: ExecutableTearOffResolution
      type: T Function<T>(T)
    staticType: T Function<T>(T)
  typeArgumentTypes: [int]
  staticType: int Function(int)

int Function(int) b = someGenericFunctionValue

ImplicitFunctionInstantiation
  operand: UnqualifiedNameExpression(someGenericFunctionValue)
    resolution: VariableReadResolution
      type: T Function<T>(T)
    staticType: T Function<T>(T)
  typeArgumentTypes: [int]
  staticType: int Function(int)

int Function(int) c = CallableObject()

ImplicitFunctionInstantiation
  operand: ImplicitCallTearOff
    operand: ConstructorInvocation(CallableObject())
      staticType: CallableObject
    element: CallableObject.call
    staticType: T Function<T>(T)
  typeArgumentTypes: [int]
  staticType: int Function(int)
```

If `call` is already non-generic and its tear-off type satisfies the context, only `ImplicitCallTearOff` is inserted. If an expression already has a generic function type, only `ImplicitFunctionInstantiation` is inserted. If a callable object has a generic `call` method, the two nested nodes expose the actual order: first produce the bound `call` function, then instantiate that generic function. Each intermediate static type belongs to the expression that produces it, so no duplicated `uninstantiatedType` field or optional contextual-adaptation payload is needed.

The same `ImplicitCallTearOff` is useful for explicit `callableObject<int>` as shown above. The written `FunctionInstantiation` remains a source node owning `<int>`, while the inserted adaptation makes its operand genuinely function-valued and owns the implicit reference to `call`. This keeps explicit and contextual implicit-`call` selection consistent without requiring a tagged instantiation-resolution payload.

These operations can apply to arbitrary expressions, including index expressions, conditionals, assignments, invocations, and function literals, which is why name- or property-specific metadata would be insufficient. The current analyzer uses multiple mechanisms: it can insert a `FunctionReference` with `typeArguments == null`, store inferred tear-off type arguments on a `SimpleIdentifier`, or insert an `ImplicitCallReference`. V2 replaces that distribution with semantic adaptation nodes while retaining V1 compatibility projections where necessary.

Because an adaptation has no independent source syntax, syntax-oriented behavior must treat it as transparent. `beginToken`, `endToken`, offset, length, and source text delegate to the operand; `toSource`, formatting, comment ownership, token traversal, and ordinary covering-node queries descend through it; semantic visitors, resolved AST printers, constant evaluation, indexing, and navigation can observe it. Resolver insertion must finish before a resolved V2 unit is exposed, and parent replacement, flow-analysis keys, serialization, and cached V1 projections must be synchronized atomically.

Placement is operation-specific rather than one open policy shared by both adaptations. Context-induced generic function instantiation occurs at the expression occurrence inferred with the relevant function context. The inference-update-3 rule for a conditional `condition ? e1 : e2` with context `K` infers both `e1` and `e2` with `K`, so generic function values selected directly in the branches are instantiated independently:

```dart
T id<T>(T value) => value;

int Function(int) choose(bool condition) {
  return condition ? id : id;
}

ConditionalExpression
  thenExpression:
    ImplicitFunctionInstantiation
      operand: UnqualifiedNameExpression(id)
        staticType: T Function<T>(T)
      typeArgumentTypes: [int]
      staticType: int Function(int)
  elseExpression:
    ImplicitFunctionInstantiation
      operand: UnqualifiedNameExpression(id)
        staticType: T Function<T>(T)
      typeArgumentTypes: [int]
      staticType: int Function(int)
  staticType: int Function(int)
```

The current analyzer already represents this with one inserted no-written-type-arguments `FunctionReference` in each branch, so V2 should not move the two operations to one `ImplicitFunctionInstantiation` around the conditional result. Parentheses preserve the context passed to their contained expression and likewise do not by themselves move an instantiation to a different semantic occurrence. Assignments, collection elements, arguments, returns, switch-expression cases, and other positions should follow their specified contextual-inference rules rather than an AST-wide placement convention.

Implicit `call` tear-off is a different coercion with different placement behavior. The current implementations deliberately suppress it in several subexpression positions, including the branches of a conditional, and apply it to the resulting larger value when appropriate:

```dart
abstract class Callable {
  void call();
}

void Function() choose(
  bool condition,
  Callable first,
  Callable second,
) {
  return condition ? first : second;
}

ImplicitCallTearOff
  operand:
    ConditionalExpression
      thenExpression: UnqualifiedNameExpression(first)
        staticType: Callable
      elseExpression: UnqualifiedNameExpression(second)
        staticType: Callable
      staticType: Callable
  element: Callable.call
  staticType: void Function()
```

`tests/language/call/implicit_tearoff_exceptions_test.dart` explicitly records that this implemented conditional, cascade, and if-null behavior does not match the language specification and is protected pending an official decision. The `ImplicitCallTearOff` node remains the right representation of the coercion, including its implicit reference to `call`, but its canonical placement must follow the eventual language decision rather than being derived from the placement of `ImplicitFunctionInstantiation`. If an outer implicit `call` tear-off produces a generic function that is then context-instantiated, `ImplicitFunctionInstantiation` wraps that outer tear-off in the actual operation order.

### 9.9 Anonymous methods

Anonymous methods are an experimental language feature specified in `working/0260-anonymous-methods`. They are expressions that evaluate a receiver exactly once and immediately execute a written expression or block with that receiver available either as a rebound `this` or as one explicit parameter:

```dart
receiver.=> expression
receiver.{ statements }
receiver.(parameter) => expression
receiver.(parameter) { statements }
```

The four null-aware forms replace `.` with `?.`, and the eight cascade forms use `..` or `?..`. The parameter list, when present, must contain exactly one required positional parameter. An untyped parameter receives the receiver's static type, an explicitly typed parameter requires the receiver type to be assignable to the annotation, and a null-aware form binds the non-null form of the receiver type. The no-parameter forms instead make `this` denote the receiver and give it the corresponding receiver type. The body executes immediately rather than being captured in a closure.

Despite the language name, `AnonymousMethodInvocation` is not a `FunctionInvocation`. It has no function value, selected executable, method name, type arguments, argument list, or implicit `call` lookup. The written body is the operation being executed. It therefore remains a dedicated `Expression` and does not expose `InvocationResolution`; its receiver and body contain their own ordinary resolutions, its explicit parameter contains its declaration and inferred or written type, and the outer node's `staticType` records the result.

The body has two structurally and semantically useful variants:

```dart
sealed interface class AnonymousMethodBody implements AstNode {}

final class AnonymousExpressionBody
    implements AnonymousMethodBody {
  Token get arrow;
  Expression get expression;
}

final class AnonymousBlockBody
    implements AnonymousMethodBody {
  Block get block;
}
```

An expression body has the static type and runtime value of its expression. A block body has the return type inferred from its direct `return` statements using the rules for a synchronous non-generator function literal; normal completion contributes `Null` and evaluates to null. The context of the whole anonymous-method expression is imposed on the expression body or on every direct returned expression in the block, excluding returns nested inside another function literal or anonymous method. This context also permits an anonymous-method body to contain a leading dot shorthand:

```dart
class Box {
  final int value;

  const Box(this.value);
}

Box makeBox() => 42.=> .new(this);
```

The initializer or return context `Box` reaches `.new(this)` through the anonymous-method expression. Only the leading shorthand operation is structurally special after lowering; the anonymous-method node does not need a propagated `isDotShorthand` flag.

The ordinary source forms use:

```dart
final class AnonymousMethodInvocation
    implements Expression {
  Expression get receiver;
  Token get operator; // . or ?.
  FormalParameterList? get formalParameterList;
  FormalParameter? get receiverFormalParameter;
  AnonymousMethodBody get body;
}
```

The receiver slot is exactly `Expression`, not `NamedReceiver` or `InstanceReceiver`, because the operation captures a runtime value. A class name in `C.{ ... }` can therefore lower to `TypeLiteral(C)` and bind the runtime `Type` object. `SuperReference`, `ExtensionOverride`, `StaticQualifier`, and `ImportPrefixReference` cannot be valid receivers because none produces a value. A complete extension override or bare `super` in this slot uses `InvalidExtensionOverrideExpression` or `InvalidSuperExpression`; type-like and namespace names use their ordinary value or invalid named-read recovery. The valid receiver slot is not widened.

Cascade forms use a separate structural node:

```dart
final class CascadeAnonymousMethodInvocation
    implements Expression {
  FormalParameterList? get formalParameterList;
  FormalParameter? get receiverFormalParameter;
  AnonymousMethodBody get body;
}
```

The enclosing `CascadeSection` owns `..` or `?..` and supplies the once-evaluated cascade target. The cascade anonymous-method node does not have a nullable receiver, does not search its ancestors through `realTarget`, and does not duplicate the cascade operator. The anonymous body result is ignored when computing the whole `CascadeExpression`, whose value and type come from the original cascade target, but the section-local operation still needs a result type if later selectors in the same cascade section can apply to the value returned by the body. The exact language semantics of that last case must be settled: for `A()..{ return B(); }.value`, the current analyzer accepts `.value` as an access on `B`, while the current CFE attempts to resolve it on `A`. The specification describes the result of the whole cascaded form but does not explicitly describe this section-tail composition.

For a null-aware ordinary form, a null receiver skips the body and makes the result null; otherwise the body sees the non-null receiver type. The static type of the whole ordinary form is `Nullable(R)`, where `R` is the body result type. For a null-aware cascade, `?..` establishes the guard for the cascade and later sections share it; the whole cascade retains the nullable cascade-target type. Null shortening must cover the body and every selector that belongs to the guarded section.

The parameterless and parameterized forms have deliberately different name lookup. In a parameterless body, `this` denotes the anonymous-method receiver. Lexical lookup continues to select locals, parameters, top-level declarations, and static members, but an instance member found in an enclosing class, mixin, enum, extension type, or extension is not used; lookup restarts as member lookup on the rebound `this`, including applicable extension lookup. In a parameterized body, `this` and implicit receiver lookup retain their enclosing meaning, and only the written parameter denotes the anonymous-method receiver. `super` is consequently unavailable in a parameterless body because the enclosing instance is no longer the meaning of `this`, while a parameterized body retains the ordinary enclosing `super` context.

Flow analysis must model the body as executing exactly once for an unconditional form and at most once for a null-aware form, immediately after evaluation of the receiver. Assignments inside the body do not make outer locals non-promotable as closure capture would, promotions from an unconditional body can survive, and promotions from a conditionally skipped body generally cannot. A block body establishes its own target for `return`, but it is not an ordinary function boundary: `break` and `continue` can target enclosing statements and `await` uses the enclosing asynchronous context. Whether `yield` similarly targets an enclosing generator requires confirmation; the current CFE permits it while the current analyzer reports `yield_in_non_generator`.

The complete written `FormalParameterList` must remain in the AST even when it is invalid. Resolution can expose a convenience `FormalParameter? receiverFormalParameter` that is non-null only for the valid one-parameter form, but it must not erase empty, multiple, optional, or named parameters. The `formalParameterList` property preserves the written syntax, while `receiverFormalParameter` exposes the single valid semantic receiver binding. The current parser reports `anonymousMethodWrongParameterList` and then changes the list to null, which loses the written declarations, changes the recovery interpretation to the parameterless `this` form, and produces cascading undefined-name diagnostics for references to the written parameters. Recovery should preserve and declare the written parameters as far as possible while recording that they cannot define a valid receiver binding; the presence of a written parameter list should not accidentally rebind `this`.

An anonymous method creates a parameter and return-inference scope but does not declare a callable local function. If element-model infrastructure requires a scope owner, a dedicated `AnonymousMethodFragment` or an internal anonymous-method scope is preferable to a nameless `LocalFunctionFragment`. The explicit parameter is indexed as an ordinary declaration and its uses navigate to it. Names and invocations in the body contribute their ordinary references, including receiver-member and extension-member references selected under the rebound `this`. The anonymous-method punctuation contributes no executable reference site, and the anonymous method itself cannot be searched, renamed, torn off, or invoked by another occurrence.

The current implementation already has separate expression and block body nodes and implements receiver typing, context propagation, rebound `this`, null awareness, return inference, and immediate flow analysis. Its combined outer node still has nullable `target2`, `isCascaded`, ancestor-based `realTarget`, propagated dot-shorthand state, and a nameless `LocalFunctionFragment`; those are implementation artifacts rather than the desired V2 API. Visitor, serialization, constant evaluation, indexing, navigation, covering-node, and V1-projection support must be audited explicitly. In particular, the current CFE accepts the constant initializer `const int value = 1.=> 2`, while the analyzer currently reaches a missing `AstBinaryWriter.visitAnonymousMethodInvocation` implementation when serializing that initializer. Constant-expression eligibility is not described by the working specification and needs a language decision as well as complete analyzer support.

## 10. Binary Expressions

A binary expression always produces a value, and its right operand is always evaluated as a value, but the source occurrence to the left of an overloadable operator can be a non-expression instance-operation receiver:

```dart
a + b
super + 0
E(a) + b
super == other
E(a) != other
```

`SuperReference` and `ExtensionOverride` must not acquire a static type or become expressions merely to fit the left-operand slot. Conversely, the left operands of `&&`, `||`, and `??` must genuinely produce values: these operators perform short-circuit value evaluation rather than overridable instance dispatch. A single `BinaryExpression` whose left operand is `Expression` is therefore too narrow for operator invocation, while a single node whose left operand is `InstanceReceiver` is unnecessarily permissive for logical and if-null expressions.

The token-independent classification of overloadable binary operators is shared by ordinary binary invocations and compound assignments:

```dart
enum BinaryOperator {
  multiply,
  divide,
  modulo,
  truncatingDivide,
  add,
  subtract,
  shiftLeft,
  shiftRight,
  unsignedShiftRight,
  bitwiseAnd,
  bitwiseXor,
  bitwiseOr,
  lessThan,
  lessThanOrEqual,
  greaterThan,
  greaterThanOrEqual,
  equal,
  notEqual,
}
```

The structural split for binary expressions is:

```dart
sealed interface class BinaryExpression implements Expression {
  Token get operator;
  Expression get rightOperand;
}

final class BinaryOperatorInvocation
    implements BinaryExpression {
  InstanceReceiver get leftOperand;
  BinaryOperator get binaryOperator;
  MethodElement? get element;
}

final class LogicalAnd
    implements BinaryExpression {
  Expression get leftOperand;
}

final class LogicalOr
    implements BinaryExpression {
  Expression get leftOperand;
}

final class IfNull
    implements BinaryExpression {
  Expression get leftOperand;
}
```

Operator selection is exposed directly by the node rather than through a sealed result hierarchy. `element` is the substituted method statically selected for the operator application. It is null before resolution and also for dynamic dispatch, a non-invoking null equality, an unreachable receiver, or invalid resolution. The node's type makes those outcomes distinguishable when needed: an unresolved expression has null `staticType`, while resolved dynamic, unreachable, and invalid expressions use `dynamic`, `Never`, and canonical `InvalidType`; a non-invoking null equality has type `bool`.

On an ordinary `BinaryOperatorInvocation` or `UnaryOperatorInvocation`, the operator result is the expression's `staticType`. That type is not necessarily `element.returnType`: numeric language rules can refine the result using the operand types after method selection. `CompoundAssignment` and `IncrementOrDecrementExpression` instead expose `operatorResultType`, the value produced between the target read and write before any null shortening of the complete expression. On a `PrefixIncrement` or `PrefixDecrement` it is the new value and normally equals the outer result on the executed path. On a `PostfixIncrement` or `PostfixDecrement` it is still the new value written back, while the outer expression produces the old target-read value. When the target read and write are non-null, the reusable semantic pipeline is:

```dart
target read.type
  -> operatorResultType
  -> target write.acceptedType
```

For example, this is valid Dart:

```dart
class A {
  B operator +(int value) => B();
}

class B {}

void f(Object x) {
  if (x is A) {
    A old = x++;
    print(old);
  }
}
```

The target read has promoted type `A`, the selected `operator +` has result type `B`, the target write accepts the declared type `Object`, and the postfix expression has static type `A` because it produces the old value:

```dart
PostfixIncrement
  target:
    UnqualifiedNameAssignmentTarget(x)
      read:
        VariableReadResolution
          type: A
      write:
        VariableWriteResolution
          acceptedType: Object
  operator: ++
  element: A.operator+
  operatorResultType: B
  staticType: A
```

Similarly, in `a?.x += 1` or `a?.x++` for an `int` property, `operatorResultType` is `int` on the executed non-null path while the complete expression can have type `int?`. The property therefore names the result of the semantic operator operation rather than whichever outer source expression happens to own it. For increment and decrement it can be computed from the target read, selected element, and numeric refinement rules; an implementation need not store it independently.

A wrong right-operand type does not erase a successfully selected `element`; the expression additionally has a diagnostic. The direct nullable element follows the established analyzer reference-node convention and avoids public marker classes with no distinct payload. If a future invalid-code or navigation case requires candidates or recovery data, a focused API should be added only for that demonstrated case.

`BinaryOperatorInvocation` does not need an `Expression` suffix because the enclosing hierarchy already states that it is an expression. Its required `binaryOperator` is derived from the owned token and gives semantic clients the same vocabulary used by compound assignment without requiring scanner token kinds. Its left operand is an `InstanceReceiver`; an ordinary `Expression` implements that capability, while `SuperReference` and `ExtensionOverride` provide the two valid non-value receiver forms. Its right operand remains an `Expression` because it is evaluated as the argument of the selected operator. `StaticQualifier` and `ImportPrefixReference` do not implement this capability. A type name in `int + offset` lowers to `TypeLiteral(int)` because binary syntax applies an instance operation to the runtime `Type` object rather than performing static lookup.

```dart
a + b
  BinaryOperatorInvocation
    leftOperand: UnqualifiedNameExpression(a)
    operator: +
    binaryOperator: add
    rightOperand: UnqualifiedNameExpression(b)
    element: A.operator+
    staticType: Result

super + 0
  BinaryOperatorInvocation
    leftOperand: SuperReference
    operator: +
    binaryOperator: add
    rightOperand: IntegerLiteral(0)

E(a) + b
  BinaryOperatorInvocation
    leftOperand: ExtensionOverride(E(a))
    operator: +
    binaryOperator: add
    rightOperand: UnqualifiedNameExpression(b)

dynamicValue + b
  BinaryOperatorInvocation
    leftOperand: UnqualifiedNameExpression(dynamicValue)
    operator: +
    binaryOperator: add
    rightOperand: UnqualifiedNameExpression(b)
    element: null
    staticType: dynamic

null == b
  BinaryOperatorInvocation
    leftOperand: NullLiteral
    operator: ==
    binaryOperator: equal
    rightOperand: UnqualifiedNameExpression(b)
    element: null
    staticType: bool

a && b
  LogicalAnd
    leftOperand: UnqualifiedNameExpression(a)
    operator: &&
    rightOperand: UnqualifiedNameExpression(b)

a || b && c
  LogicalOr
    leftOperand: UnqualifiedNameExpression(a)
    operator: ||
    rightOperand:
      LogicalAnd
        leftOperand: UnqualifiedNameExpression(b)
        operator: &&
        rightOperand: UnqualifiedNameExpression(c)

a ?? b
  IfNull
    leftOperand: UnqualifiedNameExpression(a)
    operator: ??
    rightOperand: UnqualifiedNameExpression(b)
```

`==` and `!=` are `BinaryOperatorInvocation` nodes despite their special language rules because they retain receiver-shaped operator lookup; invalid explicit-extension lookup such as `E(a) == b` remains the same structural node with a null `element` and invalid `staticType`. The overloadable arithmetic, shift, relational, and bitwise operators use the same node. Compound assignments do not contain a synthetic `BinaryOperatorInvocation`: the target owns its implicit read and write results, while `CompoundAssignment` owns the intervening operator `element` and `operatorResultType`; when receiver evaluation prevents the target protocol, both access results are null. `IfNullAssignment` has a target read and possible write only when the target write is non-null and has no operator facts because `??=` is a short-circuit assignment protocol rather than an invocation of `operator ??`.

Implementation status (2026-07-31): the canonical V2 parser and resolved AST now use `BinaryOperatorInvocation` and the token-derived `BinaryOperator` enum for the overloadable binary operators described above. Resolution records the statically selected method in `element`, summary serialization preserves the dedicated node, and V1 projects it as `BinaryExpression`. Migrating `SuperExpression` and `ExtensionOverride` to dedicated receiver roles remains separate work.

`LogicalAnd` and `LogicalOr` are separate concrete nodes. Although they have the same expression-only child roles and `bool` static type, they have different precedence, determine opposite conditions under which the right operand is evaluated, compose flow states differently, and warrant distinct visitor operations. Their concrete types expose that distinction directly, so no `LogicalOperator` enum duplicates the node identity. The owned `&&` or `||` token remains available for source ownership, ranges, and rewriting, while precedence is represented both by the concrete node and by tree nesting, as in `a || (b && c)`.

`IfNull` remains separate because `??` has different typing, operand contexts, and flow behavior rather than merely the opposite short-circuit polarity. For logical and if-null nodes, a parsed left chain that selects a complete `ExtensionOverride` or bare `SuperReference` lowers to `InvalidExtensionOverrideExpression` or `InvalidSuperExpression`; the non-expression receiver cannot be installed directly in an `Expression` slot. Other invalid non-value names retain source-shaped expressions with invalid named-read resolution. The same rule applies to the right operand of every binary form. The parser knows the outer node kind from the operator token and can construct it around the smallest unresolved parsed chain without waiting for name resolution.

## 11. Unary and Postfix Expressions

The current generic `PrefixExpression` and `PostfixExpression` nodes group operations whose operands have different structural roles. V2 should instead use concrete source-operation nodes:

```dart
enum UnaryOperator {
  negate,
  bitwiseComplement,
}

final class UnaryOperatorInvocation implements Expression {
  Token get operator;
  UnaryOperator get unaryOperator;
  InstanceReceiver get operand;
  MethodElement? get element;
}

final class LogicalNot implements Expression {
  Token get operator;
  Expression get operand;
}

final class NullAssertion implements Expression {
  Expression get operand;
  Token get operator;
}
```

`UnaryOperatorInvocation` owns `-` or `~`. Both operators perform overloadable instance operations, so the operand is an `InstanceReceiver` and can be an ordinary expression, `SuperReference`, or `ExtensionOverride`. `unaryOperator` is non-null and derived from the token, giving semantic clients `negate` or `bitwiseComplement` without requiring scanner token kinds.

Implementation status (2026-07-31): the canonical V2 parser and resolved AST now use this single `UnaryOperatorInvocation` class and `UnaryOperator` enum for `-` and `~`. Resolution records the statically selected method directly in `element`; `staticType` records the operator result, including dynamic, unreachable, and invalid outcomes. V1 projects the node as `PrefixExpression`, while canonical `PrefixExpression` is now limited to `++` and `--`. The broader migration of `SuperExpression` and `ExtensionOverride` from expressions to dedicated receiver roles remains separate work.

```dart
-value
  UnaryOperatorInvocation
    operator: -
    unaryOperator: negate
    operand: UnqualifiedNameExpression(value)

-super
  UnaryOperatorInvocation
    operator: -
    unaryOperator: negate
    operand: SuperReference

~E(value)
  UnaryOperatorInvocation
    operator: ~
    unaryOperator: bitwiseComplement
    operand: ExtensionOverride(E(value))
```

Negating an integer literal has special contextual-typing and constant-evaluation rules, but it retains the ordinary operator-invocation source shape and resolution through `int.unary-`; those special rules do not justify a separate node or resolution kind:

```dart
-42
  UnaryOperatorInvocation
    operator: -
    unaryOperator: negate
    operand: IntegerLiteral(42)
    element: int.unary-
    staticType: int
```

`LogicalNot` owns prefix `!` and requires an `Expression` operand because boolean negation is not an overloadable instance operation. `NullAssertion` owns postfix `!` and likewise requires a value-producing operand; it records the resulting promoted non-nullable type and relevant flow behavior rather than any selected method. A parsed `!super`, `!E(value)`, `super!`, or `E(value)!` therefore contains `InvalidSuperExpression` or `InvalidExtensionOverrideExpression` as the canonical invalid operand rather than placing `SuperReference` or `ExtensionOverride` in the expression slot.

The concise operation names are reserved for expressions. Existing pattern nodes retain the explicit `LogicalAndPattern`, `LogicalOrPattern`, `NullAssertPattern`, and `NullCheckPattern` names; there is no `LogicalNotPattern`. `NullAssertion` is the noun naming the expression operation, while `NullAssertPattern` retains the established modifier in the pattern name.

```dart
!condition
  LogicalNot
    operator: !
    operand: UnqualifiedNameExpression(condition)

value!
  NullAssertion
    operand: UnqualifiedNameExpression(value)
    operator: !
```

Prefix and postfix increment and decrement retain the dedicated nodes described in Section 3:

```dart
++x
  PrefixIncrement
    operator: ++
    target: UnqualifiedNameAssignmentTarget(x)
    element: ...
    operatorResultType: ...

--x
  PrefixDecrement
    operator: --
    target: UnqualifiedNameAssignmentTarget(x)
    element: ...
    operatorResultType: ...

x++
  PostfixIncrement
    target: UnqualifiedNameAssignmentTarget(x)
    operator: ++
    element: ...
    operatorResultType: ...

x--
  PostfixDecrement
    target: UnqualifiedNameAssignmentTarget(x)
    operator: --
    element: ...
    operatorResultType: ...
```

The concrete node directly identifies both the written token and the source position, so there is no `UpdateOperator` enum or `updateOperator` getter. Each child remains an `AssignmentTarget`, not an expression or general instance-operation receiver, because increment and decrement perform a read, operator application, and write-back. The outer increment-or-decrement node owns the operator `element` and `operatorResultType` because the target itself describes only its read and write. Prefix nodes produce the new value and postfix nodes produce the old target-read value; increment nodes select implicit `operator +` and decrement nodes select implicit `operator -`. The four concrete types make both independent distinctions structural, while `IncrementOrDecrementExpression` supplies their common data contract.

Implementation status (2026-08-09): prefix and postfix `++` and `--` use the four canonical `PrefixIncrement`, `PrefixDecrement`, `PostfixIncrement`, and `PostfixDecrement` nodes with the shared `IncrementOrDecrementExpression` interface. They own an `AssignmentTarget`, the selected operator `element`, and `operatorResultType`; V1 projects them as the legacy `PrefixExpression` and `PostfixExpression`. Unqualified names, ordinary property selections, and ordinary indexing record independent target read and write resolutions, while structurally invalid expression operands use `InvalidExpressionAssignmentTarget`. The parser currently maps the legacy ambiguous `prefix.name` spelling through the receiver-supplied property target under its transitional `PropertyAssignmentTarget` name, including import-prefix recovery; precise `ImportPrefixedAssignmentTarget`, static-qualifier, cascade, extension-override, and super-invalid lowering still belongs to the parsed-chain migration.

Other constructs described by the grammar as postfix expressions already have more useful canonical identities:

```dart
value.name        ReceiverPropertyExtraction
value[index]      ReceiverIndexExpression
value(arguments)  CallInvocation
value<T>          FunctionInstantiation
value!            NullAssertion
value++           PostfixIncrement
```

There is no resolved V2 `PostfixExpression` container around these operations and no public common base introduced merely because their tokens follow a primary expression. Similarly, V2 does not need a general `PrefixExpression` base around unary operators, logical negation, increment/decrement, `AwaitExpression`, or `ThrowExpression`; token position alone does not provide a useful common semantic API. The parser can select unary, logical-not, null-assertion, increment, and decrement structure from the operator token before resolution while retaining only the smallest ambiguous name-led operand or target chain.

## 12. Named Read and Target Resolution

The source node hierarchy should represent source roles. Resolution data should represent lookup and evaluation meaning without creating one AST subclass for every combination of declaration kind, receiver kind, and access mode. Named value selection uses a sealed `NamedReadResolution` hierarchy rather than a kind enum accompanied by conditionally meaningful nullable fields:

```dart
sealed interface class NamedReadResolution implements ReadResolution {}

sealed interface class NamedReadResolutionWithElement
    implements NamedReadResolution {
  @override
  Element get element;
}

final class VariableReadResolution
    implements NamedReadResolutionWithElement {
  VariableElement get element;
  DartType get type;
}

final class GetterInvocationResolution
    implements NamedReadResolutionWithElement {
  GetterElement get element;
  FunctionType get invokeType;
  DartType get type;
}

final class ExecutableTearOffResolution
    implements NamedReadResolutionWithElement {
  ExecutableElement get element;
  DartType get type;
}

final class FunctionCallTearOffResolution
    implements NamedReadResolution {
  DartType get type;
  FunctionType get associatedFunctionType;
}

final class FunctionInterfaceCallTearOffResolution
    implements NamedReadResolution {
  DartType get type;
}

final class RecordFieldReadResolution
    implements NamedReadResolution {
  DartType get type;
}

final class DynamicPropertyReadResolution
    implements NamedReadResolution {
  DartType get type;
}

final class InvalidNamedReadResolution
    implements NamedReadResolution, InvalidReadResolution {
  DartType get type;
  Element? get recoveryElement;
}
```

`VariableReadResolution` represents a direct read of a local variable, formal parameter, pattern variable, or another declaration whose value is obtained without invoking an accessor. `GetterInvocationResolution` represents an explicit or implicit getter selected for a field, top-level variable, static property, or declared getter; its `invokeType` is the substituted zero-argument function type used for the invocation, while `type` is the result produced if this read executes. `ExecutableTearOffResolution` covers a function, method, or constructor when the source-shaped node does not itself require a constructor-specific role. Its `element` is the executable selected for the occurrence after receiver or enclosing-type substitution, while `type` is the function value produced if the tear-off read executes and before applying type arguments to the executable's own type parameters. Written type arguments belong to `FunctionInstantiation`, and contextually inferred function type arguments belong to `ImplicitFunctionInstantiation`. A `DotShorthandNameExpression(.named)` can expose a substituted `ConstructorElement` selected using its shorthand context without acquiring `ConstructorTypeReference`, `ConstructorSelector`, or a constructor-specific outer node. Ordinary `C.named` remains `ConstructorTearOff` because those written children are structurally meaningful. `FunctionCallTearOffResolution` represents closurization of the language-defined `call` method when the receiver or its bound supplies an exact function signature. Its primary `type` is the actual tear-off result type and can remain a type parameter; `associatedFunctionType` is the exact callable signature associated with that type. For `T extends F`, `this.call` has `type == T` and `associatedFunctionType == F`. `FunctionInterfaceCallTearOffResolution` represents the same element-free operation when lookup reaches only the core `Function` interface; its `type` is either `Function` itself or a type parameter such as `T extends Function`. Either result can belong to an explicit or cascade property extraction, an unqualified `call` name resolved against an implicit receiver, or the read side of a named assignment target. Separate leaves promise whether an exact callable signature exists without collapsing the read's flow-sensitive static type to its bound.

`RecordFieldReadResolution` represents structural record-field selection, which has no declaration element or getter invocation. The source property name identifies the selected named or positional field, while the resolution records the resulting type. `DynamicPropertyReadResolution` represents a valid property read whose lookup and dispatch occur dynamically and has type `dynamic`. The word `Property` is deliberate: a direct read of a variable whose type is `dynamic` remains `VariableReadResolution`; only receiver-based property selection can perform dynamic dispatch. `InvalidNamedReadResolution` distinguishes completed but unsuccessful resolution from the absence of a read operation and has canonical `InvalidType`. Its optional `recoveryElement` preserves a declaration found by lookup even when it cannot be used as a value, such as a named extension or import prefix. A null resolution means either that semantic data is not yet available or that receiver evaluation prevents the property read from occurring. In the latter case the value expression still has its resolved complete `staticType`, such as `Never` for a `Never` receiver or the shortened result type for an exact-null null-aware receiver.

On a value-producing name or property expression with a non-null resolution, `resolution.type` describes the value produced if that read executes, while `staticType` describes the complete expression result. They are equal when null shortening does not change the expression result. The same resolution API therefore applies without changing meaning to a target's non-null implicit read: on a compound-assignment or increment-or-decrement target with non-null read and write, `read.type` is the flow-sensitive intermediate read type even though the target itself has no `staticType`. For example, after promotion in `int? x; if (x != null) x += 1;`, the target read has type `int`, while the write continues to accept the declared variable type. For a null-aware value read `a?.x` whose getter returns `R`, the getter resolution has type `R` if it executes and the expression has static type `R?` when it terminates null shortening. A null-aware compound target such as `a?.x += 1` uses the same executed-path read type and leaves shortening of the result to the enclosing assignment expression. An exact-null or `Never` receiver instead gives the value expression a null resolution and the assignment target null read and write, so neither fabricates an unreachable operation. The value expression retains its complete `staticType`. Thus `type` describes the operation result if it executes, not whichever outer source expression happens to own or terminate it and not merely the declared type of its element.

Invalid named reads have canonical `InvalidType` and retain one optional `recoveryElement`. This can be a declaration that cannot supply a readable value, such as an extension or import prefix; ambiguity is retained as a `MultiplyDefinedElement`. Producers prefer the declaration found for the requested read, then the available lookup fallback. Consumers requiring a selected operation use `element`; navigation, invalid-code references, and declaration diagnostics can use `elementOrRecovery`. Constant evaluation must not turn a retained non-value declaration into a successfully evaluated value. No rich recovery resolution or candidate list is needed.

This hierarchy describes the named value-selection cases. `TypeLiteral` needs no named-read resolution because its node kind and `NamedType` child completely describe type-object production. `IndexExpression` instead exposes the dedicated `IndexReadResolution` described in section 5 because indexing performs `operator []` dispatch rather than resolving a variable, getter, tear-off, or record field.

Named writes use the parallel hierarchy:

```dart
abstract final class NamedWriteResolution implements WriteResolution {}

abstract final class NamedWriteResolutionWithElement
    implements NamedWriteResolution {
  @override
  Element get element;
}

abstract final class VariableWriteResolution
    implements NamedWriteResolutionWithElement {
  VariableElement get element;
  DartType get acceptedType;
}

abstract final class SetterInvocationResolution
    implements NamedWriteResolutionWithElement {
  SetterElement get element;
}

abstract final class DynamicPropertyWriteResolution
    implements NamedWriteResolution {}

abstract final class InvalidNamedWriteResolution
    implements NamedWriteResolution, InvalidWriteResolution {
  DartType get acceptedType;
  Element? get recoveryElement;
}
```

These exported resolution types are getter-only interfaces. The analyzer owns their construction through a parallel internal hierarchy: sealed `ReadResolutionImpl` and `WriteResolutionImpl` have the corresponding named and indexed implementation families as subtypes. Constructors exist only on those unexported implementation classes. `AssignmentTargetImpl` covariantly exposes these shared implementation types, so common consumers retain `TypeImpl` access. Assignment-target producers maintain `write != null || read == null`, and resolved consumers can assert the stronger invariants required by a particular target and enclosing operation. Internal serialization and resolved-AST printing pass the implementation types through their helpers and switch on the sealed read and write roots, so adding a new operation leaf requires exhaustively updating those switches, while public clients continue to depend only on the semantic API interfaces. Implementation accessors covariantly expose analyzer-internal element and type interfaces, avoiding casts back from public `Element` and `DartType` in resolver, serialization, and projection code.

Consumers that need the selected semantic write declaration use `write?.element`; an invalid write has no selected element. `InvalidNamedWriteResolution.recoveryElement` separately retains one declaration for diagnostics, navigation, and references to invalid code. It need not support writing: it can be a getter, method, or class. Ambiguous lookup retains a `MultiplyDefinedElement` rather than selecting one conflicting declaration. The resolver chooses the recovery element; consumers do not choose among candidates or unwrap a hypothetical named-write operation. Consumers whose policy includes recovery use `write.elementOrRecovery`, while selected-operation usage checks keep `write?.element`. V1 projections use the recovery element to preserve their legacy behavior. Consumers read `acceptedType` directly instead of using a compatibility `writeType` getter.

`VariableWriteResolution` represents writing a local variable, parameter, or another directly stored declaration. `SetterInvocationResolution` records the selected, already-substituted setter; its inherited `acceptedType` is derived from that setter's single value parameter. Both expose their covariantly typed element through `NamedWriteResolutionWithElement.element`. `DynamicPropertyWriteResolution` instead represents a property write whose setter lookup and dispatch occur at runtime and has `acceptedType == dynamic`, because no static setter parameter type constrains the written value. A direct write to a variable whose declared type is `dynamic` remains `VariableWriteResolution` with `acceptedType == dynamic`. An invalid named write has canonical `InvalidType`, independently of its optional recovery element.

On an assignment target, the read is absent for plain `=`, present for compound assignment, `??=`, and increment/decrement, and can have a different type and element from the write. The write is normally non-null, including when lookup produces an `InvalidNamedWriteResolution`. When receiver evaluation prevents the property-target protocol, both read and write are null; there is no fabricated `acceptedType` against which a value could be checked.

These nullable target members do not reintroduce one general `NameResolution`. A value-producing name or property expression owns its named-read resolution when a read operation occurs and retains its complete `staticType` when receiver evaluation prevents the operation. An assignment target directly owns nullable `read` and `write` members that distinguish write-only, read-write, and receiver-suppressed protocols in a resolved AST. A compound target's implicit read is resolution data on that target rather than a synthetic expression. This prevents a name used only for writing from acquiring expression properties.

Lookup binding and evaluation can still be conceptually separated. For example, an extension name or import prefix can be successfully bound but invalid as a value, a top-level variable can navigate to its variable declaration while evaluation invokes its getter, and an ambiguous import can retain multiple candidates. The public representation should expose both the semantic operation target and an IDE-oriented navigation target where they differ.

### 12.1 Removing `MethodReferenceExpression`

The current `MethodReferenceExpression` is not a useful source hierarchy. It groups assignment, binary, prefix, postfix, index, and implicit-call-reference expressions only to expose one nullable `MethodElement? element`, but that element denotes a different implicit operation in each form and is sometimes meaningless. A compound assignment can involve a target getter, an intermediate operator, and a target setter; an increment or decrement expression likewise performs read, operator, and write operations; an index occurrence can select `[]`, `[]=`, or both; and an implicit call tear-off selects `call`. None of these occurrences shares one unambiguous method-reference source role.

Canonical V2 removes `MethodReferenceExpression`. Operator-owning nodes expose their selected `element` directly; compound-assignment and increment-or-decrement nodes additionally expose `operatorResultType`. `IndexReadResolution`, `IndexWriteResolution`, `NamedReadResolution`, `NamedWriteResolution`, `InvocationResolution`, and the `ImplicitCallTearOff` adaptation expose their selected operation and invoke type at the node that owns that operation. V1 compatibility projections can delegate the legacy nullable `element` getter to the corresponding V2 owner, but V2 clients should not classify unrelated expressions through a common method-element interface.

## 13. Indexing, Navigation, Search, and Rename

The design should let source tooling consume normalized reference occurrences without reconstructing semantics from parent classes.

For:

```dart
x;
```

the name site has one read-like reference, whose exact kind can be direct value read, getter invocation, tear-off, or invalid reference. If lookup instead selects a type declaration in this value-producing position, lowering replaces the source role with `TypeLiteral`, and the name reference belongs to its `NamedType` child rather than to `NamedReadResolution`.

For:

```dart
x = value;
```

the target name has one write reference.

For:

```dart
x += value;
```

the same name site has a read reference and a write reference.

For:

```dart
prefix.x += value;
```

the prefix name references the `PrefixElement`, while `x` references the imported getter and setter.

For:

```dart
a[i] += value;
```

the bracket site references both `operator []` and `operator []=`, while `a`, `i`, and `value` contain their own expression references.

For:

```dart
E(foo).bar
```

the name `E` references the selected `ExtensionElement`, references inside `foo` are indexed as ordinary expressions, and `bar` references the selected extension member. The `ExtensionOverride` itself contributes dispatch information but no value-type reference.

For:

```dart
super.foo
```

the `foo` site references the selected superclass member. The `super` token records the special dispatch form but does not need a synthetic reference to `this`; whether navigation from `super` itself should target the superclass declaration is a separate tooling-policy question.

For:

```dart
super()
```

the `CallInvocation` references the selected superclass `call` method even though there is no `call` name token. The invocation operation itself is the reference site; the AST must not insert a synthetic property access merely to give that reference a name.

For:

```dart
target..x = 0..y;
```

the cascade target expression is evaluated and indexed once. The `x` site is a write reference and the `y` site is a getter read, both resolved using the cascade target type. The AST does not invent repeated source references to `target` for each section.

For:

```dart
receiver.(value) {
  return value.member;
}
```

the explicit parameter is indexed as a local declaration, the use of `value` references that declaration, and `member` references the selected member of the receiver type. In the parameterless `receiver.{ return member; }`, `member` instead records the ordinary implicit-receiver reference selected using the rebound `this`. The anonymous-method operator has no executable target and contributes no synthetic invocation reference.

Navigation should not be forced to choose between an accessor element needed by semantic analysis and a declaration element preferred by the user. A reference result can expose both `target` and `navigationTarget`. Invalid resolution can expose recovery targets and candidates rather than returning only `null`.

Search and rename must visit import prefix references, property/member name sites, type and constructor references, index-operator sites where appropriate, and compatibility projections consistently. The introduction of new V2 node kinds must be accompanied by explicit visitor and indexer coverage rather than relying on a generic fallback that loses reference meaning.

## 14. Relationship to V1 and V2

The proposed nodes describe a canonical V2 model. Existing V1 nodes and properties remain compatibility projections during the migration.

### 14.1 Exhaustive current-to-canonical expression crosswalk

The following tables account for every current public AST type that directly or transitively implements `Expression`. “Retain” means that the current source role remains canonical even when V1/V2 child names or implementation classes change. “Split” means that the current node combines source roles that become distinct canonical nodes. “V1-only” means that canonical V2 has another representation and exposes the current node only as a compatibility projection.

Current common expression types:

| Current public type | Canonical V2 result | Disposition |
| --- | --- | --- |
| `Expression` | `Expression` with the base API in section 2.5 | Retain with the narrower value-producing invariant and contextual argument, collection-element, and record-field roles. |
| `CommentReferableExpression` | Non-expression `CommentReference` and components | Remove from V2; documentation references are not evaluated and have no static type. |
| `CompoundAssignmentExpression` | Concrete `CompoundAssignment`, `PrefixIncrement`, `PrefixDecrement`, `PostfixIncrement`, and `PostfixDecrement` nodes with target read/write results, operator `element`, and `operatorResultType` | Remove the current read/write capability. The V2 compound-assignment source node does not reuse the legacy capability name; the four increment-or-decrement nodes share only `IncrementOrDecrementExpression`. |
| `Identifier` | Direct tokens on source-role owners | Remove from V2 together with `SimpleIdentifier` and `PrefixedIdentifier`. |
| `InvocationExpression` | `FunctionInvocation` | Replace the current common `function`, `staticInvokeType`, and `typeArgumentTypes` contract with common argument syntax and `InvocationResolution`. |
| `Literal` | `Literal` | Retain as a sealed genuine expression category and visitor fallback. |
| `MethodReferenceExpression` | Operation-specific resolutions | Remove from V2; one nullable method element cannot describe assignment, increment/decrement, index, operator, and implicit-call operations. |
| `StringLiteral` | `StringLiteral` | Retain with `stringValue`. |
| `SingleStringLiteral` | `SingleStringLiteral` | Retain with its one-delimited-string lexical API. |
| `TypedLiteral` | `TypedLiteral` | Retain for list and set-or-map literals with optional `const` and type arguments. |

Current concrete source node types:

| Current public type | Canonical V2 result | Disposition |
| --- | --- | --- |
| `AdjacentStrings` | `AdjacentStrings` | Retain. |
| `AnonymousMethodInvocation` | `AnonymousMethodInvocation` or `CascadeAnonymousMethodInvocation` | Split ordinary and cascade source forms; the ordinary node has an explicit expression receiver and the cascade node obtains its receiver from its section. |
| `AsExpression` | `AsExpression` | Retain with its expression, `as` token, type annotation, and `staticType`; no resolution object. |
| `AssignmentExpression` | `DirectAssignment`, `IfNullAssignment`, or concrete `CompoundAssignment` | Split by evaluation protocol and replace the expression-shaped left side with `AssignmentTarget`. |
| `AwaitExpression` | `AwaitExpression` | Retain; the awaited result is `staticType` and no selected declaration requires a resolution object. |
| `BinaryExpression` | Sealed `BinaryExpression` with `BinaryOperatorInvocation`, `LogicalAnd`, `LogicalOr`, and `IfNull` implementations | Retain the useful common source category but split the current concrete node by operand role and evaluation protocol. |
| `BooleanLiteral` | `BooleanLiteral` | Retain. |
| `CascadeExpression` | `CascadeExpression` with explicit `CascadeSection` children and typed cascade-start nodes | Retain the outer source role while removing nullable targets, ancestor-based real-target lookup, and target-less property/index implementation accidents. |
| `ConditionalExpression` | `ConditionalExpression` | Retain; branch context, flow, adaptations, and result typing require no resolution object. |
| `ConstructorInvocation` | `ConstructorInvocation` | Retain as canonical V2 constructor application with `ConstructorReference` structure and a selected substituted constructor element. |
| Deprecated `ConstructorReference` expression | `ConstructorTearOff` | V1-only projection. The future non-expression structural `ConstructorReference` is the current `ConstructorReference2`, not this deprecated expression class. |
| `ConstructorTearOff` | `ConstructorTearOff` | Retain with required `ConstructorTypeReference` and `ConstructorSelector`. |
| `DotShorthandConstructorInvocation` | `DotShorthandConstructorInvocation` | Retain outside `FunctionInvocation`; it directly exposes the selected substituted constructor. |
| `DotShorthandInvocation` | `DotShorthandMethodInvocation`, `DotShorthandConstructorInvocation`, or `CallInvocation` over `DotShorthandNameExpression` | Replace the ambiguous current node during resolution according to whether the shorthand selects a direct static method, constructor, or callable getter/field value. |
| `DotShorthandPropertyAccess` | `DotShorthandNameExpression` | Replace; `NamedReadResolution` distinguishes direct values, getters, method tear-offs, and constructor tear-offs. |
| `DoubleLiteral` | `DoubleLiteral` | Retain. |
| `ExtensionOverride` | Non-expression `ExtensionOverride` implementing receiver capabilities, or `InvalidExtensionOverrideExpression` when the complete override occurs in an expression-only slot | Retain the source structure but remove it from `Expression` and remove its pseudo static type; the precise no-token recovery wrapper projects to the current expression-shaped node only for invalid value placement. |
| `FunctionExpression` | `FunctionExpression` only for actual anonymous function values | Retain for genuine function expressions; top-level and local named declarations directly own their signatures and bodies and synthesize the old nested node only for V1. |
| `FunctionExpressionInvocation` | `CallInvocation` | V1-only projection of applying an argument list to a value or special instance-operation receiver. |
| `FunctionReference` | `FunctionInstantiation`, `ImplicitFunctionInstantiation`, or an ordinary source-shaped named-read expression | Remove the current overloaded node. A written `<typeArguments>` selector is `FunctionInstantiation`, contextual generic instantiation is a no-token adaptation, and an ordinary tear-off remains the corresponding named-read expression. |
| `ImplicitCallReference` | `ImplicitCallTearOff`, optionally inside `FunctionInstantiation` or `ImplicitFunctionInstantiation` | V1-only projection of the no-token semantic adaptation and any surrounding instantiation. |
| `IndexExpression` | `ReceiverIndexExpression`, `ReceiverIndexAssignmentTarget`, or the cascade index forms | Split receiver-supplied and cascade-supplied source roles while sharing `IndexReadResolution` where an implicit target read occurs. |
| `InstanceCreationExpression` | `ConstructorInvocation` | V1-only projection; canonical V2 uses `ConstructorInvocation`. |
| `IntegerLiteral` | `IntegerLiteral` | Retain; contextual `int` versus `double` selection is recorded by `staticType`. |
| `IsExpression` | `IsExpression` | Retain with its expression, `is` and optional `!` tokens, type annotation, and `bool` static type; no resolution object. |
| `ListLiteral` | `ListLiteral` | Retain. |
| `MethodInvocation` | One of the concrete `NamedFunctionInvocation` nodes, `CallInvocation`, constructor syntax, or `ExtensionOverride` according to lowering | V1-only general invocation shape; canonical V2 distinguishes direct named dispatch from invocation of a selected value and non-expression receiver roles. |
| `NullLiteral` | `NullLiteral` | Retain. |
| `ParenthesizedExpression` | `ParenthesizedExpression` | Retain because it owns tokens, precedence, source range, and context boundaries even though its value type and flow information delegate to its child. |
| `PatternAssignment` | `PatternAssignment` | Retain unchanged for now. Pattern writes remain a parallel pattern-specific model rather than being decomposed into `AssignmentTarget` leaves by this design. |
| `PostfixExpression` | `NullAssertion`, `PostfixIncrement`, or `PostfixDecrement` | Split by operation; null assertion has an expression operand, while increment and decrement have an assignment target plus operator `element` and `operatorResultType`. |
| `PrefixedIdentifier` | Property, import-prefixed, static, constructor, type, invocation, target, or documentation-reference structure selected for the occurrence | Remove from V2; no generic qualified-identifier node remains. |
| `PrefixExpression` | `UnaryOperatorInvocation`, `LogicalNot`, `PrefixIncrement`, or `PrefixDecrement` | Split by operation and operand role. |
| `PropertyAccess` | `ReceiverPropertyExtraction`, `ReceiverPropertyAssignmentTarget`, or another precise lowered qualified source role | Split value and target occurrences; import qualification and constructor selection use their dedicated structures. |
| `RecordLiteral` | `RecordLiteral` | Retain with direct expression positional fields and syntax-bearing named fields. |
| `RethrowExpression` | `RethrowExpression` | Retain; its abrupt completion and `Never` static type need no additional resolution. |
| `SetOrMapLiteral` | `SetOrMapLiteral` | Retain; enclosing context and elements determine set-versus-map interpretation. |
| `SimpleIdentifier` | Direct token on the owning source-role node, commonly `UnqualifiedNameExpression` or `UnqualifiedNameAssignmentTarget` | Remove from V2; declarations, selectors, types, labels, and other non-value names likewise expose direct tokens. |
| `SimpleStringLiteral` | `SimpleStringLiteral` | Retain. |
| `StringInterpolation` | `StringInterpolation` | Retain; interpolation components remain non-expression syntax around ordinary child expressions and need no conversion resolution. |
| `SuperExpression` | Non-expression `SuperReference`, or `InvalidSuperExpression` when bare `super` occurs in an expression-only slot | Replace; `super` changes dispatch for the implicit current instance but does not produce an independently typed value, while the precise no-token recovery wrapper preserves invalid value placement. |
| `SwitchExpression` | `SwitchExpression` | Retain with existing scrutinee and case structure; case scopes, patterns, flow, exhaustiveness, and result inference require no switch-resolution object. |
| `SymbolLiteral` | `SymbolLiteral` | Retain. |
| `ThisExpression` | `ThisExpression` | Retain as the explicitly written current-instance value with only `staticType`; implicit `this` remains absent from the AST. |
| `ThrowExpression` | `ThrowExpression` | Retain; its abrupt completion and `Never` static type fit the expression contract. |
| `TypeLiteral` | `TypeLiteral` containing `NamedType` | Retain as a value-producing runtime `Type` object expression, but remove its `CommentReferableExpression` role. |

The audit found no current public expression type without a canonical disposition. The intentionally unchanged edge is `PatternAssignment`, whose pattern-specific write model remains outside this refactoring. The simple value-producing control nodes `AsExpression`, `AwaitExpression`, `ConditionalExpression`, `IsExpression`, `ParenthesizedExpression`, `SwitchExpression`, `ThisExpression`, `ThrowExpression`, and `RethrowExpression` retain their current source structures and need no operation-resolution hierarchy. Two internal expression-shaped adapters also disappear. `RewrittenMethodInvocationImpl` is unnecessary because resolved lowering constructs the explicit canonical invocation, constructor, call, extension-override, or dot-shorthand node rather than tagging an intermediate. `SyntheticIdentifier` currently implements `SimpleIdentifier` only to send a name through lookup when no identifier node exists; V2 lookup accepts the name or token as an ordinary lookup request rather than fabricating an expression interface.

### 14.2 Exhaustive grammar-to-canonical coverage ledger

This ledger covers the expression grammar implemented by the current Dart 3.14 SDK checkout, accepted expression-adjacent syntax that supplies values or performs writes, and analyzer-supported experimental expression syntax already represented by the current AST and discussed in this document, notably anonymous methods. The accepted features added after the Dart 3.10 dot-shorthand specification in this checkout do not add another expression source form: private named parameters affect parameter declarations, primary constructors add declaration, parameter, initializer, and body syntax whose nested expressions already use the ordinary roles below, and record-use changes annotation and compiler semantics without adding expression grammar. Lexical variations such as digit separators, raw strings, multiline strings, and operator-token spellings remain properties of the same source nodes. Arbitrarily malformed token streams and parser token-insertion strategies are not enumerable; for invalid source the ledger instead specifies the canonical recovery topology after parsing has produced the closest grammatical form. A resolved V2 unit must contain one of the listed canonical source roles or recovery roles and no parser-only chain.

The recent accepted-feature audit has an explicit disposition for each expression-relevant change: digit separators are lexical variants of integer and double literal tokens; wildcard variables affect declaration and write binding rather than adding an expression form; null-aware list/set elements and null-aware map keys and values use `NullAwareElement` and `MapLiteralEntry`; and dot shorthands use the parsed-head and three resolved leading-operation roles described below. Records, patterns, extension types, constructor tear-offs, enhanced enums, and super parameters are represented in their corresponding primary, contextual, constructor, pattern, type, and parameter rows rather than treated as implicit coverage.

“Parsed chain” below means a `ParsedExpressionChain` or `ParsedAssignmentTargetChain` containing only the smallest resolution-dependent chain island. Structurally known parentheses, literals, operators, index selectors, null assertions, calls on already grouped values, and enclosing contextual nodes remain outside that island. `ParsedDotShorthandExpression` is an additional outer parser-only boundary rather than a larger kind of parsed chain: it wraps the ordinarily structured expression for the complete shorthand selector chain, whose leading ambiguous island has `ParsedDotShorthandHead`. “Ordinary resolution” means that each nested name, type, invocation, index, operator, or constructor operation uses the operation-specific result listed in the resolution ledger rather than a result owned by the enclosing control node. “V1 projection” names the compatibility shape rather than requiring a newly allocated projection at parse time; resolution-side projections are created only after canonical lowering.

#### 14.2.1 Primary and value-producing source forms

| Written form | Parse-time V2 | Canonical resolved V2 | Resolution facts | Invalid canonical form and V1 projection |
| --- | --- | --- | --- | --- |
| `x` | One-head `ParsedExpressionChain(ParsedNameHead(x))` unless the parser slot already fixes a more specific role | `UnqualifiedNameExpression`, or `TypeLiteral(NamedType)` when lookup and value syntax select a type object | `NamedReadResolution` on an ordinary value occurrence; `NamedType` resolution on a type literal | A non-value extension name or import prefix remains `UnqualifiedNameExpression` with `InvalidNamedReadResolution`; V1 is `SimpleIdentifier` or the existing `TypeLiteral` rewrite |
| `int`, `void`, `dynamic`, `C`, or another type spelling used as a value | Parsed name chain, including any import-qualified name inside the ambiguous island | `TypeLiteral` containing the source-shaped `NamedType` | `NamedType` owns the represented type and declaration; `TypeLiteral.staticType` is `Type` | Invalid type-object production remains `TypeLiteral` when type syntax was selected, otherwise the ordinary invalid name expression; V1 is `TypeLiteral` |
| `this` | `ThisExpression` | `ThisExpression` | Only `staticType`; the enclosing executable determines the current instance | Invalid context retains `ThisExpression` with diagnostics and recovery type; V1 is `ThisExpression` |
| bare `super` in an expression slot | `SuperReference` selected by keyword parsing and wrapped or lowered when the slot boundary is known | `InvalidSuperExpression(SuperReference)` | No value resolution; the child preserves the special receiver reference | The form is intrinsically invalid as a value; V1 projects `SuperExpression` |
| `true`, `false`, `null`, integer, and double literals | Corresponding literal node | `BooleanLiteral`, `NullLiteral`, `IntegerLiteral`, or `DoubleLiteral` | Only `staticType`; contextual numeric typing may make an integer literal `double` | The same node retains malformed or contextually invalid tokens and diagnostics; V1 is the same literal kind |
| one string, adjacent strings, or interpolation | `SimpleStringLiteral`, `StringInterpolation`, or `AdjacentStrings` with `InterpolationExpression` children | Same literal topology | Child expressions have ordinary resolution; interpolation conversion introduces no named reference or resolution object | Recovery remains in the string/interpolation topology; V1 uses the same string nodes with projected child expressions |
| `#name`, `#a.b`, or `#operator` | `SymbolLiteral` with pound token and component tokens | `SymbolLiteral` | Only `staticType` and constant evaluation; components are not identifier expressions | Invalid spelling remains token-preserving symbol recovery; V1 is `SymbolLiteral` |
| `[elements]` or `<T>[elements]`, with optional `const` | `ListLiteral` containing `CollectionElement` children | `ListLiteral` | Literal inference and `staticType`; nested elements use their own contextual and operation facts | Invalid element mixtures remain literal and collection-element recovery; V1 is `ListLiteral` |
| `{elements}` or `<T>{elements}`, with optional `const` | `SetOrMapLiteral` containing `CollectionElement` children | `SetOrMapLiteral` | Context and elements determine set versus map and aggregate `staticType` | Ambiguous or inconsistent contents remain one `SetOrMapLiteral` with diagnostics; V1 is `SetOrMapLiteral` |
| `(e,)`, `(e1, e2)`, or `(<named fields>)`, with optional `const` | `RecordLiteral` with direct expression fields and `RecordLiteralNamedField` children | `RecordLiteral` | Field expressions have ordinary resolution; the literal owns field ordering and aggregate record type | Invalid arity, duplicate names, or mixed fields remain record topology; V1 is `RecordLiteral` |
| `(e)` | `ParenthesizedExpression` around the parsed or stable child | `ParenthesizedExpression` | Only delegated value and flow facts plus its own source range and precedence | Missing or extra delimiter recovery remains parenthesized syntax; V1 is `ParenthesizedExpression` |
| `(parameters) => e`, `(parameters) { ... }`, or generic function-literal forms | `FunctionExpression` | `FunctionExpression` | Declared fragment, inferred or declared function type, parameter correspondence, and ordinary body resolution | Invalid signatures or bodies remain `FunctionExpression` recovery; V1 is `FunctionExpression` |
| `new C(args)`, `const C.named(args)`, or implicit `C(args)` constructor syntax | Constructor-shaped parsed chain for implicit ambiguous syntax; explicit `new` and `const` can construct constructor structure directly | `ConstructorInvocation` with `ConstructorReference` and `ArgumentList` | Selected substituted `ConstructorElement`; argument correspondence belongs to `ArgumentList`; expression owns constructed `staticType` | Explicit constructor syntax remains `ConstructorInvocation` with nullable element when missing; ambiguous implicit syntax selects constructor topology only by the lowering rules; V1 is `InstanceCreationExpression` |
| `C.new` or `C.named` constructor tear-off | Parsed name chain until the type/static/property/constructor role is known | `ConstructorTearOff` with required `ConstructorTypeReference` and `ConstructorSelector` | Selected substituted constructor and tear-off `staticType` | A type-qualified missing constructor can retain constructor topology only when constructor syntax or distinguished recovery selects it; V1 is deprecated `ConstructorReference` |
| `E(value)` where `E` is an extension name | Parsed chain containing name and arguments | Non-expression `ExtensionOverride` in a receiver-capability slot, or `InvalidExtensionOverrideExpression` in an expression-only slot | Extension element, explicit and inferred type arguments, extended type, and resolved argument expression | The invalid value wrapper has `InvalidType` and no second resolution; V1 projects the current expression-shaped `ExtensionOverride` |
| `switch (e) { cases }` | `SwitchExpression` with parsed child expressions and pattern structure | `SwitchExpression` | Scrutinee and case expressions have ordinary resolution; flow, exhaustiveness, case scopes, and result inference belong to switch analysis | Invalid cases remain switch and pattern recovery; V1 is `SwitchExpression` |
| `<pattern> = e` when parsed as pattern assignment | `PatternAssignment` | `PatternAssignment` | Pattern-specific matched-value and assigned-variable write facts; the right side is an ordinary expression | Invalid patterns remain pattern recovery rather than becoming ordinary `AssignmentTarget`; V1 is `PatternAssignment` |
| `rethrow` in its admitted statement occurrence | `RethrowExpression` inside the corresponding statement topology | `RethrowExpression` | Abrupt completion and `Never` static type | Invalid context retains the node and diagnostics; V1 is `RethrowExpression` |
| `.name`, `.name(args)`, or constant constructor shorthand `const .name(args)` | `ParsedDotShorthandExpression` around the complete ordinarily structured selector expression, with `ParsedDotShorthandHead` in its leading `ParsedExpressionChain` island | `DotShorthandNameExpression`, `DotShorthandMethodInvocation`, `DotShorthandConstructorInvocation`, or `CallInvocation` over a shorthand name read, followed by retained ordinary selectors | `DotShorthandContextResolution` plus ordinary named-read, invocation, or substituted-constructor facts | A missing or unusable context produces `InvalidDotShorthandContextResolution`; a usable context with a missing member retains `ValidDotShorthandContextResolution` and uses invalid operation data on the same selected canonical role; invalid bare `const .name` remains token-preserving shorthand recovery rather than a valid constant tear-off form; V1 projects the current dot-shorthand property, invocation, or constructor node |

#### 14.2.2 Selectors, invocations, operators, assignments, and cascades

| Written form | Parse-time V2 | Canonical resolved V2 | Resolution facts | Invalid canonical form and V1 projection |
| --- | --- | --- | --- | --- |
| `receiver.name` or `receiver?.name` | Stable property node when the receiver role is already fixed; otherwise a parsed chain | `ReceiverPropertyExtraction` with `NamedReceiver` | `NamedReadResolution`; the operator token owns ordinary versus null-aware source structure | Namespace and missing-member failures retain the selected property or import-prefixed topology with invalid resolution; V1 is `PropertyAccess` or `PrefixedIdentifier` as appropriate |
| `prefix.name` where `prefix` is an import prefix | Parsed chain | `ImportPrefixedNameExpression(ImportPrefixReference(prefix.), name)` | `NamedReadResolution` for the imported declaration; the grouped prefix owns the period | Missing, hidden, or ambiguous imports retain import-prefixed topology with invalid resolution; V1 is `PrefixedIdentifier` or equivalent legacy property shape |
| `C.name` or `E.name` used for static selection | Parsed chain | `ReceiverPropertyExtraction(StaticQualifier, .name)` unless constructor syntax is selected | Qualifier element plus ordinary static `NamedReadResolution` | No static candidate defaults to property access with invalid resolution; constructor topology requires constructor syntax or distinguished recovery; V1 is legacy identifier/property access |
| `receiver[index]` or `receiver?[index]` | `ReceiverIndexExpression` around the smallest parsed receiver chain | `ReceiverIndexExpression` with `InstanceReceiver` | `IndexReadResolution`; question token records conditional evaluation and outer null shortening | Invalid receiver or operator retains `ReceiverIndexExpression` with invalid index resolution; non-value receiver structures use their precise recovery wrapper when the receiver slot requires it; V1 is `IndexExpression` |
| `f<T>(args)` where `f` directly selects a function or implicit-receiver method | Parsed chain containing type arguments and arguments | `UnqualifiedFunctionInvocation` | `ExecutableInvocationResolution` and argument correspondence | A selected variable or getter instead lowers to `CallInvocation`; unresolved direct-invocation recovery uses `UnqualifiedFunctionInvocation` with invalid resolution; V1 is `MethodInvocation` or `FunctionExpressionInvocation` |
| `receiver.method<T>(args)` | Parsed chain for method-versus-property-call ambiguity | `ReceiverMethodInvocation` | `ExecutableInvocationResolution`, dynamic resolution, or no invocation resolution when receiver evaluation cannot complete | A selected getter or field lowers to `CallInvocation(ReceiverPropertyExtraction)`; missing direct member defaults to `ReceiverMethodInvocation` with `InvalidInvocationResolution`; V1 is `MethodInvocation` |
| `prefix.function<T>(args)` where the import selects a top-level function | Parsed chain | `ImportPrefixedFunctionInvocation` | `ExecutableInvocationResolution` | An imported getter or variable lowers to `CallInvocation(ImportPrefixedNameExpression)`; unresolved imported invocation remains import-prefixed with invalid resolution; V1 is `MethodInvocation` |
| `..method<T>(args)` or `?..method<T>(args)` starting a cascade section | `CascadeSection` whose ambiguous body is parsed as a cascade-start chain | `CascadeMethodInvocation` | `InvocationResolution`; the section owns `..` or `?..` and supplies the active target privately | A getter or field followed by arguments becomes a cascade property read followed by `CallInvocation`; missing direct member retains cascade method topology with invalid resolution; V1 is target-less cascaded `MethodInvocation` |
| `.method<T>(args)` as a dot shorthand | Parsed shorthand chain | `DotShorthandMethodInvocation` when direct static method selection succeeds | `DotShorthandContextResolution` and `ExecutableInvocationResolution` | Getter or field selection lowers to `CallInvocation(DotShorthandNameExpression)`; constructor selection uses its constructor node; invalid direct method selection retains method topology with invalid resolution; V1 is `DotShorthandInvocation` |
| `value<T>` with written standalone type arguments | Parsed chain containing `ParsedTypeArguments` | `FunctionInstantiation` | Operand resolution plus resolved written type argument types and outer `staticType` | Constructor/type syntax retains its own type-argument ownership; invalid function instantiation remains a token-preserving `FunctionInstantiation` only when the selector is interpreted as function-value instantiation; V1 is `FunctionReference` |
| `value(args)` where the grouped or resolved receiver is a function value or callable object | Stable outer call when grouping already proves value application; otherwise parsed chain | `CallInvocation` | `FunctionTypeInvocationResolution` for an exact function type, `FunctionInterfaceInvocationResolution` for core `Function`, `ExecutableInvocationResolution` for implicit `call`, or dynamic or invalid invocation resolution; a receiver that cannot complete produces no invocation resolution | Invalid application retains `CallInvocation`; V1 is `FunctionExpressionInvocation` or legacy invocation recovery |
| `super(args)` or `E(value)(args)` in an ordinary expression context | Stable or lowered special receiver followed by arguments | `CallInvocation` whose receiver is `SuperReference` or `ExtensionOverride` | `ExecutableInvocationResolution` for the selected inherited or extension `call` method, or another invocation-result variant | Invalid `call` selection retains `CallInvocation`; the receiver does not become an expression or acquire a static type; V1 uses legacy invocation or extension-override projection |
| `value!` | `NullAssertion` around the parsed or stable operand | `NullAssertion` | Flow and resulting non-nullable `staticType`; no operation resolution | Non-value operands use precise invalid expression wrappers; V1 is `PostfixExpression` |
| `-value` or `~value` | `UnaryOperatorInvocation` around the smallest parsed receiver chain | `UnaryOperatorInvocation` | Selected `element`, expression `staticType`, and token-derived `UnaryOperator` | Invalid dispatch retains the node with null `element` and invalid type; V1 is `PrefixExpression` |
| `!value` | `LogicalNot` | `LogicalNot` | Boolean context, flow, and `staticType`; no selected operator element | Non-value operand uses a precise invalid expression wrapper; V1 is `PrefixExpression` |
| `++target` or `--target` | `PrefixIncrement` or `PrefixDecrement` with parsed or stable `AssignmentTarget` | The corresponding concrete prefix node | Target read/write resolution plus intervening `element` and `operatorResultType`; concrete type selects implicit `+` or `-` | Structurally impossible targets use an `InvalidAssignmentTarget`; honest locations use invalid read/write resolution; V1 is `PrefixExpression` |
| `target++` or `target--` | `PostfixIncrement` or `PostfixDecrement` with parsed or stable `AssignmentTarget` | The corresponding concrete postfix node | Target read/write resolution, operator result used for write-back, and old-value outer `staticType`; concrete type selects implicit `+` or `-` | Same target recovery rule as prefix increment/decrement; V1 is `PostfixExpression` |
| overloadable binary operators `*`, `/`, `%`, `~/`, `+`, `-`, `<<`, `>>`, `>>>`, `&`, `^`, `\|`, comparisons, `==`, and `!=` | `BinaryOperatorInvocation` around parsed or stable children | `BinaryOperatorInvocation` | Token-derived `BinaryOperator`, selected `element`, and expression `staticType`; left child admits `InstanceReceiver`, right child is `Expression` | Invalid dispatch retains the node with null `element` and invalid type; invalid non-value right operands use precise wrappers; V1 is `BinaryExpression` |
| `left && right` | `LogicalAnd` | `LogicalAnd` | Boolean contexts, right-operand evaluation on the true path, flow composition, and `staticType`; no operation resolution | Both children must be expressions and use precise invalid wrappers where necessary; V1 is `BinaryExpression` |
| `left \|\| right` | `LogicalOr` | `LogicalOr` | Boolean contexts, right-operand evaluation on the false path, flow composition, and `staticType`; no operation resolution | Both children must be expressions and use precise invalid wrappers where necessary; V1 is `BinaryExpression` |
| `left ?? right` | `IfNull` | `IfNull` | Context, flow, and result `staticType`; no operation resolution | Both children remain expression recovery; V1 is `BinaryExpression` |
| `e is T` or `e is! T` | `IsExpression` | `IsExpression` | Child expression resolution, type-annotation resolution, promotion facts, and `bool` static type | Invalid types remain `IsExpression` with type recovery; V1 is `IsExpression` |
| `e as T` | `AsExpression` | `AsExpression` | Child expression resolution, type-annotation resolution, and cast result `staticType` | Invalid types remain `AsExpression` with type recovery; V1 is `AsExpression` |
| `condition ? then : otherwise` | `ConditionalExpression` | `ConditionalExpression` | Boolean condition, branch contexts, flow, branch-local semantic adaptations, and result type | Invalid children remain ordinary expression recovery; V1 is `ConditionalExpression` |
| `await e` | `AwaitExpression` | `AwaitExpression` | Context propagation, await flattening, flow, and result `staticType`; no named operation resolution | Invalid async context or operand retains `AwaitExpression`; V1 is `AwaitExpression` |
| `throw e` | `ThrowExpression` | `ThrowExpression` | Operand resolution, abrupt completion, and `Never` static type | Invalid context retains `ThrowExpression`; V1 is `ThrowExpression` |
| `target = value` | `DirectAssignment` with parsed or stable target | `DirectAssignment` | Required target write and no target read; assigned value is an ordinary expression | Structurally impossible targets use precise invalid target variants; honest name/property/import/index targets retain invalid write resolution; V1 is `AssignmentExpression` |
| `target ??= value` | `IfNullAssignment` | `IfNullAssignment` | Target read and conditional write, flow, and outer result type; no selected operator element | Same target recovery split; V1 is `AssignmentExpression` |
| `target op= value` for overloadable compound operators | `CompoundAssignment` | `CompoundAssignment` | Target read, operator `element` and `operatorResultType`, target write, and outer result type | Same target recovery split plus null element and invalid operator result type as needed; V1 is `AssignmentExpression` |
| `target..section1..section2` or `target?..section` | `CascadeExpression` with explicit `CascadeSection` children and parsed bodies where needed | `CascadeExpression` with typed cascade-start body nodes | Target expression is evaluated once; sections reuse named, index, invocation, target, operator, and flow resolutions; outer static type is the target type | Invalid sections retain canonical section-local topology and invalid resolutions; invalid extension-override target uses the dedicated recovery described earlier; V1 uses legacy cascaded nodes with target-less children |
| `receiver.=> e`, `receiver.{...}`, `receiver.(parameter) => e`, or `receiver.(parameter) {...}` | `AnonymousMethodInvocation` | `AnonymousMethodInvocation` | Receiver evaluation, optional receiver formal, anonymous body scope, return inference, flow, and `staticType` | Invalid formal lists and receiver binding remain token-preserving anonymous-method recovery; V1 is the current `AnonymousMethodInvocation` |
| `..=> e`, `..{...}`, or the parameterized cascade anonymous forms | `CascadeSection` with cascade anonymous body | `CascadeAnonymousMethodInvocation` as the section body | Active cascade target supplied privately, optional receiver formal, anonymous body scope, and section-local result type | Invalid formal/body recovery remains cascade anonymous topology; V1 projects current cascaded anonymous-method representation |

#### 14.2.3 Contextual value roles and expression-adjacent syntax

| Contextual syntax | Canonical V2 ownership | Resolution or contextual facts | Invalid recovery and V1 projection |
| --- | --- | --- | --- |
| Positional argument `f(e)` | The `Expression` directly implements `Argument`; no wrapper | `correspondingParameter` on the contextual argument role; expression and invocation retain their own resolution | Argument-list recovery preserves the expression; V1 uses the expression directly |
| Named argument `f(name: e)` | `NamedArgument` owns name, colon, and value expression | Corresponding parameter and the name reference belong to the named argument; value has ordinary resolution | Unknown or duplicate name remains `NamedArgument`; V1 uses the current named-argument node |
| Ordinary list or set element `[e]` or `{e}` | The `Expression` directly implements `CollectionElement` | Element context comes from literal inference; no element resolution object | Invalid value remains expression recovery; V1 uses the expression directly |
| Null-aware element `[?e]` or `{?e}` | `NullAwareElement` owns `?` and value expression | Nullable element context, conditional contribution, and literal inference; no `staticType` or resolution on the wrapper | Invalid or unnecessary null awareness remains `NullAwareElement`; V1 uses the current node |
| Map entry `{key: value}`, `{?key: value}`, `{key: ?value}`, or `{?key: ?value}` | `MapLiteralEntry` owns optional key question, key expression, colon, optional value question, and value expression | Key/value contexts, key-before-value short circuit, and map inference; no entry resolution object | Invalid questions or types remain one map entry with diagnostics; V1 uses `MapLiteralEntry` |
| Spread `...e` or null-aware spread `...?e` | `SpreadElement` owns the operator and expression | Iterable/map context, conditional contribution for null-aware spread, and literal inference; no spread resolution object | Invalid spread operand remains `SpreadElement`; V1 is the current node |
| Collection `if`, `if-case`, `for`, or `await for` | `IfElement` or `ForElement` owns control syntax, scopes, declarations/patterns, and nested elements | Conditions, patterns, iterables, flow, and nested values use their ordinary analysis; no collection-control resolution object | Invalid control syntax remains the corresponding collection element recovery; V1 uses current nodes |
| Positional record field `(e, ...)` | The `Expression` directly implements `RecordLiteralField` | Record context and aggregate type; no field resolution object | Invalid value remains expression recovery; V1 uses the expression directly |
| Named record field `(name: e)` | `RecordLiteralNamedField` owns name, colon, and expression | The label is structural, not a declaration lookup; the record owns ordering/type | Duplicate or invalid names remain named-field recovery; V1 uses the current node |
| `$name` or `${e}` interpolation | `InterpolationExpression` owns delimiters and child expression | Child has ordinary resolution; string conversion is intrinsic and has no selected element or adaptation node | Invalid interpolation remains interpolation recovery; V1 uses the current node |
| Variable, field, or pattern declaration initializer | Declaration owns its initializer expression directly | Declared type supplies context; declaration fragment/element owns the binding; this is initialization rather than `NamedWriteResolution` | Invalid initializer remains on the declaration; V1 uses the current declaration topology |
| Formal-parameter default value | Default-clause syntax owns the expression | Parameter type supplies context; constant evaluation and parameter binding remain separate | Invalid default remains default-clause recovery; V1 uses the current formal-parameter topology |
| Return expression, expression function body, or yielded expression | Enclosing statement/body owns the expression | Enclosing executable return/yield type supplies context; expression has ordinary resolution | Invalid executable context retains the enclosing source node and expression; V1 uses current nodes |
| Conditions and guards of `if`, loops, assertions, switch guards, and pattern guards | Enclosing statement, element, assertion, or guard owns the expression | Boolean context, flow, and pattern facts; no condition-resolution object | Invalid condition remains expression recovery in the same owner; V1 uses current nodes |
| Expression statement `e;` | `ExpressionStatement` owns one expression | Expression's own static type and operations; the statement discards the value | Non-value `super` and extension override use precise invalid expression wrappers; V1 uses `ExpressionStatement` |
| Traditional `for` initializer expression, condition, and updater expressions | `ForPartsWithExpression` or the declaration-specific `ForParts` owner keeps the existing expressions in their grammar slots | Initializer/updaters use ordinary expression resolution; condition receives boolean context and flow analysis | Invalid clauses remain in the enclosing `ForStatement`; V1 uses the current for-parts topology |
| Constant-pattern expression and legacy switch-case constant | `ConstantPattern` or the corresponding compatibility switch-case structure owns the expression | Constant context and the expression's ordinary type/name/constructor resolution; pattern matching owns no additional value-resolution object | Invalid constants remain pattern or switch recovery; this expression-hierarchy design does not otherwise restructure patterns |
| Map-pattern key, relational-pattern operand, or pattern-variable-declaration initializer | Existing `MapPatternEntry`, `RelationalPattern`, or `PatternVariableDeclaration` owns the expression | Required constant or comparison context, matched-value constraints, binding, and the expression's ordinary resolution | Invalid pattern expressions remain in pattern-specific recovery; this design does not convert them to assignment targets or add a general pattern-expression resolution |
| Switch-statement scrutinee | `SwitchStatement` owns the expression; each pattern/case and guard retains its own source node | Scrutinee context, exhaustiveness/flow analysis, and ordinary expression resolution | Invalid scrutinee or members remain switch/pattern recovery; V1 uses the current switch topology |
| Assertion condition and optional message | `AssertStatement` or `AssertInitializer` owns both expressions | Condition receives boolean context; message and both child expressions use ordinary resolution and constant-context rules appropriate to the owner | Invalid assertion syntax remains assertion recovery; `assert(...)` parsed in a general expression slot is parser recovery, not another valid expression form |
| Constructor field initializer `this.field = e` | `ConstructorFieldInitializer` owns optional `this.`, field token, selected field, equals token, and expression | Field type supplies context; direct field-storage initialization rather than setter invocation | Null field element represents unresolved/invalid selection; V1 synthesizes the legacy field-name identifier |
| Redirecting initializer `this(...)` or `this.named(...)` | `RedirectingConstructorInvocation` | Selected substituted constructor and argument correspondence; no expression `staticType` | Missing constructor retains initializer topology and nullable element; V1 uses current initializer node |
| Super initializer `super(...)` or `super.named(...)` | `SuperConstructorInvocation` | Selected substituted constructor and argument correspondence; no expression `staticType` | Missing constructor retains initializer topology and nullable element; V1 uses current initializer node |
| Factory redirection target `factory C(...) = D.named;` | `ConstructorDeclaration.factoryRedirectionTarget` contains `ConstructorReference` (`ConstructorReference2` during migration) without an argument list | Selected substituted target constructor; the surrounding factory declaration supplies the redirecting signature | Missing target retains the constructor-reference topology and nullable element; V1 uses the current factory-redirection structure |
| Constructor-form annotation `@C(...)` or `@C.named(...)` | Current union-like `Annotation`, pending an optional future split | Selected substituted constructor, arguments, constant restrictions, and element annotation | Constant-reference versus constructor-form API remains an explicit open structural question; V1 is current `Annotation` |
| Constant-reference annotation `@constant` or qualified equivalent | Current union-like `Annotation` | Selected constant declaration and element annotation; no expression value node | Missing or invalid constant remains annotation recovery; V1 is current `Annotation` |
| Enum constant with optional `.named(args)` suffix | `EnumConstantDeclaration` owns the selected constructor; optional `EnumConstantArguments` owns only written suffix syntax | Substituted enum constructor, explicit argument correspondence, and implicit `index` and `name` arguments | Missing constructor remains enum declaration topology with nullable element; V1 uses current enum nodes |
| Unqualified assignment target `x` | `UnqualifiedNameAssignmentTarget` once assignment or increment/decrement syntax fixes the target role | Direct `NamedReadResolution? read` and `NamedWriteResolution? write` according to the enclosing protocol | Invalid lookup remains the same honest target with non-null invalid operation resolution; V1 projects `SimpleIdentifier` |
| Property assignment target `receiver.name` or `receiver?.name` | `ReceiverPropertyAssignmentTarget` with `NamedReceiver`; an ambiguous namespace/value receiver begins in `ParsedAssignmentTargetChain` and lowers to this role when property targeting is selected | Getter/setter asymmetry is represented by direct independent read/write results; a receiver path that prevents access produces null read and write | Invalid lookup retains property-target topology; V1 is `PropertyAccess` or an identifier-shaped target |
| Import-prefixed assignment target `prefix.name` | `ImportPrefixedAssignmentTarget(ImportPrefixReference(prefix.), name)` after a parsed target chain selects the namespace role | Imported getter/setter or variable results belong directly to the target's `read` and `write` | Hidden or missing name remains an import-prefixed target with invalid read or write resolution; V1 is `PrefixedIdentifier` |
| Static, extension-static, super, or explicit-extension property target | `ReceiverPropertyAssignmentTarget` with `StaticQualifier`, `SuperReference`, or `ExtensionOverride` receiver, parsed neutrally only where the receiver role is ambiguous | Outer named read/write results record getter/setter dispatch; receiver role records static, superclass, or explicit-extension selection | Invalid member selection retains property-target topology; V1 uses legacy property access |
| Index assignment target `receiver[index]` or `receiver?[index]` | Stable `ReceiverIndexAssignmentTarget` around the smallest parsed receiver chain | Direct `IndexReadResolution? read` and `IndexWriteResolution? write`; receiver and index remain value expressions or an admitted special receiver, and null read and write record that the receiver prevents the protocol | Invalid `[]`/`[]=` lookup retains index-target topology with non-null invalid operation resolution; V1 is `IndexExpression` in an assignment context |
| Cascade property or index assignment target | `CascadeSection` with `CascadePropertyAssignmentTarget` or `CascadeIndexAssignmentTarget` body | Ordinary named or index read/write results live directly on the target; active cascade receiver supplied privately | Invalid member/operator selection retains the cascade-start target and invalid resolution; V1 uses target-less cascaded property/index nodes |
| Expression, extension override, or super in a syntactic target position that cannot denote a location | Parser construction or lowering selects `InvalidExpressionAssignmentTarget`, `InvalidExtensionOverrideAssignmentTarget`, or `InvalidSuperAssignmentTarget` | Invalid write and, when `hasRead`, invalid read resolution; a compound-assignment or increment/decrement resolver may use the fully resolved child for operator recovery | V1 projects the closest legacy left-hand-side expression and diagnostics |
| Existing-variable for-in `for (x in iterable)` or `await for` | `ForEachPartsWithIdentifier` owns identifier, `in`, iterable, and `NamedWriteResolution` | Destination accepted type supplies iterable element context; no assignment-target or expression node for `x` | Invalid destination uses `InvalidNamedWriteResolution`; V1 projects the legacy identifier |
| Declaration and pattern for-in forms | Existing declaration- or pattern-specific `ForEachParts` variants | Declaration/pattern binding, iterable analysis, and flow | Recovery remains in the corresponding declaration/pattern form; V1 uses current nodes |
| Field formal `this.field` | `FieldFormalParameter` owns tokens and declared fragment | Parameter element owns its associated field and effective/private name facts | Invalid association is nullable on the element relationship; no assignment resolution; V1 uses current node |
| Super formal `super.parameter` | `SuperFormalParameter` owns tokens and declared fragment | Parameter element owns its associated superclass parameter; enclosing constructor owns constructor selection | Invalid association is nullable on the element relationship; no invocation or write resolution; V1 uses current node |
| Assignment-pattern variable leaves | Pattern-specific assigned-variable nodes | Matched value type, destination write type, deferred atomic commit, and flow | Invalid pattern writes remain pattern resolution; they do not become ordinary assignment targets |

#### 14.2.4 Exhaustive semantic-operation resolution ledger

| Semantic operation | Owning source role | Required successful result | Invalid, dynamic, unreachable, or special result |
| --- | --- | --- | --- |
| Direct variable or parameter read | Unqualified, import-prefixed, property, cascade, or shorthand name expression where direct storage read is meaningful | `VariableReadResolution(element, type)` | `InvalidNamedReadResolution`; dynamic property cases use their dedicated named-read result, while an unreachable receiver produces no read result |
| Getter or field-property read | Same named-read owners | `GetterInvocationResolution(element, invokeType, type)` | `DynamicPropertyReadResolution` or `InvalidNamedReadResolution(candidates, recovery)`; an unreachable receiver produces no read resolution |
| Function, method, or constructor tear-off represented by a named-read owner | Same named-read owners, including dot shorthand | `ExecutableTearOffResolution(element, type)` | `InvalidNamedReadResolution`; ordinary constructor-qualified syntax instead uses `ConstructorTearOff` |
| Tear-off of the special `call` method of a function value | Property or cascade property extraction, unqualified name expression with an implicit function-typed receiver, or corresponding target read | An exact function signature uses `FunctionCallTearOffResolution(type, associatedFunctionType)`; `type` can be a type parameter that is `associatedFunctionType`-bounded | Core `Function` or a type parameter bounded by it uses `FunctionInterfaceCallTearOffResolution(type)`; invalid or unreachable receivers use their corresponding result |
| Structural record-field read | `ReceiverPropertyExtraction` | `RecordFieldReadResolution(type)` | Invalid named read for missing fields; record receivers are never dynamic solely because they are records |
| Direct variable or parameter write | Unqualified target or existing-variable for-in owner | `VariableWriteResolution(element, acceptedType)` | `InvalidNamedWriteResolution` |
| Setter/property write | Property, import-prefixed, or cascade property target | `SetterInvocationResolution(element)`; `acceptedType` is the selected setter's value-parameter type | `DynamicPropertyWriteResolution` or `InvalidNamedWriteResolution(recoveryElement)`; a receiver path that cannot execute produces no write result |
| Combined named target access | Name/property/import/cascade target | Direct `NamedReadResolution? read` and `NamedWriteResolution? write`, with read presence determined by the enclosing assignment or increment/decrement protocol | Null read and write mean that the receiver prevents the protocol; structural non-target source uses an `InvalidAssignmentTarget`; valid target syntax with failed lookup uses non-null invalid read/write results |
| Index read through `operator []` | `ReceiverIndexExpression`, `CascadeIndexExpression`, or implicit read of an `IndexAssignmentTarget` | `MethodIndexReadResolution(element, type)` | `DynamicIndexReadResolution` or `InvalidIndexReadResolution(recoveryElement)`; null means unresolved or that receiver evaluation prevents the operation |
| Index write through `operator []=` | `ReceiverIndexAssignmentTarget` or cascade index target | `MethodIndexWriteResolution(element, acceptedType)` | `DynamicIndexWriteResolution` or `InvalidIndexWriteResolution(recoveryElement)`; null target read and write mean neither index operation can execute |
| Direct named executable invocation | Concrete `NamedFunctionInvocation` | `ExecutableInvocationResolution(element, invokeType, type)` | `DynamicInvocationResolution` or `InvalidInvocationResolution(candidates, recovery)`; a receiver that cannot complete produces no invocation result |
| Direct named invocation of the special `call` method of a function type | `ReceiverMethodInvocation`, `UnqualifiedFunctionInvocation`, or `CascadeMethodInvocation` | `FunctionCallInvocationResolution(invokeType, type)` | Core `Function` uses `FunctionInterfaceInvocationResolution(type: dynamic)`; dynamic and invalid receivers use their corresponding result, while a receiver that cannot complete produces no result |
| Application of an already function-typed value | `CallInvocation` | `FunctionTypeInvocationResolution(invokeType, type)` | Core `Function` uses `FunctionInterfaceInvocationResolution(type: dynamic)`; dynamic and invalid values use their corresponding result, while a value that cannot complete produces no result |
| Implicit `call` invocation on a callable object, `super`, or extension override | `CallInvocation` | `ExecutableInvocationResolution(callElement, invokeType, type)` | Dynamic or invalid invocation result; a receiver that cannot complete produces no result; the implicit reference has no member-name token |
| Overloadable binary or unary operator | `BinaryOperatorInvocation`, `UnaryOperatorInvocation`, compound assignment, increment, or decrement | Selected substituted `MethodElement`; ordinary invocations use `staticType`, while compound-assignment and increment-or-decrement nodes use `operatorResultType` | Null element with dynamic, `Never`, or `InvalidType` result as appropriate |
| Equality where language rules perform no method invocation | Equality `BinaryOperatorInvocation` | Null `element` and `staticType: bool` | Invalid equality uses null `element` and canonical `InvalidType`; exact ownership for both null operand orders follows the equality rules already discussed |
| Constructor selection/application | `ConstructorReference`, `ConstructorTearOff`, dot-shorthand constructor invocation, super/redirecting initializer, annotation, or enum declaration | Selected substituted `ConstructorElement`; its `type` is the effective signature | Nullable element denotes unresolved/invalid selection until a concrete need justifies a sealed constructor result hierarchy |
| Static namespace qualification | `StaticQualifier` | Selected qualifier `Element` plus the outer named operation's resolution | Nullable/recovery element on the qualifier and invalid outer named operation |
| Import namespace qualification | `ImportPrefixReference` embedded in a precise import-prefixed owner, `NamedType`, constructor reference, static qualifier, or extension override | Selected `PrefixElement`; outer owner resolves the imported declaration | Invalid `prefix?.name` is ordinary property access with prefix candidate recovery, never an import-prefix reference |
| Explicit extension override selection | `ExtensionOverride` | Extension element, extended type, and resolved type arguments | Invalid selection preserves candidates and argument syntax without giving the override a value `staticType` |
| Type-object production | `TypeLiteral(NamedType)` | Resolved `NamedType`; expression static type `Type` | Invalid type syntax or declaration remains type resolution recovery without `NamedReadResolution` |
| Dot-shorthand namespace selection | Concrete dot-shorthand expression/invocation | `ValidDotShorthandContextResolution` or `InvalidDotShorthandContextResolution` plus the selected ordinary operation result | Missing/unusable context is distinct from a valid context whose namespace lacks the requested member; the valid result exposes `contextType` and normalized `lookupType`, and its namespace declaration is `lookupType.element` |
| Written generic function instantiation | `FunctionInstantiation` | Resolved written type argument types and instantiated outer static type | Invalid arity/bounds remain on the same source node; callable-object operands may contain `ImplicitCallTearOff` |
| Context-induced generic function instantiation | `ImplicitFunctionInstantiation` | Operand, inferred type argument types, and instantiated outer static type | Inserted only when the language operation occurs; placement remains operation-rule dependent |
| Implicit conversion of callable object to bound `call` tear-off | `ImplicitCallTearOff` | Operand, selected `call` method, and resulting function static type | Placement follows the separate implicit-tear-off rule; no token or synthetic member-name child |
| Explicit argument-to-parameter matching | Direct expression argument or `NamedArgument` | `correspondingParameter` and ordinary invocation/constructor signature facts | Unmatched arguments retain null correspondence and diagnostics |
| Null shortening | Resolver-managed region across property, invocation, index, target, increment/decrement, and cascade topology | Outer node static type and operation-result `type` include shortening where appropriate | No `NullShortingExpression` or dedicated resolution object |
| Constant evaluation and intrinsic conversions | Every potentially constant expression, collection component, interpolation, annotation, and constructor site | Derived constant-evaluation result; interpolation conversion and iterable/await protocols are intrinsic analysis operations | Not represented as named-reference resolution unless a written or language-defined reference is independently useful |

#### 14.2.5 Parser-only lowering and phase ledger

| Parser-only or ambiguous form | Resolution-dependent choices | Required canonical outcome | Stability and recovery requirements |
| --- | --- | --- | --- |
| One-head `ParsedNameHead(foo)` | Variable/getter/tear-off, type literal, non-value prefix/extension, unresolved, or ambiguous declaration | `UnqualifiedNameExpression`, `TypeLiteral`, or honest invalid name expression | Preserve name token and range; no parsed node survives |
| `ParsedNameHead(foo) + ParsedNameAccess(.bar)` | Value property, import-prefixed name, static property, constructor tear-off, named extension static access, or invalid default | Precise property/import/static/constructor role selected by the lookup matrix in section 8.5 | Preserve operator and name tokens; deterministic no-candidate default is value-receiver property access |
| Parsed target chain `foo.bar` before assignment or increment/decrement | Value property target, import-prefixed target, static setter target, or invalid structural target | `ReceiverPropertyAssignmentTarget`, `ImportPrefixedAssignmentTarget`, or precise invalid target | Never lower a write-only occurrence to an ordinary expression merely to reuse read APIs |
| Parsed `foo(args)` | Direct function/method invocation, callable value, constructor invocation, extension override, or invalid invocation | `UnqualifiedFunctionInvocation`, `CallInvocation`, `ConstructorInvocation`, `ExtensionOverride`, or precise invalid wrapper/default | Argument-list object and corresponding-parameter data survive; invalid canonical topology follows section 8.5 |
| Parsed `foo.bar(args)` | Receiver method, getter/field followed by call, import-prefixed function, constructor, static method, imported/static callable property, or extension override | One of the concrete named invocations, `CallInvocation` over a named read, constructor role, or extension override | No untyped invocation target; preserve both selector and argument tokens |
| Parsed standalone `<T>` selector | Function instantiation versus constructor/type argument ownership | `FunctionInstantiation`, `ConstructorTypeReference`, constructor invocation/tear-off, or invalid owner selected by grammar and lookup | Type-argument-list identity survives when its canonical owner survives |
| Parsed `<T>(args)` selector | Direct generic invocation, constructor syntax, or callable value instantiation/application | Concrete named invocation, constructor invocation, or `CallInvocation` with any required nested `FunctionInstantiation` | Preserve grouping rules such as `C.named<int>` versus `(C.named)<int>` |
| Stable `ReceiverIndexExpression` whose receiver is a parsed chain | Runtime `Type` value, ordinary value, extension override, super, or invalid value | Keep the same outer index node and replace only its receiver | Index and bracket identity survive; receiver lowering must not reinterpret `C[0]` as static indexing |
| Stable null assertion, parentheses, binary/control node, argument, collection element, record field, interpolation, or initializer containing a parsed chain | Child name/type/receiver role only | Keep stable outer node and replace the parsed child once | Outer identity, context routing, null shortening, comments, and parent links survive |
| Parsed `super.name(args)` | Direct super method versus super getter followed by call | `ReceiverMethodInvocation(SuperReference)` or `CallInvocation(ReceiverPropertyExtraction(SuperReference))` | Preserve the one `SuperReference`; bare invalid super uses `InvalidSuperExpression` |
| Parsed extension-looking `E(value)` followed by selector/index/call/operator | Extension override versus ordinary callable/constructor/name recovery | `ExtensionOverride` in admitted receiver slots; otherwise ordinary selected value/call/constructor topology | Complete invalid override in expression slot uses `InvalidExtensionOverrideExpression`, not a fake static type on the override |
| Parsed dot shorthand maximal chain | `ParsedDotShorthandExpression` owns the ordinarily structured complete shorthand expression; its unique leading ambiguous island has `ParsedDotShorthandHead`, while index, null assertion, null-aware selection, and other stable selectors retain their ordinary nodes | One of the three concrete shorthand heads followed by retained ordinary canonical nodes | The wrapper receives the maximal-chain shorthand context and routes it to the unique head before disappearing; an immediate equality RHS sees the wrapper directly, and surrounding parentheses terminate the boundary |
| Parsed cascade section body | Property/index read or target, method/call invocation, increment/decrement, assignment, anonymous method, and trailing ordinary selectors | One `CascadeSection` with one typed body node | Section owns `..`/`?..`; no public receiver child or `cascadeTarget` on cascade-start nodes |
| Invalid name/property/index/invocation/operator/constructor after completed lookup | Valid source topology with failed semantic operation | Same canonical source node with the corresponding invalid resolution or nullable constructor element | Parsed syntax never survives merely because resolution failed |
| Complete non-value receiver forced into expression slot | Extension override or bare super | `InvalidExtensionOverrideExpression` or `InvalidSuperExpression` | Wrapper owns no tokens and is visible recovery structure, not a semantic adaptation |
| Structurally impossible assignment target | Value expression, extension override, or super | Corresponding precise `InvalidAssignmentTarget` subtype | Target records invalid read/write resolutions according to `hasRead`; its child remains fully resolved |
| Contextual function adaptation | Generic function value or callable object coerced by context | Insert `ImplicitFunctionInstantiation`, `ImplicitCallTearOff`, or their semantic-order nesting | No parse-only adaptation; insertion finishes before resolved clients observe the tree |
| V1 request for a parse-only unit | Neutral V2 chain has no legacy equivalent | Cached legacy guessed expression/target projection permitted only outside the resolution pipeline | Resolution pipeline asserts that no V1 projection exists before lowering |
| Resolved-unit publication | All lowering and semantic insertion complete | Canonical resolved tree with no parsed heads/components | Verify reciprocal parents, unique ownership, preserved first/last tokens, no discarded semantic-map keys, and synchronized serialization/projections |

#### 14.2.6 Whole-AST dependency boundary

The ledger above is exhaustive for expression syntax and the adjacent source roles whose value, write, invocation, or constructor semantics directly interact with this design. It is not by itself an exhaustive redesign of every Dart AST node. Removing `Identifier`, `SimpleIdentifier`, and `PrefixedIdentifier` creates a whole-AST dependency that must be tracked separately:

| Non-expression name role | V2 direction | Coverage status |
| --- | --- | --- |
| Declaration names and declared fragments | Owning declaration exposes its written token and fragment/element directly | Direction established; individual declarations still require generator-by-generator migration |
| Type annotations | `NamedType`, type-parameter, function-type, and structural type nodes own tokens and type resolution | Existing V2 direction is largely established; not redefined by this expression proposal |
| Named arguments | `NamedArgument` owns the name token and corresponding parameter | Covered by this ledger |
| Labels and label uses | `Label` and `LabelReference` own tokens and label elements | Existing V2 direction established |
| Constructor type references and selectors | `ConstructorTypeReference`, `ConstructorSelector`, and `ConstructorReference` own tokens and substituted constructor selection | Covered by this ledger |
| Import prefixes used for qualification | `ImportPrefixReference` owns prefix and period only inside precise qualified source roles | Covered by this ledger |
| Documentation references | Dedicated non-expression `CommentReference` components own tokens and navigation elements | Covered structurally in section 6.1; exact component API remains open |
| Annotations | Split constant-reference and constructor-invocation roles eventually, or keep the current union with typed nullable facts during migration | Structurally open |
| Import/export combinator names | Replace identifier children with source-role-owned tokens plus any declaration/reference facts actually required by indexing | Outside the expression design and not yet exhaustively specified |
| Directive, configuration, library, augmentation, and other qualified names | Preserve their grammar-specific token containers and role-specific resolution; do not route them through value expressions | Outside the expression design and not yet exhaustively specified |
| Remaining declaration, parameter, pattern, and member-name occurrences | Use owner tokens and fragments/elements; add a common interface only after a demonstrated client need | Outside the expression design and requires a separate whole-AST identifier-removal ledger |

The expression hierarchy can therefore be considered source-form complete once the remaining no-token adaptation contract and invalid/recovery payloads are settled, but the broader statement “V2 removes all identifier nodes everywhere” requires the separate whole-AST migration ledger named in the final row. The two claims should not be conflated.

### 14.3 Representative V1 projections

Representative projections include:

```dart
V2 ParsedExpressionChain in a parse-only unit
  -> V1 legacy expression-shaped parse tree

V2 ParsedAssignmentTargetChain in a parse-only unit
  -> V1 legacy expression-shaped left-hand-side parse tree

V2 ParsedDotShorthandExpression in a parse-only unit
  -> V1 current dot-shorthand parse tree for its complete selector expression

V2 TopLevelFunctionDeclaration
  -> V1 FunctionDeclaration whose synthetic FunctionExpression projection
     groups the V2 type parameters, formal parameter list, and body

V2 LocalFunctionDeclaration
  -> V1 FunctionDeclarationStatement containing a synthetic
     FunctionDeclaration whose synthetic FunctionExpression projection
     groups the V2 type parameters, formal parameter list, and body

V2 FunctionExpression
  -> V1 FunctionExpression

V2 ConstructorInvocation
  -> V1 InstanceCreationExpression

V2 ConstructorTearOff
  -> V1 deprecated ConstructorReference expression

V2 UnqualifiedNameExpression
  -> V1 SimpleIdentifier

V2 UnqualifiedNameAssignmentTarget
  -> V1 SimpleIdentifier used as AssignmentExpression.leftHandSide

V2 DirectAssignment / IfNullAssignment / CompoundAssignment
  -> V1 AssignmentExpression

V2 InvalidExpressionAssignmentTarget
  -> its contained expression as the V1 assignment or increment/decrement operand

V2 InvalidExtensionOverrideAssignmentTarget
  -> V1 ExtensionOverride expression as the assignment or increment/decrement operand

V2 InvalidSuperAssignmentTarget
  -> V1 SuperExpression as the assignment or increment/decrement operand

V2 ReceiverPropertyExtraction
  -> V1 PropertyAccess or PrefixedIdentifier according to legacy source shape

V2 ReceiverPropertyAssignmentTarget
  -> V1 PropertyAccess or PrefixedIdentifier used as the left-hand side

V2 ReceiverPropertyExtraction / ReceiverPropertyAssignmentTarget
  with StaticQualifier receiver
  -> V1 PrefixedIdentifier or PropertyAccess according to legacy source shape

V2 ImportPrefixedNameExpression
  -> V1 PrefixedIdentifier

V2 ImportPrefixedAssignmentTarget
  -> V1 PrefixedIdentifier used as the left-hand side

V2 TypeLiteral with NamedType
  -> V1 TypeLiteral with the corresponding legacy NamedType view

V2 FunctionInstantiation with an ordinary function-valued operand
  -> V1 FunctionReference with written type arguments

V2 FunctionInstantiation with ImplicitCallTearOff operand
  -> V1 ImplicitCallReference with written type arguments

V2 ImplicitFunctionInstantiation with an ordinary function-valued operand
  -> V1 FunctionReference with no written type arguments

V2 ImplicitFunctionInstantiation with ImplicitCallTearOff operand
  -> V1 ImplicitCallReference with inferred type arguments

V2 ImplicitCallTearOff without an enclosing instantiation
  -> V1 ImplicitCallReference

V2 UnqualifiedFunctionInvocation / ReceiverMethodInvocation
  -> V1 MethodInvocation

V2 ImportPrefixedFunctionInvocation
  -> V1 MethodInvocation whose target is the import prefix

V2 CallInvocation
  -> V1 FunctionExpressionInvocation

V2 CascadeMethodInvocation
  -> V1 target-less MethodInvocation with .. or ?.. metadata

V2 AnonymousMethodInvocation
  -> V1 ordinary AnonymousMethodInvocation with an explicit receiver

V2 CascadeAnonymousMethodInvocation
  -> V1 target-less AnonymousMethodInvocation with .. or ?.. metadata

V2 DotShorthandNameExpression
  -> V1 DotShorthandPropertyAccess

V2 DotShorthandMethodInvocation
  -> V1 DotShorthandInvocation

V2 DotShorthandConstructorInvocation
  -> V1 DotShorthandConstructorInvocation

V2 ExtensionOverride as a non-expression receiver
  -> V1 ExtensionOverride expression

V2 InvalidExtensionOverrideExpression
  -> V1 ExtensionOverride expression in the invalid value slot

V2 SuperReference
  -> V1 SuperExpression

V2 InvalidSuperExpression
  -> V1 SuperExpression in the invalid value slot

V2 BinaryOperatorInvocation / LogicalAnd / LogicalOr / IfNull
  -> V1 BinaryExpression

V2 UnaryOperatorInvocation / LogicalNot / PrefixIncrement / PrefixDecrement
  -> V1 PrefixExpression

V2 NullAssertion / PostfixIncrement / PostfixDecrement
  -> V1 PostfixExpression

V2 ReceiverIndexExpression
  -> V1 IndexExpression

V2 ReceiverIndexAssignmentTarget
  -> V1 IndexExpression used as the left-hand side

V2 cascade property/index starter nodes
  -> V1 target-less PropertyAccess or IndexExpression with .. or ?.. metadata

V2 CommentReference with non-expression components
  -> V1 CommentReference containing SimpleIdentifier, PrefixedIdentifier, or PropertyAccess according to component count

```

These projections require correct V1 and V2 parent links, child-entity traversal, covering-node behavior, and delegated semantic properties. A standalone parse-only V1 projection of a parsed chain may synthesize and cache the legacy guessed tree even though V2 deliberately retains the neutral chain; that parse tree is not subsequently transformed into a resolved result. A tree in the resolution pipeline must not materialize a V1 projection until lowering has installed the canonical V2 nodes, and the implementation should assert this boundary rather than attempt to replace or synchronize a projection created from provisional syntax. V1 projection can collapse nested V2 semantic adaptations when the current V1 node already combines the same operations, most notably an `ImplicitCallReference` that stores inferred or written type arguments for the selected `call` tear-off.

Every V1 `SimpleIdentifier` or `PrefixedIdentifier` in these mappings is compatibility structure synthesized from direct V2 owner tokens and source-role nodes. There is no canonical V2 identifier node whose identity must be shared with the projection. A cached projection can preserve stable V1 identity while delegating its token and resolved element to the V2 owner or resolution that supplies the corresponding legacy fact.

The parser, resolver, flow analysis, summary reader and writer, constant evaluation, and analyzer-owned visitors should operate on V2 nodes. V1 should not become an independent second implementation model.

### 14.4 Compact canonical inventory and coherence audit

The crosswalk and grammar ledger establish coverage, but they deliberately repeat nodes under each source spelling and semantic operation. The following compact inventory removes that repetition and shows the proposed resolved V2 expression hierarchy in one place. Indentation denotes primary AST taxonomy; comments call out important cross-cutting capabilities that do not create another parent-child layer:

```dart
Expression
  Literal
    BooleanLiteral
    DoubleLiteral
    IntegerLiteral
    NullLiteral
    RecordLiteral
    SymbolLiteral
    StringLiteral
      AdjacentStrings
      SingleStringLiteral
        SimpleStringLiteral
        StringInterpolation
    TypedLiteral
      ListLiteral
      SetOrMapLiteral

  NameExpression
    UnqualifiedNameExpression
    ImportPrefixedNameExpression
    DotShorthandNameExpression               // also DotShorthandExpression
    PropertyExtraction
      ReceiverPropertyExtraction
      CascadePropertyExtraction
  TypeLiteral

  FunctionExpression
  ParenthesizedExpression
  AsExpression
  IsExpression
  AwaitExpression
  ConditionalExpression
  SwitchExpression
  ThisExpression
  ThrowExpression
  RethrowExpression
  PatternAssignment

  AssignmentExpression
    DirectAssignment
    IfNullAssignment
    CompoundAssignment
  IncrementOrDecrementExpression
    PrefixIncrement
    PrefixDecrement
    PostfixIncrement
    PostfixDecrement

  IndexExpression
    ReceiverIndexExpression
    CascadeIndexExpression
  CascadeExpression

  FunctionInvocation
    NamedFunctionInvocation
      UnqualifiedFunctionInvocation
      ReceiverMethodInvocation
      ImportPrefixedFunctionInvocation
      CascadeMethodInvocation
      DotShorthandMethodInvocation           // also DotShorthandExpression
    CallInvocation
  ConstructorInvocation
  ConstructorTearOff
  DotShorthandConstructorInvocation          // also DotShorthandExpression
  AnonymousMethodInvocation
  CascadeAnonymousMethodInvocation

  BinaryExpression
    BinaryOperatorInvocation
    LogicalAnd
    LogicalOr
    IfNull
  UnaryOperatorInvocation
  LogicalNot
  NullAssertion

  FunctionInstantiation
  ImplicitCallTearOff                         // resolution-only adaptation
  ImplicitFunctionInstantiation              // resolution-only adaptation

  InvalidExtensionOverrideExpression         // invalid value placement only
  InvalidSuperExpression                     // invalid value placement only
```

Direct expressions additionally implement the contextual `Argument`, `CollectionElement`, and `RecordLiteralField` roles, but those roles do not add wrapper expressions. `DotShorthandExpression` is a cross-cutting source capability implemented by the three leading shorthand operations rather than another exclusive branch. A possible `SemanticAdaptation` interface is likewise only a common operand API for the two no-token adaptation nodes; the concrete adaptations remain the canonical operations even if that interface stays internal.

The resolved non-expression structures that directly participate in expression topology are:

```dart
AssignmentTarget
  UnqualifiedNameAssignmentTarget
  PropertyAssignmentTarget
    ReceiverPropertyAssignmentTarget
    CascadePropertyAssignmentTarget
  ImportPrefixedAssignmentTarget
  IndexAssignmentTarget
    ReceiverIndexAssignmentTarget
    CascadeIndexAssignmentTarget
  InvalidAssignmentTarget
    InvalidExpressionAssignmentTarget
    InvalidExtensionOverrideAssignmentTarget
    InvalidSuperAssignmentTarget

NamedReceiver
  InstanceReceiver
    Expression
    ExtensionOverride
    SuperReference
  StaticQualifier

ImportPrefixReference                        // namespace qualifier, not receiver
ConstructorTypeReference
ConstructorSelector
ConstructorReference                        // optional selector
CascadeSection
AnonymousMethodBody
  AnonymousExpressionBody
  AnonymousBlockBody
```

`InstanceReceiver` refines `NamedReceiver`: an expression, extension override, or superclass reference can fill both kinds of slot, while a static qualifier can fill only a named-selection slot. These are source capabilities rather than ownership nodes. `ImportPrefixReference` is deliberately outside both because `prefix.` is owned by precise import-prefixed nodes. `ConstructorReference` means only the written type reference plus optional selector currently named `ConstructorReference2`; constructor tear-offs and dot shorthand retain their different required source shapes.

The syntax-bearing contextual and nearby roles covered by the design without joining `Expression` or `AssignmentTarget` are:

```dart
Argument
  Expression                                  // direct positional argument
  NamedArgument

CollectionElement
  Expression                                  // direct list or set element
  MapLiteralEntry
  NullAwareElement
  SpreadElement
  IfElement
  ForElement

RecordLiteralField
  Expression                                  // direct positional field
  RecordLiteralNamedField

FunctionDeclaration
  TopLevelFunctionDeclaration
  LocalFunctionDeclaration

CommentReference
  CommentReferenceName
  CommentReferenceOperator

ForEachPartsWithIdentifier                    // existing-variable write
ConstructorFieldInitializer                   // field-storage initialization
FieldFormalParameter
SuperFormalParameter
Annotation                                    // current constant/constructor union
EnumConstantDeclaration
```

These roles are included because they own expressions, perform writes or constructor selection, or replace expression-shaped V1 compatibility structure. They are not evidence for broadening the value or assignment-target hierarchies. Patterns other than `PatternAssignment` and its contextual write leaves retain their separate pattern AST, while declarations, directives, combinators, labels, and other whole-AST name owners remain outside this expression refactoring as stated in section 14.2.6.

The only parser-phase additions are:

```dart
ParsedExpressionChain                       // temporarily implements Expression
ParsedAssignmentTargetChain                 // temporarily implements AssignmentTarget
ParsedDotShorthandExpression                // maximal contextual wrapper

ParsedExpressionChainHead
  ParsedNameHead
  ParsedValueHead
  ParsedSuperHead
  ParsedDotShorthandHead

ParsedExpressionChainComponent
  ParsedNameAccess
  ParsedTypeArguments
  ParsedArguments
```

Index access, null assertion, parentheses, binary expressions, calls on already grouped values, and other structurally known operations do not acquire parsed counterparts. Every parsed node above is absent from every resolved V2 unit.

The semantic-result taxonomy is parallel to, rather than embedded in, the source-node taxonomy. Invalid named and indexed results belong both to their operation family below and to the common `InvalidReadResolution` or `InvalidWriteResolution` classification:

```dart
NamedReadResolution
  VariableReadResolution
  GetterInvocationResolution
  ExecutableTearOffResolution
  FunctionCallTearOffResolution
  FunctionInterfaceCallTearOffResolution
  RecordFieldReadResolution
  DynamicPropertyReadResolution
  InvalidNamedReadResolution

NamedWriteResolution
  VariableWriteResolution
  SetterInvocationResolution
  DynamicPropertyWriteResolution
  InvalidNamedWriteResolution

IndexReadResolution
  MethodIndexReadResolution
  DynamicIndexReadResolution
  InvalidIndexReadResolution

IndexWriteResolution
  MethodIndexWriteResolution
  DynamicIndexWriteResolution
  InvalidIndexWriteResolution

InvocationResolution
  ExecutableInvocationResolution
  FunctionTypeInvocationResolution
  FunctionCallInvocationResolution
  FunctionInterfaceInvocationResolution
  DynamicInvocationResolution
  InvalidInvocationResolution
```

Assignment targets directly expose the corresponding nullable read and write results. A non-null write identifies the write operation and its accepted type; in a resolved AST, null read and write state that receiver evaluation or exact-null shortening prevents the complete target protocol. Producer-side assertions exclude a non-null read paired with a null write without adding public target-state subclasses. Operator nodes and constructor sites expose their selected substituted elements directly rather than adding one-field resolution families. Dot-shorthand context selection similarly uses explicit valid and invalid results rather than conditionally meaningful nullable fields.

Across the named-read, index-read, and invocation families, a valid `type` describes the value produced if that operation executes. The enclosing expression's `staticType` describes the complete expression result and alone incorporates null shortening. Invalid results retain their canonical `InvalidType` outcome, and an operation prevented by receiver evaluation remains a null resolution rather than a fabricated unreachable result or a present resolution whose operation type was made nullable by surrounding control flow. An operation that executes and itself produces `Never` retains its ordinary non-null resolution with `type == Never`.

The resulting coherence audit is:

| Criterion | Result | Consequence |
| --- | --- | --- |
| One canonical node per source role | Pass | The apparent overlaps are intentional disjoint spellings or evaluation protocols: import-prefixed selection is not receiver property access, direct named invocation is not invocation of a selected value, constructor application is not calling a tear-off, and cascade-start operations have no written receiver child. No two resolved nodes compete for the same fully classified source occurrence. |
| Common interfaces correspond to common operations | Pass for the structural core | `AssignmentExpression`, `FunctionInvocation`, `NamedFunctionInvocation`, `BinaryExpression`, `DotShorthandExpression`, the narrower literal interfaces, receiver capabilities, and operation-resolution interfaces provide a real common child or result API. `Literal`, `CollectionElement`, `RecordLiteralField`, and `AnonymousMethodBody` are useful sealed exhaustive source categories even where they intentionally add no common payload. `ReferenceSite` and `ConstructorInvocationSite` remain optional indexing adapters rather than required AST ancestry. `SemanticAdaptation` has a real common operand but need not be public. |
| Valid structure is not weakened for reuse | Pass with explicit phase and recovery boundaries | Required versus optional source children reflect valid grammar: constructor tear-offs require a selector, ordinary constructor references permit its omission, and dot shorthand directly owns its required name. Parser-only chains temporarily inhabit typed slots, and `CascadeExpression.target` admits a non-expression `InstanceReceiver` solely so invalid extension-override recovery can replace a parsed target honestly; resolved valid cascades still require an expression target. The analysis-result phase distinguishes unresolved AST from completed resolution; nullable operation properties can additionally represent source-specific semantic absence, and nullable constructor elements deliberately also cover failed selection until richer invalid payload is needed. The current union-like `Annotation` and the function/getter/setter declaration shape remain separate non-expression structural questions. |
| Structural nodes encode source and evaluation shape rather than declaration kind | Pass | Static, instance, extension, superclass, dynamic, getter, field, method, and constructor-tear-off meanings are represented by receiver variants and typed resolution results rather than one AST subclass per element kind. Assignment, logical, if-null, increment/decrement, constructor, and direct-versus-value invocation splits remain structural because their evaluation protocols and child roles differ. |
| Parser neutrality does not leak into canonical V2 | Pass as an enforceable phase invariant | Neutral chains own only the smallest ambiguous islands, the dot-shorthand wrapper owns only the maximal contextual boundary, stable outer nodes survive lowering, and resolved-tree verification rejects every parsed head, component, chain, and wrapper. No generic `AstNode` target or receiver survives as a canonical substitute for a classified source role. |
| Every canonical node has a V1 projection strategy | Pass at the shape level, with implementation-risk areas | Section 14.3 supplies a projection for every removed, split, or inserted expression form. The difficult cases are cached synthetic declaration wrappers, collapse of nested no-token adaptations, non-expression `super` and extension-override receivers projected as V1 expressions, target-less cascade children, and the prohibition on materializing a parsed-chain projection in the resolution pipeline. These require explicit identity and parent tests but reveal no structurally unmappable V2 node. |

`DotShorthandContextResolution` follows the same typed-result direction. Its valid leaf preserves the contextual input and the normalized interface type used for namespace lookup; the namespace declaration is derived from `lookupType.element` rather than duplicated. Its invalid leaf represents an absent or unusable context. A valid context whose namespace lacks the requested member remains a valid context result paired with an invalid operation result, so clients do not have to infer context-selection state from nullable fields.

The audit therefore finds the canonical V2 source taxonomy complete and internally non-overlapping. Remaining questions concern exact names, public versus internal exposure of optional adapter interfaces, invalid and recovery payloads, semantic-adaptation placement, and a few language-semantics disagreements; they do not require another expression syntax node unless the language adds a new source form.

## 15. Implementation Consequences

The name-expression hierarchy uses a sealed `NameExpressionImpl` with a covariant `NamedReadResolutionImpl? resolution` getter; `PropertyExtractionImpl` derives from it. The five concrete implementations retain their own source children, lookup paths, evaluation protocols, and V1 projections. The canonical property-extraction name field becomes `name`, with V1 projections preserving their legacy identifier APIs. Clients that currently extract the same name and resolution through concrete-type unions can instead accept `NameExpression` or `NameExpressionImpl`; clients that evaluate receivers or depend on qualification or contextual lookup still inspect the concrete form. This change provides common typing and pattern matching, not an automatic `visitNameExpression` callback. V2 visitors currently dispatch concrete nodes, and any common visitor hook requires a separate visitor-design decision.

### 15.1 Immediate follow-up CLs

- [x] Implement `ImplicitFunctionInstantiation` after
  `UnqualifiedNameExpression` and `ImportPrefixedNameExpression`. Contextual
  generic function instantiation now wraps an operand retaining its generic
  function type. V1 projects the adaptation as `FunctionReference` where
  supported, or folds it into the operand projection and populates
  `SimpleIdentifier.tearOffTypeArgumentTypes` for older language versions.
  Callable-object conversion composes this node with `ImplicitCallTearOff`.
- [x] Implement `ImplicitCallTearOff` for context-induced callable-object
  conversions. The no-token node owns an `operand` and selected `MethodElement`;
  its type is the method's function type before function instantiation. When
  inference supplies type arguments, an outer `ImplicitFunctionInstantiation`
  owns them. Preserve V1 `ImplicitCallReference`, including folding inferred
  type arguments into that projection. Cover source ranges, parent replacement,
  visitors, serialization, reference tracking, and V2/V1 resolved-node output.
- [x] Implement `FunctionInstantiation` for written type arguments, with a
  required `TypeArgumentList` and a function-valued operand. For `callable<int>`,
  compose it with `ImplicitCallTearOff` and project both operations as the
  existing V1 `ImplicitCallReference`. Ordinary operands project as V1
  `FunctionReference`. The parser still constructs `FunctionReference` while
  name lookup distinguishes function instantiation from type and constructor
  syntax; resolution lowers the function-value cases to `FunctionInstantiation`.
  Written arguments retain their source ownership on invalid instantiations.
  Visitors, constant evaluation, diagnostics, and summaries consume the V2 node.

Function-declaration construction must stop using `FunctionExpression` as a reusable declaration suffix. The parser already distinguishes local-function declarations from top-level declarations, so it can construct `LocalFunctionDeclaration` directly in a statement slot and `TopLevelFunctionDeclaration` directly in a compilation-unit-member slot while placing type parameters, formal parameters, and the body on that canonical owner. Element binding assigns one fragment to the declaration or genuine anonymous expression that owns the executable scope rather than copying the same fragment onto a declaration and a nested fake expression. Resolver, flow-analysis, indexing, serialization, and visitor code must replace `functionDeclaration.functionExpression` traversal with the direct declaration children. V1 projections synthesize and cache the old `FunctionDeclaration.functionExpression` and `FunctionDeclarationStatement.functionDeclaration` layers, preserve their legacy ranges and traversal, and synchronize V1 and V2 parent relationships without changing the canonical V2 owner.

The current `Expression.isAssignable` API becomes unnecessary. Assignability is represented structurally by `AssignmentTarget`, while non-location syntax uses `InvalidExpressionAssignmentTarget`, `InvalidExtensionOverrideAssignmentTarget`, or `InvalidSuperAssignmentTarget`. Parser checks that currently query `isAssignable` must instead construct `ParsedAssignmentTargetChain`, one of these syntactically appropriate invalid targets, or another canonical target and let target lowering or recovery report invalid forms. Source-shaped targets with invalid writes remain their ordinary name, property, import-prefixed, or index target and expose invalid read/write resolution rather than being replaced by an invalid structural target.

The current `Expression.canBeConst` API also leaves the canonical base. The prefer-const verifiers and fixes should call a dedicated const-insertion analysis service for the few source forms that admit an explicit keyword, rather than relying on a default-false property on every expression. V1 projection can preserve the existing getter by delegating to that service. `Expression.inConstantContext`, `Expression.unParenthesized`, and `Expression.computeConstantValue()` remain derived public conveniences and require no stored fields beyond the existing tree and resolution state.

The canonical parser and generator must stop constructing `SimpleIdentifier` and `PrefixedIdentifier` as reusable V2 leaves. Declaration builders, type nodes, selectors, arguments, labels, combinators, comment references, parsed name heads, value expressions, and assignment targets place name tokens directly on their source-role owners. Resolver rewrites move or reuse those tokens when lowering an ambiguous parsed chain, and operation-specific resolution supplies elements and types. V2 visitors have no identifier visit methods; clients visit the owning node and inspect its token. V1 projection is the only layer that reconstructs identifier nodes and legacy prefixed topology.

Parent-sensitive methods such as `SimpleIdentifier.inGetterContext`, `SimpleIdentifier.inSetterContext`, and corresponding methods on `IndexExpression` should disappear from the canonical model. The node's parent slot and direct target read/write state encode whether it is read, written, or both.

The V2 `AssignmentExpression` hierarchy splits the current general node into `DirectAssignment`, `IfNullAssignment`, and `CompoundAssignment`; all three project to the existing V1 `AssignmentExpression`. Their target changes from `Expression` to `AssignmentTarget`, and prefix/postfix increment/decrement operands change similarly. During parsing, an ambiguous target-shaped chain that is followed by an assignment or increment/decrement operator is assembled as `ParsedAssignmentTargetChain`, while syntax already known not to denote a location can be placed in the appropriate invalid target recovery node. Lowering replaces every provisional form with a canonical target: ordinary targets receive their read/write resolution directly, while the three structurally invalid targets record invalid read/write resolutions and retain their fully resolved typed child. A compound-assignment or increment/decrement resolver may privately observe that those children currently also implement `InstanceReceiver` when performing operator recovery, but generators and public APIs must not encode that accidental overlap as one common child slot. The parser already knows which assignment subclass or concrete increment/decrement node to construct from its token; name resolution is needed to lower ambiguous targets and fill target read/write results, operator `element`, and `operatorResultType`. Existing-variable for-in syntax is not an `AssignmentTarget`: its grammar admits only one identifier token, which `ForEachPartsWithIdentifier` owns directly together with `NamedWriteResolution`. A `ConstructorFieldInitializer` likewise owns its field-name token and selected `FieldElement` directly because it initializes field storage without ordinary setter dispatch. Assignment patterns and other write-like contexts remain syntax-specific and should be audited independently rather than being broadened merely because they perform writes.

The current `ExtensionOverride` and `SuperExpression` cease to be canonical V2 expressions. They become non-expression implementations of `NamedReceiver` and `InstanceReceiver`, while `InvalidExtensionOverrideExpression` and `InvalidSuperExpression` fill only invalid expression-required placements and V1 retains expression-shaped compatibility projections. `StaticQualifier` implements only `NamedReceiver`. `ImportPrefixReference` implements neither capability and remains the grouped `prefix.` child of import-prefixed name nodes and other qualified references. Property-access and `ReceiverMethodInvocation.receiver` slots use the named-selection capability, while `CallInvocation.receiver`, indexing, `BinaryOperatorInvocation.leftOperand`, and `UnaryOperatorInvocation.operand` use the instance-operation capability. `LogicalAnd.leftOperand`, `LogicalOr.leftOperand`, `IfNull.leftOperand`, every binary right operand, `LogicalNot.operand`, `NullAssertion.operand`, arguments, assigned values, and other genuinely value-producing slots require `Expression`. The four `IncrementOrDecrementExpression` implementations require `AssignmentTarget`. `CascadeExpression.target` uses `InstanceReceiver` so that a parser-only chain can lower directly to an invalid extension-override target, valid resolved cascades enforce `target is Expression`, and each `CascadeSection.body` is an `Expression` whose first operation can use a receiver-less cascade-start node resolved through private active-target context.

Import-prefix rewriting must inspect the operator as well as the receiver binding. A parsed `prefix.foo` with a plain period can become `ImportPrefixedNameExpression` or `ImportPrefixedAssignmentTarget`, and the grouped prefix child owns that period. A parsed `prefix?.foo` cannot make the same rewrite: it remains a property access or property assignment target whose attempted expression receiver has invalid named-read resolution. Resolution still performs import-namespace lookup for `foo` and records the imported member and type as recovery data, but reports `prefixIdentifierNotFollowedByDot` and gives the canonical expression or access result `InvalidType`.

Invocation lowering similarly becomes an explicit source-role selection from `ParsedExpressionChain`. A direct unqualified call becomes `UnqualifiedFunctionInvocation`; a direct receiver-qualified method call becomes `ReceiverMethodInvocation`; an import prefix plus imported function becomes `ImportPrefixedFunctionInvocation`; and a static interpretation produces `ReceiverMethodInvocation` with `StaticQualifier`. When lookup selects a variable, getter, or field, lowering creates `CallInvocation` whose receiver is the corresponding unqualified, property, static, or import-prefixed value expression. A call whose receiver selects `SuperReference` or `ExtensionOverride` also uses `CallInvocation`, but without inventing an expression value for that receiver. Constructors and extension overrides select their distinct roles; a complete extension override left in an expression-only slot is then contained by `InvalidExtensionOverrideExpression`. This selection must finish before the resolved unit is exposed, after which V1 `MethodInvocation` or `FunctionExpressionInvocation` projections can be created from the canonical V2 topology.

Null shorting remains the existing resolver and shared type-inference protocol rather than becoming a new canonical AST concern. The resolver already starts a region at a null-aware access, continues it when analyzing receiver-like child edges, and finishes it at the enclosing expression boundary that owns the nullable result type. V2 adapts those calls to the new `ReceiverPropertyExtraction`, `ReceiverMethodInvocation`, `CallInvocation`, `ReceiverIndexExpression`, assignment-target, increment/decrement-target, function-instantiation, and cascade-section children. Parsed-chain lowering must preserve the active resolver region, but neither the parsed nor resolved hierarchy adds a `NullShortingExpression`, a flow marker, or optional null-shorting metadata to every operation.

Dot-shorthand lowering starts from `ParsedDotShorthandExpression`, whose one `expression` child is the complete shorthand selector expression built from ordinary stable AST nodes and small ambiguous `ParsedExpressionChain` islands. The wrapper receives the shorthand context for the maximal selector chain and routes it through the child's leading receiver structure to the unique `ParsedDotShorthandHead`; ordinary downward inference through the selector expression remains distinct and does not automatically receive that context. A selected static method with arguments becomes `DotShorthandMethodInvocation`, a selected constructor with arguments becomes `DotShorthandConstructorInvocation`, and a selected getter or field followed by arguments becomes `CallInvocation` whose receiver is `DotShorthandNameExpression`. Bare direct values, getter reads, static method tear-offs, and constructor tear-offs all become `DotShorthandNameExpression`; the concrete `NamedReadResolution` subtype, selected element, read type, inferred constructor type arguments, and recovery data preserve the semantic distinction without changing source structure. Subsequent property access, method invocation, call invocation, index access, null assertion, null-aware access, and cascades retain their ordinary nodes; those within the shorthand grammar boundary are initially beneath the wrapper and survive its removal, while a cascade or operation outside that boundary remains outside from parsing onward. The wrapper lets the immediate equality-right-operand rule test one concrete node kind and lets parentheses terminate the shorthand boundary without a recursive search for an inner marker. Neither parsing nor lowering propagates an `isDotShorthand` flag through the ordinary nodes.

Function-instantiation lowering similarly distinguishes written syntax from inserted semantics. A standalone parsed type-argument selector becomes `FunctionInstantiation` only when it instantiates a function value; type literals, constructor type references, and direct invocations retain their own structural ownership. When the operand is a callable object, resolution inserts `ImplicitCallTearOff` before resolving the written or inferred instantiation. Context-induced generic instantiation inserts `ImplicitFunctionInstantiation` at the expression position selected by the language's contextual-inference rules. These no-token nodes must be created before resolved clients observe the tree and must not leak into parse-only V2 ASTs.

Anonymous-method construction does not require parser-neutral resolution-dependent lowering once the receiver expression has been built: `.=>`, `.{`, `.(parameter) =>`, and `.(parameter) {` identify the source role syntactically. The parser constructs `AnonymousMethodInvocation` for `.` and `?.`; a cascade section constructs `CascadeAnonymousMethodInvocation` after the section has taken ownership of `..` or `?..`. The parser preserves every written formal parameter even when the list is invalid. Resolution then establishes the immediate receiver binding, rebound-`this` or explicit-parameter scope, body context, result type, null-shortening region, and flow effects without inserting a function invocation or closure node. A leading parser-neutral dot shorthand inside the body is lowered normally using the context imposed on the anonymous-method result.

The resolver API changes from a method shaped like:

```dart
resolveForWrite(Expression node, bool hasRead)
```

to something closer to:

```dart
resolveAssignmentTarget(
  AssignmentTarget target,
  TargetAccessMode mode,
)
```

where the mode is write-only or read-write. A structurally valid target directly records the selected read and write elements and types; an `InvalidAssignmentTarget` records invalid operations and directs operator recovery through its concrete child.

AST generators need child-slot categories richer than the current `isInValueExpressionSlot` boolean. Useful categories include value expression, named receiver, instance receiver, assignment target, parsed expression chain, parsed assignment-target chain, parsed dot-shorthand expression, parsed super head, parsed dot-shorthand head, invalid extension-override expression child, invalid super expression child, invalid expression target child, invalid extension-override target child, invalid super target child, call-invocation receiver, function-instantiation operand, semantic-adaptation operand, static qualifier, dot-shorthand context, constructor type reference, selector, declaration name, and pattern-related roles. The parsed chain nodes share their head and component structure without implementing both semantic roles, while `ParsedDotShorthandExpression` has one ordinary expression child and does not add parsed variants of stable selector nodes. The five concrete named-function-invocation nodes share generated name, type-argument, argument-list, and resolution APIs through their interfaces but declare only the structural children they actually own; two retain function-specific concrete names and three use method-specific names according to the declarations they can select after lowering. No generated generic invocation-target child is needed. The two invalid receiver-expression wrappers have precise typed children and no resolution fields or token ownership. The three invalid assignment-target variants likewise own no tokens but carry invalid read/write resolutions; the generator must not unify the latter children merely because they currently also satisfy `InstanceReceiver`. The three resolved dot-shorthand nodes similarly share only their period, name, and shorthand-context APIs, while invocation, constructor, and value-specific children remain on the concrete source operation that owns them. `DotShorthandNameExpression` requires no generated constructor selector because it already owns the only written name token.

Parse-only AST printers, node locators, covering-node tests, formatters, token-oriented tools, and V1 projections must understand the neutral chain and its components, including `ParsedSuperHead`, a neutral dot-shorthand head, and the maximal-chain boundary used to compute its context. Resolved AST printers, indexers, navigation visitors, reference-name collectors, flow analysis, and serialization must never receive a parsed chain. Lowering requires especially careful parent-link and covering-node validation and must preserve the original name, operator, type arguments, argument list, source range, comments, corresponding-parameter data, null-shortening behavior, dot-shorthand context and head selection, and any compatibility projection identity that clients are allowed to observe. Indexers traverse through `InvalidExtensionOverrideExpression` to the extension reference and through `InvalidSuperExpression` to the `super` reference without creating a second reference on either wrapper. They must also record implicit `call` references for `CallInvocation` and `ImplicitCallTearOff` even though no member-name token exists. Syntax-oriented tools must skip through no-token semantic adaptations by default; the invalid receiver-expression wrappers are ordinary recovery structure rather than semantic adaptations and remain visible to resolved visitors. Both behaviors need explicit generator and visitor support rather than parent-class accidents.

The V2 generator and resolver should remove `MethodReferenceExpression` and the current `InvocationExpression` implementation base. Operation-specific resolutions provide the former's legacy method element, while the concrete `FunctionInvocation` hierarchy shares only argument-list, written type-argument, and invocation-resolution APIs. Documentation comments require a parallel non-expression path: the parser constructs `CommentReference` components directly, the specialized resolver assigns component elements without invoking expression type or flow analysis, and V1 projection alone reconstructs the old expression-shaped comment child.

## 16. Working Conclusions

The current discussion supports the following working conclusions:

1. A source node should implement `Expression` when its occurrence produces a value, not merely because it participates in evaluation or is currently represented by an expression subclass. Resolved V2 additionally permits narrowly defined no-token semantic adaptations that transform one produced value into another and expose their own resulting static types, plus the two precise no-token invalid recovery containers required when a complete `ExtensionOverride` or `SuperReference` must fill an expression slot.
2. A plain assignment target is not an expression and has no static type.
3. `DirectAssignment`, `IfNullAssignment`, and `CompoundAssignment` represent write-only, conditional read/write, and read-operator-write protocols respectively. Compound-assignment and increment-or-decrement targets have separate read and write elements and types; they still do not have one static type. The outer compound-assignment or increment-or-decrement expression owns the intervening operator `element` and `operatorResultType`, the value passed from the operator application to the target write.
4. Property and index reads should have expression nodes, while property and index writes should use assignment-target nodes.
5. Receiver slots should use operation-specific sealed capabilities. `NamedReceiver` is accepted before `.name`, while `InstanceReceiver` is accepted before indexing and supported instance operators.
6. `InstanceReceiver` refines `NamedReceiver`. Ordinary expressions, `ExtensionOverride`, and `SuperReference` implement `InstanceReceiver`; `StaticQualifier` implements only `NamedReceiver`; `ImportPrefixReference` implements neither.
7. `PropertyExtraction` has `ReceiverPropertyExtraction` and `CascadePropertyExtraction` concrete forms; `PropertyAssignmentTarget` has the parallel receiver and cascade forms. The receiver forms cover value, extension-override, `super`, and static named access. Separate static-member outer nodes are unnecessary.
8. `ImportPrefixReference` owns the grouped qualifier `prefix.`, so direct `prefix.foo` reads and writes use `ImportPrefixedNameExpression` and `ImportPrefixedAssignmentTarget` rather than exposing the same period as both a prefix child and property operator.
9. `prefix?.foo` cannot contain an `ImportPrefixReference` because there is no plain period for it to own. It remains an ordinary property access with an invalid attempted value receiver, reports `prefixIdentifierNotFollowedByDot`, and preserves the imported member and type only as recovery data; its canonical static type is `InvalidType`. The assignment form follows the corresponding property-target model.
10. `E(foo)` evaluates `foo` and fixes extension dispatch but does not itself produce a value. It retains extension, type-argument, and extended-type information without exposing `staticType`; when the complete override occurs in an expression-only slot, `InvalidExtensionOverrideExpression` contains it and supplies canonical `InvalidType`.
11. `super` is represented by a non-expression `SuperReference`; it uses the implicit current instance while forcing superclass dispatch. Bare `super` in an expression-only slot is contained by `InvalidSuperExpression`, which supplies canonical `InvalidType`.
12. `E.staticMember` uses `StaticQualifier(E)`, while `E(foo).member` uses `ExtensionOverride(E(foo))`.
13. `CascadeExpression.target` is structurally an `InstanceReceiver` so that the parsed chain in `E(3)..member` can lower to `ExtensionOverride`. In valid resolved code the target must be an `Expression`; a non-expression target produces a diagnostic and gives the cascade expression `InvalidType`.
14. A type declaration name in `C[0]` is a value-producing `TypeLiteral`, not a `StaticQualifier`, because bracket syntax performs instance operation lookup on the runtime `Type` object.
15. A named extension in `E[0]` remains an attempted `UnqualifiedNameExpression` with invalid named-read resolution and `InvalidType`; it does not denote a `Type` object, and extensions on `Type` are not applicable.
16. `.` and `?.` belong to ordinary property access nodes; `..` and `?..` belong to explicit cascade-section nodes.
17. Cascaded property and index access need explicit cascade-start value and assignment-target nodes rather than nullable targets and ancestor-based `realTarget` lookup.
18. Canonical V2 removes `Identifier`, `SimpleIdentifier`, and `PrefixedIdentifier`. Source-role owners expose name tokens directly, value and target occurrences use their concrete name nodes, and qualified syntax lowers to its precise property, import-prefix, static, constructor, type, invocation, or documentation-reference structure. `NameExpression` supplies a shared value-only contract for named accesses, including property extractions; a general `ReferenceName`, `NameOccurrence`, or other interface spanning unrelated name roles still requires a demonstrated client requirement. V1 compatibility alone synthesizes identifier nodes.
19. Import prefixes, constructor type references, static qualifiers, extension overrides, and `super` references are not expressions.
20. `StaticQualifier` has an optional import prefix, a name, and an `Element?`, but no type arguments. The same node can qualify named access through type-like declarations and named extensions; it does not need element-kind-specific subclasses.
21. `ConstructorTypeReference` remains distinct because type arguments are meaningful in its source role. `C<int>.x` is a constructor tear-off, potentially invalid, and does not fall back to property access with a static qualifier even when `x` names a static member.
22. The parser preserves only structurally ambiguous chain portions in `ParsedExpressionChain` or `ParsedAssignmentTargetChain`; it continues to construct stable nodes such as index access, index targets, null assertion, parentheses, binary expressions, subsequent calls, and cascade sections around the smallest ambiguous island. A bare name used as the receiver of a stable operation remains a one-head parsed chain until resolution distinguishes an ordinary value read, `TypeLiteral`, or invalid non-value use. Dot shorthand additionally uses `ParsedDotShorthandExpression` as an outer contextual boundary around the complete ordinarily structured shorthand selector expression; this wrapper does not cause stable selectors to acquire parsed component variants.
23. Parsed expression and assignment-target chains share a parser-only `ParsedExpressionChainHead` and typed `ParsedNameAccess`, `ParsedTypeArguments`, and `ParsedArguments` components but remain separate nodes implementing `Expression` and `AssignmentTarget` respectively. `ParsedNameHead` keeps a bare leading name neutral until lowering selects its source role, `ParsedValueHead` begins a newly ambiguous invocation-shaped chain at an already value-producing expression, `ParsedSuperHead` contains `SuperReference` for invocation-shaped `super.name(arguments)` until method-versus-getter-call resolution is known, and `ParsedDotShorthandHead` marks the unique leading namespace-selection operation within a `ParsedDotShorthandExpression`. A single parser node should not implement both expression and target roles.
24. Both valid and invalid resolved units contain no parsed chains or `ParsedDotShorthandExpression` wrappers. Role-specific lowering returns `Expression`, `AssignmentTarget`, `NamedReceiver`, or `InstanceReceiver` rather than an untyped AST node, selects canonical source interpretations, uses `InvalidExtensionOverrideExpression` and `InvalidSuperExpression` only when those complete non-value receivers must fill an expression slot, preserves tokens, comments, ranges, references, stable outer-node identity, and parent relationships, and finishes before the resolved AST is exposed; it does not lower source constructs into compiler IR operations. The parser should preferably accumulate ambiguous components in a temporary non-AST builder and materialize the expression or target role only when the enclosing syntax determines it.
25. Canonical source node kinds should encode grammatical roles, while resolution records should encode declaration, getter/setter, tear-off, invalid, and recovery meanings without creating a concrete AST subclass for every semantic combination. Type-object production is the structural `TypeLiteral` exception rather than a `NamedReadResolution` kind.
26. `FunctionInvocation` is the generic expression category, with `NamedFunctionInvocation` for direct invocation through a written function or method name and `CallInvocation` for applying an argument list to an `InstanceReceiver`. The concrete names do not need an `Expression` suffix.
27. `NamedFunctionInvocation` has five longer-named concrete structural forms: `UnqualifiedFunctionInvocation`, `ReceiverMethodInvocation`, `ImportPrefixedFunctionInvocation`, `CascadeMethodInvocation`, and `DotShorthandMethodInvocation`. They share the name, type-argument, argument-list, and resolution API directly and do not introduce a sealed target wrapper.
28. The concrete names reflect the declarations that remain possible after lowering. `UnqualifiedFunctionInvocation` can select a local or top-level function or an implicit-receiver method, and `ImportPrefixedFunctionInvocation` selects an imported top-level function. `ReceiverMethodInvocation`, `CascadeMethodInvocation`, and `DotShorthandMethodInvocation` always represent direct method dispatch because a selected getter, field, or other callable value instead lowers to `CallInvocation`. `ReceiverMethodInvocation` covers instance, static, extension, superclass, and dynamic method dispatch without splitting into semantic subclasses.
29. A selected variable, getter, or field lowers to `CallInvocation` rather than a named invocation. `object.getter()` becomes a call whose receiver is `ReceiverPropertyExtraction`, `(object.method)()` contains an explicit method-tear-off read, and `object.method()` lowers directly to `ReceiverMethodInvocation`.
30. `CallInvocation.receiver` is an `InstanceReceiver`, not an `Expression`. This admits ordinary expression values as well as non-expression `SuperReference` and `ExtensionOverride` receivers, so `super()` and `E(object)()` resolve implicit `call` dispatch without pretending that either receiver produces a value.
31. `InvocationResolution` is a sealed hierarchy with executable, function-type application, special function-`call`, core-`Function`, dynamic, and invalid results. `ExecutableInvocationResolution` records a directly invoked executable or implicitly selected declared `call` method. `FunctionTypeInvocationResolution` applies an argument list directly to an already function-typed value, while `FunctionCallInvocationResolution` directly invokes the language-defined named `call` method of a function type; both have a required effective `invokeType` and no executable element. `FunctionInterfaceInvocationResolution` covers invocation through core `Function`, has result type `dynamic`, and deliberately does not implement `StaticInvocationResolution` because no function signature is known. `DynamicInvocationResolution` remains distinct for genuinely dynamic lookup or dispatch. Every non-null valid result carries the type produced if the invocation executes; a receiver that cannot complete produces no invocation resolution, while an invocation that executes and returns `Never` retains its ordinary resolution. Invalid results use canonical `InvalidType`, and the enclosing expression's `staticType` alone incorporates null shortening. Invalid recovery points directly to a valid result.
32. Ordinary function and method tear-offs remain `UnqualifiedNameExpression`, `ReceiverPropertyExtraction`, `ImportPrefixedNameExpression`, and related source-shaped value nodes with `ExecutableTearOffResolution`; a general concrete `FunctionTearOff` node is unnecessary. A tear-off of the language-defined `call` method uses the same source-shaped nodes with element-free `FunctionCallTearOffResolution` for an exact function type or `FunctionInterfaceCallTearOffResolution` for core `Function`. `ConstructorTearOff` remains distinct because constructor selection has its own source structure.
33. A written standalone `<typeArguments>` selector on a function value is represented by `FunctionInstantiation`, whose operand is an `Expression` and whose type-argument list is required. If the written operand is a callable object, resolution inserts `ImplicitCallTearOff` so that the canonical `FunctionInstantiation` operand is the selected function value rather than encoding implicit `call` in a tagged resolution payload.
34. Type arguments followed immediately by an argument list belong to a direct `NamedFunctionInvocation` or `CallInvocation`, not to an intermediate `FunctionInstantiation`. Parentheses make the distinction explicit: `f<int>()` is one invocation, while `(f<int>)()` invokes the value produced by a nested instantiation.
35. Constructor precedence remains special. `C<int>.named` is a `ConstructorTearOff` whose type reference owns `<int>`; `C.named<int>` is invalid rather than a `FunctionInstantiation`; `(C.named)<int>` is an ordinary `FunctionInstantiation`; and `C.named<int>(arguments)` remains an invalid constructor invocation rather than tear-off followed by call.
36. Context-induced generic function instantiation and implicit `call` tear-off use sparse no-token `ImplicitFunctionInstantiation` and `ImplicitCallTearOff` expression nodes rather than optional contextual metadata on every expression. Nested adaptations expose the operation order and intermediate static types, and each implicit `call` node owns its no-token reference to the selected method.
37. Placement is operation-specific. `ImplicitFunctionInstantiation` occurs at the expression occurrence to which contextual inference supplies the instantiating context; in a conditional, both branches are inferred with the outer context and therefore receive branch-local instantiations when applicable. `ImplicitCallTearOff` follows separate coercion rules: current implementations place it around a complete conditional, cascade, or if-null result in cases where they suppress it in subexpressions, and the documented specification disagreement must be resolved before that placement is considered canonical. Syntax-oriented APIs treat both node kinds as transparent, while semantic visitors can observe them.
38. `BinaryExpression` has four structural implementations: `BinaryOperatorInvocation`, whose left operand is an `InstanceReceiver`; `LogicalAnd`, `LogicalOr`, and `IfNull`, whose left operands are `Expression`s. Every binary right operand is an `Expression`.
39. `BinaryOperatorInvocation` covers overloadable operators including the special `==` and `!=` forms, and admits `SuperReference` and `ExtensionOverride` without pretending that they produce values. Logical and if-null expressions reject those non-value receivers structurally. Its required token-derived `BinaryOperator` is shared with `CompoundAssignment`, where an assignment token such as `+=` maps to `BinaryOperator.add`. Binary and unary nodes expose the selected `element` directly and use their expression `staticType` for the operator result; compound-assignment and increment-or-decrement nodes additionally expose `operatorResultType` for the intermediate value written back. No operator-resolution hierarchy is needed.
40. `LogicalAnd` and `LogicalOr` are separate concrete expression nodes. Their types directly expose their different precedence, right-operand evaluation condition, flow composition, and visitor operation, so there is no redundant `LogicalOperator` enum. Existing pattern nodes retain the explicit `LogicalAndPattern` and `LogicalOrPattern` names.
41. Generic resolved `PrefixExpression` and `PostfixExpression` nodes are unnecessary. Unary operator application, logical negation, null assertion, prefix increment/decrement, and postfix increment/decrement use concrete nodes with operand roles appropriate to each operation; other postfix grammar forms retain their property, index, invocation, and function-instantiation identities.
42. `UnaryOperatorInvocation` covers `-` and `~`, accepts an `InstanceReceiver`, and exposes a required token-derived `UnaryOperator` with `negate` and `bitwiseComplement` values. Integer-literal negation retains this node and resolves through `int.unary-`; its special typing and constant evaluation do not require a separate structural kind. `LogicalNot` and `NullAssertion` instead require `Expression` operands. The concise operation names denote expressions; `NullAssertPattern` and `NullCheckPattern` retain their explicit pattern names, and there is no `LogicalNotPattern`.
43. `IncrementOrDecrementExpression` is the common data contract for `PrefixIncrement`, `PrefixDecrement`, `PostfixIncrement`, and `PostfixDecrement`. All four require an `AssignmentTarget` child and own the `element` and `operatorResultType` for their implicit `+` or `-` invocation. The concrete type identifies both source position and increment-versus-decrement without a redundant operator enum: prefix nodes produce the new value, postfix nodes produce the old target-read value, increment nodes select implicit `operator +`, and decrement nodes select implicit `operator -`. The four concrete operation names omit the redundant `Expression` suffix, while the abstract taxonomic interface retains it as the head noun.
44. Dot shorthand has a common `DotShorthandExpression` API and three resolved leading operations: `DotShorthandNameExpression`, `DotShorthandMethodInvocation`, and `DotShorthandConstructorInvocation`. The shared period, name, and shorthand context describe the omitted static namespace, while the concrete node owns the named-read resolution, method-invocation resolution, or selected substituted constructor appropriate for the written head.
45. A dot-shorthand static method call lowers directly to `DotShorthandMethodInvocation`; a selected getter or field followed by arguments lowers to `CallInvocation` with `DotShorthandNameExpression` as its receiver; and a constructor with arguments lowers to `DotShorthandConstructorInvocation`. Bare direct values, getter reads, static method tear-offs, and constructor tear-offs all use `DotShorthandNameExpression`. The concrete `NamedReadResolution` subtype distinguishes reads from executable tear-offs, and the selected executable distinguishes a method tear-off from a constructor tear-off without requiring `ConstructorSelector` or a constructor-specific dot-shorthand node.
46. Only the leading dot-shorthand operation is structurally special. Later property, invocation, call, index, null-assertion, null-aware, and cascade selectors use their ordinary nodes, without a propagated `isDotShorthand` bit or a no-token `StaticQualifier`; clients can recover the source fact by finding the explicit inner shorthand node.
47. Dot-shorthand context belongs to the language's maximal shorthand selector chain, including its asymmetrical immediate-right-operand rules for equality and inequality. The parser wraps the complete ordinarily structured selector expression in `ParsedDotShorthandExpression`; its unique leading ambiguous `ParsedExpressionChain` island has `ParsedDotShorthandHead`. Resolution routes the wrapper's shorthand context to that head, replaces only ambiguous islands, retains ordinary index, null-assertion, and other stable nodes, installs the resolved child in the wrapper's former parent slot, and removes the wrapper.
48. Dot shorthand has no valid assignment-target form. An outer property or index target can contain an invalid shorthand receiver for recovery, but the hierarchy does not introduce `DotShorthandAssignmentTarget`.
49. `AnonymousMethodInvocation` is a dedicated value-producing expression and is not a `FunctionInvocation`: it has no selected executable, name, argument list, function value, or implicit `call` reference.
50. Ordinary anonymous methods require an `Expression` receiver because they bind an actual runtime value. Non-value receivers such as `SuperReference`, `ExtensionOverride`, `StaticQualifier`, and `ImportPrefixReference` are structurally invalid in this slot.
51. `AnonymousExpressionBody` and `AnonymousBlockBody` remain separate body nodes. The expression form gets its value and type from its expression, while the block form infers its value type from direct returns and evaluates to null on normal completion.
52. Cascade anonymous methods use `CascadeAnonymousMethodInvocation`; the enclosing cascade section owns `..` or `?..` and supplies the cascade target. They do not use nullable targets or ancestor-based `realTarget` lookup.
53. An anonymous method preserves its complete written `FormalParameterList`, including invalid lists, in `formalParameterList`. The computed `receiverFormalParameter` exposes the single valid required positional parameter without erasing syntax or turning invalid parameterized code into the parameterless rebound-`this` form.
54. Parameterless anonymous methods rebind `this` and implicit instance lookup to the receiver, while parameterized forms retain the enclosing `this` and bind the receiver only to the explicit parameter.
55. Anonymous-method bodies execute immediately for flow analysis. They establish a return target but are not ordinary function boundaries for enclosing `break`, `continue`, and asynchronous context, so a nameless `LocalFunctionFragment` is not the preferred canonical scope representation.
56. Anonymous methods participate normally in contextual inference and can pass their result context into a leading dot shorthand in the body; no propagated dot-shorthand flag belongs on the anonymous-method node.
57. `NamedReadResolution` is a sealed semantic-result hierarchy rather than a kind enum with nullable payload fields. Variable reads, getter invocations, executable tear-offs, the two element-free function-`call` tear-off results, record-field reads, dynamic property reads, and invalid results expose only their meaningful data. `FunctionCallTearOffResolution` additionally exposes the exact `FunctionType associatedFunctionType` associated with its primary `type`, which can preserve a type parameter such as `T extends F`; `FunctionInterfaceCallTearOffResolution` records that lookup reached only core `Function` and likewise preserves `T extends Function` as its result type. Every valid result carries the type produced if that read executes; a value expression's `staticType` separately incorporates null shortening, while a compound-assignment or increment-or-decrement target with non-null read and write uses the same field for its flow-sensitive intermediate read type. An invalid result has canonical `InvalidType` and points directly to an optional valid recovery carrying its own hypothetical executed-path type. If receiver evaluation prevents a property read from occurring, the resolution is null and the value expression alone retains the complete static type.
58. `IndexExpression` has `ReceiverIndexExpression` and `CascadeIndexExpression` concrete forms, and `IndexAssignmentTarget` has the parallel receiver and cascade forms. All reuse `IndexReadResolution`, whose method, dynamic, and invalid variants describe `operator []` dispatch; assignment targets additionally expose `IndexWriteResolution? write`. Every valid result carries the type produced or accepted if the operation executes, while an invalid result has canonical `InvalidType`. `MethodIndexReadResolution.type` is derived from its substituted `element.returnType`; null shortening affects the enclosing expression's `staticType`, not this operation type. Method index read and write results do not repeat `element.type` through an `invokeType` getter. A receiver target has null read and write when receiver evaluation or exact-null shortening prevents the target protocol. Null awareness belongs to the receiver form's question token or the enclosing `CascadeSection`, while enclosing expression structure determines where the shortened result becomes nullable.
59. The existing `TypeLiteral` is the value-producing source role for type syntax and directly contains `NamedType`; it does not expose `NamedReadResolution` or require `TypeObjectResolution`. `NamedType` owns the import prefix, name, written type arguments, declaration, and represented type, while `TypeLiteral.staticType` is `Type`. Valid type literals exclude the nullable question token and other `NamedType` states not admitted by type-literal syntax, and whole-chain lowering selects static qualification or constructor syntax before constructing a type literal.
60. `AssignmentTarget` exposes `ReadResolution? read` and `WriteResolution? write`; named and indexed families retain narrower getter types. The shared interfaces expose `type` and `acceptedType`, respectively, and nullable selected `element`; named `WithElement` interfaces and method-index resolutions narrow `element` to non-null. Invalid resolutions expose no selected element even when recovery exists. Syntactic `hasRead` is independent of resolution availability. Every actual named write is non-null. Invalid named and index writes retain an optional `recoveryElement` and have `InvalidType` as their accepted type. When the receiver prevents the target protocol, both operations are null. Structurally invalid targets instead record an invalid write and, when `hasRead`, an invalid read. Before resolution they may also be null; the analysis-result phase, rather than a per-target wrapper, states whether semantic data is available. The producer maintains `write != null || read == null`; there are no public target-state subclasses, generic `AccessResolution`, or target-read wrapper.
61. `ConstructorReference2` represents the specific written structure `ConstructorTypeReference` followed by an optional `ConstructorSelector`; the same structure is valid in ordinary constructor invocation and a factory redirection target. It should eventually become `ConstructorReference`, but it should not become a universal wrapper for every source occurrence that selects a constructor.
62. `ConstructorTearOff` remains a separate expression with a required selector because bare `C` is a `TypeLiteral`, while dot-shorthand constructor invocation directly owns its required period and name because its type namespace comes from context. Sharing these shapes through optional AST children would weaken valid-state guarantees.
63. Constructor sites directly expose the final selected substituted `ConstructorElement`; the substituted view supports argument and return typing at the occurrence, while `element.baseElement` supplies canonical declaration identity for navigation and indexing.
64. `ConstructorSelectionResolution` and `ConstructorInvocationResolution` are unnecessary without concrete additional payload. The substituted constructor's `type` is the effective invocation signature, argument correspondence belongs to `ArgumentList`, and expression result typing belongs to the outer expression.
65. Ordinary and dot-shorthand constructor expressions, explicit `super` and `this` constructor initializers, constructor-form annotations, and enum constant declarations should expose the same substituted-constructor fact without being forced into one source topology or a speculative resolution hierarchy.
66. `EnumConstantDeclaration`, rather than its optional `EnumConstantArguments`, owns the selected enum constructor. Every enum constant invokes a constructor and supplies implicit `index` and `name` arguments even when no argument suffix is written.
67. `FunctionExpression` is reserved for an actual anonymous function value. It owns optional type parameters, a required `formalParameterList`, a body, an anonymous `LocalFunctionFragment`, and its inferred function `staticType`; it is not used as the suffix of a named declaration and needs no separate resolution object.
68. `TopLevelFunctionDeclaration` directly owns its return type, name, type parameters, optional formal parameter list, body, modifiers, and selected executable fragment as a `CompilationUnitMember`. It has no expression static type; reading its declared name later is the value-producing tear-off occurrence.
69. `LocalFunctionDeclaration` directly implements `Statement`, owns a required formal parameter list and `LocalFunctionFragment`, and replaces both the canonical nested `FunctionExpression` and the tokenless `FunctionDeclarationStatement` wrapper. `FunctionDeclaration` is a shared API capability rather than a visitor superclass that forces top-level and local declarations into one taxonomic role.
70. V1 compatibility may synthesize the old `FunctionDeclaration.functionExpression` and `FunctionDeclarationStatement.functionDeclaration` layers, but canonical V2 parser, resolver, element-binding, flow, serialization, indexing, and visitor code operate on the direct top-level, local, and anonymous-function owners.
71. `Expression` directly implements the contextual `Argument`, `CollectionElement`, and `RecordLiteralField` roles. Ordinary positional occurrences have no wrapper; syntax-bearing alternatives such as named arguments, null-aware elements, map entries, spreads, collection control elements, and named record fields retain their own nodes.
72. `Argument.correspondingParameter` describes only an explicit argument occurrence. Operator operands, index operands, assigned values, and increment-or-decrement targets do not become arguments merely because the selected executable has formal parameters; their invocation relationships belong to the corresponding operation owner.
73. `CollectionElement` and `RecordLiteralField` remain sealed contextual unions without common static-type or resolution payloads. Literal inference, constant context, set-versus-map interpretation, record field ordering, and the resulting aggregate type belong to the enclosing literal and resolver.
74. The current `MethodReferenceExpression` is removed from canonical V2. Its assignment, operator, index, and implicit-call implementations have no common source role. Operator nodes expose their selected elements directly, while index and implicit-call operations retain their focused resolution APIs; no common method-reference interface is needed.
75. The current `InvocationExpression` is replaced by `FunctionInvocation`, which has common argument-list, optional written type-argument, and invocation-resolution APIs but no fabricated common `function` expression. Constructor and anonymous-method forms do not participate in this hierarchy.
76. Documentation comment references are not expressions. `CommentReference` directly owns a short sequence of non-expression name or operator components and their resolved elements; it does not wrap `CommentReferenceTarget`, expose `staticType`, or participate in ordinary expression resolution.
77. Current comment-reference compatibility requires only one-, two-, and three-component identifier or operator chains with optional leading `new`; type arguments such as `[List<int>]` are not currently parsed as analyzer `CommentReference` nodes. Future syntax can extend the component model without making documentation references value-producing expressions.
78. `Literal`, `TypedLiteral`, `StringLiteral`, and `SingleStringLiteral` remain in canonical V2. They describe genuine sealed syntactic categories or expose concrete shared source APIs, and every literal implementation is a value-producing expression.
79. `Literal` does not acquire a common constness API, and record literals do not join `TypedLiteral`; literal constness, explicit `const` syntax, type arguments, and lexical string properties remain on the narrow hierarchies that can state them accurately.
80. Literals need no resolution hierarchy. Contextual numeric typing and aggregate inference are exposed by `staticType`, set-versus-map interpretation remains on `SetOrMapLiteral`, and constant evaluation and interpolation conversion remain separate analysis or language operations.
81. `Expression` retains `staticType` rather than renaming it to `type`. The name distinguishes the statically computed value type from written type syntax, represented types, declaration types, and runtime types, and avoids conflicts with the existing structural `type` children on `AsExpression`, `IsExpression`, and `TypeLiteral`.
82. The canonical base `Expression` directly exposes `staticType`, `precedence`, `inConstantContext`, `unParenthesized`, and `computeConstantValue()`. Precedence is source structure, while constant context, parenthesis stripping, and constant evaluation are computed conveniences rather than stored resolution payloads.
83. `Expression.isAssignable` is removed because `AssignmentTarget` represents write capability structurally. `Expression.canBeConst` is removed because explicit-const insertion is an expensive lint and fix analysis applicable only to a few source forms and belongs in a dedicated service.
84. Through its contextual roles, a direct expression retains `argumentExpression`, `fieldExpression`, and `correspondingParameter`; the first two return the expression itself, and the parameter is available only for a matched explicit argument occurrence. `CollectionElement` adds no common property.
85. Every current public AST type that directly or transitively implements `Expression` has an explicit canonical V2 disposition in section 14.1. That establishes subtype-inventory completeness, not grammar completeness: section 14.2 separately audits expression-adjacent roles and, in particular, records accepted null-aware collection syntax that an `Expression`-only inventory cannot discover.
86. `AsExpression`, `AwaitExpression`, `ConditionalExpression`, `IsExpression`, `ParenthesizedExpression`, `SwitchExpression`, `ThisExpression`, `ThrowExpression`, and `RethrowExpression` retain their current source structures and use `staticType`, their resolved children, and ordinary flow or constant analysis without node-specific resolution objects.
87. `PatternAssignment` is intentionally retained unchanged as a genuine expression with a parallel pattern-specific write model. This refactoring does not decompose its leaf writes into `AssignmentTarget`; any future unification belongs to a separate pattern design.
88. `InstanceCreationExpression`, deprecated expression-shaped `ConstructorReference`, `FunctionExpressionInvocation`, `FunctionReference`, `ImplicitCallReference`, general `MethodInvocation`, `Identifier`, `SimpleIdentifier`, `PrefixedIdentifier`, `CommentReferableExpression`, `MethodReferenceExpression`, and the current `InvocationExpression` contract are V1 compatibility shapes or removed common abstractions rather than canonical V2 nodes.
89. The internal `RewrittenMethodInvocationImpl` and `SyntheticIdentifier` expression-shaped adapters are unnecessary in the final implementation. Resolver lowering produces the selected canonical invocation, constructor, call, extension-override, or dot-shorthand node directly, while lookup that has no source identifier accepts a name or token request without implementing `SimpleIdentifier`.
90. Canonical V2 has no general public `InvalidExpression` hierarchy. Bare named extensions and import prefixes used as values remain source-shaped name expressions with `InvalidNamedReadResolution`; only a complete `ExtensionOverride` or bare `SuperReference` forced into an expression-only slot uses the precise no-token recovery node `InvalidExtensionOverrideExpression` or `InvalidSuperExpression`. The wrapper owns no tokens or resolution object, has `InvalidType`, preserves the typed child and its references, and is distinct from a value-producing semantic adaptation.
91. Structural target failure is identified by the target node, independently of the shared invalid-resolution classification. An honest name, property, import-prefixed, or index target remains that concrete node with invalid read or write resolution, while source that cannot denote a storage location uses the sealed `InvalidAssignmentTarget` variants `InvalidExpressionAssignmentTarget`, `InvalidExtensionOverrideAssignmentTarget`, and `InvalidSuperAssignmentTarget`. Each exposes its precise typed child, an `InvalidWriteResolution`, and an `InvalidReadResolution` when `hasRead` is true. Named and index invalid resolutions also implement these common invalid interfaces. Although all three children currently implement `InstanceReceiver` and can support private compound-assignment or increment/decrement operator recovery, that overlap is accidental and is not their public structural contract.
92. Parsed-chain lowering is resolution-driven and replaces each provisional chain root exactly once after lookup and selector grouping choose one canonical topology. The lowerer may use a private wide chain-state accumulator, but its public-facing entry points and final parent slots remain role-specific. Discarded roots and component containers receive no type, reference, resolution, or flow data; tokens, surviving child nodes, stable outer nodes, source ranges, and argument correspondence are preserved.
93. Standalone parse trees may lazily project parsed chains to legacy V1 syntax, while trees in the resolution pipeline must lower before creating any V1 projection and should assert that no provisional projection exists. Resolved-tree verification rejects every surviving `Parsed*` chain or component and checks parent reciprocity, single ownership, source-token boundaries, and absence of discarded nodes from semantic maps.
94. Null shorting uses the analyzer's existing resolver and shared type-inference protocol. V2 only adapts its start, continue, and finish calls to the new structural child roles and preserves active regions during parsed-chain lowering; it adds no `NullShortingExpression` and no public null-shorting metadata to expression or resolution nodes.
95. Invalid parsed chains lower to the canonical node selected by unambiguous syntax, an actual declaration, or a distinguished recovery declaration; failure is represented by that node's typed invalid resolution rather than by retaining parser-neutral syntax. A keywordless type-qualified `C.missing()` with no constructor, getter, field, or method candidate becomes `ReceiverMethodInvocation(StaticQualifier(C), missing, ())` with `InvalidInvocationResolution`. `ConstructorInvocation` is used when constructor interpretation is established, including explicitly constructor-shaped invalid source whose selected constructor element is null.
96. `CascadeSection` has one `Expression body` for reads, direct invocations, assignments, increments, decrements, anonymous methods, and longer section-local chains; it needs no operation-specific subclasses. The section owns `..` or `?..` and discards its body's final value. Cascade-start nodes have no receiver child or public `cascadeTarget` getter: the resolver supplies the active target privately, their operation-specific resolutions expose semantic results, and source clients can inspect the enclosing `CascadeExpression`.
97. Cascade-start property reads, property targets, index reads, index targets, and direct method invocations reuse `NamedReadResolution`, `NamedReadResolution` plus `NamedWriteResolution`, `IndexReadResolution`, `IndexReadResolution` plus `IndexWriteResolution`, and `InvocationResolution` respectively. Operation results describe the section-local executed path, while property and index assignment targets use null read and write when cascade-target evaluation prevents access. Cascade target sourcing, `?..` control, and final body-value disposal remain structural responsibilities of `CascadeExpression` and `CascadeSection`, not cascade-specific resolution variants.
98. Existing-variable for-in syntax admits only an identifier and remains `ForEachPartsWithIdentifier`, directly owning its name token and `NamedWriteResolution`; it does not contain an `Expression`, `SimpleIdentifier`, or nested `AssignmentTarget`. The write's `acceptedType` supplies context for the iterable and the resolved iterable element type is repeatedly written through that destination. Invalid writes retain the same source node with `InvalidNamedWriteResolution`, while declaration and pattern for-in forms remain separate.
99. `ConstructorFieldInitializer` directly owns its optional `this.`, field-name token, selected nullable `FieldElement`, equals token, and initializer expression. It is constructor-specific field-storage initialization rather than ordinary assignment, so it has no `AssignmentTarget`, `NamedWriteResolution`, or field-name `staticType`; the selected field type directly supplies the initializer context, and V1 alone synthesizes the legacy `SimpleIdentifier`.
100. `FieldFormalParameter` retains its existing direct `this`, period, and name tokens plus `FieldFormalParameterFragment`. The fragment's element is the declared parameter and its nullable `field` is the initialized field; this preserves distinct written, binding, private, augmentation, and field names without duplicating `fieldElement` on the AST. The node is a declaration and constructor-specific initialization site, not an expression, assignment target, or named-write operation.
101. `SuperFormalParameter` retains its direct `super`, period, and name tokens plus `SuperFormalParameterFragment`. The fragment's element is the declared parameter and its nullable `superConstructorParameter` is the parameter in the superclass constructor selected by the enclosing constructor; positional association need not follow the written name. Its `super` token is not a `SuperReference`, and the node has no expression, assignment-target, named-write, or invocation role.
102. Null-aware collection syntax retains the existing non-expression source roles. `NullAwareElement` owns the leading question token and value expression, while `MapLiteralEntry` owns independently optional question tokens for its key and value. Conditional contribution, key-before-value short circuit, and collection inference belong to literal analysis; neither source role has `staticType` or an operation-resolution object.
103. The grammar-to-canonical ledger in section 14.2 accounts separately for accepted primary expressions, selectors, operators, assignments, cascades, contextual value roles, write sites, semantic operations, invalid topology, parser-only lowering, and V1 projection. Expression-form completeness is checked against grammar and adjacent contextual roles rather than inferred only from the current `Expression` subtype inventory.
104. Expression hierarchy completeness does not by itself complete whole-AST removal of `Identifier`, `SimpleIdentifier`, and `PrefixedIdentifier`. Annotations, import/export combinators, directives, configurations, declarations, patterns, and other non-expression name roles require a separate owner-by-owner identifier-removal ledger even though their direction is to expose direct tokens and role-specific elements rather than reuse value expressions.
105. The compact inventory in section 14.4 contains every expression source form implemented by the current Dart 3.14 checkout, including the experimental anonymous-method forms, and finds no competing canonical nodes for one fully classified source occurrence. Features added after dot shorthand in this checkout add declaration or annotation semantics but no additional expression source form.
106. Apparent overlaps are resolved by source ownership and evaluation protocol: import qualification is not receiver access, direct named invocation is not application of a selected value, constructor invocation is not calling a constructor tear-off, ordinary and cascade-start operations differ by whether a receiver is written, and assignment targets do not become value expressions merely because some protocols read them.
107. `ReferenceSite` and `ConstructorInvocationSite` are optional indexing or navigation adapters rather than required source-node ancestry. `SemanticAdaptation` may remain an internal common operand interface. The canonical taxonomy depends only on the concrete source and adaptation nodes listed in section 14.4.
108. Parser-only chains and the maximal dot-shorthand wrapper are explicit phase exceptions, not canonical expression categories. Stable index, null-assertion, parenthesized, binary, and already-grouped call nodes retain their ordinary identities around the smallest ambiguous islands, and every resolved-tree verifier rejects all surviving parsed nodes.
109. `DotShorthandContextResolution` is a sealed valid/invalid result. `ValidDotShorthandContextResolution` exposes the contextual input as `contextType` and the normalized interface namespace as `lookupType`; clients obtain the namespace declaration from `lookupType.element`. `InvalidDotShorthandContextResolution` retains a supplied unusable `contextType`, or null when no context was available. A missing member is an invalid operation within a valid context, not an invalid context result, and no public context-failure enum is introduced without an independent client.

110. `NameExpression` is the sealed common superclass of `UnqualifiedNameExpression`, `ImportPrefixedNameExpression`, `DotShorthandNameExpression`, and `PropertyExtraction`, including its receiver and cascade forms. It exposes `name` and `NamedReadResolution? resolution` for value-producing named accesses; canonical property extractions inherit `name` instead of `propertyName`. Null resolution covers both unresolved nodes and accesses prevented by receiver evaluation. Assignment targets and non-value name roles remain outside this hierarchy. The common type shares information while preserving concrete token ownership, lookup, and receiver-evaluation protocols; it adds no `element` getter or automatic common visitor callback.

## 17. Open Questions

- Should top-level ordinary functions, getters, and setters eventually become separate concrete declaration nodes so that `TopLevelFunctionDeclaration.formalParameterList` can be required for the ordinary function form and absent by construction for getters?
- What general recovery representation should preserve invalid local-function modifiers such as `external`, `static`, and `abstract` without adding misleading valid properties to `LocalFunctionDeclaration`?
- Should the common `FunctionDeclaration` capability include metadata and every shared syntactic child directly as sketched, or should annotation access remain on the two concrete roles and the common capability expose only the executable signature and body?
- What exact V1 projection identity and parent guarantees are required when `TopLevelFunctionDeclaration` and `LocalFunctionDeclaration` directly own children that appear under synthetic V1 `FunctionExpression` and `FunctionDeclarationStatement` wrappers?
- What are the final names of `UnqualifiedNameExpression` and `UnqualifiedNameAssignmentTarget`?
- Should `ReferenceSite` and `ResolvedReference` be public AST APIs, internal indexing adapters, or part of a separate resolved-reference service?
- Should `CommentReference` use one component list as sketched, or use separate concrete source forms for one-, two-, and three-component references, and exactly how should a final `operator` spelling own its keyword and operator tokens?
- What exact candidate, navigation, and recovery payload belongs in each concrete `NamedReadResolution`, `NamedWriteResolution`, and `InvalidInvocationResolution` subtype, and which fields should be public?
- After the analysis-result phase distinguishes unresolved data, which invalid, multiply-defined, and recovery outcomes still require richer typed resolution state?
- Should `navigationTarget` be stored directly, computed by a canonicalization service, or exposed alongside the semantic target by every reference result?
- Invalid index reads and writes retain a single `recoveryElement`; no candidate list or hypothetical valid recovery object is needed.
- Is `StaticQualifier` the final name, and what exact declaration kinds should its `Element?` document as valid while still supporting recovery?
- Are `ParsedExpressionChain`, `ParsedAssignmentTargetChain`, `ParsedDotShorthandExpression`, `ParsedExpressionChainHead`, `ParsedNameHead`, `ParsedValueHead`, `ParsedSuperHead`, `ParsedDotShorthandHead`, `ParsedExpressionChainComponent`, `ParsedNameAccess`, `ParsedTypeArguments`, and `ParsedArguments` the final names, and exactly which additional ambiguous chain-shaped sequences belong inside the neutral representation?
- Beyond the settled no-candidate defaults, exactly which inaccessible or multiply-defined candidate sets count as a distinguished recovery declaration that may select qualifier, invocation, constructor, callable-value, or extension-override topology?
- Is `CascadeAnonymousMethodInvocation` the final name, and should ordinary and cascade anonymous-method nodes share a public interface beyond their common body and `formalParameterList` APIs?
- When selectors follow a cascaded anonymous block, as in `A()..{ return B(); }.value`, do they apply to the anonymous body result or to the cascade target, and what static type belongs to the cascade-start node?
- Should anonymous methods expose a dedicated `AnonymousMethodFragment`, use an internal scope object without a public fragment, or reuse a broader non-callable executable-scope abstraction?
- For an invalid written anonymous-method parameter list, which parameters are declared for recovery, and how is the invalid receiver binding represented without rebinding `this` or losing source structure?
- Do `yield` and other enclosing-executable-sensitive constructs cross an anonymous-method block boundary, and how should the analyzer and CFE agree on the resulting flow and diagnostics?
- Which anonymous-method forms are constant expressions, and what serialization and constant-evaluation representation is required for them?
- Should invalid extension-override cascade sections always recover by resolving against the extension, and what recovery type should downstream flow analysis observe after the enclosing cascade receives `InvalidType`?
- In invalid and recovery cases, exactly when should lowering select `CallInvocation` rather than a concrete `NamedFunctionInvocation` based on a variable, getter, or field found by recovery, and when should a call receiver become `ExtensionOverride`?
- Is `FunctionInstantiation` the final name, or should the written `<typeArguments>` selector use `GenericFunctionInstantiation`, and what exact invalid and recovery data remains necessary after its operand and nested semantic adaptations expose the valid operation structurally?
- Are `ImplicitFunctionInstantiation` and `ImplicitCallTearOff` the final names, and should they share a public `SemanticAdaptation` interface, an internal marker, or only a generated implementation convention?
- Which `ImplicitFunctionInstantiation` positions beyond the settled conditional-branch case still require explicit confirmation from contextual-inference rules, especially assignment results versus right-hand sides and other expressions whose value can itself have a generic function type?
- What is the accepted placement rule for `ImplicitCallTearOff` in conditionals, cascades, if-null expressions, and the other exceptions recorded by `tests/language/call/implicit_tearoff_exceptions_test.dart`, where current implementation behavior is documented as disagreeing with the language specification?
- Which node-location, covering-node, source-range, parent-navigation, replacement, formatting, serialization, flow-analysis, and visitor APIs should expose no-token semantic adaptations, and which should skip through them transparently?
- Exactly which property, index, invocation, unary-operator, and cascade slots should accept `NamedReceiver` or `InstanceReceiver` instead of `Expression`?
- Are `InvalidExpressionAssignmentTarget`, `InvalidExtensionOverrideAssignmentTarget`, and `InvalidSuperAssignmentTarget` the final public names?
- Are `BinaryOperatorInvocation` and `BinaryOperator` the final public names?
- Are `UnaryOperatorInvocation`, `UnaryOperator`, `IncrementOrDecrementExpression`, `PrefixIncrement`, `PrefixDecrement`, `PostfixIncrement`, and `PostfixDecrement` the final public names?
- Are `ReceiverMethodInvocation`, `CascadeMethodInvocation`, and `DotShorthandMethodInvocation` the final method-specific concrete names under `NamedFunctionInvocation`?
- Are `ExecutableInvocationResolution`, `FunctionTypeInvocationResolution`, `FunctionCallInvocationResolution`, `FunctionInterfaceInvocationResolution`, `DynamicInvocationResolution`, `InvalidInvocationResolution`, and the intermediate `StaticInvocationResolution` the final public names?
- Should constructor-application nodes share a public `ConstructorInvocationSite.constructorElement` capability, use node-specific getters and delegation, use an internal indexing adapter, or rely on the general reference-site service?
- Which concrete invalid-navigation, candidate, or recovery requirement would justify replacing nullable substituted constructor elements with a sealed constructor resolution hierarchy?
- Should the current union-like `Annotation` be split into constant-reference and constructor-invocation forms, and where should its typed substituted constructor element be exposed until that happens?
- Should enum constructor information expose any normalized mapping for the implicit `index` and `name` arguments, or is the selected substituted element plus the enum source role sufficient?
- Are `DotShorthandExpression`, `DotShorthandNameExpression`, `DotShorthandMethodInvocation`, and `DotShorthandConstructorInvocation` the final names?
- Which canonical node owns invalid standalone constructor type arguments in `.new<int>` and `.named<int>`, and how should its recovery resolution differ from a valid generic static function instantiation?
- Should navigation from the `super` token itself target the superclass declaration, or should only the selected member name contribute a reference?
- Beyond the value-only `NameExpression` hierarchy, should `ImportPrefixedNameExpression`, `ImportPrefixedAssignmentTarget`, `ReceiverPropertyExtraction`, and `ReceiverPropertyAssignmentTarget` share a small public named-access interface for tooling, or should `ReferenceSite` serve that broader role?
- At what stage are V1 compatibility projections created for parsed chains, and which parts of a synthesized legacy parse tree can remain stable when lowering selects the canonical V2 kind?
- Which token, source-range, reference-site, and projection identities must remain stable across parsed-chain lowering for flow analysis, fixes, node covering, and cached projections?
