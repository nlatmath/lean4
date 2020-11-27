/-
Copyright (c) 2020 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura, Sebastian Ullrich
-/
import Std.ShareCommon
import Lean.Util.CollectLevelParams
import Lean.Util.FoldConsts
import Lean.Elab.CollectFVars
import Lean.Elab.Command
import Lean.Elab.SyntheticMVars
import Lean.Elab.Binders
import Lean.Elab.DeclUtil
namespace Lean.Elab

inductive DefKind where
  | «def» | «theorem» | «example» | «opaque» | «abbrev»

def DefKind.isTheorem : DefKind → Bool
  | «theorem» => true
  | _         => false

def DefKind.isDefOrAbbrevOrOpaque : DefKind → Bool
  | «def»    => true
  | «opaque» => true
  | «abbrev» => true
  | _        => false

def DefKind.isExample : DefKind → Bool
  | «example» => true
  | _         => false

structure DefView where
  kind          : DefKind
  ref           : Syntax
  modifiers     : Modifiers
  declId        : Syntax
  binders       : Syntax
  type?         : Option Syntax
  value         : Syntax

namespace Command

open Meta

def mkDefViewOfAbbrev (modifiers : Modifiers) (stx : Syntax) : DefView :=
  -- parser! "abbrev " >> declId >> optDeclSig >> declVal
  let (binders, type) := expandOptDeclSig (stx.getArg 2)
  let modifiers       := modifiers.addAttribute { name := `inline }
  let modifiers       := modifiers.addAttribute { name := `reducible }
  { ref := stx, kind := DefKind.abbrev, modifiers := modifiers,
    declId := stx.getArg 1, binders := binders, type? := type, value := stx.getArg 3 }

def mkDefViewOfDef (modifiers : Modifiers) (stx : Syntax) : DefView :=
  -- parser! "def " >> declId >> optDeclSig >> declVal
  let (binders, type) := expandOptDeclSig (stx.getArg 2)
  { ref := stx, kind := DefKind.def, modifiers := modifiers,
    declId := stx.getArg 1, binders := binders, type? := type, value := stx.getArg 3 }

def mkDefViewOfTheorem (modifiers : Modifiers) (stx : Syntax) : DefView :=
  -- parser! "theorem " >> declId >> declSig >> declVal
  let (binders, type) := expandDeclSig (stx.getArg 2)
  { ref := stx, kind := DefKind.theorem, modifiers := modifiers,
    declId := stx.getArg 1, binders := binders, type? := some type, value := stx.getArg 3 }

namespace MkInstanceName

-- Table for `mkInstanceName`
private def kindReplacements : NameMap String :=
  Std.RBMap.ofList [
    (`Lean.Parser.Term.depArrow, "DepArrow"),
    (`Lean.Parser.Term.«forall», "Forall"),
    (`Lean.Parser.Term.arrow, "Arrow"),
    (`Lean.Parser.Term.prop,  "Prop"),
    (`Lean.Parser.Term.sort,  "Sort"),
    (`Lean.Parser.Term.type,  "Type")
  ]

abbrev M := StateRefT String CommandElabM

def isFirst : M Bool :=
  return (← get) == ""

def append (str : String) : M Unit :=
  modify fun s => s ++ str

partial def collect (stx : Syntax) : M Unit := do
  match stx with
  | Syntax.node k args =>
    unless (← isFirst) do
      match kindReplacements.find? k with
      | some r => append r
      | none   => pure ()
    for arg in args do
      collect arg
  | Syntax.ident (preresolved := preresolved) .. =>
    unless preresolved.isEmpty && (← resolveGlobalName stx.getId).isEmpty do
      match stx.getId.eraseMacroScopes with
      | Name.str _ str _ =>
          if str[0].isLower then
            append str.capitalize
          else
            append str
      | _ => pure ()
  | _ => pure ()

def mkFreshInstanceName : CommandElabM Name := do
  let s ← get
  let idx := s.nextInstIdx
  modify fun s => { s with nextInstIdx := s.nextInstIdx + 1 }
  return Lean.Elab.mkFreshInstanceName s.env idx

