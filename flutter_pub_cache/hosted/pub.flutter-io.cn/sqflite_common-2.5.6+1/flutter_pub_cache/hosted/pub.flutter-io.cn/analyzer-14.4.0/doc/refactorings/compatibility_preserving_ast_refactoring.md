# Compatibility-Preserving AST Refactoring

This document describes a dual-view migration model for evolving analyzer AST structure without forcing existing clients to observe a replacement direct-child topology immediately. The motivating example is constructor references, where a constructor name that was previously viewed as a `SimpleIdentifier` child of `ConstructorName` can become a token owned by `ConstructorSelector`, but the approach is intended to apply to future AST migrations as well.

The core idea is to name the two API slots explicitly. V1 is the unsuffixed API surface (`accept`, `parent`, `childEntities`, and so on). V2 is the `2`-suffixed API surface (`accept2`, `parent2`, `childEntities2`, and so on). During the current constructor-reference migration the analyzer builds, resolves, rewrites, serializes, and otherwise operates only on the V2 tree. V1 is a compatibility projection for clients that have not migrated. V2 is a staging slot for structural AST migrations, not the next permanent API generation.

A client must choose one tree view and stay within it. This avoids double visiting, preserves V1 visitor behavior for V1 clients, and gives migrated analyzer code a coherent implementation model.

