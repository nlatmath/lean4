inductive Expr where
  | app (f : String) (args : Array Expr)

def Expr.size (e : Expr) : Nat := Id.run do
  match e with
  | app f args =>
    let mut sz := 1
    for h : i in [: args.size] do
      sz := sz + size (args.get ⟨i, h.upper⟩)
    return sz
