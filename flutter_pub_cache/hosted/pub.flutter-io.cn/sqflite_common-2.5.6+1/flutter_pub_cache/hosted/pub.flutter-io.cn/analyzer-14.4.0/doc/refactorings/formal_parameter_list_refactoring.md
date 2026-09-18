# FormalParameterList Refactoring

This document proposes a structural cleanup of `FormalParameterList`:

- split leading required positional formal parameters from the following delimited formal parameters
- introduce a `DelimitedFormalParameters` node that owns `[` / `]` or `{` / `}`
- replace the current flat physical `parameters` list with two structurally honest child positions
- keep the existing flat API available as a compatibility projection during the migration period

The goal is to make the AST match the syntactic grouping of formal parameters, make child ordering fully generated, and give the delimiter pair a natural owner.

This is a compatibility-preserving migration, not an in-place breaking change. Existing public properties and V1 traversal remain available during the deprecation period. The new structure is the primary generated model, while the old flat structure is a compatibility projection.

Migration model reference: [Compatibility-Preserving AST Refactoring #63685](https://github.com/dart-lang/sdk/issues/63685).

## 1. Problem Statement

`FormalParameterList` currently stores every formal parameter in one flat `NodeList`:

```text
abstract final class FormalParameterList implements AstNode {
  Token get leftParenthesis;
  NodeList<FormalParameter> get parameters;
  Token? get leftDelimiter;
  Token? get rightDelimiter;
  Token get rightParenthesis;
}
```

This model does not match source order. In a declaration such as:

```text
void f(int x, {required String y, bool z = false}) {}
```

the source structure is:

```text
leftParenthesis
required positional formal parameter: int x
leftDelimiter: {
named formal parameter: required String y
named formal parameter: bool z = false
rightDelimiter: }
rightParenthesis
```

But the AST properties group all three formal parameters into one list. The left delimiter therefore occurs in the middle of a list-valued property. A generated child-entity description can put the complete list before or after the delimiter, but cannot place the delimiter inside the list.

This mismatch has several consequences.

### Child entities need a manual implementation

`FormalParameterListImpl._childEntities` is handwritten. It expands the `parameters` list into repeated child entities named `parameter` and inserts the left delimiter by comparing offsets.

That implementation is exceptional in two ways:

- it prevents `_childEntities` from being generated like most AST nodes
- the child name `parameter` does not correspond to a real AST property

The exceptional representation is observable in analyzer AST text expectations, where formal parameters appear as repeated `parameter:` entries instead of one `parameters` list.

### The delimiter pair has no syntactic owner

`leftDelimiter` and `rightDelimiter` jointly introduce one syntactic group, but they are represented as two independently nullable properties on the outer list. The type system does not express the ordinary invariant that both belong to the same optional construction.

### Token linking depends on the exceptional child order

`AstNodeImpl.linkNodeTokens` walks raw named child entities. If `FormalParameterListImpl._childEntities` were generated using the current flat model, all formal parameters would be traversed before `leftDelimiter`, and the token `previous` / `next` chain would be linked in the wrong order.

`ChildEntities.syntacticEntities` already flattens list-valued entities and sorts them by offset when necessary, so public `childEntities` can compensate for the flat model. Raw child-entity consumers cannot. The current manual method makes the raw representation lexical for this one node.

### The flat list hides a meaningful grammar boundary

The delimiter is not merely punctuation around some arbitrary suffix. It distinguishes one of two formal-parameter forms:

- `[...]` contains optional positional formal parameters
- `{...}` contains named formal parameters, which can be required or optional

Requiredness belongs to each named formal parameter. The curly-brace group as a whole is therefore not accurately described as an "optional parameter" group.

## 2. Design Principles

### Syntax should be owned by the construct it delimits

A delimiter pair belongs to a collection-level construct, not to its first or last element. The AST should have one node that owns both delimiters and the formal parameters between them.

### Child properties should have one generated lexical order

The real implementation tree should be expressible through ordinary generated child properties. Token linking, child iteration, containment, serialization, and AST printing should not require a node-specific reconstruction of lexical order.

### Group form and parameter requiredness are different concepts

Square brackets select optional positional form. Curly braces select named form. A formal parameter inside the named form can independently be required or optional.

### Public names should retain the domain noun

The analyzer contains both formal parameters and type parameters. A raw name such as `parameters` or `parameterGroup` is easy to misunderstand when the declaring type is not visible at the use site.

The proposed API therefore uses the complete term `formalParameters`, even where that produces relatively long names. Foundational AST vocabulary should prefer precision and discoverability over local brevity.

### Compatibility views should not compromise the primary tree

The parser, resolver, summary reader, and generated implementation should use the new tree directly. Existing flat APIs should be projections over that tree rather than independently maintained storage.

## 3. Proposed Design

### 3.1 Introduce `DelimitedFormalParameters`

Add a node representing the bracketed or braced group:

```text
abstract final class DelimitedFormalParameters implements AstNode {
  Token get leftDelimiter;
  NodeList<FormalParameter> get formalParameters;
  Token get rightDelimiter;

  bool get isNamed;
}
```

The delimiter tokens are required properties of an optional group node. Missing tokens produced by error recovery are represented by synthetic tokens, as in other analyzer AST nodes.

The `isNamed` getter encapsulates the interpretation of the left delimiter. It is `true` for a curly-braced named group and `false` for a square-bracketed optional positional group. Clients that need the distinction do not need to inspect token types directly:

```text
if (node.delimitedFormalParameters case var group?) {
  if (group.isNamed) {
    // Named formal parameters.
  } else {
    // Optional positional formal parameters.
  }
}
```

The group classification deliberately says nothing about requiredness. For example, both parameters below belong to one named group:

```text
void f({required int x, int y = 0}) {}
```

### 3.2 Reshape `FormalParameterList`

The preferred final API is:

```text
abstract final class FormalParameterList implements AstNode {
  Token get leftParenthesis;

  NodeList<FormalParameter> get requiredPositionalFormalParameters;

  DelimitedFormalParameters? get delimitedFormalParameters;

  Token get rightParenthesis;
}
```

This gives the generated child order:

```text
leftParenthesis
requiredPositionalFormalParameters
delimitedFormalParameters
rightParenthesis
```

`DelimitedFormalParameters` in turn has the generated child order:

```text
leftDelimiter
formalParameters
rightDelimiter
```

No child property needs to be split or interleaved manually.

### 3.3 Examples

An empty list:

```text
void f() {}
```

has this shape:

```text
FormalParameterList
  leftParenthesis: (
  requiredPositionalFormalParameters: []
  delimitedFormalParameters: null
  rightParenthesis: )
```

A list containing only required positional formal parameters:

```text
void f(int x, String y) {}
```

has this shape:

```text
FormalParameterList
  leftParenthesis: (
  requiredPositionalFormalParameters:
    RegularFormalParameter: int x
    RegularFormalParameter: String y
  delimitedFormalParameters: null
  rightParenthesis: )
```

Optional positional formal parameters:

```text
void f(int x, [String y = '']) {}
```

have this shape:

```text
FormalParameterList
  leftParenthesis: (
  requiredPositionalFormalParameters:
    RegularFormalParameter: int x
  delimitedFormalParameters: DelimitedFormalParameters
    leftDelimiter: [
    formalParameters:
      RegularFormalParameter: String y = ''
    rightDelimiter: ]
  rightParenthesis: )
```

Named formal parameters, including required named formal parameters:

```text
void f(int x, {required String y, bool z = false}) {}
```

have this shape:

```text
FormalParameterList
  leftParenthesis: (
  requiredPositionalFormalParameters:
    RegularFormalParameter: int x
  delimitedFormalParameters: DelimitedFormalParameters
    leftDelimiter: {
    formalParameters:
      RegularFormalParameter: required String y
      RegularFormalParameter: bool z = false
    rightDelimiter: }
  rightParenthesis: )
```

### 3.4 Structural invariants

For valid source, the proposed tree has these invariants:

- every element of `requiredPositionalFormalParameters` has required positional kind
- a group with `isNamed == false` uses square brackets and contains optional positional formal parameters
- a group with `isNamed == true` uses curly braces and contains named formal parameters
- requiredness of a named formal parameter is represented by that formal parameter, not by the group
- `delimitedFormalParameters == null` means there is no bracketed or braced group
- a non-null `delimitedFormalParameters` always owns both delimiter tokens

Error recovery can produce synthetic tokens or formal parameters whose kinds do not satisfy the valid-source invariants. The tree should preserve the syntactic grouping selected by the parser rather than moving recovered formal parameters between lists solely to make their semantic kinds agree.

## 4. Naming

The proposed names are intentionally explicit:

```text
requiredPositionalFormalParameters
delimitedFormalParameters
formalParameters
```

The repetition is acceptable because these properties are often read through a locally named variable such as `node`, where the declaring type is not visible. The complete name also distinguishes them from type parameters.

### Why `delimitedFormalParameters`

`delimitedFormalParameters` describes the shared syntax without making an incorrect semantic claim.

Names based on optionality are problematic. A `{...}` group can contain `required` named formal parameters, so `optionalFormalParameters` is not a faithful description of the group.

The language grammar term `optionalOrNamedFormalParameters` is technically accurate: it means optional-positional formal parameters or named formal parameters. It is nevertheless easy to misread as saying that named formal parameters are optional. `delimitedFormalParameters` avoids that ambiguity.

### Why not shorten the properties

The following shorter names were considered:

- `parameters`: ambiguous between formal and type parameters
- `requiredPositional`: turns adjectives into an unclear collection noun
- `delimited`: does not say what is delimited
- `items`, `elements`, or `contents`: lose the domain meaning
- `section` or `part`: introduce generic structural vocabulary without explaining the syntax
- `trailingFormalParameters`: describes position but not why the group exists

Long names in generated and structural AST code are preferable to short names that require surrounding type context to understand.

### Why `DelimitedFormalParameters` instead of `FormalParameterGroup`

`FormalParameterGroup` is not used because `group` is generic structural vocabulary and does not identify the syntax represented by the node. A property such as `delimitedFormalParameterGroup` would also be longer without adding information beyond `delimitedFormalParameters`.

`DelimitedFormalParameters` describes the shared syntax directly and aligns with the property `delimitedFormalParameters`. The `isNamed` getter exposes the only classification that consumers need without introducing additional node types or an enum.

## 5. Compatibility Projection

During the compatibility window, the existing V1 API remains available:

```text
NodeList<FormalParameter> get parameters;
Token? get leftDelimiter;
Token? get rightDelimiter;
```

These properties are projected from the new tree.

### Flat `parameters`

The old `parameters` getter presents a fixed-length concatenated view of:

```text
requiredPositionalFormalParameters
+ delimitedFormalParameters?.formalParameters
```

This projection must continue to satisfy the `NodeList` contract, including:

- stable indexing
- `owner == FormalParameterList`
- `beginToken` and `endToken`
- fixed-length behavior
- visitor dispatch

It should be a read-only projected `NodeList`, not a second independently mutable storage list. This requires either a general concatenated projected `NodeList` implementation or a migration-specific implementation.

### Delimiter getters

The old delimiter getters are direct projections:

```text
leftDelimiter  -> delimitedFormalParameters?.leftDelimiter
rightDelimiter -> delimitedFormalParameters?.rightDelimiter
```

### Parent relationships

Leading required positional formal parameters have the same parent in both views:

```text
formalParameter.parent  == formalParameterList
formalParameter.parent2 == formalParameterList
```

Formal parameters inside `DelimitedFormalParameters` have different logical parents:

```text
formalParameter.parent  == formalParameterList
formalParameter.parent2 == delimitedFormalParameters
```

The `DelimitedFormalParameters` node is V2-only during migration, so it is not visible through V1 visitor, parent, child, or locator APIs.

### Visitor and child-entity behavior

V1 traversal must preserve the existing flat behavior:

```text
FormalParameterList
  parameter
  parameter
  ...
```

It skips the V2-only group node and visits all projected formal parameters directly.

V2 traversal follows the real tree and visits the group node. V2 named child entities are fully generated from the new properties:

```text
FormalParameterList
  requiredPositionalFormalParameters
  delimitedFormalParameters

DelimitedFormalParameters
  leftDelimiter
  formalParameters
  rightDelimiter
```

The group is one V2-only `DelimitedFormalParameters` node. Its generated visitor and child entities are independent of whether its delimiters are square or curly.

After the compatibility window and rebaseline, the generated V2 shape becomes the unsuffixed primary AST shape and the handwritten flat child-entity projection is removed.

## 6. Derived and Consuming APIs

### `parameterFragments`

`FormalParameterList.parameterFragments` remains a derived flat view. Its implementation concatenates the fragment projections from both formal parameter collections in source order.

The final API does not add an `allFormalParameters` convenience iterable. Clients use the two structural properties and explicitly concatenate them when they genuinely need a flat view. This avoids retaining a second, non-owning representation of the formal parameter children after the compatibility projection has been removed.

### Formal parameter kind

`FormalParameterImpl.kind` and the corresponding public `isNamed`, `isRequired`, and related getters remain useful. They describe the semantic kind of an individual formal parameter and support invalid or recovered cases. The new group does not replace them.

For valid source, the group form and individual kinds agree. Consumers can use the group when they care about syntax and the individual kind when they care about parameter semantics.

### Source printing

`ToSourceVisitor` should print:

1. `leftParenthesis`
2. the required positional formal parameters
3. the optional delimited group
4. `rightParenthesis`

The delimited group prints its own delimiters and formal parameters. This removes delimiter-state logic from the outer list visitor.

### Token linking

The new primary tree is already lexical, so raw generated child traversal links tokens correctly:

```text
FormalParameterList
  leftParenthesis
  requiredPositionalFormalParameters
  delimitedFormalParameters
  rightParenthesis
```

and inside the group:

```text
leftDelimiter
formalParameters
rightDelimiter
```

No offset comparison or special `FormalParameterListImpl` override is needed in the final tree.

### Serialization

The summary representation currently stores the flat formal parameters and delimiter kind. The primary serialized form should instead preserve:

- the leading required positional formal parameters
- the concrete optional positional or named formal-parameter group
- the formal parameters inside the group

The reader should construct the new tree directly. The old flat getters are then projected from the reconstructed primary tree.

## 7. Error Recovery

The group node improves recovery representation.

### Empty recovered groups

Malformed source can contain an empty group such as `([])` or `({})`. A `DelimitedFormalParameters` node can own the delimiter pair even when its `formalParameters` list is empty.

Attaching delimiters to the first or last formal parameter cannot represent this case.

### Missing delimiters

If either delimiter is missing, the parser should create a synthetic token and retain the group node. This preserves the invariant that a present group owns both delimiter positions while retaining recovery information through token syntheticity.

The synthetic left delimiter retains the token type intended by the parser, so `isNamed` continues to describe the recognized form during recovery.

### Mismatched delimiters and recovered kinds

The AST should preserve the actual or synthetic tokens selected by recovery. It should not require matching token types at construction time, because doing so could discard useful invalid-source structure.

A mismatched closing delimiter does not change the classification selected by the opening delimiter or parser context. For example, a named group ending in a recovered `]` still has `isNamed == true`.

Likewise, recovered formal parameters should remain in the syntactic group in which the parser placed them even if their computed `ParameterKind` is unexpected.

## 8. Alternatives Considered

### Keep the flat tree and lexicalize consumers

The smallest change is to generate the current `_childEntities`, then teach every lexical consumer to flatten list-valued child entities and sort them by offset. In particular, `AstNodeImpl.linkNodeTokens` could consume `ChildEntities.syntacticEntities` instead of raw named entities.

This would remove the immediate token-linking dependency on the manual method. It does not address:

- the independently nullable delimiter pair
- the absence of a node representing the group
- the structural mismatch between the flat list and the grammar
- raw named child entities whose property grouping is not lexical

This is a reasonable tactical cleanup if an AST shape migration is not justified, but it is not the preferred final model.

If this alternative is implemented independently, offset sorting should be stable for entities with equal offsets. Synthetic recovery tokens and nodes can share offsets, and token ordering must not depend on an unstable sort.

### Put delimiter tokens on `FormalParameter`

The first formal parameter could own the left delimiter, and the last could own the right delimiter. This is rejected because delimiter ownership would depend on position rather than syntax.

It also behaves poorly for:

- an empty recovered group
- a single formal parameter that would own both delimiters
- replacement or movement of the first or last formal parameter
- clients inspecting a formal parameter outside its list context

### Split into two lists but keep delimiters on `FormalParameterList`

The outer node could contain:

```text
requiredPositionalFormalParameters
leftDelimiter
delimitedFormalParameters
rightDelimiter
```

This gives generated lexical order without introducing another node. It still models one optional syntactic construction as three independently nullable properties and provides no natural home for group-specific behavior.

Introducing `DelimitedFormalParameters` is a small increase in node count that provides stronger invariants and a deeper abstraction.

### Use separate node types for the two forms

The AST could introduce separate `OptionalPositionalFormalParameters` and `NamedFormalParameters` node types.

This is not preferred because the two forms have identical children and behavior. Separate node types would add public types, visitor methods, and registrations whose implementations immediately converge. A derived `isNamed` getter provides the useful distinction while keeping the structural model minimal.

## 9. Migration Strategy

This refactoring uses the dual-view migration model described in [Compatibility-Preserving AST Refactoring #63685](https://github.com/dart-lang/sdk/issues/63685).

### Steps

1. Add the V2-only `DelimitedFormalParameters` node, with a generated implementation, visitor, child entities, containment, and serialization support.
2. Add the new primary child properties to `FormalParameterList`:
   - `requiredPositionalFormalParameters`
   - `delimitedFormalParameters`
3. Update `AstBuilder` and the summary reader to construct the new primary tree directly.
4. Keep `FormalParameterImpl.kind` populated for every formal parameter.
5. Implement the V1 `parameters` getter as a fixed-length concatenated projected `NodeList`.
6. Project the V1 `leftDelimiter` and `rightDelimiter` getters from the group node.
7. Preserve V1 `visitChildren`, `childEntities`, `namedChildEntities`, parent, ancestor, locator, and node-covering behavior.
8. Generate the V2 traversal and child-entity implementation from the new structural properties.
9. Update analyzer, analysis_server, linter, and SDK-owned tools to use the new properties where the distinction matters.
10. Update source printing, resolution, informative data, summary serialization, AST factories, and AST binary round-tripping.
11. Add analyzer changelog and migration guidance for public clients.
12. After the deprecation window, remove the flat compatibility properties and V1 projection, rebaseline the new structure to unsuffixed APIs, and remove the manual `FormalParameterListImpl._childEntities` implementation.

## 10. Testing

Tests should cover both tree views during migration.

### Structural cases

- empty formal parameter list
- required positional formal parameters only
- optional positional formal parameters only
- required positional followed by optional positional formal parameters
- named formal parameters only
- required positional followed by named formal parameters
- a named group containing both required and optional named formal parameters
- nested formal parameter lists in function-typed formal parameters and generic function types

### Recovery cases

- empty square-bracket and curly-brace groups
- missing left delimiter
- missing right delimiter
- mismatched delimiters
- synthetic formal parameters sharing offsets with delimiters
- unexpected formal parameter kinds inside a recovered group

### Compatibility cases

- V1 `parameters` indexing and iteration preserve flat source order
- V1 `NodeList.owner`, `beginToken`, and `endToken` preserve their contracts
- V1 parents point directly to `FormalParameterList`
- V2 parents for grouped formal parameters point to `DelimitedFormalParameters`
- V1 recursive visitors do not visit the V2-only group
- V2 recursive visitors dispatch to `DelimitedFormalParameters` and visit each formal parameter exactly once
- `DelimitedFormalParameters.isNamed` distinguishes optional positional form from named form
- V1 and V2 child entities expose their respective tree shapes
- token `previous` / `next` links remain in lexical order after summary reading and node detachment/relinking
- source and binary summary round-tripping preserve delimiter form and formal parameter kinds

## 11. Non-Goals

This document does not propose:

- changing the `FormalParameter` leaf hierarchy
- removing or replacing `ParameterKind`
- changing requiredness rules for named formal parameters
- modeling comma separators as AST child tokens
- redesigning `TypeParameterList`
- introducing one shared abstraction for formal parameter lists and type parameter lists

The refactoring is specifically about the internal grouping and delimiter ownership of formal parameters.
