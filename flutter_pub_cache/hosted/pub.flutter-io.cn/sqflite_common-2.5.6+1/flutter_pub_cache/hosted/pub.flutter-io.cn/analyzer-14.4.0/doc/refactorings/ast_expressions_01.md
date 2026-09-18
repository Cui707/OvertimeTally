# AST Expressions in Analyzer, Front End, and Kernel: Exploration 01

This document records an exploration of how expressions are represented in `pkg/analyzer`, `pkg/front_end`, and `pkg/kernel`. It is an inventory and comparison, not a design document. The final sections record possible design directions and open questions, but do not make decisions.

The counts and class lists below describe the checkout at the time this document was written. They exclude abstract grouping classes and include concrete implementation-visible expression kinds, so they should be treated as a snapshot rather than a stable API statement.

## 1. Summary

The three packages represent different stages and optimize for different uses.

| Package and representation | Concrete expression kinds | Main characteristic |
|---|---:|---|
| Analyzer public AST | 44 | Mostly source-shaped, but also contains resolution-only nodes and semantic data |
| Front end `InternalExpression` | 91 | A pre-inference intermediate containing both source constructs and semantic distinctions |
| Kernel `Expression` | 70 | A resolved and often lowered semantic IR |

The counts do not indicate that one package supports more language features than another. Analyzer distinguishes many source forms that disappear in kernel, while kernel distinguishes semantic operations that share one analyzer source form. Front end has both kinds of distinctions during body building and inference, which contributes to its larger intermediate hierarchy.

The analyzer currently uses the same AST object graph for parsed and resolved code. Resolution stores elements and types on nodes and sometimes rewrites parsed nodes into different node kinds. This makes the tree useful to source-oriented clients, but it also means that syntactic nodes, semantic references, value-producing expressions, write targets, and qualifiers are sometimes represented by the same classes.

`SimpleIdentifier` is the clearest example. It is an `Expression`, but it is also used for method and property selectors, constructor names, import prefixes, combinator names, field references, declaration-related names, and for-in write targets. Some of those uses can have a value type, some are assigned a pseudo-expression type for compatibility, and some remain with `staticType == null` after resolution.

Kernel takes the opposite approach. It has no general identifier expression. A resolved occurrence becomes a semantic operation such as `VariableGet`, `StaticGet`, `InstanceGet`, `DynamicGet`, `VariableSet`, a tear-off, an invocation, or a `TypeLiteral`. Names are values or references owned by those semantic nodes, not child expressions.

Front end has an explicit phase boundary. Its `SimpleIdentifier` is not an expression. Context-sensitive expression occurrences are commonly represented by a `Generator`, then by an `InternalExpression`, and inference returns an `ExpressionInferenceResult` containing a known type and a kernel `Expression`.

## 2. Analyzer Expression Model

The public documentation in `pkg/analyzer/lib/dart/ast/ast.dart` describes the analyzer AST as a syntactic model. It also describes the same AST as being either unresolved or resolved: unresolved nodes have semantic properties that return `null`, while resolved identifiers are associated with elements and resolved expressions have types.

The expression interface is declared in `pkg/analyzer/lib/src/dart/ast/ast.dart`. `Expression.staticType` returns `null` if the AST has not been resolved. `ExpressionImpl` stores this in a nullable `_staticType` field.

### 2.1 Concrete analyzer expression kinds

The 44 concrete public expression kinds can be grouped as follows.

Literals and literal-like source forms:

- `AdjacentStrings`
- `BooleanLiteral`
- `DoubleLiteral`
- `IntegerLiteral`
- `ListLiteral`
- `NullLiteral`
- `RecordLiteral`
- `SetOrMapLiteral`
- `SimpleStringLiteral`
- `StringInterpolation`
- `SymbolLiteral`

Names, primary expressions, and accesses:

- `SimpleIdentifier`
- `PrefixedIdentifier`
- `PropertyAccess`
- `DotShorthandPropertyAccess`
- `IndexExpression`
- `ThisExpression`
- `SuperExpression`

Invocations, construction, and references:

- `AnonymousMethodInvocation`
- `MethodInvocation`
- `FunctionExpressionInvocation`
- `InstanceCreationExpression`
- `FunctionReference`
- `DotShorthandConstructorInvocation`
- `DotShorthandInvocation`

Operators and control expressions:

- `AsExpression`
- `AssignmentExpression`
- `AwaitExpression`
- `BinaryExpression`
- `CascadeExpression`
- `ConditionalExpression`
- `IsExpression`
- `ParenthesizedExpression`
- `PatternAssignment`
- `PostfixExpression`
- `PrefixExpression`
- `RethrowExpression`
- `SwitchExpression`
- `ThrowExpression`

Function literal:

- `FunctionExpression`

Nodes introduced during resolution:

- `ConstructorReference`
- `ExtensionOverride`
- `ImplicitCallReference`
- `TypeLiteral`

`ConstructorReference`, `ImplicitCallReference`, and `TypeLiteral` are documented as not being produced directly by the parser. `ExtensionOverrideImpl` is constructed by resolution and by resolved-AST deserialization rather than by the ordinary parser AST builder.

Some other kinds are hybrids. For example, an `InstanceCreationExpression` can come directly from explicit `new` or `const` syntax, but an invocation parsed as a `MethodInvocation` can also be rewritten into an `InstanceCreationExpression`. A `FunctionExpressionInvocation` can represent directly parsed expression invocation syntax or be introduced when a parsed method invocation is found to invoke the result of a getter.

### 2.2 Parsed and resolved topology

`pkg/analyzer/lib/src/dart/resolver/ast_rewrite.dart` describes and implements several topology changes performed after parsing. Examples include:

- `C()` can be parsed as a `MethodInvocation` and rewritten as an `InstanceCreationExpression` when `C` resolves to a class or an appropriate type alias.
- `E(x)` can be parsed as a `MethodInvocation` and rewritten as an `ExtensionOverride` when `E` resolves to an extension.
- `C.named` can be parsed as a `PrefixedIdentifier` and rewritten as a `ConstructorReference`.
- `prefix.C.named` can be parsed as a `PropertyAccess` and rewritten as a `ConstructorReference`.
- `C` or `prefix.C` in a value-expression slot can be rewritten as a `TypeLiteral`.
- Syntax initially parsed as an instance creation can be rewritten as a function reference followed by a method invocation when the apparent type name resolves to a function.

Other resolver components perform additional expression rewrites. `MethodInvocationResolver` can replace a `MethodInvocation` with a `FunctionExpressionInvocation`, `FunctionReferenceResolver` can introduce `ImplicitCallReference`, and `PrefixedIdentifierResolver` can replace a `PrefixedIdentifier` with a `PropertyAccess` for some record-field accesses.

The resolver maintains a rewrite stack and an expando mapping original expressions to replacement expressions. Flow-analysis information is conventionally associated with the original expression even when the AST contains a replacement. Parent child slots are updated during the rewrite, so node identity and topology can differ between parsed and resolved results.

### 2.3 Static types and pseudo-expression static types

`ExpressionImpl.recordStaticType` records the type of a true expression and also performs resolver behavior such as marking flow-analysis exit for bottom types.

`ExpressionImpl.setPseudoExpressionStaticType` is different. Its documentation says that it is used when an expression AST node occurs in a place where it is not technically a true expression, with the `SimpleIdentifier` representing a method name as the example. This distinction is observable in resolved AST dumps:

- A local or top-level variable occurrence represented by `SimpleIdentifier` has its value type.
- A `MethodInvocation.methodName` can have the invoked method or getter type even though the selector is not independently evaluated as a value expression.
- An import-prefix `SimpleIdentifier` commonly has `staticType: null` after resolution.
- A type-defining identifier can have no type when used as a qualifier, or it can cause the surrounding syntax to be rewritten as a `TypeLiteral` with static type `Type` when used as a value.
- Invalid value expressions generally use `InvalidType`, so `null` is not simply the invalid-code representation.

`ResolverVisitor.dispatchExpression` contains explicit exceptions to the expectation that a resolved expression has a type. It permits a null type for `ExtensionOverride` and for identifiers whose elements are extensions, interface declarations, import prefixes, or type aliases. If no exception applies, the resolver asserts that a type was recorded.