Related issue: [ConstructorName and ConstructorReference Refactoring #63107](https://github.com/dart-lang/sdk/issues/63107).

## Table of Contents

- [Problem Statement](#problem-statement)
- [Terminology](#terminology)
- [Design Goals](#design-goals)
- [Non-Goals](#non-goals)
- [Proposed Model](#proposed-model)
  - [V1 Tree View](#v1-tree-view)
  - [V2 Tree View](#v2-tree-view)
  - [Compatibility Projection](#compatibility-projection)
  - [Canonical State And Projection Objects](#canonical-state-and-projection-objects)
- [APIs To Split](#apis-to-split)
- [V2-Only Nodes](#v2-only-nodes)
- [Visitor Semantics](#visitor-semantics)
- [Parent And Ancestor Semantics](#parent-and-ancestor-semantics)
- [Child Getter And NodeList Semantics](#child-getter-and-nodelist-semantics)
- [Child Entity Semantics](#child-entity-semantics)
- [Generator Requirements](#generator-requirements)
- [Mutation Semantics](#mutation-semantics)
- [Example: Constructor Invocation Replacement](#example-constructor-invocation-replacement)
- [Splits And Disappearing Nodes](#splits-and-disappearing-nodes)
- [Analyzer Migration](#analyzer-migration)
- [Serialization And Tokens](#serialization-and-tokens)
- [Testing](#testing)
- [Annotation Staging](#annotation-staging)
- [Rebaseline](#rebaseline)
- [Migration Plan](#migration-plan)
- [Open Questions](#open-questions)

<a name="problem-statement"></a>
## Problem Statement

AST refactorings often need to insert, remove, split, or rename nodes. If the analyzer changes only the node getters while leaving one visitor and one parent chain, then V1 clients and V2 clients can need mutually incompatible traversal behavior.

For example, suppose the V1 direct-child relationship is:

```text
P1 -> N
```

and the V2 direct-child relationship is:

```text
P2 -> N
```

Clients migrated to the V2 API expect recursive traversal to reach `N` through `P2`, and expect `N.parent2` to be `P2`. Clients that remain on the V1 API expect recursive traversal to reach `N` through `P1`, and expect `N.parent` to be `P1`. If a single traversal tries to honor both child relationships, it can visit `N` twice. If it chooses only one relationship, either V1 clients or V2 clients see the wrong tree.

The same issue appears whenever a child is split into several replacement nodes, folded into a different parent, moved under an inserted node, or removed from the implementation tree but still needs to be exposed through compatibility APIs.

The V1 AST API therefore cannot remain both the implementation tree and a compatibility layer. It needs to become one coherent view, while the V2 API becomes another coherent view.

<a name="terminology"></a>
## Terminology

The "V1 tree view" is the tree shape exposed by existing APIs such as `accept`, `AstVisitor`, `visitChildren`, `parent`, `childEntities`, `nodeCovering`, and ancestor helpers.

The "V2 tree view" is the tree shape exposed by V2 APIs such as `accept2`, `AstVisitor2`, `visitChildren2`, `parent2`, `childEntities2`, `nodeCovering2`, and corresponding ancestor helpers.

A "V2-only node" is a node that exists in the V2 tree view but did not exist as a node in the V1 tree view.

A "compatibility projection" is the implementation of one API view in terms of the tree data used by the other view. In the current migration, V1 is projected from V2. A projection is allowed to hide V2-only nodes, synthesize V1 child relationships, or expose V1 getters backed by V2 nodes, but all APIs in the projected view must agree with each other.

A "V1 projection object" is a physical AST object synthesized to represent a V1 node that has no physical identity in the canonical V2 tree. It has a cached V2 origin, participates only in V1 topology, and delegates semantic behavior to that origin. Repeatedly projecting the same V2 origin must return the same V1 object.

<a name="design-goals"></a>
## Design Goals

- Preserve the existing public AST traversal behavior for clients that use the V1 APIs.
- Provide a coherent V2 traversal model for analyzer internals and migrated clients in the current migration window.
- Avoid double visiting a node in any single traversal.
- Keep `parent`, ancestor helpers, and child iteration consistent within each tree view.
- Make AST evolution general enough to support moved children, inserted nodes, split nodes, removed nodes, and renamed nodes.
- Keep the implementation mostly generated so adding a V2 view is mechanical rather than hand-written for each AST class.
- Let analyzer, analysis_server, and linter migrate together to the V2 APIs because they are in the Dart SDK and can be updated in one change series.
- Keep parsing, resolution, rewriting, mutation, and serialization entirely on the V2 representation while a migration is active.
- Keep resolved and mutable state canonical on V2 objects rather than synchronizing duplicate V1 state.
- Keep deprecated APIs available as projections until the normal analyzer API deprecation process removes them.

<a name="non-goals"></a>
## Non-Goals

- Do not preserve V1 mutation semantics for internal-only mutation APIs such as `replaceChild` and `removeChild`.
- Do not resolve, rewrite, or serialize V1 projection objects as if they were canonical AST nodes.
- Do not maintain independently mutable or independently resolved state on V1 projection objects.
- Do not make V2-only nodes usable through V1 visitor APIs.
- Do not guarantee that clients can safely mix V1 and V2 tree APIs in one algorithm.
- Do not keep two AST tree views permanently after a migration has completed.
- Do not alternate the preferred public API surface between V1 and V2 for every AST change. V2 is a staging slot; the stabilized shape should return to V1/no-suffix APIs.
- Do not prevent all per-refactoring design decisions. The framework should be general, but each AST migration still needs a local projection between the two API contracts.

<a name="proposed-model"></a>
## Proposed Model

The analyzer should expose two explicit AST tree views during a migration period.

The V1 view remains attached to unsuffixed API names and is marked deprecated or marked for later deprecation as needed for the current migration. Existing clients that do not migrate continue to see the V1 tree shape. V2 nodes introduced by the refactoring are not visible to V1 recursive visitors and do not participate in the V1 parent chain.

The V2 view is attached to `2`-suffixed API names. Analyzer internals and migrated clients use this view during the current migration. V2 nodes are visible, V2 child ordering is used, and `parent2` returns the parent in the V2 tree.

The two views are not two independently maintained physical trees. There is one canonical V2 implementation graph. Nodes whose shape is unchanged can be shared between the two views and can have both a V1 parent and a V2 parent. When a V1 node has been replaced entirely, a cached V1 projection object represents it for compatibility, but that object is a facade over a V2 origin rather than a second independently processed node.

Version identity is separate from migration role, but this document intentionally uses V2 as the recurring staging slot. During a structural migration, V2 is the analyzer implementation view and V1 is the projected compatibility view. After clients have had a deprecation window to move to the V2 shape, the stabilized structure should be rebaselined back into V1/no-suffix APIs. A later batch of AST changes can then start again from a V1-only canonical tree and use V2 as the staging slot.

<a name="v1-tree-view"></a>
### V1 Tree View

The V1 tree view is the unsuffixed API contract. In the current migration it is the compatibility contract for existing clients. Existing traversal APIs continue to behave as if the V1 direct-child topology still exists.

For any node that existed before the migration, V1 APIs answer using the V1 projected shape:

- `accept(visitor)` dispatches only to V1 `AstVisitor` methods.
- `visitChildren(visitor)` visits only V1 children in V1 lexical order.
- `parent` returns the V1 parent, which may be different from the V2 parent.
- `root` follows the V1 parent chain.
- `thisOrAncestorMatching` and `thisOrAncestorOfType` follow the V1 parent chain.
- `childEntities` yields V1 syntactic entities.
- `CompilationUnit.nodeCovering` returns the minimal covering node using V1 children.

The V1 tree view must be internally coherent. If a V1 recursive visitor reaches node `N` as a child of `P1`, then `N.parent` must be `P1` in the V1 view, and V1 ancestor helpers must produce the same answer.

<a name="v2-tree-view"></a>
### V2 Tree View

The V2 tree view is the implementation model for the current migration.

For migrated code:

- `accept2(visitor)` dispatches to `AstVisitor2` methods.
- `visitChildren2(visitor)` visits V2 children in V2 lexical order.
- `parent2` returns the parent in the V2 tree.
- `root2` follows the V2 parent chain.
- `thisOrAncestorMatching2` and `thisOrAncestorOfType2` follow the V2 parent chain.
- `childEntities2` yields V2 syntactic entities.
- `CompilationUnit.nodeCovering2` has the same contract as `nodeCovering`.

The V2 view is what analyzer internals should use while this migration is active. It is also the view that generated implementations should treat as primary when building, resolving, serializing, locating, and editing ASTs for this CL.

This rule applies even when a V1 projection happens to implement a familiar internal interface. A V1 projection must not be passed to the resolver, rewriter, summary writer, constant evaluator, or any other analyzer component that expects a canonical node. Such components dispatch through V2 nodes and V2 APIs only.

<a name="compatibility-projection"></a>
### Compatibility Projection

For this migration, V1 APIs are implemented as projections from the V2 representation. This keeps the parser and resolver model coherent while preserving V1 traversal behavior.

The projection can be simple, such as returning a compatibility `SimpleIdentifier` from a deprecated `name` getter backed by a V2 selector token. It can also be structural, such as making a V1 visitor skip the `ConstructorSelector` node and visit the projected identifier as if it were still a direct child of `ConstructorName`.

The important invariant is that each view is coherent by itself. A V1 visitor must not see a V2-only node. A V1 child getter, node-list getter, child-entity traversal, or parent walk must not expose a V2-only node either. A V2 visitor must not see synthetic V1 topology that is not part of the V2 tree.

<a name="canonical-state-and-projection-objects"></a>
### Canonical State And Projection Objects

V2 objects own all mutable and resolved state. This includes child storage, elements, types, inferred type arguments, constant-evaluation state, and other information produced by analyzer processing. V1 projection objects should derive structure from their origins and delegate semantic APIs rather than copying state.

For example, if a V2-only `ConstructorInvocation` is projected as a V1 `InstanceCreationExpression`, the V1 object can override semantic getters and operations to use its origin:

```text
projectedInstance.staticType  -> constructorInvocation.staticType
projectedInstance.isConst     -> constructorInvocation.isConst
projectedInstance.canBeConst  -> constructorInvocation.canBeConst
```

The exact implementation can be hand-written where the legacy node has substantial behavior. The required invariants are:

- every V1 projection object has exactly one V2 origin
- projecting the same origin repeatedly returns the same V1 identity
- semantic values are delegated or derived, not copied and synchronized
- V1 tree APIs operate on the projected V1 topology
- V2 tree APIs on a V1-only projection throw, just as V1 tree APIs throw on a V2-only node
- V2 mutation is immediately reflected by V1 getters, either through delegation or through a projection cache with explicit invalidation

Projection objects can contain cached child projections because public AST identity is observable. They must not contain an independently editable copy of the source tree or an independently resolved copy of semantic state.

<a name="apis-to-split"></a>
## APIs To Split

The split must cover every public API whose result depends on child topology or parent topology. The analyzer has long used the suffix `2` for replacement APIs, so this document uses that convention for the V2 tree-view APIs.

| V1 API | V2 API | Notes |
| --- | --- | --- |
| `AstNode.accept` | `AstNode.accept2` | Existing visitors observe the V1 tree; V2 visitors observe the V2 tree. |
| `AstVisitor` and subclasses | `AstVisitor2` and subclasses | Includes recursive, generalizing, unifying, throwing, simple, delegating, timed, and breadth-first variants as appropriate. |
| `AstNode.visitChildren` | `AstNode.visitChildren2` | Must use the child list for the selected tree view. |
| `AstNode.parent` | `AstNode.parent2` | Existing nodes can have different answers in the two views. V2-only nodes throw from `parent`. |
| `AstNode.root` | `AstNode.root2` | Follows the corresponding parent chain. |
| `AstNode.thisOrAncestorMatching` | `AstNode.thisOrAncestorMatching2` | Follows the corresponding parent chain. |
| `AstNode.thisOrAncestorOfType` | `AstNode.thisOrAncestorOfType2` | Follows the corresponding parent chain. |
| Existing scalar child getters whose child shape changes | V2 child getter, usually with a `2` suffix | For example, `BinaryExpression.leftOperand` can be a V1 projection while `leftOperand2` is the real V2 child. |
| Existing `NodeList` child getters whose element shape changes | V2 `NodeList` getter, usually with a `2` suffix | For example, `ArgumentList.arguments` can be a V1 projected list while `arguments2` is the real V2 child list. |
| `AstNode.childEntities` | `AstNode.childEntities2` | `childEntities` is public and therefore must be part of the compatibility story. |
| `AstNodeImpl.namedChildEntities` | `AstNodeImpl.namedChildEntities2` | Internal, but tests and analyzer diagnostics use it heavily. |
| `CompilationUnit.nodeCovering` | `CompilationUnit.nodeCovering2` | Covering-node lookup is public and follows child containment, so it must use the selected tree view. |
| `NodeLocator`, `FindNode`, and related utilities | `NodeLocator2`, `FindNode2`, and related utilities | Locator behavior follows traversal and child containment. Analyzer tests use the V2 variants; tests in packages that consume analyzer remain on the V1 variants unless intentionally migrated. |

Private and internal implementation hooks can be V2-only unless a V1 public API calls them. For example, `replaceChild` and `removeChild` are not public API and do not need a V1 version. In contrast, `CompilationUnit.nodeCovering` delegates to child-containment logic, so generated containment must also be split: `_childContainingRange` backs `nodeCovering`, and `_childContainingRange2` backs `nodeCovering2`.

<a name="v2-only-nodes"></a>
## V2-Only Nodes

A V2-only node exists only in the V2 tree view. It should not be usable through V1 tree APIs because there is no V1 tree concept that corresponds to it.

For a V2-only node:

```text
node.parent       throws StateError
node.root         throws StateError
node.accept       throws StateError
node.visitChildren throws StateError
node.childEntities throws StateError
```

The corresponding V2 APIs work normally:

```text
node.parent2
node.root2
node.accept2
node.visitChildren2
node.childEntities2
```

Throwing is better than returning `null` because a `null` parent could be misinterpreted as "this node is a root in the V1 tree". A V2-only node is not a V1 root; it is outside the V1 view.

For the same reason, `accept` on a V2-only node should throw immediately. Calling the V1 visitor API on a node that has no V1-tree identity is a mixed-view bug, and failing loudly makes that bug easier to find than silently skipping the node or pretending it has V1 children.

The throw is not a substitute for projection. A V2-only node should not escape from a V1 API in the first place. If a client obtains a V2-only node through a V1 getter, a V1 `NodeList`, V1 `childEntities`, or a V1 visitor, that API has leaked the V2 tree view.

<a name="visitor-semantics"></a>
## Visitor Semantics

The main rule is that a node is visited at most once in a single traversal.

V1 recursive traversal uses V1 child relationships. It can visit shared nodes through projected V1 paths, but it skips V2-only nodes. V2 recursive traversal uses V2 child relationships and visits every V2 node.

For example, in a migration that moves `N` from V1 parent `P1` to V2 parent `P2`, V1 traversal does this:

```text
visit(P1)
  visit(N)
```

V2 traversal does this:

```text
visit2(P2)
  visit2(N)
```

The same physical `N` object is not visited twice in either traversal. It only has two different logical parents depending on the selected view. In a larger AST, `P2` might itself be reachable through `P1`, or it might be reached through a different route; the important local invariant is that each traversal chooses exactly one parent-to-child edge for `N`.

Generated visitor classes should be duplicated rather than taught ad hoc compatibility rules. This keeps a custom `RecursiveAstVisitor` subclass and a custom `RecursiveAstVisitor2` subclass easy to reason about.

<a name="parent-and-ancestor-semantics"></a>
## Parent And Ancestor Semantics

Parent APIs are part of the tree view. They cannot remain singular if traversal is split.

For nodes that exist in both views, `parent` and `parent2` can differ. For nodes that exist only in the V2 view, V1 parent APIs throw.

This also means parent-sensitive helper APIs must be duplicated. For example, helpers such as `thisOrAncestorOfType`, expression context predicates, declaration-context predicates, and other utilities that inspect `parent` need V2 equivalents or need to be migrated to use `parent2`.

Analyzer internals should not call a V1 helper from V2 visitor code. Mixed-view use is the main risk of this design.

<a name="child-getter-and-nodelist-semantics"></a>
## Child Getter And NodeList Semantics

AstBuilder should build the V2 tree in the current migration. That means fields owned by implementation classes should generally store V2 children, and generated constructors should attach those children through the V2 parent relationship.

However, existing public child getters are part of the V1 tree view. If a child position can now contain a V2-only node, the V1 getter must project that child to a V1-compatible node.

For a scalar expression child, the implementation should distinguish the real V2 child from the V1 projection:

```text
BinaryExpression.leftOperand   -> V1 projection
BinaryExpression.leftOperand2  -> real V2 child
```

For example, if the V2 left operand is a constructor tear-off:

```text
leftOperand2 == ConstructorTearOff
leftOperand  == ConstructorReference projection
```

The parent relationship must be coherent in each view:

```text
leftOperand.parent   == BinaryExpression
leftOperand2.parent2 == BinaryExpression
```

The same rule applies to list-valued child getters. A list that can contain migrated expression nodes needs separate V1 and V2 views:

```text
ArgumentList.arguments   -> V1 projected list
ArgumentList.arguments2  -> real V2 child list
```

The V2 list stores the nodes built by AstBuilder. The V1 list must not contain V2-only nodes. If a V2 list entry is a V2-only node, the V1 list contains its compatibility projection at the same position.

`NodeList` cannot be resized, which makes projected lists practical. The V1 list can be a cached read-only projected `NodeList` rather than a second mutable storage list. Its `owner` must still be the V1 parent node, and each element it returns must have the corresponding V1 parent. If `NodeListImpl` continues to mean "physical storage list", projections should use a separate read-only implementation instead of pretending to be storage.

Generated node code should use the selected view consistently:

- V1 getters, `visitChildren`, `childEntities`, `nodeCovering`, and V1 containment use V1 scalar/list projections
- V2 getters, `visitChildren2`, `childEntities2`, `nodeCovering2`, and V2 containment use the corresponding stored scalar/list children

If a child exists unchanged in both views, the same physical object can be returned by both getters. Separate projection objects are only needed for children whose V1 and V2 shapes differ.

<a name="child-entity-semantics"></a>
## Child Entity Semantics

`childEntities` is public, so it must expose the V1 tree view until it is removed. `childEntities2` should also be public from the start because it is part of the coherent V2 tree-view API surface, but it should be marked `@experimental` while the V2 tree view is still staging.

`namedChildEntities` is internal, but it should still be split because many diagnostics, AST printers, and tests depend on it.

V1 `childEntities` should expose the same nodes and tokens that V1 `visitChildren` exposes. V2 `childEntities2` should expose the real V2 child entities.

This matters for structural tests and for tools that do not use visitors but still walk nodes by child entities. If only visitors are split, clients can still observe the V2 shape accidentally through `childEntities`.

`childEntities` is not a separate escape hatch from child getters. It must be generated from the V1 child getter and V1 `NodeList` view. If it directly exposes a physical storage list that contains V2-only nodes, it leaks the V2 tree through a V1 API. Conversely, `childEntities2` should use the V2 child getter and real V2 `NodeList` view.

<a name="generator-requirements"></a>
## Generator Requirements

Projection should be explicit in `GenerateNodeProperty`. The generator should not infer projection from `isInValueExpressionSlot`, child type, or naming convention alone. `isInValueExpressionSlot` describes semantic context; it does not say that the child shape changed in this migration.

A migrated scalar property should name the real V2 property and declare the V1 name and projection strategy:

```text
GenerateNodeProperty(
  'leftOperand2',
  v1Name: 'leftOperand',
  v1Projection: V1Projection.expression,
  isInValueExpressionSlot: true,
)
```

The generated implementation then uses the V2 property as storage and exposes the V1 property as a projection:

```text
leftOperand2 -> real V2 child
leftOperand  -> V1 projection of leftOperand2
```

Generated APIs must use the actual property name for the selected view. V1 named child entities use `v1Name`; V2 named child entities use the real V2 property name:

```text
ChildEntities get _childEntities =>
    ChildEntities()..addNode('leftOperand', leftOperand);

ChildEntities get _childEntities2 =>
    ChildEntities()..addNode('leftOperand2', leftOperand2);
```

The same rule applies to list-valued properties:

```text
GenerateNodeProperty(
  'arguments2',
  v1Name: 'arguments',
  v1Projection: V1Projection.argument,
  isInValueExpressionSlot: true,
)
```

and:

```text
ChildEntities get _childEntities =>
    ChildEntities()..addNodeList('arguments', arguments);

ChildEntities get _childEntities2 =>
    ChildEntities()..addNodeList('arguments2', arguments2);
```

`V1Projection` is symbolic metadata for the generator. It is not a function value stored in the annotation. Even if Dart constant evaluation can represent some function tear-offs, using a symbolic value keeps the annotation stable and lets the generator emit the right helper call in source.

For example, the generator can map enum values to static projection helpers:

```text
V1Projection.expression -> V1Projection.toV1Expression(...)
V1Projection.argument   -> V1Projection.toV1Argument(...)
```

The projection helpers should live as static methods on the `V1Projection`
enum, not on every node implementation class:

```text
enum V1Projection {
  none,
  expression,
  argument;

  static ExpressionImpl toV1Expression(ExpressionImpl node) {
    if (node is ConstructorTearOffImpl) {
      return node.constructorReference;
    }
    if (node is ConstructorInvocationImpl) {
      return node.instanceCreationExpression;
    }
    return node;
  }

  static ArgumentImpl toV1Argument(ArgumentImpl node) {
    if (node is ExpressionImpl) {
      return toV1Expression(node);
    }
    return node;
  }
}
```

Keeping these helpers out of `ExpressionImpl` and `ArgumentImpl` makes the compatibility boundary explicit. The projection is migration machinery, not an inherent behavior of every expression or argument node.

Projected V1 lists should not be plain `List`s. They need to satisfy the `NodeList` contract, including `owner`, `beginToken`, `endToken`, fixed-length behavior, and visitor dispatch. If `NodeListImpl` continues to represent physical storage, projected lists should use a private read-only implementation such as `_V1ProjectedNodeListImpl`.

The projected list should be derived from the current V2 list instead of being independently mutable storage. A wrapper can avoid cache invalidation:

```text
final class _V1ProjectedNodeListImpl<
  V2Node extends AstNodeImpl,
  V1Node extends AstNodeImpl
> with ListMixin<V1Node> implements NodeList<V1Node> {
  final AstNodeImpl _owner;
  final NodeListImpl<V2Node> _base;
  final V1Node Function(V2Node node) _toV1;
}
```

The `_toV1` function is migration-specific. The framework can call it, but each refactoring defines the actual mapping. For the constructor-reference migration, the relevant expression projections include:

```text
ConstructorTearOffImpl     -> ConstructorReferenceImpl
ConstructorInvocationImpl -> InstanceCreationExpressionImpl
```

The objects on the right are cached V1 projections whose semantic behavior delegates to the V2 origins on the left.

Generated mutation and replacement code should update the real V2 property or list. V1 projected getters and lists should reflect those current V2 children rather than maintaining a second mutable child store.

<a name="mutation-semantics"></a>
## Mutation Semantics

Internal mutation APIs should use the V2 tree shape only.

`replaceChild`, `removeChild`, node-list ownership, and `_becomeParentOf` are implementation details, not public compatibility contracts. They should operate on the V2 tree in this migration so parser, resolver, and rewriting code do not need to maintain two editable object graphs.

V1 projection APIs still need to reflect V2-tree mutation. For example, replacing a V2 `ConstructorSelector` changes what the deprecated V1 `name` getter returns. Prefer deriving the V1 answer from the current V2 origin. If compatibility identity requires caching a child projection, the V2 mutation point must update or invalidate that cache.

Mutation APIs update the real V2 children. V1 projections should be derived from the current V2 children rather than maintained as independently mutable storage. The same rule applies to semantic state: resolver writes go to V2 nodes, and V1 semantic getters delegate to those nodes rather than being kept in sync by the resolver.

<a name="example-constructor-invocation-replacement"></a>
## Example: Constructor Invocation Replacement

The constructor migration replaces this complete V1 expression shape:

```text
InstanceCreationExpression
  ConstructorName
    NamedType
    period: .
    name: SimpleIdentifier
  ArgumentList
```

with this canonical V2 shape:

```text
ConstructorInvocation
  ConstructorReference2
    ConstructorTypeReference
    ConstructorSelector
      period: .
      name2: Token
  ArgumentList
```

The whole V1 `InstanceCreationExpression` and its `ConstructorName` subtree are
cached projections. The V1 `SimpleIdentifier` can view the same source token:

```text
projectedConstructorName.name.token == selector.name2
```

The argument list can be the same physical node while participating in two
logical parent chains:

```text
argumentList.parent  == projectedInstanceCreation
argumentList.parent2 == constructorInvocation
```

V2-only nodes have no V1 identity:

```text
constructorInvocation.parent  throws StateError
selector.parent               throws StateError
```

V1 recursive traversal sees:

```text
InstanceCreationExpression
  ConstructorName
    NamedType
    SimpleIdentifier
  ArgumentList
```

V2 recursive traversal sees:

```text
ConstructorInvocation
  ConstructorReference2
    ConstructorTypeReference
    ConstructorSelector
  ArgumentList
```

The V1 projection delegates semantic behavior such as `staticType`, `isConst`,
and constructor resolution to its `ConstructorInvocation` origin. It is never
sent through V2 resolution or serialization.

This preserves V1 client expectations without denying the V2 AST structure to migrated code.

<a name="splits-and-disappearing-nodes"></a>
## Splits And Disappearing Nodes

The same projection model handles more than moving a child from one parent to another.

If one V1 child is split into multiple V2 nodes, the V1 API can expose one projected V1 child if that is what the V1 contract required, or expose a facade-like node if the V1 child represented a concept that no single V2 child owns. The V2 data must store enough information to answer the V1 getter and traversal contract.

If a V1 child disappears from the real V2 tree, the V2 parent still needs to retain enough source tokens, elements, or semantic state to synthesize the V1 API result during the deprecation period.

If a V1 node is renamed but the structure is otherwise unchanged, the projection can be nearly trivial: V1 getter names and V1 visitor methods forward to the same implementation object while V2 names expose the preferred model.

Each refactoring still needs local decisions about the V1 projection, but those decisions are made inside a general two-view framework rather than through one-off traversal tricks.

<a name="analyzer-migration"></a>
## Analyzer Migration

Analyzer, analysis_server, linter, and SDK-owned tools can migrate to the V2 view together.

The internal migration rule is strict: while a V2 migration is active, analyzer code builds and processes only the V2 tree. It uses `accept2`, `visitChildren2`, `parent2`, V2 ancestor helpers, V2 child getters, and V2 child-entity APIs. Resolver and rewriter dispatch must never receive a V1 projection object. Summary writing serializes V2 objects, and summary reading reconstructs V2 objects before any V1 facade is requested.

This does not require duplicating every unchanged object. A node that has the same physical representation in both views can remain shared, but analyzer code still reaches it through the V2 API surface. V1-only objects exist solely at the public compatibility boundary and can be created lazily.

Generated code should make this mechanical. Node implementations can generate both V1 and V2 visitor methods, both V1 and V2 child-entity methods, and both parent accessors where needed.

The main implementation risk is mixed-view code. During SDK implementation, temporarily deprecating V1 nodes, changed properties, and tree APIs makes analyzer diagnostics identify remaining SDK uses. The SDK migration is complete only when analyzer, analysis_server, linter, and other migrated SDK code analyze cleanly without those V1 uses. Compatibility projection code is then isolated to explicit V1 facade implementations and V1-facing tests.

<a name="serialization-and-tokens"></a>
## Serialization And Tokens

Summary serialization must serialize the canonical V2 tree, not V1 projection objects. Summary read reconstructs V2 objects and canonical semantic state first; V1 facades are created lazily when a V1 API is requested. If a projection needs information that cannot otherwise be derived, that information is stored as canonical compatibility data on the V2 representation rather than as a separately serialized V1 node.

Token chains should be maintained for the V2 real tree. V1 projections should view those same tokens; they should not require a second token stream. A token-chain validator for the V2 AST should validate the real V2 child order, while any V1 validator should be understood as validating the projected V1 view.

If a V2-only node is synthesized during summary read, it must be linked into the V2 token chain correctly. V1 traversal should still skip it and expose the projected V1 token and node order.

<a name="testing"></a>
## Testing

Tests should cover both tree views during the migration period.

V1 tests should verify that V1 recursive visitors, V1 parent relationships, and V1 child entities remain stable for clients that have not migrated.

V2 tests should verify that `accept2`, `parent2`, `childEntities2`, `namedChildEntities2`, `nodeCovering2`, locators, and summary read/write expose and preserve the V2 real tree.

`ResolvedAstPrinter` should print both shapes for AST nodes updated by a migration. The V1 printout verifies the compatibility projection that V1 clients observe, and the V2 printout verifies the real V2 AST shape used by migrated analyzer code. This avoids choosing one structural text format that accidentally hides regressions in the other view.

The most important invariant tests are:

- A V1 recursive visitor does not visit V2-only nodes.
- A V2 recursive visitor visits V2-only nodes.
- A node is not visited twice in either traversal.
- `parent` agrees with V1 traversal.
- `parent2` agrees with V2 traversal.
- V2-only nodes throw from V1 tree APIs.
- V1 getters remain coherent with V1 traversal.
- V1 scalar child getters do not return V2-only nodes.
- V1 `NodeList` child getters do not contain V2-only nodes.
- V1 `childEntities` and `namedChildEntities` do not expose V2-only nodes, including through flattened V1 lists.
- V1 `nodeCovering` does not return V2-only nodes.
- Replacing a real V2 child is reflected through the corresponding V1 scalar getter or projected `NodeList`.
- Repeated projection of one V2 origin returns the same V1 object.
- V1-only projection objects throw from V2 traversal and parent APIs and are never accepted by resolver or serializer entry points.
- Resolved V1 getters such as `staticType`, `element`, inferred type arguments, and const-related properties agree with their V2 origins without separately resolving the projections.
- V2 mutation or resolution performed after a projection is first requested is observable through that existing V1 projection.

<a name="annotation-staging"></a>
## Annotation Staging

AST migrations need different annotations at different points in the implementation and release cycle.

While the SDK is being migrated, V1 APIs should temporarily use normal `@Deprecated` annotations that point to the V2 APIs. This includes an entire legacy node type when the V2 model replaces that node, and individual legacy properties when their enclosing node remains current. It is useful because SDK analysis then shows every remaining V1-API use in analyzer, analysis_server, linter, and other SDK-owned code.

Before publishing an analyzer package where the replacement APIs are still not ready as public migration guidance, the temporary annotations must be changed. V2 APIs should be marked `@experimental`, and V1 APIs should not remain `@Deprecated` if the deprecation message would direct users to experimental APIs.

To keep the V1 APIs searchable and mechanically marked without producing public deprecation diagnostics, analyzer should have an analyzer-local marker:

```text
/// Marks an API that should become deprecated once its replacement is ready for
/// public migration guidance.
///
/// This annotation is analyzer-internal and does not produce deprecation
/// diagnostics. Use it when `@Deprecated` would be premature because the
/// replacement API is still experimental or otherwise not ready to recommend.
final class ToBeDeprecated {
  /// An optional note for maintainers.
  final String message;

  /// Creates a marker for an API that will be deprecated later.
  const ToBeDeprecated([this.message = '']);
}
```

The intended sequence is:

1. During active SDK migration, use `@Deprecated('Use ...')` on V1 nodes, changed properties, and tree APIs to find SDK uses.
2. Before publishing with experimental replacement APIs, mark the V2 APIs `@experimental`.
3. After SDK-owned code is clean, and before publishing with experimental replacements, downgrade the temporary V1-API `@Deprecated` annotations to `@ToBeDeprecated`.
4. When the replacement APIs are ready for public migration guidance, replace `@ToBeDeprecated` with real `@Deprecated` annotations.

The temporary real deprecations are an internal migration instrument, not a promise that experimental V2 APIs are already suitable public replacements. No analyzer package should be published in the intermediate state where stable V1 APIs are deprecated specifically in favor of experimental APIs.

Generated V1 visitor declarations and hand-written projection implementations
necessarily reference deprecated V1 types and members. Those compatibility
boundary files can use narrowly scoped suppressions or generator-owned
allowlisting. Deprecation diagnostics should remain enabled everywhere else so
that such suppressions do not conceal mixed-view analyzer code.

The AST implementation generator and visitor generators should use a manually
editable AST version policy constant, such as `_astVersionPolicy`, for this
release-cycle policy. A single policy enum avoids invalid combinations between
a generation mode and an annotation stage. For example, `_AstVersionPolicy` can
include:

- `v1Only`: no active V2 tree view and no active V1 projection.
- `v2MigrationSdk`: V2 is the implementation view, V2 APIs are experimental,
  and V1 APIs are temporarily deprecated to find SDK uses.
- `v2MigrationPublishExperimental`: V2 is the implementation view, V2 APIs are
  experimental, and V1 APIs are marked `@ToBeDeprecated`.
- `v2MigrationPublishStable`: V2 is the implementation view, V2 APIs are stable,
  and V1 APIs are deprecated for public migration.
- `v2AliasesOnly`: V1/no-suffix is canonical after rebaseline, and any V2 APIs
  are aliases rather than a second tree view.

The policy is intentionally directional while a V2 migration is active:
`GenerateNodeProperty.name` is the V2 property and `v1Name` is the V1 projected
property. The property metadata still describes AST shape: `v1Name` and
`v1Projection` do not decide whether an API is experimental or deprecated. For
generated implementation members, the policy controls whether the real
replacement property is annotated `@experimental`, and whether the V1 projection
member is annotated `@Deprecated(...)` or `@ToBeDeprecated`.

For hand-written interface getters, the annotations remain explicit in source
because they are the public API surface. The generator should validate migrated
properties with `v1Name`: the replacement getter has the expected stage
annotation, and the V1 getter has the expected stage annotation. This keeps
the stage flip mechanical without hiding public API changes inside generated
code.

<a name="rebaseline"></a>
## Rebaseline

After the V2 shape has stabilized and clients have had a deprecation window to
migrate, the AST should be rebaselined back to a single V1/no-suffix tree. This
is not a reverse projection from V2 to V1. It is a mechanical rewrite that makes
the stabilized V2 shape the ordinary V1 shape.

For a changed child property, rebaseline changes migration metadata such as:

```text
GenerateNodeProperty(
  'leftOperand2',
  v1Name: 'leftOperand',
  v1Projection: V1Projection.expression,
)
```

to the canonical unsuffixed form:

```text
GenerateNodeProperty('leftOperand')
```

After rebaseline:

- AstBuilder builds the V1/no-suffix canonical properties.
- Analyzer internals use V1/no-suffix traversal, parent, child-entity, and
  child-getter APIs again.
- Generated `visitChildren`, `parent`, `childEntities`, `nodeCovering`, and
  related APIs use one tree topology for the stabilized shape.
- V1 projection metadata for the completed migration has no active use.
- Runtime projection helpers such as projected `NodeList` support should have
  no active uses for the stabilized shape. They can be removed if unused, or
  kept dormant if the generator is expected to support another V2 migration
  soon.

The V2 APIs may remain temporarily after rebaseline as deprecated aliases, but
those aliases should not imply a second tree view. A deprecated V2 alias should
return the same canonical child and participate in the same tree topology as the
V1 API. Alias support, if needed, is separate from compatibility projection.

This avoids a permanent ping-pong public API model. Clients may migrate to V2
while a structural migration is active, but after the rebaseline the
no-suffix V1 APIs are again the canonical public and internal APIs. The next
structural AST migration starts from that V1-only baseline and uses V2 as the
staging slot again.

<a name="migration-plan"></a>
## Migration Plan

1. Add generated support for V2 tree-view APIs: `accept2`, `AstVisitor2`, visitor subclasses, `visitChildren2`, `parent2`, `root2`, ancestor helpers, `childEntities2`, `nodeCovering2`, and internal named child entities for the V2 view.
2. During SDK implementation, temporarily mark V1 tree-view APIs deprecated where they expose a shape that is being replaced, so SDK-owned uses are visible.
3. Implement V2 AST nodes and V2 getters as the implementation model, including canonical mutable and resolved state.
4. Implement cached V1 projection objects and V1 projections for scalar child getters, `NodeList` getters, traversal, parent chains, child entities, and semantic delegation.
5. Migrate parser, resolver, rewriter, serializer, analyzer, analysis_server, linter, and SDK-owned visitors to operate only on V2 nodes and APIs.
6. Mark V2 APIs `@experimental` if the analyzer package can be published before the V2 APIs are ready for public migration guidance.
7. Replace temporary V1-API `@Deprecated` annotations with `@ToBeDeprecated` before publishing in that state.
8. Update V2-view tests to expect the V2 real tree shape.
9. Keep V1-view tests for public compatibility.
10. When the V2 APIs are ready for public migration guidance, replace `@ToBeDeprecated` with real `@Deprecated` annotations on V1 APIs.
11. After the deprecation window, rebaseline the stabilized V2 shape into V1/no-suffix APIs as the canonical internal and public view.
12. Remove active V1 projection metadata and generated/runtime projection uses for the completed migration.
13. Optionally keep V2 APIs briefly as deprecated aliases to the canonical V1 APIs, without maintaining a second tree view.

<a name="open-questions"></a>
## Open Questions

- How much generated support is needed for V1 projections that are not a simple subset of V2 children?
- Should projected V1 `NodeList` values use a dedicated read-only implementation instead of `NodeListImpl`?
- How much dormant projection support should remain in the generator after
  rebaseline, versus being reintroduced for the next V2 migration?
- Should deprecated V2 aliases after rebaseline be generated, hand-written, or
  avoided entirely?
