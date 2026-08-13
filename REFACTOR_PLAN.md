# BCC & BMK Refactor Plan

## Executive Summary

This document provides a comprehensive analysis of open bugs in the bcc (BlitzMax compiler) and bmk (build tool) repositories, identifies root causes, prioritises fixes, and proposes a four-phase plan to bring the toolchain to a robust, extensible state.

---

## 1. Bug Inventory & Root Cause Analysis

### 1.1 Function Pointer Bugs (Critical)

| Issue | Title | Root Cause | Severity |
|-------|-------|-----------|----------|
| [#686](https://github.com/bmx-ng/bcc/issues/686) | Function pointer issues (GCC 14 incompatible-pointer-types) | `ctranslator.bmx` emits raw `Byte Ptr` return from helper function assigned directly to a typed function pointer global. The generated C code omits the cast, so GCC 14's stricter `-Wincompatible-pointer-types` (now an error by default) rejects it. | **P0 - Blocker** |
| [#662](https://github.com/bmx-ng/bcc/issues/662) | Null function error wrapper causes segfaults | `ctranslator.bmx` emits `&brl_blitz_NullFunctionError` as the default value for uninitialised function pointers, but the generated wrapper signature does not match the actual function pointer type, causing segfaults at runtime when the pointer is invoked or checked. | **P0 - Blocker** |
| [#681](https://github.com/bmx-ng/bcc/issues/681) | Function pointer assignment ignores `Var` arg differences | `TFunctionPtrType.EqualsType()` in [`type.bmx:2191`](type.bmx:2191) compares arg types via `EqualsType()` but does not check `T_VAR` flag on each argument. A `Function F(i:Int Var)` can be assigned to `Local x(i:Int)` without error. | **P1 - High** |
| [#664](https://github.com/bmx-ng/bcc/issues/664) | Incorrect variance checks for function type conversions | `TFunctionPtrType.ExtendsType()` at [`type.bmx:2204`](type.bmx:2204) has co/contravariance backwards. Return types should be **covariant** (func return must extend target return) and parameters should be **contravariant** (target param must extend func param). Currently both directions use the same `ExtendsType` polarity. | **P1 - High** |
| [#626](https://github.com/bmx-ng/bcc/issues/626) | First-class functions / function pointer arrays don't work | `TArrayExpr.Semant()` in [`expr.bmx:2963`](expr.bmx:2963) fails when array literal contains function references: (a) `Null` in the array triggers "Auto array element has no type" because `TNullType` is not handled for function pointer arrays, (b) indexing the result of `[F]` directly fails because the expression is not recognised as invocable. | **P1 - High** |
| [#484](https://github.com/bmx-ng/bcc/issues/484) | Array-of-function literals cause errors when indexed directly | Same root cause as #626 -- `TIndexExpr` on an inline `TArrayExpr` containing function refs does not propagate the `TFunctionPtrType` element type correctly. | **P1 - High** |
| [#562](https://github.com/bmx-ng/bcc/issues/562) | Auto array element has no type (function pointer array) | The test at [`tests/framework/language/fp_arrays_01.bmx`](tests/framework/language/fp_arrays_01.bmx) fails with "Auto array element has no type". Same cluster as #626/#484. | **P1 - High** |
| [#444](https://github.com/bmx-ng/bcc/issues/444) | Function/Method references wrongly interpreted as calls | When a function identifier appears without parentheses, the parser sometimes treats it as an invocation rather than a reference. The `invokedWithBraces` flag in `TInvokeExpr` is the mechanism used to distinguish the two, but it is not consistently set. | **P2 - Medium** |

**Root Cause Summary (Function Pointers):**
The function pointer subsystem is spread across four files with no single owner:
- [`type.bmx`](type.bmx) -- `TFunctionPtrType` type representation, equality/extends checks
- [`expr.bmx`](expr.bmx) -- `TInvokeExpr`, `TArrayExpr`, `TCastExpr` handle function-ptr semantics ad hoc
- [`decl.bmx`](decl.bmx) -- `TFuncDecl` scope/semant for function pointer decls, `equalsFunc()` matching
- [`ctranslator.bmx`](ctranslator.bmx) -- C code generation for function pointer types, casts, null wrappers

The core problem is that function pointers are bolted on as a special case of `TFuncDecl` with a `FUNC_PTR` flag rather than being a first-class type with proper semantics. This leads to:
1. Missing casts in generated C code
2. Incomplete type equality checks (no `Var` flag comparison)
3. Reversed variance in `ExtendsType`
4. `TArrayExpr` not handling Null or direct indexing for function pointer element types

### 1.2 Generics Bugs (Critical)

| Issue | Title | Root Cause | Severity |
|-------|-------|-----------|----------|
| [#753](https://github.com/bmx-ng/bcc/issues/753) | Undefined references for TTreeMaps in imports | When a generic type (e.g. `TTreeMap<String, TTrendsEntry>`) is instantiated in an imported file, the generic instance's C symbol (`gimpl_TTreeMapSTTTrendsEntry`) is generated in the importing module's translation unit but the definition is not emitted because the instantiation happens during import processing and the code generator doesn't track cross-file generic instantiations. | **P0 - Blocker** |
| [#724](https://github.com/bmx-ng/bcc/issues/724) | Nested generics issue (TLinkedList of TLinkedList) | `TClassDecl.GenInstance()` at [`decl.bmx:2770`](decl.bmx:2770) re-parses the template source to create instances. When the type parameter `T` is itself a generic instantiation (e.g. `TLinkedList<String>`), the inner generic's type arguments are not properly resolved during the outer generic's instantiation, causing "Unable to find overload" errors. | **P0 - Blocker** |
| [#501](https://github.com/bmx-ng/bcc/issues/501) | Segfault when stack importing TStack | Recursive generic instantiation across import boundaries causes a segfault. When file A imports file B which imports file C, and both B and C use `TStack<X>`, the generic instance lookup in `GenInstance()` can re-enter semanting before the first instance is fully constructed. | **P0 - Blocker** |
| [#617](https://github.com/bmx-ng/bcc/issues/617) | Unused nested generics unable to compile | A generic type containing a field of another generic type (e.g. `TTreeMap<K,V>` inside `TTempMap<K,V>`) fails to compile unless the field is actually accessed. The instantiation of inner generics is deferred but the symbol is still referenced in the generated C code. | **P1 - High** |
| [#376](https://github.com/bmx-ng/bcc/issues/376) | Compilation of generics (no semantic analysis of generic bodies) | Generic type bodies are only parsed, never semantically analysed until instantiation. This means errors in generic code are only caught when the generic is used with specific type arguments, and even then the errors are reported in the consumer's context rather than the library's. | **P2 - Medium (design debt)** |
| [#614](https://github.com/bmx-ng/bcc/issues/614) | Generics self increment issue | Edge case in generic method bodies where `Self` type resolution fails. | **P2 - Medium** |
| [#302](https://github.com/bmx-ng/bcc/issues/302) | Allow functions/methods to introduce type parameters | Feature request: generic functions (not just generic types). Currently only `Type` can have type parameters. | **P3 - Enhancement** |
| [#301](https://github.com/bmx-ng/bcc/issues/301) | Allow structs to introduce type parameters | Feature request for generic structs. | **P3 - Enhancement** |
| [#299](https://github.com/bmx-ng/bcc/issues/299) | Generics and Reflection | Reflection should expose generic type information. | **P3 - Enhancement** |

**Root Cause Summary (Generics):**
Generics are implemented as a template/macro system: `TClassDecl` stores raw source text in `templateSource`, and `GenInstance()` at [`decl.bmx:2770`](decl.bmx:2770) re-parses it from scratch for each instantiation via `TGenProcessor.processor.ParseGeneric()`. Problems:
1. **No cross-file instantiation tracking**: Generic instances created during import don't get their C symbols emitted in the right translation unit.
2. **No re-entrancy guard**: Recursive generic instantiation (A uses B<C>, B<C> uses A) can segfault.
3. **Nested generics broken**: When `T` itself is a generic instantiation, the template substitution doesn't recurse properly.
4. **No semantic pre-validation**: Generic bodies are not type-checked until instantiation, so library authors ship broken generics unknowingly (#376).

### 1.3 Build System Bugs (bmk)

| Issue | Title | Root Cause | Severity |
|-------|-------|-----------|----------|
| [#133](https://github.com/bmx-ng/bmk/issues/133) | bmk doesn't take configured options into account | Build options from config files are ignored for some actions. | **P1 - High** |
| [#123](https://github.com/bmx-ng/bmk/issues/123) | @bmk pragma ignored in main source file | The `@bmk` pragma processing happens after the main file is already parsed. | **P1 - High** |
| [#93](https://github.com/bmx-ng/bmk/issues/93) | Changed custom conditionals not recognized in quick compiles | Dependency tracking doesn't consider conditional compilation flags. Changing a `-ud` flag doesn't trigger recompilation. | **P1 - High** |
| [#69](https://github.com/bmx-ng/bmk/issues/69) | Enforce module recompile on big compiler changes | No version/hash tracking for the compiler itself in the build cache. | **P2 - Medium** |
| [#115](https://github.com/bmx-ng/bmk/issues/115) | Files missing during compilation | Race condition or ordering issue in dependency resolution. | **P2 - Medium** |
| [#138](https://github.com/bmx-ng/bmk/issues/138) | Fix: Correct no-exceptions removal for cc_opts | Incorrect string manipulation when removing flags. | **P2 - Quick fix** |

### 1.4 Other Notable bcc Bugs

| Issue | Title | Severity |
|-------|-------|----------|
| [#705](https://github.com/bmx-ng/bcc/issues/705) | Constructor chaining broken in structs | P1 |
| [#698](https://github.com/bmx-ng/bcc/issues/698) | Wrong overload used when arg is a function result | P1 |
| [#684](https://github.com/bmx-ng/bcc/issues/684) | Struct fields can't be modified via methods | P1 |
| [#682](https://github.com/bmx-ng/bcc/issues/682) | Super type methods not inherited correctly | P1 |
| [#683](https://github.com/bmx-ng/bcc/issues/683) | Structs with fields "o1"/"o2" fail (name collision) | P2 |
| [#656](https://github.com/bmx-ng/bcc/issues/656) | @bmk pragma broken since 0.139 | P1 |
| [#476](https://github.com/bmx-ng/bcc/issues/476) | Incorrect precedence for casts without parens | P2 |
| [#578](https://github.com/bmx-ng/bcc/issues/578) | Segfault using array entry as loop variable | P1 |

---

## 2. Priority Matrix

### Blocking (must fix before any refactoring)
1. **#662** - NullFunctionError wrapper segfaults (function pointers unusable)
2. **#686** - GCC 14 function pointer type mismatch (won't compile on modern GCC)
3. **#753** - Generic import undefined references (generics unusable across files)
4. **#501** - Generic segfault on recursive imports
5. **#724** - Nested generics broken

### Quick Wins (isolated fixes, high value)
1. **#681** - Add `T_VAR` flag check to `TFunctionPtrType.EqualsType()` (~5 lines)
2. **#664** - Fix variance direction in `TFunctionPtrType.ExtendsType()` (~10 lines)
3. **#683** - Struct field name collision with generated C names
4. **#138** (bmk) - Fix cc_opts string manipulation

### Deferred (need architectural changes)
1. **#376** - Semantic analysis of generic bodies (Phase 3)
2. **#302/#301** - Generic functions/structs (Phase 3)
3. **#299** - Generics and reflection (Phase 4)
4. **#626/#484/#562** - Function pointer arrays (Phase 2 refactor)

---

## 3. Phased Implementation Plan

### Phase 1: Critical Bug Fixes (Weeks 1-3)

**Goal**: Make function pointers and generics usable on modern toolchains.

#### 1a. Fix NullFunctionError wrapper segfaults (#662)

**File**: [`ctranslator.bmx`](ctranslator.bmx)

**Problem**: `&brl_blitz_NullFunctionError` is used as a universal null sentinel for all function pointer types, but its signature doesn't match the actual function pointer's C type. When the pointer is called or compared, the type mismatch causes segfaults.

**Fix approach**:
- Generate a properly-typed null wrapper for each distinct function pointer signature.
- In `TransValue()` (around line 617) and global init code, instead of emitting `&brl_blitz_NullFunctionError`, emit a cast: `(RetType(*)(ArgTypes...))&brl_blitz_NullFunctionError`
- Alternatively, generate per-signature static inline wrapper functions that match the expected signature and call through to the error handler.

#### 1b. Fix GCC 14 function pointer type mismatches (#686)

**File**: [`ctranslator.bmx`](ctranslator.bmx)

**Problem**: When a `Global alcOpenDevice:Byte Ptr(devicename$z) = P("alcOpenDevice")` is translated, the RHS returns `Byte Ptr` (i.e. `unsigned char*`) but the LHS expects a function pointer type `int(*)(unsigned char*)`. The generated C code assigns the raw pointer without a cast.

**Fix approach**:
- In `TransGlobalInit()` and assignment translation, when the RHS expression type is `Byte Ptr` (or any pointer) and the LHS is `TFunctionPtrType`, emit an explicit C cast using `TransCast()`.
- The `TransCast()` method already exists at [`ctranslator.bmx:830`](ctranslator.bmx:830) -- it just needs to be called in more places.

#### 1c. Fix Var-flag check in function pointer equality (#681)

**File**: [`type.bmx`](type.bmx)

**Change at line 2197-2200**:
```blitzmax
For Local a:Int = 0 Until func.argDecls.Length
    ' does our arg equal declared arg?
    If Not func.argDecls[a].ty.EqualsType(tyfunc.argDecls[a].ty) Then Return False
    ' check Var modifier matches
    If (func.argDecls[a].ty._flags & T_VAR) <> (tyfunc.argDecls[a].ty._flags & T_VAR) Then Return False
Next
```

#### 1d. Fix variance direction in ExtendsType (#664)

**File**: [`type.bmx`](type.bmx)

**Change at lines 2204-2214**: The return type check is correct (covariant: `func.retType.ExtendsType(tyfunc.retType)`), but the argument check has the wrong direction. For contravariance, we need `func.argDecls[a].ty.ExtendsType(tyfunc.argDecls[a].ty)` (the *source* function's arg type must be a supertype of the *target*'s arg type):
```blitzmax
Method ExtendsType:Int( ty:TType, noExtendString:Int = False, widensTest:Int = False, ignoreObjectSubclasses:Int = False)
    If TFunctionPtrType( ty )
        Local tyfunc:TFuncDecl = TFunctionPtrType(ty).func
        ' Covariant return: our return type must extend target return type
        If Not func.retType.ExtendsType(tyfunc.retType) Then Return False
        If Not (func.argDecls.Length = tyfunc.argDecls.Length) Then Return False
        For Local a:Int = 0 Until func.argDecls.Length
            ' Contravariant args: target arg type must extend our arg type
            If Not func.argDecls[a].ty.ExtendsType(tyfunc.argDecls[a].ty) Then Return False
        Next
        Return True
    EndIf
    Return IsPointerType( ty, 0, T_POINTER )<>Null
End Method
```

#### 1e. Fix generic cross-file instantiation (#753, #617)

**Files**: [`decl.bmx`](decl.bmx), [`ctranslator.bmx`](ctranslator.bmx)

**Problem**: When `GenInstance()` creates a generic instantiation during import processing, the C code generator emits the symbol reference in the importing file but the definition ends up missing because the instance was created in a different compilation context.

**Fix approach**:
- Track all generic instances that need code generation in a global registry (already partially exists via `instances` list on the template class).
- During C code emission, check if each referenced generic instance has its definition emitted in the current translation unit. If not, emit it.
- Add an `emitted:Int` flag to `TClassDecl` to prevent duplicate emission.

#### 1f. Fix recursive generic import segfault (#501)

**File**: [`decl.bmx`](decl.bmx)

**Problem**: `GenInstance()` can re-enter itself before the first instance is fully set up, causing null pointer dereference.

**Fix approach**:
- Add a re-entrancy guard: before calling `ParseGeneric()`, insert the partially-constructed instance into the `instances` list with a `DECL_SEMANTING` flag.
- When `GenInstance()` is called recursively and finds a `DECL_SEMANTING` instance, return it immediately (forward reference).
- Complete the instance setup after `ParseGeneric()` returns and clear the flag.

#### 1g. Fix nested generics (#724)

**File**: [`decl.bmx`](decl.bmx)

**Problem**: When `T` in `TLinkedList<T>` is itself `TLinkedList<String>`, the template argument substitution doesn't properly handle the nested generic's type arguments.

**Fix approach**:
- In `GenInstance()`, when constructing `instArgs`, recursively resolve any generic types in the arguments before template substitution.
- Ensure that `TTemplateDets` carries the fully-resolved type information for nested generics.

### Phase 2: Function Pointer & Array Subsystem Refactor (Weeks 4-6)

**Goal**: Make function pointers first-class citizens in the type system.

#### 2a. Refactor TFunctionPtrType

**Files**: [`type.bmx`](type.bmx), [`expr.bmx`](expr.bmx), [`decl.bmx`](decl.bmx)

- `TFunctionPtrType` should store its own `retType:TType` and `argTypes:TType[]` directly rather than delegating to a `TFuncDecl`. The `TFuncDecl` approach conflates the *declaration* of a function with the *type* of a function pointer.
- Add proper `Var` flag handling in all comparison methods.
- Add proper co/contravariance support.
- Make `TFunctionPtrType` implement `ToString()` with a readable signature format.

#### 2b. Fix function pointer arrays (#626, #484, #562)

**File**: [`expr.bmx`](expr.bmx)

- In `TArrayExpr.Semant()`, handle `TNullType` elements in function pointer arrays by treating them as null values of the inferred function pointer type.
- Support direct indexing of array literals `[F][0]` by ensuring `TIndexExpr` can handle `TArrayExpr` as its base expression.
- Add proper type propagation so `[F][0]()` chains work.

#### 2c. Fix function reference vs call ambiguity (#444)

**File**: [`expr.bmx`](expr.bmx), [`parser.bmx`](parser.bmx)

- Make the `invokedWithBraces` flag redundant by instead distinguishing at the AST level between `TFuncRefExpr` (a reference to a function) and `TInvokeExpr` (a call to a function).
- This requires a new `TFuncRefExpr` node type.

#### 2d. Harden C code generation for function pointers

**File**: [`ctranslator.bmx`](ctranslator.bmx)

- Always emit explicit casts when assigning to function pointer variables.
- Generate properly-typed null sentinel wrappers per function signature.
- Ensure `TransCast()` is used consistently in all assignment, argument passing, and return contexts.

### Phase 3: New Language Features (Weeks 7-12)

**Goal**: Implement the requested language features with clean, tested implementations.

#### 3a. Working function pointers (consolidation of Phase 1+2 fixes)
- Full test suite for function pointer scenarios including arrays, callbacks, nested calls, null handling.

#### 3b. Working generics
- Semantic pre-validation of generic bodies (#376): Add a "generic semant" pass that type-checks using placeholder types for type parameters.
- Generic functions and methods (#302): Extend `TFuncDecl` to support type parameters.
- Generic structs (#301): Extend struct handling to support type parameters.

#### 3c. Working callbacks
- Delegate/closure support (#360): Introduce a `TClosureType` that captures environment.
- Method references as callbacks: Allow `obj.Method` to be passed as a callback by auto-generating a closure.

#### 3d. Const string arrays
- Add `Const` modifier support for array declarations.
- Emit `const` qualifier in generated C code for string array literals.

#### 3e. Optional named parameters
- Extend `TArgDecl` with a `name` field usable at call sites.
- Parser changes to support `FuncCall(paramName: value)` syntax.
- Matching logic in overload resolution to handle named arguments.

#### 3f. Case-sensitive variables
- Add a compiler flag or directive to enable case-sensitive identifiers.
- Modify `TScopeDecl.FindDecl()` to use case-sensitive comparison when enabled.
- This must be opt-in per-module for backwards compatibility.

#### 3g. Enhanced compiler directives

Add version-checking compiler directives:
```blitzmax
?bcc >= 0.158
?bmk >= 3.56
?gcc >= 12
?llvm >= 18
```

**Implementation**:
- Extend the preprocessor/conditional compilation system in [`toker.bmx`](toker.bmx).
- Add version query functions for bcc, bmk, and detected build tools.
- Parse comparison operators in conditional expressions.

#### 3h. Ternary operator

Add `var = a ? b : c` syntax:
- New `TTernaryExpr` AST node in [`expr.bmx`](expr.bmx).
- Parser support in [`parser.bmx`](parser.bmx) for `? :` operator with correct precedence.
- Type inference: result type is `BalanceTypes(b.exprType, c.exprType)`.
- C translation is trivial: `a ? b : c`.

#### 3i. C-style switch with jump tables

Implement optimised switch/select statements:
- New `TJumpSwitchStmt` AST node for integer-keyed switches with dense case ranges.
- Detect when a Select statement has contiguous integer cases and emit a C `switch` with computed goto or jump table.
- Fall back to if-else chain for sparse cases.
- Prioritise O(1) dispatch for dense integer ranges.

### Phase 4: AST & Build System Redesign (Weeks 13-20)

**Goal**: Clean, modular, extensible architecture.

#### 4a. AST Redesign

**Current problems**:
- Types, declarations, expressions, and statements are all in separate files but tightly coupled via globals (`_env`, `_envStack`, `_appInstance`, `_loopnest`).
- Semant passes are interleaved with parsing -- `Semant()` is called during parse in many cases.
- The translator (`TCTranslator`) directly reaches into AST internals.

**Proposed architecture**:
1. **Separate parse and semant phases completely**: The parser produces an undecorated AST. A separate semant pass walks the tree, resolves names, checks types, and annotates nodes.
2. **Visitor pattern for AST traversal**: Replace the current `Trans()` method on each node with an `Accept(visitor)` pattern. The C translator becomes a visitor.
3. **Immutable AST nodes**: After semant, nodes should be immutable. Transformations produce new trees.
4. **Eliminate globals**: `_env`, `_envStack`, `_appInstance` should be passed as context objects through the semant pass.
5. **Type system as a separate module**: `TType` and its subclasses should be a self-contained module with clear interfaces.

**New file structure**:
```
src/
  ast/
    types.bmx        -- TType hierarchy
    decls.bmx        -- TDecl hierarchy
    exprs.bmx        -- TExpr hierarchy
    stmts.bmx        -- TStmt hierarchy
    visitor.bmx      -- Visitor interface
  parse/
    toker.bmx        -- Tokeniser
    parser.bmx       -- Parser (produces raw AST)
  semant/
    resolver.bmx     -- Name resolution
    typechecker.bmx  -- Type checking
    semant.bmx       -- Orchestrator
  codegen/
    ctranslator.bmx  -- C code generator (visitor)
    mangler.bmx      -- Name mangling
  build/
    config.bmx       -- Configuration
    options.bmx      -- Command-line options
```

#### 4b. Build System (bmk) Redesign

**Current problems**:
- Custom scripting language for build rules is hard to extend (#67 suggests Lua).
- Dependency tracking is incomplete (doesn't track compiler flags #93, compiler version #69).
- No proper parallel build support.

**Proposed changes**:
1. **Content-addressed build cache**: Hash source files + compiler flags + compiler version to determine staleness. Eliminates #93 and #69.
2. **Proper dependency graph**: Build a DAG of compilation units, track all inputs (source, headers, flags, compiler binary hash).
3. **Parallel compilation**: With a proper DAG, independent compilation units can be built in parallel.
4. **Plugin architecture**: Allow modules to register custom build steps via a well-defined interface rather than `@bmk` pragmas.
5. **Enhanced version checking**: Integrate with Phase 3g's compiler directives so build decisions can be made based on tool versions.

---

## 4. Specific Code Areas to Modify

### type.bmx
- `TFunctionPtrType.EqualsType()` (line 2191): Add `T_VAR` flag check
- `TFunctionPtrType.ExtendsType()` (line 2204): Fix variance direction
- Add `TFunctionPtrType.ToString()` for better error messages

### expr.bmx
- `TArrayExpr.Semant()` (line 2963): Handle `TNullType` in function pointer arrays
- `TArrayExpr.Semant()` (line 2974): Fix `TFunctionPtrType` balancing with null
- Add new `TFuncRefExpr` node type for function references
- Add new `TTernaryExpr` node type (Phase 3)

### decl.bmx
- `TClassDecl.GenInstance()` (line ~2770): Add re-entrancy guard, fix nested generic resolution, add cross-file tracking
- `TFuncDecl.Semant()` (line ~2172): Clean up function pointer scope handling
- Global state (`_env`, `_envStack`, `_appInstance`) to be encapsulated (Phase 4)

### ctranslator.bmx
- `TransValue()` (line ~617): Emit typed casts for null function pointer sentinels
- `TransGlobalInit()` (line ~7090): Emit casts for `Byte Ptr` to function pointer assignments
- `TransAssignStmt()` (line ~3377): Ensure casts on all function pointer assignments
- All `&brl_blitz_NullFunctionError` references: Replace with properly-typed wrappers

### parser.bmx
- Add ternary operator parsing (Phase 3)
- Add enhanced conditional directive parsing (Phase 3)

### toker.bmx
- Add version comparison operators for conditional compilation (Phase 3)

---

## 5. Testing Strategy

### Unit Tests (per fix)
- Each bug fix gets a test case in `tests/framework/language/`
- Function pointer tests: assignment, arrays, null handling, variance, callbacks
- Generic tests: cross-file, nested, recursive, with constraints

### Regression Tests
- Existing test suite must continue passing
- Add the reproduction cases from each issue as regression tests

### Integration Tests
- Build real-world modules (brl.collections, pub.openal) with the fixed compiler
- Test with GCC 12, 13, 14 to ensure generated C code is standards-compliant

---

## 6. Risk Assessment

| Risk | Mitigation |
|------|------------|
| Function pointer refactor breaks existing code | Comprehensive test suite; keep old codegen path behind a flag initially |
| Generic re-entrancy fix introduces infinite loops | Add depth limit to `GenInstance()` recursion |
| AST redesign is too large to land at once | Do it incrementally: first extract types, then visitors, then eliminate globals |
| Build system changes break module compilation | Maintain backwards compatibility with existing `.bmx` cache format initially |

---

## 7. Timeline Summary

| Phase | Duration | Key Deliverables |
|-------|----------|-----------------|
| Phase 1 | Weeks 1-3 | Critical bug fixes for function pointers (#662, #686, #681, #664) and generics (#753, #501, #724) |
| Phase 2 | Weeks 4-6 | Function pointer subsystem refactor, function pointer arrays working (#626, #484, #562) |
| Phase 3 | Weeks 7-12 | New features: ternary, jump-table switch, enhanced directives, named params, case sensitivity, const arrays |
| Phase 4 | Weeks 13-20 | AST redesign, build system overhaul, visitor pattern, elimination of global state |