This means that `staticType == null` can currently mean at least two broad things: the AST is unresolved, or the node is resolved but does not denote a value expression. More detailed cases include prefixes, qualifiers, extension overrides, type-like names in non-value roles, and other compatibility node uses.

### 2.4 `SimpleIdentifier` roles

`Identifier` implements `Expression`, and both `SimpleIdentifier` and `PrefixedIdentifier` therefore implement `Expression`. `SimpleIdentifier` also has parent-sensitive methods such as `inDeclarationContext`, `inGetterContext`, and `inSetterContext` that reconstruct the node's role from its parent and child slot.

The following table shows representative uses.

| Source example | Role of the identifier | Independently value-producing? |
|---|---|---:|
| `x;` | Local, parameter, top-level, or implicit-instance read | Yes |
| `o.m()` where the node is `m` | Invocation selector | No |
| `o.p` where the node is `p` | Property selector | No |
| `prefix.f` where the node is `prefix` | Import qualifier | No |
| `prefix.f` where the node is `f` | Qualified reference or selector | Not independently |
| `C.named` | Type-shaped qualifier and constructor selector | Not independently |
| `for (x in xs)` | Existing-variable write target | No |
| `this.x = e` in a constructor initializer | Field reference | No |
| `import 'a.dart' as p` | Prefix declaration | No |
| `show x` or `hide x` | Namespace name | No |
| A constructor declaration's old-style type name | Declaration/type name | No |
| `C` in a value slot | Syntactic identifier resolved as a type literal | The resolved whole occurrence is a value of type `Type` |

The public AST currently exposes `SimpleIdentifier` children in annotations, constructor declarations and references, constructor field initializers, dot-shorthand expressions, for-in parts, show/hide combinators, import prefixes, method invocations, prefixed identifiers, property accesses, and compatibility projections for constructor selectors.

### 2.5 Invocation-specific mismatch

`InvocationExpression.function` is declared to return an `Expression`. For `FunctionExpressionInvocation`, that child is an evaluated function expression. For `MethodInvocation`, `MethodInvocationImpl.function` returns `methodName`, which is a `SimpleIdentifier` selector.

This provides a uniform API for invocations, but it means that two semantically different things occupy the same property: an expression whose value is called, and a selector used to perform method lookup. The pseudo-expression static type on method names supports this uniform API. Getter-then-call cases add another distinction: the getter has a read type, the returned callable has an invoke type, and the whole invocation has a result type.

### 2.6 Value-expression slot metadata

Generated analyzer nodes have an internal `isInValueExpressionSlot` method. `GenerateNodeProperty` has a corresponding `isInValueExpressionSlot` flag. The AST rewriter uses this information to decide whether an identifier that resolves to a type should become a `TypeLiteral`.

Examples of value-expression slots include binary operands, conditional branches, argument values, return expressions, and the right-hand side of an assignment. Examples of non-value slots include type annotations, method selectors, constructor selectors, and the left-hand side of a plain assignment. Some receiver slots are semantically ambiguous before resolution because the same syntax can be an evaluated receiver, an import prefix, a type qualifier, or an extension override.

### 2.7 Existing AST V2 direction

The current V2 work has already removed `SimpleIdentifier` from many declaration-side APIs by using `Token` properties. It has also introduced dedicated reference nodes for roles that require more than a token:

- `ImportPrefixReference` contains the prefix token, period, and resolved element, but is not an expression.
- `LabelReference` contains the label token and resolved label element, but is not an expression.
- `ConstructorSelector` represents the period and constructor name. Its V2 name is a token, while the old `SimpleIdentifier` API is maintained as a V1 compatibility projection.
- `NamedType` contains a token name and an optional `ImportPrefixReference` rather than using identifier expressions for those components.

These nodes provide existing examples of source ranges and resolved elements being available without classifying the referenced name as a value expression.

## 3. Kernel Expression Model

Kernel expressions are declared primarily in `pkg/kernel/lib/src/ast/expressions.dart`, with pattern-related expressions in `pkg/kernel/lib/src/ast/patterns.dart`.

