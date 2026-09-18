# AST Expressions and Assignment Targets: V2 Design Summary

This code-first summary is a provisional analyzer V2 design, not an accepted specification.

For rationale, edge cases, coverage, and implementation consequences, see the [detailed V2 design](ast_expressions_and_assignment_targets.md); the initial inventory is in [Exploration 01](ast_expressions_01.md).

## 1. Rules

```dart
// AST classes describe source roles; resolution objects describe the declaration
// found and operation performed. Do not create LocalVariableExpression,
// GetterExpression, etc. for resolution meanings of one source role.

Expression
  // An AST node that is evaluated to produce a value.
  // After resolution staticType is non-null; invalid value expressions use InvalidType.
  //
  // Narrow exception: a no-token semantic adaptation that transforms one value into another.

AssignmentTarget
  // An AST node that denotes the destination of an assignment.
  // It does not itself produce a value and has no staticType.
  // A write can store in a variable or invoke a property setter or operator []=.
  // It directly exposes nullable read and write resolutions.
  // In a resolved AST, a null write means that no target access executes and
  // implies a null read.

NamedReceiver
  // An AST node accepted before .name or ?.name.

InstanceReceiver
  // A NamedReceiver also accepted before indexing, call, and supported instance operators.

ParsedExpressionChain / ParsedAssignmentTargetChain
  // Parser-only exceptions for the smallest structurally ambiguous expression or target island.

ParsedDotShorthandExpression
  // Parser-only wrapper for the maximal shorthand context boundary around an ordinarily structured expression.

Resolved phase
  // No Parsed* chain, head, component, or shorthand wrapper remains, even in invalid code.

Invalid resolution
  // Uses a concrete invalid resolution with InvalidType.
  // Where useful, recovery points to a complete hypothetical valid resolution; it does not make the source operation valid.

Canonical model
  // Analyzer internals use V2.
  // V1 is a deprecated compatibility projection, not a second semantic model.
```

The four basic cases are:

```dart
x;

UnqualifiedNameExpression
  name: x
  resolution: VariableReadResolution(...)
  staticType: ...


x = 0;

DirectAssignment                   // Expression; the complete assignment produces a value.
  target: UnqualifiedNameAssignmentTarget    // Not Expression; no staticType; no read of x.
    name: x
    read: null
    write: VariableWriteResolution(...)
  operator: =
  value: IntegerLiteral(0)


x += 1;

CompoundAssignment
  target: UnqualifiedNameAssignmentTarget    // One source target, not a synthetic read plus a synthetic write.
    name: x
    read: VariableReadResolution(...)
    write: VariableWriteResolution(...)
  operator: +=
  binaryOperator: add
  value: IntegerLiteral(1)
  element: ...
  operatorResultType: ...


x ??= 1;

IfNullAssignment
  target: UnqualifiedNameAssignmentTarget
    name: x
    read: VariableReadResolution(...)
    write: VariableWriteResolution(...)
  operator: ??=
  value: IntegerLiteral(1)
  // No operator element: ??= is a short-circuit assignment protocol.
```

Read and write types can differ:

```dart
void f(num x) {
  if (x is int) {
    x += 1;
  }
}
```

```dart
UnqualifiedNameAssignmentTarget(x)
  read:
    type: int                                // Promoted type used to read x.
  write:
    acceptedType: num                        // Declared type used to write x.
  // No target.staticType.
```

## 2. Proposed taxonomy

This is the complete proposed resolved V2 inventory. Indentation denotes the primary taxonomy; comments identify cross-cutting capabilities.

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

Direct expressions also implement `Argument`, `CollectionElement`, and `RecordLiteralField`. `DotShorthandExpression` is shared by the three leading shorthand operations. `SemanticAdaptation` is an optional common operand capability, not an exclusive taxonomy layer.

The five concrete `NameExpression` forms share `name` and `resolution`, without a common `element` getter or wrapper. Property extractions inherit `name` instead of `propertyName`; assignment-target APIs are unchanged. Lookup, qualification, shorthand context, and receiver evaluation remain form-specific: Wolf must establish the appropriate receiver before emitting the shared named operation.

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

Contextual and expression-adjacent source roles remain structurally distinct:

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

The parser-only additions are absent from every resolved V2 unit:

```dart
ParsedExpressionChain                         // temporarily implements Expression
ParsedAssignmentTargetChain                   // temporarily implements AssignmentTarget
ParsedDotShorthandExpression                  // maximal contextual wrapper

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

Resolution data describes operations independently of source shape; section 8 details the named, indexed, and invocation families.

Targets maintain `write != null || read == null`. Resolved receiver-suppressed access has null operations; unqualified and import-prefixed targets always have a write. Writes expose `acceptedType`; compound/update nodes expose `operatorResultType`. Dot-shorthand context has valid/invalid results. `ReferenceSite` and `ResolvedReference` remain provisional.

Constructor type arguments and selectors remain constructor-owned after syntax or a distinguished recovery declaration selects that topology, even if element selection fails. Ambiguous keywordless `C.name()` selects constructor, static-method, or callable-value topology during chain lowering. `ConstructorReference` is currently named `ConstructorReference2`.

Core fields:

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
  BinaryOperator get binaryOperator;          // Required; derived from operator.
  MethodElement? get element;
  DartType? get operatorResultType;
}

sealed class AssignmentTarget implements AstNode {
  bool get hasRead;
  ReadResolution? get read;
  WriteResolution? get write;
}

abstract final class IncrementOrDecrementExpression implements Expression {
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

sealed class NameExpression implements Expression {
  Token get name;

  /// Null before resolution or when receiver evaluation prevents the access.
  /// An executed invalid access has an InvalidNamedReadResolution.
  NamedReadResolution? get resolution;
}

final class UnqualifiedNameExpression implements NameExpression {}

final class ImportPrefixedNameExpression implements NameExpression {
  ImportPrefixReference get importPrefix;
}

final class UnqualifiedNameAssignmentTarget implements AssignmentTarget {
  Token get name;
  NamedReadResolution? get read;
  NamedWriteResolution? get write;
}

sealed interface class PropertyExtraction implements NameExpression {}

final class ReceiverPropertyExtraction implements PropertyExtraction {
  NamedReceiver get receiver;
  Token get operator;                        // . or ?.
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
  Token get operator;                        // . or ?.
}

final class ImportPrefixedAssignmentTarget implements AssignmentTarget {
  ImportPrefixReference get importPrefix;
  Token get name;
  NamedReadResolution? get read;
  NamedWriteResolution? get write;
}

sealed interface class IndexExpression implements Expression {
  Token get leftBracket;
  Expression get index;
  Token get rightBracket;
  IndexReadResolution? get resolution;
}

final class ReceiverIndexExpression implements IndexExpression {
  InstanceReceiver get receiver;
  Token? get question;                       // a?[i]
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

Lookup failure preserves target shape. Structurally invalid targets retain typed children for diagnostics and recovery. Nullable fields record an invalid write after resolution and an invalid read when `hasRead`; child types remain separate. No resolvedness flag or child-type test is needed. Serialization uses optional-object presence markers without payload.

`hasRead` is syntactic: false for `=`, true for compound assignments, `??=`, and updates. Resolution does not guarantee execution (`??=` writes conditionally). Target getters retain named/indexed/invalid types.

Receiver fields:

```dart
/// A source node accepted before a named property or method selection.
sealed interface class NamedReceiver implements AstNode {}
sealed interface class InstanceReceiver implements NamedReceiver {}

