import Lean
import Std.Lean.PersistentHashSet
-- import Leaff.Deriving.Optics
import Leaff.Hash
import Leaff.HashSet
-- import Std.Lean.HashMap


/-!
# Leaff (Lean Diff) core

## Main types
- `Trait` hashable functions of `ConstantInfo`'s and environments used to determine whether two constants are different
- `Diff` the type of a single human understandable difference between two environments


## Design
We consider diffs coming from 3 different sources
- Constants (defs, lemmas, axioms, etc)
- Environment extensions (attributes, docstrings, etc)
- Imports (direct and transitive)

## TODO
- is there a way to include defeq checking in this?
  for example if a type changes but in a defeq way
- make RFC to core to upgrade hashing algo
- make core issue for hash of bignums
- make unit tests

-/
open Lean

-- TODO upstream??
def moduleName (env : Environment) (n : Name) : Name :=
match env.getModuleIdxFor? n with
| some modIdx => env.allImportedModuleNames[modIdx.toNat]!
| none => env.mainModule

/--
Traits are functions from `ConstantInfo` and the environment
to some hashable type `α` that when changed,
results in some meaningful difference between two constants.
For instance the type, name, value of a constant, or whether it is an axiom,
theorem, or definition. -/
structure Trait :=
  /-- the target type, could be a name, expr, string, etc -/
  α : Type
  /-- the value of a constants trait in the given environment -/
  val : ConstantInfo → Environment → α
  id : Name := by exact decl_name%
  [ins : Hashable α]
  [ts : ToString α] -- for debugging

instance : BEq Trait where
  beq a b := a.id == b.id
instance : Repr Trait where
  reprPrec a := reprPrec a.id
instance {t : Trait} : Hashable t.α := t.ins
instance {t : Trait} : ToString t.α := t.ts

def Trait.mk' (α : Type) [Hashable α] [ToString α] (val : ConstantInfo → Environment → α) (name : Name := by exact decl_name%) :
  Trait := ⟨α, val, name⟩
namespace Trait
/-- The type of the constant -/
def type : Trait := Trait.mk' Expr (fun c _ => c.type)

instance : Inhabited Trait := ⟨type⟩

/-- The value of the constant, ie proof -/
def value : Trait := Trait.mk' Expr (fun c _ => c.value!)

/-- The name of the constant -/
def name : Trait := Trait.mk' Name (fun c _ => c.name)
/-- Def, thm, axiom, etc -/
def species : Trait := Trait.mk' Nat fun c _ => (fun
  | .axiomInfo _ => 1 -- "axiom"
  | .defnInfo _ => 2 -- "def"
  | .thmInfo _ => 3 -- "thm"
  | .opaqueInfo _ => 4 -- "opaque"
  | .quotInfo _ => 5 -- "quot"
  | .inductInfo _ => 6 -- "induct"
  | .ctorInfo _ => 7 -- "ctor"
  | .recInfo _ => 8 /-"rec"-/)
  c -- TODO is there a better way to do this

def speciesDescription : ConstantInfo → String
  | .axiomInfo _ => "axiom"
  | .defnInfo _ => "def"
  | .thmInfo _ => "thm"
  | .opaqueInfo _ => "opaque"
  | .quotInfo _ => "quot"
  | .inductInfo _ => "induct"
  | .ctorInfo _ => "ctor"
  | .recInfo _ => "rec"

/-- The module the constant is defined in -/
def module : Trait := Trait.mk' Name (fun c e => moduleName e c.name)

-- TODO add universe vars trait? possibly already covered by type
-- TODO maybe def safety as a trait?
-- TODO maybe reducibility hints

def relevantTraits : List Trait := [name, type, value, species, module]

-- TODO use diffhash type fold1 to remove initial value
@[specialize 1]
def hashExcept (t : Trait) : ConstantInfo → Environment → UInt64 :=
  (relevantTraits.filter (· != t)).foldl (fun h t c e => mixHash (hash (t.val c e)) (h c e)) (fun _ _ => 7) -- TODO 0 or 7...

-- TODO use diffhash type fold1 to remove initial value
@[specialize 1]
def hashExceptMany (t : List Trait) : ConstantInfo → Environment → UInt64 :=
  (relevantTraits.filter (!t.contains ·)).foldl (fun h t c e => mixHash (hash (t.val c e)) (h c e)) (fun _ _ => 7) -- TODO 0 or 7...


end Trait