`kernel.Expression` has a non-null `getStaticType(StaticTypeContext)` operation. Some node types compute their type from their target or children, while other node types store a result type or function type because it cannot be reconstructed cheaply or precisely. Resolution phase is not represented by nullability of the expression type.

Kernel has no equivalent of an unresolved general-purpose `SimpleIdentifier` expression. A source name occurrence becomes a more specific semantic node or disappears into another node's target/name fields.

### 3.1 Reads, writes, and tear-offs

Representative read nodes include:

- `VariableGet`
- `RecordIndexGet`
- `RecordNameGet`
- `DynamicGet`
- `InstanceGet`
- `AbstractSuperPropertyGet`
- `SuperPropertyGet`
- `StaticGet`

Representative write nodes include:

- `VariableSet`
- `DynamicSet`
- `InstanceSet`
- `AbstractSuperPropertySet`
- `SuperPropertySet`
- `StaticSet`

Tear-offs are also explicit semantic operations:

- `FunctionTearOff`
- `InstanceTearOff`
- `StaticTearOff`
- `ConstructorTearOff`
- `RedirectingFactoryTearOff`
- `TypedefTearOff`

Static and variable nodes refer directly to declarations. Instance and dynamic accesses contain an evaluated receiver plus a `Name`. Instance accesses also contain an interface target and substituted result type when applicable. The `Name` is not an expression and does not have an independent static type.

### 3.2 Invocations

Kernel distinguishes invocation semantics that the analyzer often represents with one source node kind:

- `DynamicInvocation`
- `InstanceInvocation`
- `InstanceGetterInvocation`
- `FunctionInvocation`
- `LocalFunctionInvocation`
- `AbstractSuperMethodInvocation`
- `SuperMethodInvocation`
- `StaticInvocation`
- `ConstructorInvocation`
- `RedirectingFactoryInvocation`

`InstanceGetterInvocation` makes getter-then-call semantics explicit. Dynamic and instance invocations record access kinds that distinguish valid instance dispatch, `Object` dispatch, nullable or inapplicable error recovery, dynamic access, `Never`, invalid receiver types, and unresolved targets.

### 3.3 Source forms that are lowered or merged

Kernel does not preserve all analyzer source expression distinctions.

- `SimpleIdentifier`, `PrefixedIdentifier`, and `PropertyAccess` become semantic get, set, invocation, tear-off, or type-literal nodes.
- Most binary operators become invocations. `&&` and `||` use `LogicalExpression`; equality has `EqualsCall` and `EqualsNull` forms.
- Prefix and postfix increment, compound assignment, and null-aware assignment become combinations of reads, writes, invocations, conditionals, and `Let` expressions.
- Cascades are lowered using temporary variables and `Let` expressions.
- Parentheses disappear.
- Adjacent strings and interpolation become `StringConcatenation`.
- Collection control flow and spread can use block expressions or list, set, and map concatenation forms, especially in constant-related representations.
- Extension overrides disappear into static extension-member operations.
- `super` is represented by specific super access and invocation nodes rather than a general `SuperExpression` receiver.

Kernel also has expressions that are primarily IR or transformation devices rather than direct source constructs, including `Let`, `BlockExpression`, `ConstantExpression`, `FileUriExpression`, `FileUriConstantExpression`, `CheckLibraryIsLoaded`, and `InstanceCreation` for partially unevaluated constant construction.

`InvalidExpression` is an explicit kernel node with a non-null static type. This permits an invalid resolved value expression to remain an expression without using a null type to indicate failure.

## 4. Front End Expression Model

Front end body building and inference are spread across `pkg/front_end/lib/src/base/identifiers.dart`, `pkg/front_end/lib/src/kernel/expression_generator.dart`, `pkg/front_end/lib/src/kernel/internal_ast.dart`, and `pkg/front_end/lib/src/type_inference/inference_visitor.dart`.

### 4.1 Identifiers are separate from expressions

Front end's base `Identifier` interface provides a token, name, offsets, optional initializer, optional operator, and type-name view. `SimpleIdentifier` extends `IdentifierImpl`; neither class implements `InternalExpression` or kernel `Expression`.