abstract final class Expression
    implements AstNode, Argument, CollectionElement, RecordLiteralField, InstanceReceiver {
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
  // No staticType: E(x) selects extension dispatch but does not produce a wrapper value.
}

final class SuperReference implements InstanceReceiver {
  Token get superKeyword;
  // No staticType: super changes lookup and dispatch for the implicit current instance.
}

final class StaticQualifier implements NamedReceiver {
  ImportPrefixReference? get importPrefix;
  Token get name;
  Element? get element;
  // No typeArguments and no staticType.
}

final class ImportPrefixReference implements AstNode {
  Element? get element;
  Token get name;
  Token get period;                          // Owns both prefix and the following period.
}
```

The canonical `Expression` API retains only value-oriented and derived syntax operations; assignability and const-keyword insertion leave the base contract:

```dart
abstract final class Expression
    implements Argument, CollectionElement, RecordLiteralField, InstanceReceiver {
  DartType? get staticType;
  Precedence get precedence;
  bool get inConstantContext;
  Expression get unParenthesized;
  AttemptedConstantEvaluationResult? computeConstantValue();
}

final class InvalidExtensionOverrideExpression implements Expression {
  ExtensionOverride get extensionOverride;
}

final class InvalidSuperExpression implements Expression {
  SuperReference get superReference;
}
```

The two invalid wrappers own no tokens or resolution objects and supply `InvalidType` only when a complete non-value receiver must occupy an expression-typed slot. Ordinary invalid value occurrences retain their honest source node with invalid resolution.

`FunctionExpression` is reserved for a written anonymous function value. Named top-level and local declarations directly own their signature and body instead of containing a non-value nested `FunctionExpression`:

```dart
abstract final class FunctionExpression implements Expression {
  TypeParameterList? get typeParameters;
  FormalParameterList get formalParameterList;
  FunctionBody get body;
  LocalFunctionFragment? get declaredFragment;
}

sealed interface class FunctionDeclaration implements AstNode {
  NodeList<Annotation> get metadata;
  TypeAnnotation? get returnType;
  Token get name;
  TypeParameterList? get typeParameters;
  FormalParameterList? get formalParameterList;
  FunctionBody get body;
  ExecutableFragment? get declaredFragment;
}

TopLevelFunctionDeclaration
  implements CompilationUnitMember, FunctionDeclaration

LocalFunctionDeclaration
  implements Statement, FunctionDeclaration
  FormalParameterList get formalParameterList; // Required override.
  LocalFunctionFragment? get declaredFragment;
```

Direct positional arguments, ordinary list or set elements, and positional record fields are the expressions themselves. Syntax-bearing alternatives such as `NamedArgument`, `MapLiteralEntry`, `NullAwareElement`, `SpreadElement`, collection `IfElement`/`ForElement`, and `RecordLiteralNamedField` remain separate contextual nodes and do not acquire `staticType` merely because they contain expressions.

Nearby write and initialization roles remain source-specific rather than becoming `AssignmentTarget`s:

```dart
ForEachPartsWithIdentifier
  Token get identifier;
  NamedWriteResolution? get write;

ConstructorFieldInitializer
  Token? get thisKeyword;
  Token? get period;
  Token get fieldName;
  FieldElement? get fieldElement;
  Token get equals;
  Expression get expression;

FieldFormalParameter
  // declaredFragment.element.field records the initialized field.

SuperFormalParameter
  // declaredFragment.element.superConstructorParameter records the forwarded parameter.
```

`PatternAssignment` remains a genuine expression with pattern-specific transactional writes; its `AssignedVariablePattern` leaves are not ordinary `AssignmentTarget`s. Declaration and pattern for-in forms likewise retain their own source roles.

## 3. Access examples

### 3.1 Property and index access

`PropertyExtraction` and `IndexExpression` are common operation categories. Their `Receiver*` forms own a written receiver and the receiver-local `.`/`?.` or `?` token; their `Cascade*` forms receive the once-evaluated target from `CascadeExpression`, while `CascadeSection` owns `..` or `?..`. An unqualified name has no synthetic receiver, and an import prefix remains a namespace qualifier rather than a `NamedReceiver`.

```dart
a.x

ReceiverPropertyExtraction
  receiver: UnqualifiedNameExpression(a)    // Expression; evaluates a.
  operator: .
  name: x
  resolution: GetterInvocationResolution(x)


a.x = 0

DirectAssignment
  target: ReceiverPropertyAssignmentTarget          // No target.staticType.
    receiver: UnqualifiedNameExpression(a)  // The receiver is still an Expression.
    operator: .
    propertyName: x
    read: null
    write: SetterInvocationResolution(x=)
  operator: =
  value: IntegerLiteral(0)


a.x += 1

ReceiverPropertyAssignmentTarget
  receiver: UnqualifiedNameExpression(a)
  propertyName: x
  read: GetterInvocationResolution(x)
  write: SetterInvocationResolution(x=)


a[i] += 1

ReceiverIndexAssignmentTarget
  receiver: UnqualifiedNameExpression(a)    // Evaluated once.
  index: UnqualifiedNameExpression(i)       // Evaluated once.
  read: MethodIndexReadResolution(operator [])
  write: MethodIndexWriteResolution(operator []=)
```

### 3.2 Special receivers

```dart
E(object).x

ReceiverPropertyExtraction
  receiver: ExtensionOverride
    name: E
    argumentList: (UnqualifiedNameExpression(object))
    element: ExtensionElement(E)
    extendedType: ...
  operator: .
  name: x
  resolution: GetterInvocationResolution(extension getter x)


super.x = value

DirectAssignment
  target: ReceiverPropertyAssignmentTarget
    receiver: SuperReference(super)
    propertyName: x
    read: null
    write: SetterInvocationResolution(superclass setter x=)
  value: UnqualifiedNameExpression(value)


C.x

ReceiverPropertyExtraction
  receiver: StaticQualifier
    name: C
    element: ClassElement(C)
  name: x
  resolution: GetterInvocationResolution(static getter x)
```

A complete non-value receiver forced into an expression slot uses a precise no-token invalid wrapper; a bare extension or import-prefix name instead remains an attempted name expression:

```dart
E(object);
  InvalidExtensionOverrideExpression
    extensionOverride: ExtensionOverride(E(object))
    staticType: InvalidType