/-
Copied from mathlib:
Lean 4 makes declarations which are technically not internal
(that is, head string does not start with `_`) but which sometimes should
be treated as such. For example, the `to_additive` attribute needs to
transform `proof_1` constants generated by `Lean.Meta.mkAuxDefinitionFor`.
This might be better fixed in core, but until then, this method can act
as a polyfill. This method only looks at the name to decide whether it is probably internal.
Note: this declaration also occurs as `shouldIgnore` in the Lean 4 file `test/lean/run/printDecls`.
-/
-- def Lean.Name.isInternal' (declName : Name) : Bool :=
--   declName.isInternal ||
--   match declName with
--   | .str _ s => "match_".isPrefixOf s || "proof_".isPrefixOf s
--   | _        => true
-- TODO maybe isBlackListed from mathlib instead? or something else that removes mk.inj and sizeOf_spec

open Lean

-- TODO shorten after https://github.com/leanprover/lean4/pull/3058
deriving instance BEq for ReducibilityHints
deriving instance BEq for DefinitionVal
deriving instance BEq for QuotKind
deriving instance BEq for QuotVal
deriving instance BEq for InductiveVal
deriving instance BEq for ConstantInfo

-- TODO simplify binders (a b : Name)
/--
A type representing single differences between two environments, limited
to changes that a user might wish to see.
-/
inductive Diff : Type
  | added (const : ConstantInfo) (relevantModule : Name) -- TODO use constantinfo in others too
  | removed (const : ConstantInfo) (relevantModule : Name)
  | renamed (oldName newName : Name) (namespaceOnly : Bool) (relevantModule : Name)
  | movedToModule (name oldModuleName newModuleName : Name) -- maybe args here
  | proofChanged (name : Name) (isProofRelevant : Bool) (relevantModule : Name) -- TODO maybe value changed also for defs
  | typeChanged (name : Name) (relevantModule : Name)
  | speciesChanged (name : Name) (fro to : String) (relevantModule : Name) -- species is axiom, def, thm, opaque, quot, induct, ctor, rec
  | movedWithinModule (name : Name) (relevantModule : Name)
  | extensionEntriesModified (ext : Name) -- TODO maybe delete?
  | docChanged (name : Name) (relevantModule : Name) -- TODO how does module/other doc fit in here
  | docAdded (name : Name) (relevantModule : Name)
  | docRemoved (name : Name) (relevantModule : Name)
  | moduleAdded (name : Name)
  | moduleRemoved (name : Name)
  | moduleRenamed (oldName newName : Name)
  | attributeAdded (attrName name : Name) (relevantModule : Name)
  | attributeRemoved (attrName name : Name) (relevantModule : Name)
  | attributeChanged (attrName name : Name) (relevantModule : Name)
  | directImportAdded (module importName : Name) -- these might be pointless
  | directImportRemoved (module importName : Name)
  | transitiveImportAdded (module importName : Name)
  | transitiveImportRemoved (module importName : Name)
-- deriving DecidableEq, Repr
deriving BEq

-- what combinations? all pairs?
-- renamed and proof modified
-- renamed and moved to module


-- TODO maybe variant "optic"s for isBlah that returns all args of blah not just a bool
-- set_option trace.derive_optics true
-- derive_optics Diff

namespace Diff
/-- Priority for displaying diffs, lower numbers are more important and should come first in the output.
These should all be distinct as it is what we use to group diffs also -/
def prio : Diff → Nat
  | .added _ _ => 80
  | .removed _ _ => 90
  | .renamed _ _ false _ => 200
  | .renamed _ _ true _ => 210
  | .movedToModule _ _ _ => 220
  | .movedWithinModule _ _ => 310
  | .proofChanged _ true _ => 110 -- if the declaration is proof relevant (i.e. a def) then it is more important
  | .proofChanged _ _ _ => 250
  | .typeChanged _ _ => 100
  | .speciesChanged _ _ _ _ => 140
  | .extensionEntriesModified _ => 150
  | .docChanged _ _ => 240
  | .docAdded _ _ => 230
  | .docRemoved _ _ => 160
  | .moduleAdded _ => 10
  | .moduleRemoved _ => 20
  | .moduleRenamed _ _ => 30
  | .attributeAdded _ _ _ => 180
  | .attributeRemoved _ _ _ => 190
  | .attributeChanged _ _ _ => 260
  | .directImportAdded _ _ => 195
  | .directImportRemoved _ _ => 270
  | .transitiveImportAdded _ _ => 330
  | .transitiveImportRemoved _ _ => 340
-- TODO maybe order this in src to make it clearer

def mod : Diff → Name
  | .added _ m
  | .removed _ m
  | .renamed _ _ _ m
  | .movedWithinModule _ m
  | .proofChanged _ _ m
  | .typeChanged _ m
  | .speciesChanged _ _ _ m
  | .docChanged _ m
  | .docAdded _ m
  | .docRemoved _ m
  | .moduleAdded m
  | .moduleRemoved m
  | .attributeAdded _ _ m
  | .attributeRemoved _ _ m
  | .directImportAdded m _
  | .directImportRemoved m _
  | .movedToModule _ _ m
  | .moduleRenamed _ m
  | .transitiveImportAdded m _
  | .transitiveImportRemoved m _
  | .attributeChanged _ _ m => m
  | .extensionEntriesModified _ => Name.anonymous