`BodyBuilder.handleIdentifier` uses the parser's `IdentifierContext`. Declaration-like occurrences are pushed as identifiers. Scope-reference occurrences are looked up and generally become builders or generators rather than remaining identifier nodes.

This means the same lexical token can enter different representations depending on its grammatical and scope context without every occurrence first becoming an expression.

### 4.2 Generators delay context-sensitive semantic choices

`Generator` represents a subexpression for which the front end cannot yet build an expression because its use is not known. Its documentation uses `a[x] = b` as an example: after parsing `a[x]`, the builder does not yet know whether it needs an index read or index write.

Generators have operations for building:

- a simple read
- an assignment
- a for-in target
- a null-aware assignment
- a compound assignment
- prefix and postfix increment
- indexed access
- invocation
- selector access
- type application
- pattern assignment

Representative generator kinds include `VariableUseGenerator`, `PropertyAccessGenerator`, `ThisPropertyAccessGenerator`, `NullAwarePropertyAccessGenerator`, `SuperPropertyAccessGenerator`, `IndexedAccessGenerator`, `StaticAccessGenerator`, extension access generators, `PrefixUseGenerator`, `LoadLibraryGenerator`, and several error or context-aware generators.

`BodyBuilder.toValue` converts a `Generator` to an `InternalExpression` by calling `buildSimpleRead`. Other syntactic contexts call the appropriate generator operation instead. Thus read/write/invoke distinctions are made before the final kernel expression is produced, without treating the original name or selector as an independently typed expression.

### 4.3 `InternalExpression` is pre-inference

`InternalExpression` is a front-end-specific tree node with a file offset and an `acceptInference` method. It does not have a stored static type. Inference visits it with a type context and returns an `ExpressionInferenceResult`.

`ExpressionInferenceResult` contains:

- a known inferred `DartType`
- the inferred kernel `Expression`
- an optional more precise post-coercion type

The returned kernel expression can have a different shape from the input internal expression. For example, inference of a binary expression can produce a semantic invocation; inference of a collection with control-flow elements can produce a kernel block expression; and compound operations can produce multiple kernel operations.

### 4.4 Front end internal expression categories

The 91 concrete `InternalExpression` kinds include several overlapping categories.

Source-like constructs include `BinaryExpression`, `UnaryExpression`, `ParenthesizedExpression`, `Cascade`, `MethodInvocation`, `ExpressionInvocation`, conditional, logical, `is`, `as`, await, literals, function expressions, switch expressions, pattern assignments, and dot shorthand.

Resolved access distinctions include variable, property, static, super, extension, index, constructor, type-alias, and load-library forms.

Compound and context-sensitive distinctions include local/static/super/property/extension increment and decrement, if-null sets, compound sets, index sets, and extension-specific variants.

Some internal nodes are close to kernel nodes, while others retain source constructs that kernel later lowers. The hierarchy is therefore neither a pure parser AST nor a final semantic IR.

### 4.5 Source fidelity

Front end's internal AST is intended for compilation rather than public source tooling. Internal nodes generally retain file offsets but do not preserve the complete scanner-token topology, comments, all recovery structure, or the public parent/child source model expected by analyzer clients.

Front end therefore demonstrates a parsed/building/resolved phase separation, but its exact intermediate representation does not directly substitute for the analyzer AST.

## 5. Cross-Package Examples

The following table illustrates typical representation changes. Exact kernel output depends on static types, error recovery, language features, and later transformations.