super;
  InvalidSuperExpression
    superReference: SuperReference(super)
    staticType: InvalidType

E;
  UnqualifiedNameExpression(E)
    resolution: InvalidNamedReadResolution(recoveryElement: ExtensionElement(E))
    staticType: InvalidType
```

An unqualified instance member does not get a synthetic `this` child:

```dart
x

UnqualifiedNameExpression
  name: x
  resolution: GetterInvocationResolution or ExecutableTearOffResolution
    element: instance getter/field/method x
    // Implicit-this dispatch is a resolution fact, not source structure.
```

### 3.3 Import prefixes

```dart
prefix.foo

ImportPrefixedNameExpression
  importPrefix: ImportPrefixReference
    name: prefix
    period: .
    element: PrefixElement(prefix)
  name: foo
  resolution: VariableReadResolution, GetterInvocationResolution, or ExecutableTearOffResolution


prefix.foo += value

ImportPrefixedAssignmentTarget
  importPrefix: ImportPrefixReference(prefix.)
  name: foo
  read: GetterInvocationResolution(imported getter foo)
  write: SetterInvocationResolution(imported setter foo=)


prefix?.foo

ReceiverPropertyExtraction
  receiver: UnqualifiedNameExpression(prefix)
    resolution: InvalidNamedReadResolution
      recoveryElement: PrefixElement(prefix)
    staticType: InvalidType
  operator: ?.
  name: foo
  resolution: InvalidNamedReadResolution
    recoveryElement: GetterElement(imported foo)
  staticType: InvalidType

// Resolution reports prefixIdentifierNotFollowedByDot.
```

### 3.4 Type and extension names

```dart
abstract final class TypeLiteral implements Expression {
  NamedType get type;                         // Syntax denoting the represented type.
  // staticType is Type; type.type is the represented type, for example C<int>.
}

C;

TypeLiteral
  type: NamedType(C)
  staticType: Type


C.x

ReceiverPropertyExtraction
  receiver: StaticQualifier(C)                // Static lookup; C is not evaluated as a Type object.
  name: x


C[0]

ReceiverIndexExpression
  receiver: TypeLiteral
    type: NamedType(C)                        // Bracket syntax cannot perform static lookup.
    staticType: Type
  index: IntegerLiteral(0)
  resolution: MethodIndexReadResolution       // May be supplied by an extension on Type.
    element: extension operator [] on Type


E.x

ReceiverPropertyExtraction
  receiver: StaticQualifier(E)                // E is a named extension used for static lookup.
  name: x


E[0]

ReceiverIndexExpression
  receiver: UnqualifiedNameExpression(E)
    resolution: InvalidNamedReadResolution    // A named extension does not denote a Type object.
      recoveryElement: ExtensionElement(E)       // Retained for navigation.
    staticType: InvalidType
  index: IntegerLiteral(0)
  resolution: InvalidIndexReadResolution
    type: InvalidType
  staticType: InvalidType
```

Constructor precedence:

```dart
C<int>.named
  ConstructorTearOff
    typeReference: ConstructorTypeReference(C<int>)
    selector: ConstructorSelector(.named)

C.named<int>
  invalid constructor-reference instantiation
  // Does not become FunctionInstantiation(ReceiverPropertyExtraction(C.named), <int>).

(C.named)<int>
  FunctionInstantiation
    operand: ParenthesizedExpression(ConstructorTearOff(C.named))
    typeArguments: <int>

C.named<int>(arguments)
  invalid ConstructorInvocation
  // Does not become tear-off + function instantiation + call.
```

## 4. Invocations and instantiations

Taxonomy:

```dart
abstract final class FunctionInvocation implements Expression {
  TypeArgumentList? get typeArguments;
  ArgumentList get argumentList;
  InvocationResolution? get resolution;
}

abstract final class NamedFunctionInvocation implements FunctionInvocation {
  Token get name;
}

UnqualifiedFunctionInvocation
  // f()

ReceiverMethodInvocation
  NamedReceiver get receiver;
  Token get operator;
  // object.m(), super.m(), E(object).m(), C.m()

ImportPrefixedFunctionInvocation
  ImportPrefixReference get importPrefix;
  // prefix.f()

CascadeMethodInvocation
  // target..m(); the enclosing CascadeSection owns ..

DotShorthandMethodInvocation
  Token get period;
  // .m()

CallInvocation
  InstanceReceiver get receiver;
  // (f)(), object.getter(), super(), E(object)()
```

`UnqualifiedFunctionInvocation` can select a local or top-level function or an implicit-receiver method, and `ImportPrefixedFunctionInvocation` selects an imported top-level function. `ReceiverMethodInvocation`, `CascadeMethodInvocation`, and `DotShorthandMethodInvocation` always represent direct method dispatch after lowering; a getter, field, variable, or other produced callable value followed by arguments lowers to `CallInvocation`.

```dart
f() declared function       -> UnqualifiedFunctionInvocation(ExecutableInvocationResolution)
f() function-valued variable-> CallInvocation(UnqualifiedNameExpression(f), FunctionTypeInvocationResolution)
f() core Function           -> CallInvocation(UnqualifiedNameExpression(f), FunctionInterfaceInvocationResolution)
f.call() exact function type -> ReceiverMethodInvocation(FunctionCallInvocationResolution)
f.call() core Function       -> ReceiverMethodInvocation(FunctionInterfaceInvocationResolution)
prefix.f() imported function-> ImportPrefixedFunctionInvocation(ExecutableInvocationResolution)
object.method() direct method-> ReceiverMethodInvocation(ExecutableInvocationResolution)
object.getter() callable read-> CallInvocation(ReceiverPropertyExtraction(object.getter))
super()                     -> CallInvocation(SuperReference(super), inherited call method)
E(object)()                 -> CallInvocation(ExtensionOverride(E(object)), extension call method)
```

Ordinary tear-offs use `ExecutableTearOffResolution` on their source-shaped name or property expression. The element-free language-defined `call` operation uses `FunctionCall*Resolution` with an exact associated signature, or `FunctionInterface*Resolution` when only core `Function` is known. Existing call and named-invocation nodes preserve whether `call` was written; no function-call-specific AST node is needed.

Written and implicit function adaptations:

```dart
final class FunctionInstantiation implements Expression {
  Expression get operand;
  TypeArgumentList get typeArguments;          // Required: this node owns written syntax.
  List<DartType>? get typeArgumentTypes;
}

sealed interface class SemanticAdaptation implements Expression {
  Expression get operand;
  // No tokens; source range delegates to operand.
}

final class ImplicitCallTearOff implements SemanticAdaptation {
  Expression get operand;
  MethodElement get element;
}

final class ImplicitFunctionInstantiation implements SemanticAdaptation {
  Expression get operand;
  List<DartType> get typeArgumentTypes;
}
```

```dart
f<int>
  FunctionInstantiation
    operand: UnqualifiedNameExpression(f)
    typeArguments: <int>