open Std

def mkConstWithLevelParams' (constInfo : ConstantInfo) : Expr :=
mkConst constInfo.name (constInfo.levelParams.map mkLevelParam)

-- TODO can we make the output richer,
-- colours (sort of handled by diff format in github)
-- but could add some widget magic also?
-- links / messagedata in the infoview maybe extracted as links somehow
-- especially for the diffs command
-- could we even have some form of expr diff?
open ToFormat in
def summarize (diffs : List Diff) : MessageData := Id.run do
  if diffs == [] then return "No differences found."
  let mut out : MessageData := "Found differences:" ++ Format.line
  let mut diffs := diffs.toArray
  let _inst : Ord Name := ⟨Name.quickCmp⟩
  let _inst : Ord (Nat × Name) := lexOrd
  let _inst : LT (Nat × Name) := ltOfOrd
  diffs := diffs.qsort (fun a b => (a.prio, a.mod) < (b.prio, b.mod))
  let mut oldmod : Name := Name.anonymous
  for d in diffs do
    let mod := d.mod
    if mod != oldmod then
      oldmod := mod
      out := out ++ m!"@@ {mod} @@\n"
    out := out ++ (match d with
      -- TODO add expr to all of these
      -- TODO see if universe printing can be disabled
      | .added const _                                  => m!"+ added {mkConstWithLevelParams' const}"
      | .removed const _                                 => m!"- removed {mkConstWithLevelParams' const}"
      | .renamed oldName newName true _                 => m!"! renamed {oldName} → {newName} (changed namespace)"
      | .renamed oldName newName false _                => m!"! renamed {oldName} → {newName}"
      | .movedToModule name oldModuleName newModuleName => m!"! moved {name} from {oldModuleName} to {newModuleName}"
      | .movedWithinModule name _                       => m!"! moved {name} within _  ule"
      | .proofChanged name true _                       => m!"! value changed for {name}"
      | .proofChanged name false _                      => m!"! proof changed for {name}"
      | .typeChanged name _                             => m!"! type changed for {name}"
      | .speciesChanged name fro to _                   => m!"! {name} changed from {fro} to {to}"
      | .extensionEntriesModified ext                   => m!"! extension entry modified for {ext}"
      | .docChanged name _                              => m!"! doc modified for {name}"
      | .docAdded name _                                => m!"+ doc added to {name}"
      | .docRemoved name _                              => m!"- doc removed from {name}"
      | .moduleAdded name                               => m!"+ module added {name}"
      | .moduleRemoved name                             => m!"- module removed {name}"
      | .moduleRenamed oldName newName                  => m!"! module renamed {oldName} → {newName}"
      | .attributeAdded attrName name _                 => m!"+ attribute {attrName} added to {name}"
      | .attributeRemoved attrName name _               => m!"- attribute {attrName} removed from {name}"
      | .attributeChanged attrName name _               => m!"! attribute changed to {attrName} or otherwise modified for {name}"
      | .directImportAdded module importName            => m!"+ direct import {importName} added to {module}"
      | .directImportRemoved module importName          => m!"- direct import {importName} removed from {module}"
      | .transitiveImportAdded module importName        => m!"+ transitive import {importName} added to {module}"
      | .transitiveImportRemoved module importName      => m!"- transitive import {importName} removed from {module}")
      ++ "\n"
  out := out ++ m!"{diffs.size} differences"
  pure out

end Diff

namespace PersistentEnvExtension

def getImportedState [Inhabited α] (ext : PersistentEnvExtension (Name × α) (Name × α) (NameMap α)) (env : Environment) : NameMap α :=
RBMap.fromArray (ext.exportEntriesFn (ext.getState env) ++ (ext.toEnvExtension.getState env).importedEntries.flatten) Name.quickCmp

-- TODO use mkStateFromImportedEntries maybe?
end PersistentEnvExtension
namespace MapDeclarationExtension

def getImportedState [Inhabited α] (ext : MapDeclarationExtension α) (env : Environment) : NameMap α :=
RBMap.fromArray ((ext.getEntries env).toArray ++ (ext.toEnvExtension.getState env).importedEntries.flatten) Name.quickCmp

  -- match env.getModuleIdxFor? declName with
  -- | some modIdx =>
  --   match (modIdx).binSearch (declName, default) (fun a b => Name.quickLt a.1 b.1) with
  --   | some e => some e.2
  --   | none   => none
  -- | none => (ext.getState env).find? declName