| Source construct | Analyzer | Front end before inference | Typical kernel result |
|---|---|---|---|
| `x` | `SimpleIdentifier` | `VariableUseGenerator`, then `InternalVariableGet`, or another access generator | `VariableGet`, `StaticGet`, `InstanceGet`, `DynamicGet`, or `TypeLiteral` |
| `prefix.x` | `PrefixedIdentifier` | Prefix/static/type-use generator | A static get/tear-off/invocation or type literal; the prefix is not an expression |
| `o.x` | `PrefixedIdentifier` or `PropertyAccess` | `PropertyAccessGenerator`, then property/extension get | `InstanceGet`, `DynamicGet`, static extension invocation, or record get |
| `o.m()` | `MethodInvocation` | Generator or `MethodInvocation` | `InstanceInvocation`, `DynamicInvocation`, `StaticInvocation`, or extension invocation |
| `getter()` | Frequently rewritten to `FunctionExpressionInvocation` | Getter access followed by expression invocation | Get plus `FunctionInvocation` or `InstanceGetterInvocation` |
| `x = y` | `AssignmentExpression` with identifier/property/index LHS | Generator `buildAssignment` | Variable/static/instance/dynamic set |
| `x += y` | `AssignmentExpression` with read/write metadata | Compound-set internal node | Reads, operator invocation, set, and possibly `Let` |
| `x++` | `PostfixExpression` with read/write metadata | Specialized inc/dec internal node | Reads, invocation, set, and temporaries |
| `a + b` | `BinaryExpression` with operator element and invoke type | `BinaryExpression` | Usually an invocation; logical and equality cases have dedicated nodes |
| `C` in a value context | Parsed identifier, rewritten `TypeLiteral` | Type-use generator, then `InternalTypeLiteral` | `TypeLiteral` |
| `C.named` tear-off | Parsed access, rewritten `ConstructorReference` | Constructor tear-off internal node | `ConstructorTearOff` |
| `C()` | Parsed or rewritten `InstanceCreationExpression` | Constructor invocation internal node | `ConstructorInvocation` or `StaticInvocation` for factory cases |
| `E(o).m` | `ExtensionOverride` receiver plus access | Explicit extension access generator | Static extension-member operation |
| `a..b()..c()` | `CascadeExpression` preserving source sections | `Cascade` with synthetic receiver variable | Nested `Let` and invocation expressions |
| `'a $x' 'b'` | `StringInterpolation` and `AdjacentStrings` | `InternalStringConcatenation` | `StringConcatenation` |
| `(x)` | `ParenthesizedExpression` | `ParenthesizedExpression` | The inner expression |

## 6. Factual Observations

The analyzer's expression hierarchy currently represents more than value expressions. It also represents selectors, qualifiers, restricted receivers, type-shaped references, and assignment-related occurrences.

The analyzer already has multiple type-like semantic properties for one source expression: `staticType`, `staticInvokeType`, method-name or getter type, tear-off type arguments, read type, write type, corresponding parameter, and referenced element. A single `staticType` property does not capture all invocation and assignment semantics, which is why additional properties and pseudo-expression types exist.

The analyzer's source topology can change during resolution. Its resolved-only expression nodes show that parser nodes and resolved nodes are already conceptually different even though they occupy one mutable AST.

Kernel makes value-expression boundaries explicit because selector names and declaration references are fields of semantic operations, not expression children. Kernel's expression type is not nullable based on phase.

Front end separates identifiers, context-sensitive access generation, pre-inference expressions, and inferred kernel expressions. Its larger internal hierarchy reflects the number of combinations created when source shape and semantic operation are both represented by concrete node kinds.

Analyzer AST V2 already contains examples of non-expression reference nodes and token-based names, so separating a referenced name from a value expression would extend an existing direction rather than introduce an entirely new convention.

The existing `isInValueExpressionSlot` metadata records part of the distinction, but a boolean is not enough to describe all relevant roles. In particular, receiver positions can be evaluated values, import qualifiers, type qualifiers, or extension overrides, and assignment targets have different read/write behavior depending on the enclosing operator.

## 7. Possible Design Directions, Without Decisions

This section records possibilities suggested by the comparison. It does not select an API or migration plan.

### 7.1 Continue refining one resolved source AST

One possibility is to retain a single source AST and make its node roles more precise. Plain names could use tokens, references that need elements could use dedicated reference nodes, and only actual value occurrences could use expression nodes. Resolution data would continue to be stored on the source nodes.

This direction is close to current AST V2 work and avoids a second expression graph. It would still need a way to distinguish unresolved semantic properties from resolved invalid code, and source nodes whose meaning changes during resolution would either continue to be rewritten or would need a separate semantic-result property.