f<int>()
  UnqualifiedFunctionInvocation or CallInvocation
    typeArguments: <int>                       // One direct invocation; no intermediate FunctionInstantiation.
    argumentList: ()

(f<int>)()
  CallInvocation
    receiver: ParenthesizedExpression
      FunctionInstantiation(f<int>)

int Function(int) a = id;
  ImplicitFunctionInstantiation
    operand: UnqualifiedNameExpression(id)
      staticType: T Function<T>(T)
    typeArgumentTypes: [int]
    staticType: int Function(int)

int Function(int) b = CallableObject();
  ImplicitFunctionInstantiation
    operand: ImplicitCallTearOff
      operand: ConstructorInvocation(CallableObject())
      element: CallableObject.call
      staticType: T Function<T>(T)
    typeArgumentTypes: [int]
    staticType: int Function(int)
```

The concrete adaptation nodes are canonical; `SemanticAdaptation` is only a possible capability. Context-induced generic instantiation is expression-local, including separate conditional-branch nodes. `ImplicitCallTearOff` follows different coercion rules, and its placement in the documented implementation/specification exceptions remains open.

`ImplicitFunctionInstantiation`, `ImplicitCallTearOff`, and written
`FunctionInstantiation` are implemented. Written and inferred instantiations
compose with the same tear-off node for callable operands, preserving the
combined V1 `ImplicitCallReference` projection. Ordinary function operands
project as V1 `FunctionReference`. Parsing still uses `FunctionReference`
until resolution distinguishes function-value instantiation from type and
constructor syntax. See the detailed design's
[follow-up checklist](ast_expressions_and_assignment_targets.md#151-immediate-follow-up-cls).

### 4.1 Dot shorthand

Only the leading operation is dot-shorthand-specific. Every selector after it uses the ordinary property, invocation, call, index, null-assertion, null-aware, or cascade node.

```dart
sealed interface class DotShorthandExpression implements Expression {
  Token get period;
  Token get name;                              // Includes the new token.
  DotShorthandContextResolution? get shorthandContext;
}

final class DotShorthandNameExpression
    implements NameExpression, DotShorthandExpression {}

final class DotShorthandMethodInvocation
    implements NamedFunctionInvocation, DotShorthandExpression {
  TypeArgumentList? get typeArguments;
  ArgumentList get argumentList;
  InvocationResolution? get resolution;
}

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
  DartType get contextType;                    // Context at the maximal shorthand boundary.
  InterfaceType get lookupType;                // Normalized type whose namespace is searched.
}

final class InvalidDotShorthandContextResolution
    implements DotShorthandContextResolution {
  DartType? get contextType;                   // Null when no context type was available.
}
```

Representative resolved heads are:

```dart
Color color = .red;
  DotShorthandNameExpression
    name: red
    shorthandContext: ValidDotShorthandContextResolution
      contextType: Color
      lookupType: Color
    resolution: GetterInvocationResolution(Color.red)
    staticType: Color

Point point = .origin();
  DotShorthandMethodInvocation
    name: origin
    argumentList: ()
    resolution: ExecutableInvocationResolution
      element: Point.origin

Point point = .new(1);
  DotShorthandConstructorInvocation
    name: new
    argumentList: (1)
    constructorElement: Point.new
```

An argument list does not erase the method-versus-produced-value distinction. If `C.zero` is a static method returning `C Function()`, `.zero()` is one direct invocation whose result is the function; `.zero()()` invokes that result. A getter or field is read before its callable value is invoked:

```dart
C value = .zero();    // Invalid: DotShorthandMethodInvocation has type C Function().
C value = .zero()();  // Valid: CallInvocation of that result has type C.

CallablePoint point = .origin(); // CallInvocation of a DotShorthandNameExpression getter read.
```

Written standalone type arguments instantiate the produced function value; type arguments immediately followed by arguments belong to the direct invocation:

```dart
.identity<Functions>.call(Functions()) // FunctionInstantiation, then ordinary method invocation.
.make<int>(0)                          // One DotShorthandMethodInvocation with type arguments.
```

Constructor syntax retains constructor precedence:

```dart
.new<int>()          // Invalid DotShorthandConstructorInvocation; not function instantiation + call.
.named<int>()        // Invalid DotShorthandConstructorInvocation; not function instantiation + call.
.new<int>.call()     // Constructor tear-off interpretation, then ordinary .call().
.named<int>.call()   // Constructor tear-off interpretation, then ordinary .call().
```

The invocation forms preserve their invalid written constructor type arguments on `DotShorthandConstructorInvocation`. The exact canonical recovery owner for invalid standalone `.new<int>` and `.named<int>` before a later selector remains open.

The shorthand context belongs to the entire maximal selector chain:

```dart
int value = .parse('-3').abs();

ReceiverMethodInvocation
  receiver:
    DotShorthandMethodInvocation
      name: parse
      argumentList: ('-3')
      shorthandContext: ValidDotShorthandContextResolution
        contextType: int
        lookupType: int
      resolution: ExecutableInvocationResolution
        element: int.parse
  name: abs
  argumentList: ()
  resolution: ExecutableInvocationResolution
    element: int.abs
```

`contextType` is the type supplied at the maximal shorthand boundary before
dot-shorthand-specific normalization. `lookupType` is the usable interface
type whose static namespace is searched. For a `FutureOr<C>` context they are
`FutureOr<C>` and `C`, respectively. The namespace declaration is available as
`lookupType.element`; the resolution does not duplicate it as another API
property. A resolved invalid context uses
`InvalidDotShorthandContextResolution`, while a valid context whose namespace
lacks the requested member retains `ValidDotShorthandContextResolution` and
records the member failure in the named-read, invocation, or constructor
result.

Context boundaries are language rules rather than general downward inference:

```dart
int b = .parse('-3').abs();// Valid: context belongs to the maximal selector chain.
bool c = C() == .zero;     // Valid: immediate equality RHS receives C context.
C d = C() + .zero;         // Valid: operator parameter supplies C context.

int b = (.parse('-3')).abs();// Invalid: the inner chain has no usable int context.
bool d = .zero == C();     // Invalid: equality context is asymmetric.
C e = .zero + C();         // Invalid: result context does not flow into binary LHS.
```

The parser wraps the maximal shorthand chain in `ParsedDotShorthandExpression`; exactly one inner leading chain has `ParsedDotShorthandHead`. Resolution routes context to that head, replaces it with a canonical shorthand node, reparents the retained child, and removes the wrapper. It inserts no unwritten qualifier or propagated shorthand bit.

```dart
ParsedDotShorthandExpression
  expression: ... ParsedExpressionChain(ParsedDotShorthandHead(.name)) ...
  -> resolved ordinary expression containing exactly one:
       DotShorthandNameExpression
       DotShorthandMethodInvocation
       DotShorthandConstructorInvocation
  -> wrapper removed