end MapDeclarationExtension
namespace TagDeclarationExtension

def getImportedState (ext : TagDeclarationExtension) (env : Environment) : NameSet :=
RBTree.fromArray ((ext.getEntries env).toArray ++ (ext.toEnvExtension.getState env).importedEntries.flatten) Name.quickCmp

end TagDeclarationExtension

namespace SimpleScopedEnvExtension

def getImportedState [Inhabited σ] (ext : ScopedEnvExtension α β σ) (env : Environment) : σ :=
ext.getState env

end SimpleScopedEnvExtension

open Lean Environment

namespace Lean.Environment

open Std

def importDiffs (old new : Environment) : List Diff := Id.run do
  let mut out : List Diff := []
  let mut impHeierOld : RBMap Name (List Name) Name.quickCmp := mkRBMap _ _ _ -- TODO can we reuse any lake internals here?
  let mut impHeierNew : RBMap Name (List Name) Name.quickCmp := mkRBMap _ _ _ -- TODO can we reuse any lake internals here?
  let mut idx := 0
  for mod in old.header.moduleNames do
    impHeierOld := impHeierOld.insert mod (old.header.moduleData[idx]!.imports.map Import.module).toList -- TODO notation for such updates
    idx := idx + 1
  idx := 0
  for mod in new.header.moduleNames do
    impHeierNew := impHeierNew.insert mod (new.header.moduleData[idx]!.imports.map Import.module).toList -- TODO notation for such updates
    idx := idx + 1

  for mod in new.header.moduleNames.toList.diff old.header.moduleNames.toList do
    out := .moduleAdded mod :: out
  for mod in old.header.moduleNames.toList.diff new.header.moduleNames.toList do
    out := .moduleRemoved mod :: out
  for mod in new.header.moduleNames.toList ∩ old.header.moduleNames.toList do
    for add in (impHeierNew.findD mod []).diff (impHeierOld.findD mod []) do
      out := .directImportAdded mod add :: out
    for rem in (impHeierOld.findD mod []).diff (impHeierNew.findD mod []) do
      out := .directImportRemoved mod rem :: out
  -- dbg_trace new.header.moduleData[2]!.imports
  pure out
namespace Leaff.Lean.HashMap

variable [BEq α] [Hashable α]
/-- copied from Std, we copy rather than importing to reduce the std dependency
and make changing the Lean version used by Leaff easier (hopefully) -/
instance : ForIn m (HashMap α β) (α × β) where
  forIn m init f := do
    let mut acc := init
    for buckets in m.val.buckets.val do
      for d in buckets do
        match ← f d acc with
        | .done b => return b
        | .yield b => acc := b
    return acc
end Leaff.Lean.HashMap


-- TODO upstream
instance [BEq α] [Hashable α] : ForIn m (SMap α β) (α × β) where
  forIn t init f := do
    forIn t.map₂ (← forIn t.map₁ init f) f

-- TODO upstream
deriving instance BEq for DeclarationRanges
deriving instance BEq for ReducibilityStatus

instance : ToString ReducibilityStatus where
  toString
    | ReducibilityStatus.reducible => "reducible"
    | ReducibilityStatus.semireducible => "semireducible"
    | ReducibilityStatus.irreducible => "irreducible"

open private docStringExt in Lean.findDocString?