### 7.2 Separate syntax nodes and resolved expression nodes

Another possibility is an immutable syntax AST plus a separate resolved-expression graph. A resolved expression could link back to its source syntax and have a non-null type. Semantic subclasses could distinguish local reads, property reads, dynamic accesses, invocations, writes, type literals, coercions, and invalid expressions.

A complete parallel tree provides strong phase and type invariants, but it duplicates traversal structure and needs explicit source mapping. If it combines every source shape with every semantic operation in concrete subclasses, it can acquire a large hierarchy similar to front end's internal AST.

### 7.3 Use a semantic overlay rather than a complete second tree

A related possibility is to retain the syntax AST and associate true value-expression occurrences with resolved semantic records. Such a record could contain a non-null type and a semantic payload such as local read, instance property read, direct method invocation, getter-then-call, type literal, or invalid expression.

References, write targets, and receivers could have separate result types rather than being forced into `ResolvedExpression`. This separates the source-shape axis from the semantic-operation axis and can avoid creating a concrete class for every combination. Synthetic semantic operations such as implicit call tear-offs or coercions might require multiple semantic records associated with one source occurrence.

### 7.4 Refine child-slot roles

The current generated `isInValueExpressionSlot` flag could remain an implementation detail or could evolve into a richer internal child-slot classification. Possible roles include value expression, write target, receiver or qualifier, selector, type, declaration name, reference name, and pattern-related positions.

Such metadata could support validation of AST topology, resolution dispatch, elimination of parent-type switches, and migration away from pseudo-expression types. The exact role set and whether it belongs in the public API remain open questions.

### 7.5 `SimpleIdentifier` possibilities

Possible source-model shapes include:

- Keep `SimpleIdentifier` as a lexical/reference node but remove `Expression` from its supertypes, and introduce a separate `IdentifierExpression` for value-expression syntax.
- Use tokens for most simple names and dedicated nodes only where a range plus resolved element is useful.
- Retain a whole `PrefixedIdentifier` or qualified-access source node, but make its component names non-expressions and record whether it resolved as an import-qualified access, type-qualified access, or evaluated property access elsewhere.
- Continue compatibility projections for old APIs while using token- or reference-based V2 nodes as the primary topology.

### 7.6 Questions left open

- Should the syntax tree remain mutable during resolution, or should parsed topology be stable?
- Should every syntactic `Expression` occurrence have a resolved-expression result, or only occurrences in value-producing slots?
- How should plain-assignment targets, compound-assignment targets, and for-in targets be represented relative to value expressions?
- Should extension overrides and `super` be expressions, restricted receivers, or separate source categories?
- Where should navigation elements live for method selectors and property names if those names are tokens rather than expression nodes?
- Should direct method invocation and getter-then-call be distinct resolved semantic kinds while sharing one source `MethodInvocation`?
- How should flow-analysis information be keyed when a single source expression corresponds to synthetic semantic operations?
- How should constant evaluation and AST serialization represent semantic overlays or a second graph?
- How much resolved semantic API should be public, and how much should remain an analyzer implementation detail?
- How should existing clients that visit resolved AST and inspect `SimpleIdentifier.staticType` migrate?

## Appendix A: Flat Analyzer Inventory

```text
AdjacentStrings
AnonymousMethodInvocation
AsExpression
AssignmentExpression
AwaitExpression
BinaryExpression
BooleanLiteral
CascadeExpression
ConditionalExpression
ConstructorReference
DotShorthandConstructorInvocation
DotShorthandInvocation
DotShorthandPropertyAccess
DoubleLiteral
ExtensionOverride
FunctionExpression
FunctionExpressionInvocation
FunctionReference
ImplicitCallReference
IndexExpression
InstanceCreationExpression
IntegerLiteral
IsExpression
ListLiteral
MethodInvocation
NullLiteral
ParenthesizedExpression
PatternAssignment
PostfixExpression
PrefixExpression
PrefixedIdentifier
PropertyAccess
RecordLiteral
RethrowExpression
SetOrMapLiteral
SimpleIdentifier
SimpleStringLiteral
StringInterpolation
SuperExpression
SwitchExpression
SymbolLiteral
ThisExpression
ThrowExpression
TypeLiteral
```