// No valid target form.
.zero = value;       // Invalid.
.zero.next = value;  // Outer target can retain an invalid shorthand receiver for recovery.
.zero[0] = value;    // Same; no DotShorthandAssignmentTarget.
```

### 4.2 Anonymous methods

The experimental anonymous-method forms are dedicated immediately-executed expressions, not `FunctionInvocation` nodes:

```dart
receiver.=> expression
receiver.{ statements }
receiver.(parameter) => expression
receiver.(parameter) { statements }

receiver?.=> expression
receiver?.{ statements }

receiver..=> expression
receiver..{ statements }
receiver?..=> expression
receiver?..{ statements }
```

```dart
sealed interface class AnonymousMethodBody implements AstNode {}

final class AnonymousExpressionBody implements AnonymousMethodBody {
  Token get arrow;
  Expression get expression;
}

final class AnonymousBlockBody implements AnonymousMethodBody {
  Block get block;
}

final class AnonymousMethodInvocation implements Expression {
  Expression get receiver;                    // Must produce the runtime value being bound.
  Token get operator;                         // . or ?.
  FormalParameterList? get formalParameterList;
  FormalParameter? get receiverFormalParameter;
  AnonymousMethodBody get body;
}

final class CascadeAnonymousMethodInvocation implements Expression {
  FormalParameterList? get formalParameterList;
  FormalParameter? get receiverFormalParameter;
  AnonymousMethodBody get body;
}
```

```dart
receiver.=> expression
  AnonymousMethodInvocation
    receiver: UnqualifiedNameExpression(receiver)
    operator: .
    formalParameterList: null                 // Body rebinds this.
    body: AnonymousExpressionBody(expression)

receiver.(value) { return value.member; }
  AnonymousMethodInvocation
    receiver: UnqualifiedNameExpression(receiver)
    formalParameterList: (value)              // Enclosing this remains unchanged.
    receiverFormalParameter: value
    body: AnonymousBlockBody

```

An ordinary anonymous-method receiver is an `Expression`; non-value receiver forms are invalid here. The AST preserves the complete parameter list, while `receiverFormalParameter` exposes only one valid required positional binding. Parameterless bodies rebind `this`; parameterized bodies retain the enclosing `this`. The body executes immediately for flow and return analysis without becoming an ordinary closure boundary.

## 5. Operators

Binary nodes are split by the role of their left operand:

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

sealed interface class BinaryExpression implements Expression {
  Token get operator;
  Expression get rightOperand;
}

final class BinaryOperatorInvocation implements BinaryExpression {
  InstanceReceiver get leftOperand;
  BinaryOperator get binaryOperator;           // Required; derived from operator.
  MethodElement? get element;
}

final class LogicalAnd implements BinaryExpression {
  Expression get leftOperand;
}

final class LogicalOr implements BinaryExpression {
  Expression get leftOperand;
}

final class IfNull implements BinaryExpression {
  Expression get leftOperand;
}
```

```dart
a + b
  BinaryOperatorInvocation
    leftOperand: UnqualifiedNameExpression(a)
    operator: +
    binaryOperator: add
    rightOperand: UnqualifiedNameExpression(b)
    element: A.operator+

super + 0
  BinaryOperatorInvocation
    leftOperand: SuperReference(super)
    operator: +
    binaryOperator: add
    rightOperand: IntegerLiteral(0)

E(a) != b
  BinaryOperatorInvocation
    leftOperand: ExtensionOverride(E(a))
    operator: !=
    binaryOperator: notEqual
    rightOperand: UnqualifiedNameExpression(b)

a && b
  LogicalAnd
    leftOperand: UnqualifiedNameExpression(a)
    operator: &&
    rightOperand: UnqualifiedNameExpression(b)

a || b
  LogicalOr
    leftOperand: UnqualifiedNameExpression(a)
    operator: ||
    rightOperand: UnqualifiedNameExpression(b)

a ?? b
  IfNull
    leftOperand: UnqualifiedNameExpression(a)
    rightOperand: UnqualifiedNameExpression(b)
```

Overloadable operators, including `==` and `!=`, use `BinaryOperatorInvocation`; `&&`, `||`, and `??` require value-producing left operands. `BinaryOperator` is shared with `CompoundAssignment`, which owns its operator result without a synthetic binary node. Separate `LogicalAnd` and `LogicalOr` nodes encode their distinct precedence, evaluation condition, flow, and visitor operation.

Prefix and postfix syntax is likewise split by operand role:

```dart
enum UnaryOperator {
  negate,
  bitwiseComplement,
}

final class UnaryOperatorInvocation implements Expression {
  Token get operator;
  UnaryOperator get unaryOperator;             // Required; derived from - or ~.
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

Complete operation names omit a redundant `Expression` suffix. Abstract taxonomy names such as `AssignmentExpression`, `BinaryExpression`, and `IncrementOrDecrementExpression`, and otherwise ambiguous names such as `ParenthesizedExpression`, retain it. Pattern names remain unchanged.

```dart
-value
  UnaryOperatorInvocation
    unaryOperator: negate
    operand: UnqualifiedNameExpression(value)

-super
  UnaryOperatorInvocation
    unaryOperator: negate
    operand: SuperReference(super)

~E(value)
  UnaryOperatorInvocation
    unaryOperator: bitwiseComplement
    operand: ExtensionOverride(E(value))

-42
  UnaryOperatorInvocation
    unaryOperator: negate
    operand: IntegerLiteral(42)
    element: int.unary-
    staticType: int

!condition
  LogicalNot
    operand: UnqualifiedNameExpression(condition)

value!
  NullAssertion
    operand: UnqualifiedNameExpression(value)

++x
  PrefixIncrement
    target: UnqualifiedNameAssignmentTarget(x)
    element: ...
    operatorResultType: ...

x--
  PostfixDecrement
    target: UnqualifiedNameAssignmentTarget(x)
    element: ...
    operatorResultType: ...
```

Integer-literal negation retains ordinary `int.unary-` resolution. Updates own the implicit operator facts between non-null target read/write results; postfix forms can still produce the old read type. Receiver failure produces null read and write. Generic resolved `PrefixExpression` and `PostfixExpression` nodes would erase these different operand roles.

## 6. Cascades

```dart
final class CascadeExpression implements Expression {
  InstanceReceiver get target;
  NodeList<CascadeSection> get sections;
}

final class CascadeSection implements AstNode {
  Token get operator;                          // .. or ?..
  Expression get body;
}

final class CascadePropertyExtraction implements PropertyExtraction {}

final class CascadePropertyAssignmentTarget
    implements PropertyAssignmentTarget {}

final class CascadeIndexExpression implements IndexExpression {}

final class CascadeIndexAssignmentTarget
    implements IndexAssignmentTarget {}

CascadeMethodInvocation implements NamedFunctionInvocation
CascadeAnonymousMethodInvocation implements Expression
```

`ReceiverIndexExpression` owns its written receiver; `CascadeIndexExpression` owns only `[index]`, while `CascadeExpression` supplies the shared receiver and `CascadeSection` owns `..` or `?..`. Both implement `IndexExpression`; their target counterparts similarly share `IndexAssignmentTarget` and its resolution families.

```dart
target..x = 0..y

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
      body: CascadePropertyExtraction(y)