/-- Take the diff between an old and new state of some environment extension,
at the moment we hardcode the extensions we are interested in, as it is not clear how we can go beyond that. -/
def diffExtension (old new : Environment)
    (ext : PersistentEnvExtension EnvExtensionEntry EnvExtensionEntry EnvExtensionState)
    (renames : NameMap Name)
    (revRenames : NameMap Name)
    (ignoreInternal : Bool := true) :
    IO (List Diff) := do
  -- let oldSt := ext.getState old
  -- let newSt := ext.getState new
  -- if ptrAddrUnsafe oldSt == ptrAddrUnsafe newSt then return none
  -- dbg_trace oldSt.importedEntries
  -- dbg_trace ext.statsFn oldSt
  -- dbg_trace ext.statsFn newSt
  -- let oldEntries := ext.exportEntriesFn oldSt
  -- let newEntries := ext.exportEntriesFn newSt
  -- dbg_trace oldEntries.size
  -- dbg_trace newEntries.size
  -- dbg_trace ext.name
  let mut out := []
  -- TODO map exts could be way more efficient, we already have sorted arrays of imported entries
  match ext.name with
  | ``Lean.declRangeExt => if false then do -- TODO turn this into a configurable option
      let os := MapDeclarationExtension.getImportedState declRangeExt old
      let ns := MapDeclarationExtension.getImportedState declRangeExt new
      for (a, b) in ns do
        if ignoreInternal && a.isInternalDetail then continue
        if os.find? (revRenames.findD a a) != b then
          out := .movedWithinModule a (moduleName new a) :: out
  | `Lean.docStringExt => do -- Note this is ` not ``, as docStringExt is actually private
      let os := MapDeclarationExtension.getImportedState docStringExt old
      let ns := MapDeclarationExtension.getImportedState docStringExt new
      for (a, doc) in ns do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! os.contains (revRenames.findD a a) then
          out := .docAdded a (moduleName new a) :: out
        else
          if os.find! (revRenames.findD a a) != doc then
            out := .docChanged a (moduleName new a) :: out
      for (a, _b) in os do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! ns.contains (renames.findD a a) then
          out := .docRemoved (renames.findD a a) (moduleName new (renames.findD a a)) :: out
  | ``Lean.reducibilityAttrs => do
      let os := PersistentEnvExtension.getImportedState reducibilityAttrs.ext old
      let ns := PersistentEnvExtension.getImportedState reducibilityAttrs.ext new
      for (a, red) in ns do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! os.contains (revRenames.findD a a) then
          out := .attributeAdded (toString red) a (moduleName new a) :: out
        else
          if os.find! (revRenames.findD a a) != red then
            -- TODO specify more
            out := .attributeChanged (toString red) a (moduleName new a) :: out
      for (a, red) in os do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! ns.contains (renames.findD a a) then
          out := .attributeRemoved (toString red) (renames.findD a a) (moduleName new (renames.findD a a)) :: out
  | ``Lean.protectedExt => do
      let os := TagDeclarationExtension.getImportedState protectedExt old
      let ns := TagDeclarationExtension.getImportedState protectedExt new
      for a in ns do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! os.contains (revRenames.findD a a) then
          out := .attributeAdded `protected a (moduleName new a) :: out
      for a in os do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! ns.contains (renames.findD a a) then
          out := .attributeRemoved `protected (renames.findD a a) (moduleName new (renames.findD a a)) :: out
  | ``Lean.noncomputableExt => do
      let os := TagDeclarationExtension.getImportedState noncomputableExt old
      let ns := TagDeclarationExtension.getImportedState noncomputableExt new
      for a in ns do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! os.contains (revRenames.findD a a) then
          out := .attributeAdded `noncomputable a (moduleName new a) :: out
      for a in os do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! ns.contains (renames.findD a a) then
          out := .attributeRemoved `noncomputable (renames.findD a a) (moduleName new (renames.findD a a)) :: out
  | ``Lean.Meta.globalInstanceExtension => do -- TODO test this, is this the relevant ext?
      let os := Lean.Meta.globalInstanceExtension.getState old
      let ns := Lean.Meta.globalInstanceExtension.getState new
      for (a, _) in ns do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! os.contains (revRenames.findD a a) then
          out := .attributeAdded `instance a (moduleName new a) :: out
      for (a, _) in os do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! ns.contains (renames.findD a a) then
          out := .attributeRemoved `instance (renames.findD a a) (moduleName new (renames.findD a a)) :: out
  | ``Lean.Meta.simpExtension =>
      let os := SimpleScopedEnvExtension.getImportedState Meta.simpExtension old |>.lemmaNames
      let ns := SimpleScopedEnvExtension.getImportedState Meta.simpExtension new |>.lemmaNames
      for a in ns do
        if ignoreInternal && a.key.isInternalDetail then
          continue
        if ! os.contains a then --(revRenames.findD a.key a.key) then TODO
          out := .attributeAdded `simp a.key (moduleName new a.key) :: out
      for a in os do
        if ignoreInternal && a.key.isInternalDetail then
          continue
        if ! ns.contains a then -- TODO (renames.findD a a) then
          out := .attributeRemoved `simp (renames.findD a.key a.key) (moduleName new (renames.findD a.key a.key)) :: out
  -- TODO maybe alias
  -- TODO maybe implementedBy
  -- TODO maybe export?
  -- declrange (maybe as an option)
  -- simp
  -- computable markers?
  -- coe?
  -- reducible?
  -- namespaces?
  -- docString, moduleDoc
  -- | ``Lean.classExtension => do
  --     dbg_trace "class"
  --     dbg_trace (SimplePersistentEnvExtension.getState classExtension new).outParamMap.toList
      -- for (a, b) in SimplePersistentEnvExtension.getState docStringExt new do
      --   if ! (SimplePersistentEnvExtension.getState docStringExt old).contains a then
      --     out := .docAdded a :: out
      --   else
      --     if (SimplePersistentEnvExtension.getState docStringExt old).find! a != b then
      --       out := .docChanged a :: out
      -- for (a, _b) in SimplePersistentEnvExtension.getState docStringExt old do
      --   if ! (SimplePersistentEnvExtension.getState docStringExt new).contains a then
      --     out := .docRemoved a :: out
  | ``Lean.Linter.deprecatedAttr => do
      let os := Lean.Linter.deprecatedAttr.ext.getState old
      let ns := Lean.Linter.deprecatedAttr.ext.getState new
      for (a, _b) in ns do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! os.contains (revRenames.findD a a) then
          out := .attributeAdded `deprecated a (moduleName new a) :: out
      for (a, _b) in os do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! ns.contains (renames.findD a a) then
          out := .attributeRemoved `deprecated (renames.findD a a) (moduleName new (renames.findD a a)) :: out
  | ``Lean.classExtension => do
      let os := classExtension.getState old
      let ns := classExtension.getState new
      for (a, _b) in ns.outParamMap do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! os.outParamMap.contains (revRenames.findD a a) then
          out := .attributeAdded `class a (moduleName new a) :: out
      for (a, _b) in os.outParamMap do
        if ignoreInternal && a.isInternalDetail then
          continue
        if ! ns.outParamMap.contains (renames.findD a a) then
          out := .attributeRemoved `class (renames.findD a a) (moduleName new (renames.findD a a)) :: out
  | _ => pure ()
    -- if newEntries.size ≠ oldEntries.size then
    -- -- m!"-- {ext.name} extension: {(newEntries.size - oldEntries.size : Int)} new entries"
    --   out := .extensionEntriesModified ext.name :: out
  return out