partial def main (type : Syntax) : CommandElabM Name := do
  /- We use `expandMacros` to expand notation such as `x < y` into `HasLess.Less x y` -/
  let type ← liftMacroM <| expandMacros type
  let (_, str) ← collect type |>.run ""
  if str.isEmpty then
     mkFreshInstanceName
  else
    let name := Name.mkSimple ("inst" ++ str)
    let currNamespace ← getCurrNamespace
    if (← getEnv).contains (currNamespace ++ name) then
      let rec loop (idx : Nat) :=
         let name := name.appendIndexAfter idx
         if (← getEnv).contains (currNamespace ++ name) then
           loop (idx+1)
         else
           name
      return loop 1
    else
      return name

end MkInstanceName

def mkDefViewOfConstant (modifiers : Modifiers) (stx : Syntax) : CommandElabM DefView := do
  -- parser! "constant " >> declId >> declSig >> optional declValSimple
  let (binders, type) := expandDeclSig (stx.getArg 2)
  let val ← match (stx.getArg 3).getOptional? with
    | some val => pure val
    | none     =>
      let val ← `(arbitrary)
      pure $ Syntax.node `Lean.Parser.Command.declValSimple #[ mkAtomFrom stx ":=", val ]
  return {
    ref := stx, kind := DefKind.opaque, modifiers := modifiers,
    declId := stx.getArg 1, binders := binders, type? := some type, value := val
  }

def mkDefViewOfInstance (modifiers : Modifiers) (stx : Syntax) : CommandElabM DefView := do
  -- parser! "instance " >> optional declId >> declSig >> declVal
  let (binders, type) := expandDeclSig (stx.getArg 2)
  let modifiers       := modifiers.addAttribute { name := `instance }
  let declId ← match (stx.getArg 1).getOptional? with
    | some declId => pure declId
    | none        =>
      let id ← MkInstanceName.main type
      pure <| Syntax.node `Lean.Parser.Command.declId #[mkIdentFrom stx id, mkNullNode]
  return {
    ref := stx, kind := DefKind.def, modifiers := modifiers,
    declId := declId, binders := binders, type? := type, value := stx.getArg 3
  }

def mkDefViewOfExample (modifiers : Modifiers) (stx : Syntax) : DefView :=
  -- parser! "example " >> declSig >> declVal
  let (binders, type) := expandDeclSig (stx.getArg 1)
  let id              := mkIdentFrom stx `_example
  let declId          := Syntax.node `Lean.Parser.Command.declId #[id, mkNullNode]
  { ref := stx, kind := DefKind.example, modifiers := modifiers,
    declId := declId, binders := binders, type? := some type, value := stx.getArg 2 }

def isDefLike (stx : Syntax) : Bool :=
  let declKind := stx.getKind
  declKind == `Lean.Parser.Command.«abbrev» ||
  declKind == `Lean.Parser.Command.«def» ||
  declKind == `Lean.Parser.Command.«theorem» ||
  declKind == `Lean.Parser.Command.«constant» ||
  declKind == `Lean.Parser.Command.«instance» ||
  declKind == `Lean.Parser.Command.«example»

def mkDefView (modifiers : Modifiers) (stx : Syntax) : CommandElabM DefView :=
  let declKind := stx.getKind
  if declKind == `Lean.Parser.Command.«abbrev» then
    pure $ mkDefViewOfAbbrev modifiers stx
  else if declKind == `Lean.Parser.Command.«def» then
    pure $ mkDefViewOfDef modifiers stx
  else if declKind == `Lean.Parser.Command.«theorem» then
    pure $ mkDefViewOfTheorem modifiers stx
  else if declKind == `Lean.Parser.Command.«constant» then
    mkDefViewOfConstant modifiers stx
  else if declKind == `Lean.Parser.Command.«instance» then
    mkDefViewOfInstance modifiers stx
  else if declKind == `Lean.Parser.Command.«example» then
    pure $ mkDefViewOfExample modifiers stx
  else
    throwError "unexpected kind of definition"

builtin_initialize registerTraceClass `Elab.definition

end Command
end Lean.Elab