target..x.y

CascadeExpression
  target: UnqualifiedNameExpression(target)
  sections:
    CascadeSection
      operator: ..
      body: ReceiverPropertyExtraction
        receiver: CascadePropertyExtraction(x)
        operator: .
        name: y
```

Token ownership and null-shortening boundaries:

```dart
a?[i]       // ? belongs to ReceiverIndexExpression.
a?..[i]     // ?.. belongs to CascadeSection.
a..x?[i]    // .. belongs to CascadeSection; ? belongs to the nested index access.

target?..x?.y..z
// If target is null, ?.. skips the complete cascade.
// If target.x is null, ?. skips only the remainder of the first section.
// The ..z section still runs on the original target.
```

Invalid extension-override cascade recovery:

```dart
E(3)..member

CascadeExpression
  target: ExtensionOverride(E(3))             // Structurally admitted by InstanceReceiver.
  sections:
    CascadeSection(..member)
  staticType: InvalidType                      // A valid cascade target must be an Expression.

// Resolution reports extensionOverrideWithCascade but can still resolve member through E for recovery.
```

Null shorting remains the analyzer's existing resolver and shared type-inference protocol. V2 routes its start, continue, and finish operations through the new receiver and target child roles and preserves active regions during parsed-chain lowering; it adds no `NullShortingExpression` and no public null-shorting metadata.

## 7. Parser-only chains and lowering

```dart
final class ParsedExpressionChain implements Expression {
  ParsedExpressionChainHead get head;
  NodeList<ParsedExpressionChainComponent> get components;
}

final class ParsedAssignmentTargetChain implements AssignmentTarget {
  ParsedExpressionChainHead get head;
  NodeList<ParsedExpressionChainComponent> get components;
}

final class ParsedDotShorthandExpression implements Expression {
  Expression get expression;
}

sealed class ParsedExpressionChainHead implements AstNode {}

final class ParsedNameHead implements ParsedExpressionChainHead {
  Token get name;                              // Neutral: not yet asserted to produce a value.
}

final class ParsedValueHead implements ParsedExpressionChainHead {
  Expression get expression;                  // Parentheses or another already-known value expression.
}

final class ParsedSuperHead implements ParsedExpressionChainHead {
  SuperReference get superReference;
}

final class ParsedDotShorthandHead implements ParsedExpressionChainHead {
  Token? get constKeyword;
  Token get period;
  Token get name;
}

sealed class ParsedExpressionChainComponent implements AstNode {}

final class ParsedNameAccess implements ParsedExpressionChainComponent {
  Token get operator;
  Token get name;
}

final class ParsedTypeArguments implements ParsedExpressionChainComponent {
  TypeArgumentList get typeArguments;
}

final class ParsedArguments implements ParsedExpressionChainComponent {
  ArgumentList get argumentList;
}
```

The parser keeps only the smallest ambiguous island:

```dart
foo.bar<T>(arguments)

ParsedExpressionChain
  head: ParsedNameHead(foo)
  components:
    ParsedNameAccess(.bar)
    ParsedTypeArguments(<T>)
    ParsedArguments(arguments)


foo.bar[0]

ReceiverIndexExpression                            // The outer index is structurally known.
  receiver: ParsedExpressionChain
    head: ParsedNameHead(foo)
    components:
      ParsedNameAccess(.bar)
  index: IntegerLiteral(0)


foo.bar = value

DirectAssignment
  target: ParsedAssignmentTargetChain           // Target role is known after parsing =.
    head: ParsedNameHead(foo)
    components:
      ParsedNameAccess(.bar)
  operator: =
  value: ParsedExpressionChain
    head: ParsedNameHead(value)


super.foo()

ParsedExpressionChain
  head: ParsedSuperHead
    superReference: SuperReference(super)
  components:
    ParsedNameAccess(.foo)
    ParsedArguments(())


.parse(input).abs()

ParsedDotShorthandExpression
  expression:
    ParsedExpressionChain
      head: ParsedDotShorthandHead(.parse)
      components:
        ParsedArguments((input))
        ParsedNameAccess(.abs)
        ParsedArguments(())
```

`ParsedDotShorthandExpression` records the complete maximal shorthand-chain context boundary. Its ordinarily structured child contains exactly one leading ambiguous chain whose `ParsedDotShorthandHead` marks where that context supplies the omitted static namespace; stable index, null-assertion, parenthesized, binary, and already-grouped call nodes remain ordinary nodes inside the wrapper.

Resolution consumes the complete ambiguous chain:

```dart
foo.bar

foo is a value
  -> ReceiverPropertyExtraction
       receiver: UnqualifiedNameExpression(foo)

foo is an import prefix
  -> ImportPrefixedNameExpression
       importPrefix: ImportPrefixReference(foo.)
       name: bar

foo is a type or named extension used for static lookup
  -> ReceiverPropertyExtraction
       receiver: StaticQualifier(foo)
       name: bar

invalid value use
  -> source-shaped ReceiverPropertyExtraction with InvalidNamedReadResolution


foo.bar = value

foo is a value
  -> ReceiverPropertyAssignmentTarget(receiver: UnqualifiedNameExpression(foo), propertyName: bar)

foo is an import prefix
  -> ImportPrefixedAssignmentTarget(importPrefix: foo., name: bar)

foo is a static qualifier
  -> ReceiverPropertyAssignmentTarget(receiver: StaticQualifier(foo), propertyName: bar)

honest property shape with invalid lookup or write
  -> ReceiverPropertyAssignmentTarget with a non-null invalid read or write resolution

invocation value, extension override, or bare super used as the target
  -> InvalidExpressionAssignmentTarget
  -> InvalidExtensionOverrideAssignmentTarget
  -> InvalidSuperAssignmentTarget


f()

f is a declared function or implicit-receiver method
  -> UnqualifiedFunctionInvocation

f is a variable, getter, or field
  -> CallInvocation(receiver: UnqualifiedNameExpression(f))

f is a constructor type
  -> ConstructorInvocation

f is an extension name in a receiver-capability slot
  -> ExtensionOverride


foo.bar()

bar is a directly invoked method
  -> ReceiverMethodInvocation

bar is a getter or field whose value is called
  -> CallInvocation(receiver: ReceiverPropertyExtraction(foo.bar))

foo is an import prefix and bar is an imported function
  -> ImportPrefixedFunctionInvocation

foo.bar is constructor syntax
  -> ConstructorInvocation


super.foo()

foo is a superclass method
  -> ReceiverMethodInvocation(receiver: SuperReference(super))

foo is a superclass getter whose value is called
  -> CallInvocation(receiver: ReceiverPropertyExtraction(SuperReference(super), .foo))


.name(arguments)