def extDiffs (old new : Environment) (renames : NameMap Name) (ignoreInternal : Bool := true) : IO (List Diff) := do
  let mut out : List Diff := []
  let mut revRenames := mkNameMap Name
  for (o, n) in renames do
    revRenames := revRenames.insert n o
  for ext in ← persistentEnvExtensionsRef.get do
    out := (← diffExtension old new ext renames revRenames ignoreInternal) ++ out
  pure out

-- TODO consider implementing some of the following
-- Lean.namespacesExt
-- Lean.aliasExtension
-- Lean.attributeExtension what is this? the list of all attrs, can we leverage somehow
-- Lean.Compiler.nospecializeAttr
-- Lean.Compiler.specializeAttr
-- Lean.externAttr
-- Lean.Compiler.implementedByAttr
-- Lean.neverExtractAttr
-- Lean.exportAttr
-- Lean.Compiler.CSimp.ext
-- Lean.Meta.globalInstanceExtension
-- Lean.structureExt
-- Lean.matchPatternAttr
-- Lean.Meta.instanceExtension
-- Lean.Meta.defaultInstanceExtension
-- Lean.Meta.coeDeclAttr
-- Lean.moduleDocExt
-- Lean.Meta.customEliminatorExt
-- Lean.Elab.Term.elabWithoutExpectedTypeAttr
-- Lean.Elab.Term.elabAsElim
-- Lean.Meta.recursorAttribute
-- Lean.Meta.simpExtension
-- Lean.Meta.congrExtension
-- Std.Tactic.Alias.aliasExt

open Trait

def diffHash (c : ConstantInfo) (e : Environment) : UInt64 :=
-- TODO it would be nice if there was a Haskell style foldl1 for this
relevantTraits.tail.foldl (fun h t => mixHash (hash (t.val c e)) h) (hash <| relevantTraits.head!.val c e)
-- this should essentially reduce to
-- mixHash (hash <| module.val c e) <| mixHash (hash <| species.val c e) <| mixHash (hash <| name.val c e) <| mixHash (type.val c e |>.hash) (value.val c e |>.hash)