## Appendix B: Flat Kernel Inventory

```text
AbstractSuperMethodInvocation
AbstractSuperPropertyGet
AbstractSuperPropertySet
AsExpression
AwaitExpression
BlockExpression
BoolLiteral
CheckLibraryIsLoaded
ConditionalExpression
ConstantExpression
ConstructorInvocation
ConstructorTearOff
DoubleLiteral
DynamicGet
DynamicInvocation
DynamicSet
EqualsCall
EqualsNull
FileUriConstantExpression
FileUriExpression
FunctionExpression
FunctionInvocation
FunctionTearOff
InstanceCreation
InstanceGet
InstanceGetterInvocation
InstanceInvocation
InstanceSet
InstanceTearOff
Instantiation
IntLiteral
InvalidExpression
IsExpression
Let
ListConcatenation
ListLiteral
LoadLibrary
LocalFunctionInvocation
LogicalExpression
MapConcatenation
MapLiteral
Not
NullCheck
NullLiteral
PatternAssignment
RecordIndexGet
RecordLiteral
RecordNameGet
RedirectingFactoryInvocation
RedirectingFactoryTearOff
Rethrow
SetConcatenation
SetLiteral
StaticGet
StaticInvocation
StaticSet
StaticTearOff
StringConcatenation
StringLiteral
SuperMethodInvocation
SuperPropertyGet
SuperPropertySet
SwitchExpression
SymbolLiteral
ThisExpression
Throw
TypeLiteral
TypedefTearOff
VariableGet
VariableSet
```

## Appendix C: Flat Front End `InternalExpression` Inventory

```text
AnonymousMethodBlock
AnonymousMethodExpression
BinaryExpression
Cascade
CompoundIndexSet
CompoundPropertySet
CompoundSuperIndexSet
DeferredCheck
DotShorthand
DotShorthandInvocation
DotShorthandPropertyGet
EqualsExpression
ExpressionInvocation
ExtensionCompoundIndexSet
ExtensionCompoundSet
ExtensionGet
ExtensionGetterInvocation
ExtensionIfNullIndexSet
ExtensionIfNullSet
ExtensionIncDec
ExtensionIndexGet
ExtensionIndexSet
ExtensionMethodInvocation
ExtensionSet
ExtensionTearOff
FactoryConstructorInvocation
IfNullExpression
IfNullIndexSet
IfNullPropertySet
IfNullSet
IfNullSuperIndexSet
IndexGet
IndexSet
InternalAsExpression
InternalAwaitExpression
InternalBlockExpression
InternalBoolLiteral
InternalConditionalExpression
InternalConstructorInvocation
InternalConstructorTearOff
InternalDoubleLiteral
InternalFileUriExpression
InternalFunctionExpression
InternalInstantiation
InternalIntLiteral
InternalInvalidExpression
InternalIsExpression
InternalLet
InternalListLiteral
InternalLoadLibrary
InternalLogicalExpression
InternalMapLiteral
InternalNot
InternalNullCheck
InternalNullLiteral
InternalPatternAssignment
InternalRecordLiteral
InternalRedirectingFactoryTearOff
InternalRethrow
InternalSetLiteral
InternalStaticGet
InternalStaticInvocation
InternalStaticSet
InternalStaticTearOff
InternalStringConcatenation
InternalStringLiteral
InternalSuperMethodInvocation
InternalSuperPropertyGet
InternalSuperPropertySet
InternalSwitchExpression
InternalSymbolLiteral
InternalThisExpression
InternalThrow
InternalTypeLiteral
InternalTypedefTearOff
InternalVariableGet
InternalVariableSet
LargeIntLiteral
LoadLibraryTearOff
LocalIncDec
MethodInvocation
ParenthesizedExpression
PropertyGet
PropertyIncDec
PropertySet
StaticIncDec
SuperIncDec
SuperIndexSet
TypeAliasedConstructorInvocation
TypeAliasedFactoryInvocation
UnaryExpression
```