name is a static method
  -> DotShorthandMethodInvocation

name is a getter or field whose value is called
  -> CallInvocation(receiver: DotShorthandNameExpression(.name))

name is a constructor
  -> DotShorthandConstructorInvocation
```

Invalid lowering still chooses one canonical topology. Keywordless `C.missing()` becomes `ConstructorInvocation` only when syntax or a distinguished constructor establishes that interpretation; with no candidate it becomes an invalid `ReceiverMethodInvocation`. Explicitly constructor-shaped invalid source remains `ConstructorInvocation`.

Resolved-tree invariants:

```dart
// Applies to valid and invalid resolved units.
no ParsedExpressionChain
no ParsedAssignmentTargetChain
no ParsedDotShorthandExpression
no ParsedExpressionChainHead or ParsedExpressionChainComponent

preserve original tokens
preserve comments and source ranges
preserve reference occurrences
update parent links atomically
update covering-node behavior atomically
update flow-analysis keys atomically
assert that no V1 projection was created before lowering
create resolved V1 projections only from final canonical V2 nodes

// Lowering chooses canonical source roles; it does not create getter calls, setter calls, temporaries, or kernel IR.
```

## 8. Resolution and references

```dart
abstract final class ReadResolution {
  Element? get element;
  DartType get type;
}

abstract final class WriteResolution {
  DartType get acceptedType;
  Element? get element;
}

sealed interface class NamedReadResolution implements ReadResolution {}

NamedReadResolutionWithElement implements NamedReadResolution
  Element get element;
  VariableReadResolution
    VariableElement get element;
  GetterInvocationResolution
    GetterElement get element;
    FunctionType get invokeType;
  ExecutableTearOffResolution
    ExecutableElement get element;
    List<DartType> get inferredTypeArguments;

RecordFieldReadResolution implements NamedReadResolution

DynamicPropertyReadResolution implements NamedReadResolution

InvalidNamedReadResolution implements NamedReadResolution, InvalidReadResolution
  Element? get recoveryElement;

sealed interface class NamedWriteResolution implements WriteResolution {}

NamedWriteResolutionWithElement implements NamedWriteResolution
  Element get element;
  VariableWriteResolution
    VariableElement get element;
  SetterInvocationResolution
    SetterElement get element;

DynamicPropertyWriteResolution implements NamedWriteResolution

InvalidNamedWriteResolution implements NamedWriteResolution, InvalidWriteResolution
  Element? get recoveryElement;
```

Dynamic property results describe runtime dispatch; variables typed `dynamic` retain variable resolution. `TypeLiteral` needs no named-read resolution. Indexed results:

```dart
sealed interface class IndexReadResolution implements ReadResolution {}

ValidIndexReadResolution implements IndexReadResolution
  MethodIndexReadResolution
    MethodElement get element;
  DynamicIndexReadResolution
  UnreachableIndexReadResolution

InvalidIndexReadResolution implements IndexReadResolution, InvalidReadResolution
  MethodElement? get recoveryElement;

sealed interface class IndexWriteResolution implements WriteResolution {}

ValidIndexWriteResolution implements IndexWriteResolution
  MethodIndexWriteResolution
    MethodElement get element;
  DynamicIndexWriteResolution

InvalidIndexWriteResolution implements IndexWriteResolution, InvalidWriteResolution
  MethodElement? get recoveryElement;
```

Unresolved or receiver-suppressed accesses have null resolutions. `InvalidReadResolution` and `InvalidWriteResolution` implement the read/write roots with `InvalidType` results. Named/indexed implementations also implement the common invalid `Impl` types while extending their family bases. Stateless const invalid implementations serve structural targets; target shape identifies the cause.

`element` is the selected declaration; invalid results return null. Invalid named and indexed reads/writes retain `recoveryElement`. Named recovery can retain `MultiplyDefinedElement`; index recovery retains malformed methods and uses the first parameter, if present, for index inference. Consumers choose recovery or selected `element` according to their operation. Named `WithElement` interfaces guarantee non-null elements; method-index results expose `MethodElement`.

Invocation results distinguish selected executables, application of an exact function type, direct invocation of its language-defined named `call` method, invocation through core `Function` without a known signature, dynamic dispatch, unreachable code, and invalid lookup:

```dart
sealed interface class InvocationResolution {
  DartType get type;
}

ValidInvocationResolution implements InvocationResolution
  StaticInvocationResolution
  FunctionType get invokeType;
    ExecutableInvocationResolution
      ExecutableElement get element;
    FunctionTypeInvocationResolution
    FunctionCallInvocationResolution
  FunctionInterfaceInvocationResolution
  DynamicInvocationResolution
  UnreachableInvocationResolution

InvalidInvocationResolution implements InvocationResolution
  // type is InvalidType.
  List<Element> get candidates;
  ValidInvocationResolution? get recovery;
```

`FunctionTypeInvocationResolution` applies arguments to a function value; `FunctionCallInvocationResolution` invokes the written exact `call` operation. Both have an effective signature without an executable element. Core `Function` uses `FunctionInterfaceInvocationResolution`, which produces `dynamic` without implementing `StaticInvocationResolution`; genuinely dynamic dispatch remains distinct.

Operator application exposes its selected substituted `MethodElement?` directly as `element`. On unary and binary expressions the operator result is the expression's `staticType`. Compound assignments and updates with non-null target read and write expose the intermediate `operatorResultType` between them:

```dart
target read.type
  -> operatorResultType
  -> target write.acceptedType
```

A null element means unresolved or that no method was statically selected. The accompanying nullable result type distinguishes unresolved AST from resolved dynamic, unreachable, and invalid outcomes. A non-invoking null equality has a null element and `staticType: bool`. Numeric refinement can make `staticType` or `operatorResultType` differ from `element.returnType`.

References are attached to source sites, not only to name tokens:

```dart
abstract interface class ReferenceSite {
  SourceRange get referenceRange;
  Iterable<ResolvedReference> get references;
}

final class ResolvedReference {
  ReferenceRole get role;
  Element? get target;                         // Semantic operation target.
  Element? get navigationTarget;               // Declaration preferred by navigation.
}
```

Canonical V2 removes reusable `Identifier`, `SimpleIdentifier`, and `PrefixedIdentifier` nodes. Each source-role owner owns its name token directly, while V1 alone synthesizes identifier-shaped compatibility structure. Documentation references likewise use a dedicated non-expression component model rather than `CommentReferableExpression`:

```dart
abstract final class CommentReference implements AstNode {
  Token? get newKeyword;
  NodeList<CommentReferenceComponent> get components;
  Element? get element;
}