/-- the list of trait combinations used below -/
def traitCombinations : List (List Trait) := [[name],[value],[name, value],[type],[type, value],[module],[name,module],[value,module],[type,module],[name, value, module],[type, value, module],[species]]
def constantDiffs (old new : Environment) (ignoreInternal : Bool := true) : List Diff := Id.run do
  -- dbg_trace new.header.moduleNames
  -- dbg_trace new.header.moduleData[2]!.imports
  -- TODO should we use rbmap or hashmap?
  -- let oldhashes := (HashMap.fold (fun old name const =>
  --   let ha := (diffHash const)
  -- let (all, ex) := (HashMap.fold (fun (all, ex) name const =>
  --   if const.hasValue && ! name.isInternal then (all + 1, ex + 1) else (all + 1, ex)) (0,0) old.constants)
  -- dbg_trace (all, ex)
  --   old.insert ha <| (old.findD ha #[]).push name) (mkRBMap UInt64 (Array Name) Ord.compare) old.constants)
  -- sz is roughly how many non-internal decls we expect, empirically around 1/4th of total
  -- TODO change if internals included
  let sz := max (new.constants.size / 4) (old.constants.size / 4)

  -- first we make a hashmap of all decls, hashing with `diffHash`, this should cut the space of "interesting" decls down drastically
  -- TODO reconsider internals, how useful are they
  -- TODO exclude casesOn recOn?
  -- dbg_trace "making hashes"
  let oldhashes := old.constants.fold
    (fun old name const =>
      if const.hasValue && (!ignoreInternal || !name.isInternalDetail) then old.insert name else old)
    (@mkHashSet Name _ ⟨fun n => diffHash (old.constants.find! n) old⟩ sz)
  -- dbg_trace old.constants.size
  -- dbg_trace oldhashes.size
  -- dbg_trace "hashes1 made"
  let newhashes := new.constants.fold
    (fun old name const =>
      if const.hasValue && (!ignoreInternal || !name.isInternalDetail) then old.insert name else old)
    (@mkHashSet Name _ ⟨fun n => diffHash (new.constants.find! n) new⟩ sz)
  -- dbg_trace "hash2 made"
  -- out := out ++ (newnames.sdiff oldnames).toList.map .added
  -- out := out ++ (oldnames.sdiff newnames).toList.map .removed
  -- dbg_trace out.length
  -- dbg_trace (HashSet.sdiff oldhashes newhashes).toList
  let diff := (HashSet.sdiff oldhashes newhashes).toArray
  -- dbg_trace "diffs made"
  let befores := diff.filterMap (fun (di, bef) => if bef then some (old.constants.find! di) else none)
  let afters := diff.filterMap (fun (di, bef) => if bef then none else some (new.constants.find! di))
  -- dbg_trace "bas made"
  -- dbg_trace befores.map ConstantInfo.name
  -- dbg_trace afters.map ConstantInfo.name
  -- dbg_trace afters.size
  -- -- dbg_trace dm.map (fun (c, rem) => (c.name, rem))
  -- TODO could use hashset here for explained
  let mut out : List Diff := []
  let mut explained : HashSet (Name × Bool) := HashSet.empty
  for t in traitCombinations.toArray.qsort (fun a b => a.length < b.length) do -- TODO end user should be able to customize which traits
    let f := hashExceptMany t
    let mut hs : HashMap UInt64 (Name × Bool) := HashMap.empty
    let mut co := true
    -- TODO actually check trait differences when found here!?
    for b in befores do
      let a := hs.findEntry? (f b old)
      if !explained.contains (b.name, true) then
        (hs, co) := hs.insert' (f b old) (b.name, true)
        if co then dbg_trace s!"collision when hashing for {t.map Trait.id}, all bets are off {b.name} {a.get!.2}" -- TODO change to err print
    -- dbg_trace s!"{t.id}"
    -- dbg_trace s!"{hs.toList}"
    for a in afters do
      if explained.contains (a.name, false) then
        continue
      -- dbg_trace a.name
      -- dbg_trace f a new
      -- [name, type, value, species, module] -- TODO check order
      -- TODO can we make this cleaner
      if let some (bn, _) := hs.find? (f a new) then
        if t == [name] then
          out := .renamed bn a.name false (moduleName new a.name) :: out -- TODO namespace only?
          explained := explained.insert (a.name, false) |>.insert (bn, true)
        if t == [value] then
          out := .proofChanged a.name false (moduleName new a.name) :: out -- TODO check if proof relevant
          explained := explained.insert (a.name, false) |>.insert (bn, true)
        if t == [name, value] then
          out := .renamed bn a.name false (moduleName new a.name) :: out -- TODO namespace only?
          out := .proofChanged a.name false (moduleName new a.name) :: out -- TODO check if proof relevant
          explained := explained.insert (a.name, false) |>.insert (bn, true)
        if t == [type] then -- this is very unlikely, that the type changes but not the value
          out := .typeChanged a.name (moduleName new a.name) :: out
          explained := explained.insert (a.name, false) |>.insert (bn, true)
        if t == [type, value] then
          out := .typeChanged a.name (moduleName new a.name) :: out
          out := .proofChanged a.name false (moduleName new a.name) :: out -- TODO check if proof relevant
          explained := explained.insert (a.name, false) |>.insert (bn, true)
        if t == [name, value, module] then
          out := .renamed bn a.name false (moduleName new a.name) :: out -- TODO namespace only?
          out := .proofChanged a.name false (moduleName new a.name) :: out -- TODO check if proof relevant
          out := .movedToModule a.name (moduleName old bn) (moduleName new a.name) :: out
          explained := explained.insert (a.name, false) |>.insert (bn, true)
        if t == [type, value, module] then
          out := .typeChanged a.name (moduleName new a.name) :: out
          out := .proofChanged a.name false (moduleName new a.name) :: out -- TODO check if proof relevant
          out := .movedToModule a.name (moduleName old bn) (moduleName new a.name) :: out
          explained := explained.insert (a.name, false) |>.insert (bn, true)
        if t == [species] then
          out := .speciesChanged a.name (speciesDescription (new.constants.find! bn)) (speciesDescription a) (moduleName new a.name) :: out
          explained := explained.insert (a.name, false) |>.insert (bn, true)
        if t.contains module then -- TODO finish this switch?
          out := .movedToModule a.name (moduleName old bn) (moduleName new a.name) :: out
          explained := explained.insert (a.name, false) |>.insert (bn, true)
  -- dbg_trace "final"
  for a in afters do
    if !explained.contains (a.name, false) then out := .added a (moduleName new a.name) :: out
  for b in befores do
    if !explained.contains (b.name, true) then out := .removed b (moduleName old b.name) :: out
  pure out

/-- for debugging purposes -/
def _root_.Leaff.printHashes (name : Name) : MetaM Unit := do
  let env ← getEnv
  let c := env.find? name
  match c with
  | none => IO.println "not found"
  | some c => do
  let mut out := ""
  for t in relevantTraits do
    IO.println s!"{t.id} {t.val c env}"
    IO.println s!"{hash (t.val c env)}"
    IO.println s!"{t.hashExcept c env}"
  IO.println out

/-- Some diffs are not interesting given then presence of others, so filter the list to remove them.
For instance if a decl is removed, then so will all of its attributes. -/
def minimizeDiffs (diffs : List Diff) : List Diff := Id.run do
  let mut init := diffs
  -- TODO do this for modules too
  -- TODO consider if we want to have added constants not display attributes added
  for diff in init do
    if let .removed n _ := diff then
      init := init.filter fun
        | .docRemoved m _ => m != n.name
        | .attributeRemoved _ m _ => m != n.name
        -- TODO more here
        | _ => true
  pure init

def extractRenames (diffs : List Diff) : NameMap Name := Id.run do
  let mut out := mkNameMap Name
  for diff in diffs do
    match diff with
    | .renamed old new _ _ => out := out.insert old new
    | _ => pure ()
  pure out

-- TODO make this not IO and pass exts in, perhaps
def diff (old new : Environment) (ignoreInternal : Bool := true) : IO (List Diff) := do
  let cd := constantDiffs old new ignoreInternal
  let renames := extractRenames cd
  pure <|
    minimizeDiffs <| cd ++
    importDiffs old new ++
    (← extDiffs old new renames ignoreInternal)

end Lean.Environment

unsafe
def summarizeDiffImports (oldImports newImports : Array Import) (old new : SearchPath) : IO Unit := timeit "total" <| do
  searchPathRef.set old
  let opts := Options.empty
  let trustLevel := 1024 -- TODO actually think about this value
  try
    withImportModules oldImports opts trustLevel fun oldEnv => do
      -- TODO could be really clever here instead of passing search paths around and try and swap the envs in place
      -- to reduce the need for multiple checkouts, but that seems complicated, and potentially unsafe as mmap is used to load oleans from disk
      searchPathRef.set new
      withImportModules newImports opts trustLevel fun newEnv => do
        IO.println <| ← (Diff.summarize (← oldEnv.diff newEnv)).format
  catch e =>
    if e.toString.drop (e.toString.length - 14) == "invalid header" then
      throw <| IO.userError r"invalid .olean file header, likely due to a Lean version mismatch
        you may wish to disable CHECK_OLEAN_VERSION / LEAN_CHECK_OLEAN_VERSION in your Lean build,
        or manually adjust the Lean version used by Leaff and hope for the best"
    else
      throw e

section cmd

open Lean Elab Command

-- implementation based on whatsnew by Gabriel Ebner

-- TODO add ! variant
-- TODO make ! variant macro expand
/-- `diff in $command` executes the command and then prints the
environment diff -/
elab "diff " "in" ppLine cmd:command : command => do
  let oldEnv ← getEnv
  try
    elabCommand cmd
  finally
    let newEnv ← getEnv
    logInfo (Diff.summarize <| ← oldEnv.diff newEnv)

/-- `diffs in $command` executes a sequence of commands and then prints the
environment diff -/
elab "diffs " ig:"!"? "in" ppLine cmd:command* ("end diffs")? : command => do
  let oldEnv ← getEnv
  try
    for cmd in cmd do
      elabCommand cmd
  finally
    let newEnv ← getEnv
    logInfo (Diff.summarize <| ← oldEnv.diff newEnv ig.isNone)

end cmd

diffs in
@[deprecated]
noncomputable
def a:=1
-- diffs in
-- attribute [reducible] a
