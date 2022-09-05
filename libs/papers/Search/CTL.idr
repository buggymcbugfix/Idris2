||| The content of this module is based on the paper
||| Applications of Applicative Proof Search
||| by Liam O'Connor
||| https://doi.org/10.1145/2976022.2976030

module Search.CTL

import Data.Nat
import Data.List.Lazy
import Data.List.Quantifiers
import Data.List.Lazy.Quantifiers

import public Search.Negation
import public Search.HDecidable
import public Search.Properties

%default total

------------------------------------------------------------------------
-- Type and some basic functions

||| Labeled transition diagram
public export
record Diagram (labels : Type) (state : Type) where
  constructor TD
  ||| Transition function
  transFn : (labels, state) -> List (labels, state)
  ||| Initial state
  iState : labels

%name Diagram td,td1,td2

||| Parallel composition of transition diagrams
public export
pComp :  {Lbls1, Lbls2, Sts : _}
      -> (td1 : Diagram Lbls1 Sts)
      -> (td2 : Diagram Lbls2 Sts)
      -> Diagram (Lbls1, Lbls2) Sts
pComp (TD transFn1 iState1) (TD transFn2 iState2) =
  TD compTransFn (iState1, iState2)
  where
    compTransFn : ((Lbls1, Lbls2), Sts) -> List ((Lbls1, Lbls2), Sts)
    compTransFn = (\ ((l1, l2), st) => 
                    map (\ (l1', st') => ((l1', l2), st')) (transFn1 (l1, st)) ++
                    map (\ (l2', st') => ((l1, l2'), st')) (transFn2 (l2, st)))

-- different formulation of LTE, see also:
-- https://agda.github.io/agda-stdlib/Data.Nat.Base.html#4636
-- thanks @gallais!
public export
data LTE' : (n : Nat) -> (m : Nat) -> Type where
  LTERefl : LTE' m m
  LTEStep : LTE' n m -> LTE' n (S m)

||| Convert LTE' to LTE
lteAltToLTE : {m : _} -> LTE' n m -> LTE n m
lteAltToLTE {m=0} LTERefl = LTEZero
lteAltToLTE {m=(S k)} LTERefl = LTESucc (lteAltToLTE LTERefl)
lteAltToLTE {m=(S m)} (LTEStep s) = lteSuccRight (lteAltToLTE s)


parameters (Lbls, Sts : Type)
  ||| A computation tree (corecursive rose tree?)
  data CT : Type where
    At : (Lbls, Sts) -> LazyList CT -> CT

  ||| Given a transition diagram and a starting value for the shared state,
  ||| construct the computation tree of the given transition diagram.
  covering
  model : Diagram Lbls Sts -> (st : Sts) -> CT
  model (TD transFn iState) st = follow (iState, st)
    where
      follow : (Lbls, Sts) -> CT

      followAll : List (Lbls, Sts) -> List CT
      
      follow st = At st (fromList $ followAll (transFn st))

      followAll [] = []
      followAll (st :: sts) = follow st :: followAll sts
      
  ||| A formula has a bound (for Bounded Model Checking; BMC) and a computation
  ||| tree to check against.
  public export
  Formula : Type
  Formula = (depth : Nat) -> (tree : CT) -> Type

  ||| A tree models a formula if there exists a depth d0 for which the property
  ||| holds for all depths d >= d0.
  -- Called "satisfies" in the paper
  public export
  data Models : (m : CT) -> (f : Formula) -> Type where
    ItModels : (d0 : Nat) -> ({d : Nat} -> (d0 `LTE'` d) -> f d m) -> Models m f

  ------------------------------------------------------------------------
  -- Depth invariance

  ||| Depth-invariance (DI) is when a formula cannot be falsified by increasing
  ||| the search depth.
  public export
  record DepthInv (f : Formula) where
    constructor DI
    prf : {n : Nat} -> {m : CT} -> f n m -> f (S n) m

  ||| A DI-formula holding for a specific depth means the CT models the formula in
  ||| general (we could increase the search depth and still be fine).
  public export
  diModels :  {n : Nat} -> {m : CT} -> {f : Formula} -> {auto d : DepthInv f}
           -> (p : f n m) -> Models m f
  diModels {n} {f} {m} @{(DI diPrf)} p = ItModels n (\ q => diLTE p q)
    where
      diLTE : {n, n' : _} -> f n m -> (ltePrf' : n `LTE'` n') -> f n' m
      diLTE p LTERefl = p
      diLTE p (LTEStep x) = diPrf (diLTE p x)

  ||| A trivially true (TT) formula.
  data TrueF : Formula where
    TT : {n : _} -> {m : _} -> TrueF n m

  ||| A tt formula is depth-invariant.
  TrueDI : DepthInv TrueF
  TrueDI = DI (const TT)

  ------------------------------------------------------------------------
  -- Guards

  namespace Guards
    ||| The formula `Guarded g` is true when the current state satisfies the guard
    ||| `g`.
    public export
    data Guarded : (g : (st : Sts) -> (l : Lbls) -> Type) -> Formula where
      Here :  {st : _} -> {l : _}
           -> {ms : LazyList CT} -> {depth : Nat}
           -> {g : _}
           -> (guardOK : g st l)
           -> Guarded g depth (At (l, st) ms)

    ||| Guarded expressions are depth-inv as the guard does not care about depth.
    public export
    diGuarded : {p : _} -> DepthInv (Guarded p)
    diGuarded {p} = DI prf
      where
        prf : {n : _} -> {m : _} -> Guarded p n m -> Guarded p (S n) m
        prf (Here x) = Here x   -- can be interactively generated!

  ------------------------------------------------------------------------
  -- Conjunction / And

  ||| Conjunction of two `Formula`s
  public export
  record AND' (f, g : Formula) (depth : Nat) (tree : CT) where
    constructor MkAND' --: {n : _} -> {m : _} -> f n m -> g n m -> (AND' f g) n m
    fst : f depth tree
    snd : g depth tree

  ||| Conjunction is depth-invariant
  public export
  diAND' :  {f, g : Formula}
         -> {auto p : DepthInv f}
         -> {auto q : DepthInv g}
         -> DepthInv (AND' f g)
  diAND' @{(DI diP)} @{(DI diQ)} = DI (\ a' => MkAND' (diP a'.fst) (diQ a'.snd))

  ------------------------------------------------------------------------
  -- Always Until

  namespace AU
    ||| A proof that for all paths in the tree, f holds until g does.
    public export
    data AlwaysUntil : (f, g : Formula) -> Formula where
      ||| We've found a place where g holds, so we're done.
      Here : {t : _} -> {n : _} -> g n t -> AlwaysUntil f g (S n) t

      ||| If f still holds and we can recursively show that g holds for all
      ||| possible subpaths in the CT, then all branches have f hold until g does.
      There :  {st : _} -> {lazyCTs : _} -> {n : _}
            -> f n (At st lazyCTs)
            -> All ((AlwaysUntil f g) n) (toList lazyCTs)
            -> AlwaysUntil f g (S n) (At st lazyCTs)

    ||| Provided `f` and `g` are depth-invariant, AlwaysUntil is depth-invariant
    public export
    diAU :  {f,g : _} -> {auto p : DepthInv f} -> {auto q : DepthInv g}
         -> DepthInv (AlwaysUntil f g)
    diAU @{(DI diP)} @{(DI diQ)} = DI prf
      where
        prf :  {d : _} -> {t : _}
            -> AlwaysUntil f g d t
            -> AlwaysUntil f g (S d) t
        prf (Here au) = Here (diQ au)
        prf (There au aus) = There (diP au) (mapAllAU prf aus)
          where
            -- `All.mapProperty` erases the list and so won't work here
            mapAllAU :  {d : _} -> {lt : _}
                     -> (prf : AlwaysUntil f g d t -> AlwaysUntil f g (S d) t)
                     -> All (AlwaysUntil f g d) lt
                     -> All (AlwaysUntil f g (S d)) lt
            mapAllAU prf [] = []
            mapAllAU prf (au :: aus) = (prf au) :: mapAllAU prf aus


  ------------------------------------------------------------------------
  -- Exists Until

  namespace EU
    ||| A proof that somewhere in the tree, there is a path for which f holds
    ||| until g does.
    public export
    data ExistsUntil : (f, g : Formula) -> Formula where
      ||| If g holds here, we've found a branch where we can stop.
      Here : {t : _} -> {n : _} -> g n t -> ExistsUntil f g (S n) t

      ||| If f holds here and any of the further branches have a g, then there is
      ||| a branch where f holds until g does.
      There :  {st : _} -> {ms : _} -> {n : _}
            -> f n (At st ms)
            -> Lazy.Quantifiers.Any.Any (ExistsUntil f g n) ms
            -> ExistsUntil f g (S n) (At st ms)

    ||| Provided `f` and `g` are depth-invariant, ExistsUntil is depth-invariant.
    public export
    diEU :  {f, g : _} -> {auto p : DepthInv f} -> {auto q : DepthInv g}
         -> DepthInv (ExistsUntil f g)
    diEU @{(DI diP)} @{(DI diQ)} = DI prf
      where
        prf :  {d : _} -> {t : _}
            -> ExistsUntil f g d t
            -> ExistsUntil f g (S d) t
        prf (Here eu) = Here (diQ eu)
        prf (There eu eus) = There (diP eu) (mapAnyEU prf eus)
          where
            -- `Any.mapProperty` erases the list and so won't work here
            mapAnyEU :  {d : _} -> {lt : _}
                     -> (prf : ExistsUntil f g d t -> ExistsUntil f g (S d) t)
                     -> Lazy.Quantifiers.Any.Any (ExistsUntil f g d) lt
                     -> Lazy.Quantifiers.Any.Any (ExistsUntil f g (S d)) lt
            mapAnyEU prf (Here x) = Here (prf x)
            mapAnyEU prf (There x) = There (mapAnyEU prf x)


  ------------------------------------------------------------------------
  -- Completed, and the stronger forms of Global

  ||| A completed formula is a formula for which no more successor states exist.
  public export
  data Completed : Formula where
    IsCompleted :  {st : _} -> {n : _} -> {ms : _}
                -> ms === []
                -> Completed n (At st ms)

  ||| A completed formula is depth-invariant (there is nothing more to do).
  public export
  diCompleted : DepthInv Completed
  diCompleted = DI prf
    where
      prf : {d : _} -> {t : _} -> Completed d t -> Completed (S d) t
      prf (IsCompleted p) = IsCompleted p

  ||| We can only handle always global checks on finite paths.
  public export
  alwaysGlobal : (f : Formula) -> Formula
  alwaysGlobal f = (AlwaysUntil f f) `AND'` Completed

  ||| We can only handle exists global checks on finite paths.
  public export
  existsGlobal : (f : Formula) -> Formula
  existsGlobal f = (ExistsUntil f f) `AND'` Completed

  ------------------------------------------------------------------------
  -- Proof search (finally!)

  ||| Model-checking is a half-decider for the formula `f`
  public export
  MC : (f : Formula) -> Type
  MC f = (t : CT) -> (d : Nat) -> HDec (f d t)

  ||| Proof-search combinator for guards.
  public export
  now :  {g : (st : Sts) -> (l : Lbls) -> Type}
      -> {hdec : _}
      -> {auto p : AnHDec hdec}
      -> ((st : Sts) -> (l : Lbls) -> hdec (g st l))
      -> MC (Guarded g)
  now f (At (l, st) ms) d = [| Guards.Here (toHDec (f st l)) |]

  ||| Check if the current state has any successors.
  public export
  isCompleted : MC Completed
  isCompleted (At st ms) _ = IsCompleted <$> isEmpty ms
    where
      ||| Half-decider for whether a list is empty
      isEmpty : {x : _} -> (n : LazyList x) -> HDec (n === [])
      isEmpty [] = yes Refl
      isEmpty (_ :: _) = no

  ||| Conjunction of model-checking procedures.
  public export
  mcAND' : {f, g : Formula} -> MC f -> MC g -> MC (f `AND'` g)
  mcAND' a b m n = [| MkAND' (a m n) (b m n) |]

  ||| Proof-search for `AlwaysUntil`.
  |||
  ||| Evaluates the entire `LazyList` of the state-space, since we need `f U g`
  ||| to hold across every path.
  public export
  auSearch : {f, g : Formula} -> MC f -> MC g -> MC (AlwaysUntil f g)
  auSearch _ _ _ Z = no
  auSearch p1 p2 t@(At st ms) (S n) =  [| AU.Here  (p2 t n) |]
                                   <|> [| AU.There (p1 t n) rest |]
    where
      -- in AlwaysUntil searches, we have to check the entire LazyList
      rest : HDec (All (AlwaysUntil f g n) (toList ms))
      rest = HDecidable.List.all (toList ms) (\ m => auSearch p1 p2 m n)

  ||| Proof-search for `ExistsUntil`.
  |||
  ||| Lazy over the state-space, since `E [f U g]` holds as soon as `f U g` is
  ||| found.
  public export
  euSearch : {f, g : Formula} -> MC f -> MC g -> MC (ExistsUntil f g)
  euSearch _ _ _ Z = no
  euSearch p1 p2 t@(At st ms) (S n) =  [| EU.Here  (p2 t n) |]
                                   <|> [| EU.There (p1 t n) rest |]
    where
      rest : HDec (Lazy.Quantifiers.Any.Any (ExistsUntil f g n) ms)
      rest = HDecidable.LazyList.any ms (\ m => euSearch p1 p2 m n)