sealed interface class CommentReferenceComponent implements AstNode {
  Token? get period;
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

Comment references have no `staticType`, flow analysis, or ordinary named-read resolution. Their components retain the written names or operator and independently resolved elements for navigation.

```dart
x;
  name x -> one value reference

x = value;
  name x -> one write reference

x += value;
  name x -> one read reference + one write reference

prefix.x += value;
  prefix -> PrefixElement
  x -> imported getter + imported setter

a[i] += value;
  [i] site -> operator [] + operator []=

super();
  invocation site -> inherited call method
  // No synthetic call name is added.

super + value;
  operator site -> selected superclass operator +

.named.call(0);
  shorthand name -> selected constructor tear-off
  call name -> Function.call

receiver.(value) { return value.member; }
  parameter value -> local declaration
  use value -> parameter reference
  member -> selected receiver member
  // Anonymous-method punctuation has no executable reference.
```

The sealed result shapes are proposed here; exact candidate, navigation, and recovery payloads and the public reference API remain open.

## 9. V1 projection

```dart
ParsedExpressionChain -> legacy expression-shaped parse tree
ParsedAssignmentTargetChain -> legacy expression-shaped left-hand side
ParsedDotShorthandExpression -> current complete dot-shorthand parse tree
TopLevelFunctionDeclaration -> FunctionDeclaration with synthetic FunctionExpression
LocalFunctionDeclaration -> FunctionDeclarationStatement with synthetic FunctionDeclaration and FunctionExpression
FunctionExpression -> FunctionExpression
ConstructorInvocation -> InstanceCreationExpression
ConstructorTearOff -> deprecated ConstructorReference expression
UnqualifiedNameExpression / UnqualifiedNameAssignmentTarget -> SimpleIdentifier
DirectAssignment / IfNullAssignment / CompoundAssignment -> AssignmentExpression
InvalidExpressionAssignmentTarget -> its expression as the assignment or update operand
InvalidExtensionOverrideAssignmentTarget -> ExtensionOverride as the assignment or update operand
InvalidSuperAssignmentTarget -> SuperExpression as the assignment or update operand
ReceiverPropertyExtraction / ReceiverPropertyAssignmentTarget -> PropertyAccess or PrefixedIdentifier
ImportPrefixedNameExpression / ImportPrefixedAssignmentTarget -> PrefixedIdentifier
TypeLiteral with NamedType -> TypeLiteral with the legacy NamedType view
ReceiverIndexExpression / ReceiverIndexAssignmentTarget -> IndexExpression
UnqualifiedFunctionInvocation / ReceiverMethodInvocation / ImportPrefixedFunctionInvocation -> MethodInvocation
CascadeMethodInvocation -> target-less MethodInvocation with .. or ?.. metadata
CallInvocation -> FunctionExpressionInvocation
FunctionInstantiation with ordinary operand -> FunctionReference with written type arguments
FunctionInstantiation with ImplicitCallTearOff -> ImplicitCallReference with written type arguments
ImplicitFunctionInstantiation with ordinary operand -> FunctionReference without written type arguments
ImplicitFunctionInstantiation with ImplicitCallTearOff -> ImplicitCallReference with inferred type arguments
ImplicitCallTearOff -> ImplicitCallReference
DotShorthandNameExpression -> DotShorthandPropertyAccess
DotShorthandMethodInvocation -> DotShorthandInvocation
DotShorthandConstructorInvocation -> DotShorthandConstructorInvocation
AnonymousMethodInvocation -> AnonymousMethodInvocation with explicit receiver
CascadeAnonymousMethodInvocation -> target-less AnonymousMethodInvocation with cascade metadata
ExtensionOverride / InvalidExtensionOverrideExpression -> ExtensionOverride expression
SuperReference / InvalidSuperExpression -> SuperExpression
BinaryOperatorInvocation / LogicalAnd / LogicalOr / IfNull -> BinaryExpression
UnaryOperatorInvocation / LogicalNot / PrefixIncrement / PrefixDecrement -> PrefixExpression
NullAssertion / PostfixIncrement / PostfixDecrement -> PostfixExpression
cascade-start expressions and targets -> target-less PropertyAccess, IndexExpression, or MethodInvocation
CommentReference -> legacy identifier/property component structure
```

Implementation boundary:

```dart
parser
resolver
flow analysis
constant evaluation
summary writer and reader
analyzer-owned visitors and collectors
  -> operate on canonical V2

V1
  -> generated/cached compatibility projection

resolveForWrite(Expression node, bool hasRead)
  -> resolveAssignmentTarget(AssignmentTarget target, TargetAccessMode mode)

Expression.isAssignable
SimpleIdentifier.inGetterContext
SimpleIdentifier.inSetterContext
IndexExpression parent-sensitive read/write queries
  -> absent from canonical V2

name-expression hierarchy
  -> sealed NameExpressionImpl with a covariant NamedReadResolutionImpl? resolution getter
  -> PropertyExtractionImpl derives from NameExpressionImpl
  -> concrete visitor dispatch remains; a common callback requires a separate design decision

generated child-slot categories
  -> Expression
  -> NamedReceiver
  -> InstanceReceiver
  -> AssignmentTarget
  -> ParsedExpressionChainHead and ParsedExpressionChainComponent
  -> ParsedDotShorthandExpression
  -> precise invalid receiver-expression and invalid-target children
  -> semantic-adaptation operand
  -> dot-shorthand context
  -> constructor type reference and selector

parse-only printers, node locators, covering-node logic, formatters, token tools
  -> understand neutral parsed chains

resolved printers, flow analysis, constant evaluation, serialization, indexers, navigation
  -> understand canonical lowered nodes and never receive parsed chains

syntax-oriented traversal
  -> skips through no-token semantic adaptations by default

semantic traversal
  -> can observe semantic adaptations and implicit reference sites
```

## 10. Open decisions

```dart
function declarations
  // Common API, invalid local modifiers, top-level getter/setter splits, V1 identity.

source-role names
  // Final unqualified, qualifier, invocation, invalid-target, operator, and adaptation names.

comment references
  // One component list versus concrete arities, and exact ownership of final operator syntax.

resolution and tooling
  // Candidate, recovery, semantic/navigation targets; placement of ReferenceSite.

receiver capabilities
  // Exact property, index, invocation, unary-operator, and cascade slots accepting NamedReceiver or InstanceReceiver instead of Expression.

parsed chains and lowering
  // Final Parsed* names, ambiguous islands, recovery, identity, and V1 timing.

invalid targets
  // Final Invalid*AssignmentTarget names.

invocations and semantic adaptations
  // Invalid call recovery, FunctionInstantiation naming, adaptation API and placement.

operators
  // Final invocation, enum, IncrementOrDecrementExpression, and four leaf names.

constructors, annotations, and enums
  // Shared invocation capability, sealed selection results, annotation split, enum arguments.

dot shorthand
  // Final names, context outcomes, unknown schemes, invalid constructor type arguments.

anonymous methods
  // Cascade tails, shared API, invalid parameters, scope owner, yield, constness.

cascade recovery
  // Extension-override recovery policy and downstream type after the invalid cascade receives InvalidType.

whole-AST identifier removal
  // Migration of every remaining non-expression name owner.
```
