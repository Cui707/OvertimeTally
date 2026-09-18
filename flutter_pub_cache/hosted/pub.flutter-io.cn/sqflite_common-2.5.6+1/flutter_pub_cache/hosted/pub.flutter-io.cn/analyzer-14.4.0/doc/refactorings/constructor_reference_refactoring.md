# Constructor Reference, Tear-Off, and Invocation Refactoring

This document proposes a constructor-focused AST cleanup:

- replace `ConstructorName` with a new constructor-reference node
- replace `ConstructorReference` with a new `ConstructorTearOff` node
- replace `InstanceCreationExpression` in the V2 tree with a new `ConstructorInvocation` node
- use `ConstructorSelector` wherever the AST currently models an optional `.` + constructor-name pair as separate `period` and `name` fields

The goal is to make the resolved AST more semantically honest without turning the entire tree into a semantic IR.

This is a compatibility-preserving migration, not an in-place breaking change.
Existing public nodes and properties remain available during the deprecation
period as compatibility projections. New nodes and new properties are the
primary generated model. The analyzer builds, resolves, rewrites, and
serializes only that V2 model. Old APIs are V1 projection facades that preserve
the old observable behavior without participating in analyzer processing.

Migration model reference: [Compatibility-Preserving AST Refactoring #63685](https://github.com/dart-lang/sdk/issues/63685).

For the resulting public API, see [API Shape After Refactoring](#api-shape-after-refactoring).

## 1. Problem Statement

The analyzer currently uses `ConstructorName` for a node that does not represent a declaration name.

It is the syntactic construct that identifies a constructor in source:

- a `NamedType`
- optionally followed by a named-constructor selector

Examples:

- `C`
- `C.named`
- `prefix.C<int>`
- `prefix.C<int>.named`

The name `ConstructorName` is misleading because it sounds like the declaration-side name of a constructor, similar to `ConstructorDeclaration.name` or `PrimaryConstructorName`.

At the same time, the existing `ConstructorReference` node is an expression node for constructor tear-offs such as `List.filled`. That name is also misleading, because the specification talks about constructor tear-offs, and because the node currently reuses `ConstructorName`, whose selector is optional.

There is also a deeper type-side mismatch: `ConstructorName.type` reuses `NamedType`, but in this context `NamedType.type` is intentionally `null`. That is a sign that the AST is reusing a node whose semantics do not quite fit the role; section 5 explains this problem in more detail.

`InstanceCreationExpression` presents a related migration problem. Patching it
with a new V2 child while retaining the old node kind would make one public
node represent two substantially different structures. It would also preserve
the misleading implication that every constructor invocation creates a fresh
instance; a factory constructor need not do so. The V2 migration can instead
introduce a correctly named expression node and project the entire legacy node.

This creates four design problems:

1. the shared non-expression node has a declaration-sounding name
2. the expression node has a reference-sounding name but models a construct whose selector should be required
3. the reused type child has a `TypeAnnotation` API that does not match this context
4. the invocation expression has a legacy name and shape that would otherwise need to mix V1 and V2 structure

## 2. Current State

Today the public AST has:

```text
abstract final class ConstructorName
    implements AstNode, ConstructorReferenceNode {
  NamedType get type;
  Token? get period;
  SimpleIdentifier? get name;
}

abstract final class ConstructorReference
    implements Expression, CommentReferableExpression {
  ConstructorName get constructorName;
}

abstract final class InstanceCreationExpression implements Expression {
  Token? get keyword;
  ConstructorName get constructorName;
  ArgumentList get argumentList;
  bool get isConst;
}
```

This shape has a few issues.

### `ConstructorName` is not a name

`ConstructorName` is not “the name of a constructor”. It includes the type and the optional named-constructor suffix. It is much closer to “a source-level reference to a constructor”.

### `SimpleIdentifier` is not the right node for the constructor name

The `name` child of `ConstructorName` is currently modeled as:

```text
SimpleIdentifier? get name;
```

This is also a semantic mismatch.

`SimpleIdentifier` is an expression node. In ordinary expression contexts, it can denote a value and can have a static type. But the constructor-name suffix in `C.named` is not evaluated as an expression. It is part of a constructor reference, not a value-producing expression in its own right.

So the current API reuses an expression node in a non-expression role. The reuse is structurally convenient, but semantically misleading, which is another reason to prefer `ConstructorSelector` for the optional `.` + name suffix.

### `NamedType` is not the right child node

The left side of a constructor reference looks type-like, but it is not quite an ordinary `TypeAnnotation`.

For example, in `A.named`:

- the `A` part is not an expression
- it is not a normal type annotation in source
- it does not always denote one `DartType`
- constructor lookup starts from a type-defining declaration plus optional type arguments

Today this mismatch appears in the API as a special case: `NamedType.type` is documented to be `null` when the `NamedType` is part of a constructor reference.

That special case is a design smell. It suggests that constructor references should use a dedicated node rather than reusing `NamedType`.

### `period` and `name` encode one concept as two fields

For valid source code, these fields represent one syntactic unit:

```text
.identifier
```

The analyzer already has a node for exactly this concept:

```text
abstract final class ConstructorSelector implements AstNode {
  Token get period;
  SimpleIdentifier get name;
}
```

To truly solve the problem of reusing an expression node in a non-expression role (as discussed above), `ConstructorSelector` should ideally use a `Token` for the name instead of a `SimpleIdentifier`. This keeps the node purely structural.

However, `ConstructorName`, `RedirectingConstructorInvocation`, and `SuperConstructorInvocation` still split this structure into two nullable fields.

### `ConstructorReference` does not encode tear-off structure precisely

The constructor tear-offs specification requires a selector for tear-offs:

- named tear-off: `C.name`
- unnamed tear-off: `C.new`

Plain `C` is a type literal, not a constructor tear-off.

So the expression node for constructor tear-offs should require a selector. The current `ConstructorReference` cannot express this directly because its child node allows the selector to be absent.

### `InstanceCreationExpression` should not be patched in place

The current invocation node is built around `ConstructorName`. Adding a V2
`constructorReference` getter to the same node would preserve the outer node
identity while giving it different direct children in the two views. The
dual-view framework can represent that, but it unnecessarily makes a legacy
node part of the canonical V2 model.

Replacing the whole expression gives each view one honest node kind:

```text
V1: InstanceCreationExpression -> ConstructorName
V2: ConstructorInvocation      -> ConstructorReference2
```

It also lets the V2 visitor distinguish constructor invocation directly and
leaves `InstanceCreationExpression` frozen as a compatibility API.

## 3. Design Principles

This refactoring follows these principles.

### Resolved AST should model high-value semantic distinctions

Most analyzer clients consume resolved AST. If an important semantic distinction is not modeled, clients must reconstruct it themselves.

Constructor tear-offs are a good example: they have dedicated language-spec semantics, they are not just ordinary property accesses, and clients often care about them directly.

Constructor invocation is another useful distinction. It should have a node
whose name describes invoking a constructor rather than promising allocation
of a new instance.

### Shared source structure should still be reusable

Constructor invocations, redirects, `super` constructor calls, and constructor tear-offs all refer to constructors using closely related source structure.

The AST should share that structure where doing so remains semantically honest.

### V2 is the only analyzer implementation model

Parser, resolver, AST rewriting, summary serialization, constant evaluation,
and analyzer-owned visitors should operate only on V2 nodes and APIs. Legacy
V1 nodes are cached projections for external compatibility. They can delegate
semantic getters and operations to their V2 origins, but they are never
independently resolved or rewritten.

### Optional `.` + name should be modeled as `ConstructorSelector`

If the grammar concept is “optional constructor selector”, then the AST should have one nullable node for it, not two separate nullable fields. That gives the API clearer invariants and keeps recovery behavior localized to one node shape.

## 4. Proposed Design

### 4.1 Introduce `ConstructorTypeReference`

The left side of a constructor reference should be modeled by a new node instead of reusing `NamedType`.

```text
abstract final class ConstructorTypeReference implements AstNode {
  Element? get element;
  ImportPrefixReference? get importPrefix;
  Token get name;
  TypeArgumentList? get typeArguments;
}
```

This node is intentionally not a `TypeAnnotation`.

It represents the declaration-oriented, type-shaped syntax that appears in constructor references and constructor tear-offs, without claiming to denote a normal resolved `DartType`.

This eventually removes the need for the current
`NamedType.type == null if part of ConstructorReference` exception. During the
compatibility window, old `NamedType`-based APIs remain available as deprecated
projections and must keep that exception.

### 4.2 Introduce a replacement for `ConstructorName`

The current `ConstructorName` node should be replaced by a new primary
constructor-reference node. The preferred long-term name is
`ConstructorReference`, but during the compatibility window that name is still
occupied by the existing expression node, so the staged API needs a
non-conflicting name such as `ConstructorReference2`.

```text
abstract final class ConstructorReference2 implements AstNode {
  // Substituted using the explicit or inferred constructed type.
  ConstructorElement? get element;

  ConstructorTypeReference get typeReference;
  ConstructorSelector? get selector;
}
```

The preferred final name matches what the node actually represents: a
source-level reference to a constructor, used by multiple enclosing constructs.
The old `ConstructorName` API remains available as a deprecated projection.

Examples:

- `C()` uses a constructor reference with `selector == null`
- `C.named()` uses a constructor reference with `selector.name2 == named`
- `factory A() = B.named;` uses a constructor reference

### 4.3 Introduce `ConstructorInvocation`

The current `InstanceCreationExpression` should be replaced in the canonical
V2 tree by a new `ConstructorInvocation` expression:

```text
abstract final class ConstructorInvocation implements Expression {
  Token? get keyword;
  ConstructorReference2 get constructorReference;
  ArgumentList get argumentList;
  bool get isConst;
}
```

Examples include:

- `C()`
- `C.named()`
- `const prefix.C<int>.named()`

The node reuses `ConstructorReference2` because an invocation permits either an
unnamed reference with no selector or a named reference with a selector. The
resolved `ConstructorElement` remains on that complete reference child.

`ConstructorInvocation` should not extend the current `InvocationExpression`.
That interface requires an `Expression get function`, but a
`ConstructorReference2` is deliberately not an expression. Its
`typeArguments` contract also describes type arguments applied to an invoked
function, whereas constructor type arguments belong to
`ConstructorTypeReference`. A future, smaller invocation superinterface could
share `argumentList` without reintroducing these mismatches.

The old `InstanceCreationExpression` becomes a V1-only projection over
`ConstructorInvocation`; it is not a node used by the parser or resolver. Each
V2 invocation caches one V1 projection so that public AST identity remains
stable. The V1 projection exposes the legacy `ConstructorName` projection and
shares source tokens and unchanged children where possible:

```text
ConstructorInvocation.parent2 == v2Parent
projectedInstance.parent       == v1Parent

ConstructorInvocation.argumentList.parent2 == ConstructorInvocation
projectedInstance.argumentList.parent       == projectedInstance
```

Resolved and behavioral APIs on the projection delegate to the V2 origin. For
example, `staticType`, `isConst`, `canBeConst`, and constant-evaluation entry
points must observe the result of resolving the `ConstructorInvocation` rather
than state copied onto the projected node. `accept2`, `parent2`, and other V2
tree APIs throw on the V1-only projection.

### 4.4 Introduce `ConstructorTearOff`

The current expression node named `ConstructorReference` should be replaced by
a new primary `ConstructorTearOff` node.

```text
abstract final class ConstructorTearOff
    implements Expression, CommentReferableExpression {
  // Substituted using the explicit or inferred constructed type.
  ConstructorElement? get element;

  ConstructorTypeReference get typeReference;
  ConstructorSelector get selector;
}
```

This encodes the language construct directly: it is an expression, it is specifically a constructor tear-off, and it always has a selector.

Examples:

- `C.named`
- `C.new`
- `prefix.C<int>.named`

This node should not allow `selector` to be absent, because `C` is not a constructor tear-off.

Like `ConstructorReference2.element`, `ConstructorTearOff.element` is
substituted using the explicit or inferred constructed type. Clients that need
the declaration use `element.baseElement`; clients that inspect the referenced
constructor's signature get the parameter and return types at this occurrence.
The tear-off's complete callable type is also represented by its function
`staticType`.

Summaries store the declaration element and recreate the substitution from
`staticType`. This avoids serializing references to type parameters local to
the tear-off's function type without weakening the public element contract.

The old `ConstructorReference` expression API remains available as a deprecated
projection during the compatibility window.

### 4.5 Use `ConstructorSelector` for optional named-constructor suffixes

The following nodes should use `ConstructorSelector?` instead of separate nullable `period` and `name`/`constructorName` fields:

- the new constructor-reference node
- `RedirectingConstructorInvocation`
- `SuperConstructorInvocation`

Illustratively:

```text
abstract final class RedirectingConstructorInvocation
    implements ConstructorInitializer, ConstructorReferenceNode {
  Token get thisKeyword;
  ConstructorSelector? get constructorSelector;
  ArgumentList get argumentList;
}

abstract final class SuperConstructorInvocation
    implements ConstructorInitializer, ConstructorReferenceNode {
  Token get superKeyword;
  ConstructorSelector? get constructorSelector;
  ArgumentList get argumentList;
}
```

This matches what `EnumConstantArguments` already does today.

The old split fields remain available as deprecated projections. For example,
`RedirectingConstructorInvocation.period` and
`RedirectingConstructorInvocation.constructorName` are projected from
`constructorSelector`, and must keep the same observable behavior as before.

### 4.6 Keep the tear-off node structurally separate

`ConstructorTearOff` should not be modeled as:

```text
ConstructorReference get constructor;
```

with an invariant that `constructor.selector != null`.

That design would preserve code reuse, but it weakens the public API by making an important language invariant indirect.

The expression node should expose the required selector directly.

### 4.7 Keep `ConstructorElement` on each complete constructor construct

The `ConstructorElement` should remain attached to the complete constructor
construct, not to its individual pieces.

That means:

- `ConstructorReference2` and `ConstructorTearOff` should each declare their
  own `element`
- neither new V2 node should implement the legacy `ConstructorReferenceNode`
  interface
- the legacy `ConstructorReference` should keep exposing the element through
  `constructorName.element`, without adding a new public superinterface
- `ConstructorInvocation` should expose a `ConstructorReference2` child rather
  than duplicating constructor-element state on the invocation
- `ConstructorSelector` should remain purely structural
- `ConstructorTypeReference` should keep only type-side resolution, not constructor-side resolution

This matches the semantic structure of the language:

- `ConstructorTypeReference` identifies the referenced type declaration
- `ConstructorSelector` identifies the optional named-constructor suffix
- the resolved `ConstructorElement` belongs to the combination of those parts

So the constructor element should stay on the node that represents the complete constructor reference, just as it does today.

`ConstructorReference2.element` and `ConstructorTearOff.element` are
substituted using explicit or inferred type arguments. In both cases,
`element.baseElement` is the declaration element.

`ConstructorReferenceNode` remains only as a compatibility interface for
existing public nodes. It should not shape the V2 model.

## 5. Why `ConstructorTypeReference` Should Not Be `NamedType`

It is tempting to keep reusing `NamedType` for the left side of constructor references, because the syntax is visually similar. However, doing so keeps the current semantic mismatch in the tree.

Problems with reusing `NamedType`:

- `NamedType` is a `TypeAnnotation`, but constructor references are not ordinary type annotations
- `NamedType.type` must stay `null` in this context, which makes the node behave differently from almost every other `NamedType`
- clients have to remember a special exception instead of trusting the node kind

`ConstructorTypeReference` is better because:

- it matches the actual role of the syntax
- it keeps constructor-specific semantics local to constructor-specific nodes
- it lets `NamedType` remain a real type-annotation node

This is a small increase in node count, but it removes a persistent source of API confusion.

## 6. Why `ConstructorReference` Is Better Than `ConstructorTarget`

`ConstructorTarget` is a possible alternative name for the current `ConstructorName`, but it is less precise.

Problems with `ConstructorTarget`:

- “target” suggests an invocation target or receiver target
- it does not naturally describe redirecting constructors or declaration-side references
- it is vague about whether the node is syntactic or semantic

`ConstructorReference` is better because:

- it describes what the node does in source
- it is neutral between invocation and non-invocation uses
- it matches existing analyzer terminology such as `CommentReference`

Once the old expression node is removed after its deprecation window, the
`ConstructorReference` name becomes available for the non-expression node that
actually deserves it.

## 7. Why `ConstructorInvocation` Should Replace `InstanceCreationExpression`

Keeping `InstanceCreationExpression` as the shared outer node would be less
work locally because expression-valued parents would see the same physical
child in both views. It would, however, leave a legacy name and legacy
inheritance decision in the final AST and require the node implementation to
serve two different child models.

A V2-only `ConstructorInvocation` gives the analyzer one canonical expression
shape and makes the compatibility boundary explicit. The additional parent-slot
projection cost is acceptable because V2-only `ConstructorTearOff` already
requires expression projection for scalar expression properties, argument and
collection positions, and expression-valued `NodeList`s. The mapping simply
adds:

```text
ConstructorInvocationImpl -> InstanceCreationExpressionImpl projection
```

The name also describes factory constructor calls correctly: invoking a
factory constructor does not imply allocating a fresh instance. This is a
source AST distinction, so unlike kernel it should not use separate AST node
kinds for generative constructors and factories.

### Existing public name collision

`package:analyzer/dart/constant/value.dart` already declares a public class
named `ConstructorInvocation` for evaluated const-constructor call data. This
document uses `ConstructorInvocation` as the preferred AST name because it is
the direct name of the source construct. Before making the AST API public, the
constant-value type should preferably move through its own compatibility
migration to a more specific name such as `ConstructorInvocationData` or
`ConstantConstructorInvocation`.

During any overlap, clients importing both libraries would need an import
prefix or `hide` clause. If that overlap is unacceptable, the fallback AST
name is `ConstructorInvocationExpression`, but it is less concise and should
not be chosen merely to preserve an overly general name for a data object.

## 8. Why Constructor Tear-Offs Need Their Own Node

The remaining question is whether constructor tear-offs should have their own expression node at all. They should, because the specification defines them as a distinct expression form with their own resolution and typing rules, and resolved-AST clients often care about them directly.

This is a narrower claim than a general move toward semantic member-reference nodes. Plain method tear-offs such as `obj.method` can still be represented by source-shaped nodes like `PropertyAccess` and `PrefixedIdentifier`; this document only regularizes the constructor-specific part of the AST.

## 9. Error Recovery

One motivation for split `period` and `name` fields is error recovery, because the parser may see a dangling `.`.

This refactoring should preserve recovery quality by using a `ConstructorSelector` with a synthetic `Token` when the name is missing, rather than by allowing `period != null` with no selector node.

This is already the general analyzer recovery style in other areas of the AST: syntactic structure is usually preserved by synthetic tokens/nodes rather than by dropping half of a construct.

The V2 invocation implementation must also retain invalid type arguments that
occur after a named constructor, such as in `C.named<T>()`, for source fidelity
and diagnostics. `InstanceCreationExpressionImpl` currently has internal
storage for this recovery case. Moving to `ConstructorInvocation` must preserve
those tokens and traversal order, but does not require exposing them as a
normal semantic type-argument API.

## 10. Discussion: Why This Is Different From `ImportPrefixReference`

This refactoring should not be read as a general rule that every AST node must have a tightly typed semantic element.

`ImportPrefixReference` is a useful counterexample. In syntax such as `foo.MyClass`, the `foo.` part occupies a dedicated syntactic position for an import prefix. In valid code, that position can only denote an import prefix. However, in invalid code, the token `foo` may resolve to some other declaration, and analyzer clients may still want to navigate to that declaration.

That makes a loose `Element? get element` contract on `ImportPrefixReference` defensible:

- the node still accurately models the syntactic role
- the element can preserve navigation information even when the construct is invalid
- using `null` for every non-prefix resolution would lose information that some clients care about

The `ConstructorName` / `NamedType` problem is different. There, the mismatch exists even in valid code: a `NamedType` inside a constructor reference is not acting like an ordinary type annotation, which is why its `type` must be specially documented as `null` today.

So `ImportPrefixReference` and `ConstructorTypeReference` respond to different design pressures. The former keeps a loose `Element?` for navigation in invalid code; the latter avoids reusing a type-annotation node whose API does not fit this role even in valid code.

<a name="api-shape-after-refactoring"></a>
## 11. API Shape After Refactoring

Illustratively, the main constructor-related nodes should have this shape in
the compatibility window. Names shown as `*2` or otherwise suffixed are staging
names used when the preferred long-term name is still occupied by an existing
public API. After the deprecation window, the preferred names can be collapsed.
The annotations shown are the publish-experimental stage. During the SDK
migration, the `@ToBeDeprecated` annotations are temporarily real
`@Deprecated` annotations so remaining internal V1 uses produce diagnostics.

```text
// Legacy common API. New V2 nodes don't implement it.
@ToBeDeprecated('Use element on the concrete node instead')
abstract final class ConstructorReferenceNode implements AstNode {
  /// The resolved constructor element.
  ///
  /// When the enclosing type is instantiated explicitly or by inference, this
  /// is the instantiated constructor element. Clients that need the
  /// declaration element can use `element.baseElement`.
  ConstructorElement? get element;
}

// New V2-only node (replaces NamedType in this role).
@experimental
abstract final class ConstructorTypeReference implements AstNode {
  Element? get element;
  ImportPrefixReference? get importPrefix;
  Token get name;
  TypeArgumentList? get typeArguments;
}

abstract final class ConstructorSelector implements AstNode {
  Token get period;

  // New primary API.
  @experimental
  Token get name2;

  // Legacy projection over `name2`.
  @ToBeDeprecated('Use name2 when the V2 API is stable')
  SimpleIdentifier get name;
}

// New primary node. Preferred long-term name: ConstructorReference.
// During compatibility it needs a non-conflicting name because the old
// expression node named ConstructorReference still exists.
@experimental
abstract final class ConstructorReference2 implements AstNode {
  // Substituted using the explicit or inferred constructed type.
  ConstructorElement? get element;

  ConstructorTypeReference get typeReference;
  ConstructorSelector? get selector;
}

// Replacement for the old expression node named ConstructorReference.
@experimental
abstract final class ConstructorTearOff
    implements Expression, CommentReferableExpression {
  // Substituted using the explicit or inferred constructed type.
  ConstructorElement? get element;

  ConstructorTypeReference get typeReference;
  ConstructorSelector get selector;
}

// Legacy node. Projection over ConstructorReference2.
@ToBeDeprecated('Use ConstructorReference2 when the V2 API is stable')
abstract final class ConstructorName
    implements AstNode, ConstructorReferenceNode {
  NamedType get type;

  Token? get period;

  SimpleIdentifier? get name;
}

// Legacy expression node. Projection over ConstructorTearOff.
@ToBeDeprecated('Use ConstructorTearOff when the V2 API is stable')
abstract final class ConstructorReference
    implements Expression, CommentReferableExpression {
  ConstructorName get constructorName;
}

// New canonical V2 expression.
@experimental
abstract final class ConstructorInvocation implements Expression {
  Token? get keyword;
  ConstructorReference2 get constructorReference;
  ArgumentList get argumentList;
  bool get isConst;
}

// Legacy V1-only expression. Projection over ConstructorInvocation.
@ToBeDeprecated('Use ConstructorInvocation when the V2 API is stable')
abstract final class InstanceCreationExpression implements Expression {
  Token? get keyword;
  ConstructorName get constructorName;
  ArgumentList get argumentList;
  bool get isConst;
}

abstract final class ConstructorDeclaration implements AstNode {
  // ...
  // New primary API during compatibility.
  @experimental
  ConstructorReference2? get factoryRedirectionTarget;

  // Legacy projection.
  @ToBeDeprecated('Use factoryRedirectionTarget when the V2 API is stable')
  ConstructorName? get redirectedConstructor;
}

abstract final class RedirectingConstructorInvocation
    implements ConstructorInitializer, ConstructorReferenceNode {
  Token get thisKeyword;

  // New primary API.
  @experimental
  ConstructorSelector? get constructorSelector;

  // Legacy projections.
  @ToBeDeprecated('Use constructorSelector when the V2 API is stable')
  Token? get period;

  @ToBeDeprecated('Use constructorSelector when the V2 API is stable')
  SimpleIdentifier? get constructorName;

  ArgumentList get argumentList;
}

abstract final class SuperConstructorInvocation
    implements ConstructorInitializer, ConstructorReferenceNode {
  Token get superKeyword;

  // New primary API.
  @experimental
  ConstructorSelector? get constructorSelector;

  // Legacy projections.
  @ToBeDeprecated('Use constructorSelector when the V2 API is stable')
  Token? get period;

  @ToBeDeprecated('Use constructorSelector when the V2 API is stable')
  SimpleIdentifier? get constructorName;

  ArgumentList get argumentList;
}
```

The same new constructor-reference node would be reused by:

- `ConstructorInvocation`
- `ConstructorDeclaration.factoryRedirectionTarget`

And `ConstructorSelector?` would be reused by:

- `RedirectingConstructorInvocation`
- `SuperConstructorInvocation`
- existing `EnumConstantArguments`

Legacy APIs must preserve their old behavior exactly. For example,
`ConstructorName.type` remains a `NamedType` projection during the deprecation
period, including old resolution behavior such as `NamedType.type == null` in
constructor-reference position. Similarly, projected `SimpleIdentifier`
children keep their old parent, traversal, child-entity, element, and static
type behavior.

The projected `InstanceCreationExpression` similarly preserves its old visitor
kind, children, tokens, `isConst`, `canBeConst`, `staticType`, and constant
evaluation behavior. Those semantic APIs delegate to its cached
`ConstructorInvocation` origin; the projection is not independently resolved.

This design eventually removes the need for `NamedType` documentation and
resolver logic to special-case constructor references, but only after the
legacy projection APIs are removed.

## 12. Migration Strategy

This is a compatibility-preserving staged migration. The preferred final API
can be reached only after the normal analyzer deprecation window. Until then,
new APIs are primary and generated, while old APIs are cached projections
implemented by hand where necessary.

### Steps

1. Add generated support for the new tree-view APIs described in
   `compatibility_preserving_ast_refactoring.md`.
2. Introduce `ConstructorTypeReference` API/impl and migrate the new primary
   constructor-related nodes to use it instead of `NamedType`.
3. Add the new primary replacement for `ConstructorName` using a non-conflicting
   staged name, such as `ConstructorReference2`.
4. Add the new primary `ConstructorTearOff` node as the replacement for the old
   expression node named `ConstructorReference`.
5. Add the new primary `ConstructorInvocation` node as the replacement for
   `InstanceCreationExpression`. Give it a `ConstructorReference2` child and
   keep it independent of the current `InvocationExpression` hierarchy.
6. Add new primary properties for renamed or retyped properties, for example:
   - `ConstructorDeclaration.factoryRedirectionTarget`
7. Replace `period` + `name` pairs in the new model with
   `ConstructorSelector?` where they represent an optional named-constructor
   suffix.
8. Keep the old APIs as projections. Deprecate legacy nodes themselves, but do
   not separately deprecate every property of an already deprecated node.
   Deprecate legacy properties on nodes that otherwise remain current:
   - deprecated legacy node `ConstructorName`
   - deprecated legacy node `ConstructorReference`
   - deprecated legacy node `InstanceCreationExpression`
   - `ConstructorSelector.name`
   - `ConstructorDeclaration.redirectedConstructor`
   - `RedirectingConstructorInvocation.period` and `constructorName`
   - `SuperConstructorInvocation.period` and `constructorName`
9. Cache one `InstanceCreationExpression` projection per
   `ConstructorInvocation` origin. Delegate resolved and behavioral APIs to the
   origin rather than copying semantic state.
10. Ensure every legacy projection preserves the old observable behavior exactly:
   old getters, old `AstVisitor` traversal, old `visitChildren`, old `parent`,
   old child entities, old element/static-type values, and old summary
   round-tripping.
11. Serialize the V2 tree as the only primary format. Store enough canonical
    V2 source and semantic data to reconstruct every legacy projection, but do
    not serialize projection objects or separately resolved V1 state.
12. Temporarily apply real `@Deprecated` annotations to legacy nodes,
    properties, and V1 tree APIs so remaining SDK uses are reported.
13. Update parser, resolver, rewriter, constant evaluation, summary
    reader/writer, printers, visitors, and tests to use only the V2 model and
    V2 APIs internally.
14. Migrate analysis_server, linter, and other SDK-owned tools to the new APIs.
15. Once SDK-owned code is clean, downgrade those annotations to
    `@ToBeDeprecated` before publishing while V2 remains experimental.
16. Resolve the public `ConstructorInvocation` name collision with
    `dart/constant/value.dart` before recommending the AST API publicly.
17. Add compatibility notes to the analyzer changelog and migration guidance.
18. After the deprecation window, remove legacy projection APIs, collapse staged
    names to their preferred final names where appropriate, and remove
    `NamedType` special cases related to constructor references from
    documentation and resolver code.

## 13. Non-Goals

This document does not propose:

- a full semantic AST redesign
- replacing `PropertyAccess` / `PrefixedIdentifier` with semantic member reference nodes
- introducing a unified node for all function, method, and constructor tear-offs
- folding `DotShorthandConstructorInvocation` into `ConstructorInvocation`; dot shorthand has no explicit type reference

Those are related design questions, but they are broader than this refactoring.
