{-# LANGUAGE ScopedTypeVariables, DataKinds, FlexibleContexts, ExistentialQuantification, TypeOperators, TypeFamilies #-}
module Futhark.Representation.ExplicitMemory.IndexFunction.Unsafe
       (
         IxFun
       , Indices
       , Shape
       , ShapeChange
       , rank
       , index
       , iota
       , offsetIndex
       , permute
       , reshape
       , applyInd
       , offsetUnderlying
       , underlyingOffset
       , codomain
       , linearWithOffset
       , rearrangeWithOffset
       , isDirect
         -- * Utility
       , shapeFromInts
       )
       where

import Control.Applicative

import Data.List (sort)
import Data.Singletons.Prelude
import Data.Type.Monomorphic
import Data.Type.Natural hiding (n1, n2)
import Data.Type.Ordinal
import qualified Data.Vector.Sized as Vec
import Proof.Equational
import Data.Type.Equality hiding (outer)
import qualified Text.PrettyPrint.Mainland as PP

import Prelude

import Futhark.Analysis.ScalExp
import Futhark.Representation.AST.Syntax (SubExp(..), DimChange)
import Futhark.Transform.Substitute
import Futhark.Transform.Rename
import Futhark.Util.Truths
import Futhark.Representation.AST.Attributes.Names
import qualified Futhark.Representation.ExplicitMemory.Permutation as Perm
import Futhark.Representation.ExplicitMemory.Permutation
  (Swap (..), Permutation (..))
import qualified Futhark.Representation.ExplicitMemory.IndexFunction as Safe
import qualified Futhark.Representation.ExplicitMemory.SymSet as SymSet
import Language.Futhark.Core
import Futhark.Representation.AST.Pretty (pretty)

data IxFun = forall n . IxFun (SNat ('S n)) (Safe.IxFun ScalExp ('S n))

instance Show IxFun where
  show (IxFun _ fun) = show fun

instance PP.Pretty IxFun where
  ppr (IxFun _ fun) = PP.ppr fun

instance Eq IxFun where
  IxFun (n1 :: SNat ('S n1)) fun1 == IxFun (n2 :: SNat ('S n2)) fun2 =
    case testEquality n1 n2 of
      Nothing   -> False
      Just Refl -> fun1 == fun2

instance Substitute IxFun where
  substituteNames subst (IxFun n ixfun) =
    IxFun n $ substituteNames subst ixfun

instance Rename IxFun where
  rename (IxFun n ixfun) =
    IxFun n <$> rename ixfun

type Indices     = [ScalExp]
type Shape       = [SubExp]
type ShapeChange = [DimChange SubExp]

shapeFromInts :: [Int] -> Shape
shapeFromInts = map $ Constant . IntVal . fromIntegral

rank :: IxFun -> Int
rank (IxFun n _) = sNatToInt n

index :: IxFun -> Indices -> ScalExp -> ScalExp
index f is element_size = case f of
  IxFun n f'
    | length is == sNatToInt n ->
        Safe.index f' (Vec.unsafeFromList n is) element_size
    | otherwise ->
        error $
        "Index list " ++ pretty is ++
        " incompatible with index function " ++ pretty f'

iota :: Shape -> IxFun
iota shape = case toSing (intToNat $ n-1) of
  SomeSing (sb::SNat n) ->
    IxFun (SS sb) $ Safe.iota $ Vec.unsafeFromList (SS sb) $
    map intSubExpToScalExp shape
  where n = Prelude.length shape

offsetIndex :: IxFun -> ScalExp -> IxFun
offsetIndex (IxFun n f) se =
  IxFun n $ Safe.offsetIndex f se

permute :: IxFun -> [Int] -> IxFun
permute (IxFun (n::SNat ('S n)) f) perm
  | sort perm /= [0..n'-1] =
    error $ "IndexFunction.Unsafe.permute: " ++ show perm ++
    " is an invalid permutation for index function of rank " ++
    show n'
  | otherwise =
    IxFun n $ Safe.permute f $
    Prelude.foldl (flip (:>>:)) Identity $
    fst $ Prelude.foldl buildPermutation ([], [0..n'-1]) $
    Prelude.zip [0..] perm
    -- This is fairly hacky - a better way would be to find the cycles
    -- in the permutation.
  where buildPermutation (perm', dims) (at, wants) =
          let wants' = dims Prelude.!! wants
              has = dims Prelude.!! at
              sw :: Swap ('S n)
              sw = withSingI n $
                   unsafeFromInt at :<->: unsafeFromInt wants'
          in if has /= wants
             then (sw : perm', update wants' has (update at wants' dims))
             else (perm', dims)
        n' = sNatToInt n

update :: Int -> a -> [a] -> [a]
update i x l =
  let (bef,_:aft) = Prelude.splitAt i l
  in bef ++ x : aft

reshape :: IxFun -> ShapeChange -> IxFun
reshape (IxFun _ ixfun) newshape =
  case toSing $ intToNat $ Prelude.length newshape-1 of
    SomeSing (sn::SNat n) ->
      IxFun (SS sn) $
      Safe.reshape ixfun $ Vec.unsafeFromList (SS sn) $
      map (fmap intSubExpToScalExp) newshape

applyInd :: IxFun -> Indices -> IxFun
applyInd ixfun@(IxFun (snnat::SNat ('S n)) (f::Safe.IxFun ScalExp ('S n))) is =
  case promote (Prelude.length is) :: Monomorphic (Sing :: Nat -> *) of
    Monomorphic (mnat::SNat m) ->
      case mnat %:<<= nnat of
        STrue ->
          let k = SS $ nnat %- mnat
              nmnat :: SNat (n :- m)
              nmnat = nnat %- mnat
              is' :: Safe.Indices ScalExp m
              is' = Vec.unsafeFromList mnat is
              proof :: 'S n :=: (m :+: 'S (n :- m))
              proof = sym $
                      trans (succPlusR mnat nmnat)
                      (succCongEq (minusPlusEqR nnat mnat))
              f' :: Safe.IxFun ScalExp (m :+: 'S (n :- m))
              f' = coerce proof f
          in IxFun k $ Safe.applyInd k f' is'
        SFalse ->
          error $
          unlines ["IndexFunction.Unsafe.applyInd: Too many indices given.",
                   "  Index function: " ++ pretty ixfun,
                   "  Indices" ++ pretty is]
  where nnat :: SNat n
        nnat = snnat %- sOne

offsetUnderlying :: IxFun -> ScalExp -> IxFun
offsetUnderlying (IxFun snnat f) k =
  IxFun snnat $ Safe.offsetUnderlying f k

underlyingOffset :: IxFun -> ScalExp
underlyingOffset (IxFun _ f) =
  Safe.underlyingOffset f

codomain :: IxFun -> SymSet
codomain (IxFun n f) =
  SymSet n $ Safe.codomain f

isDirect :: IxFun -> Bool
isDirect =
  maybe False (==zeroscal) . flip linearWithOffset onescal
  where zeroscal = Val (IntVal 0)
        onescal = Val (IntVal 1)

linearWithOffset :: IxFun -> ScalExp -> Maybe ScalExp
linearWithOffset (IxFun _ ixfun) =
  Safe.linearWithOffset ixfun

rearrangeWithOffset :: IxFun -> Maybe (ScalExp, [Int])
rearrangeWithOffset (IxFun n ixfun) = do
  (offset, perm) <- Safe.rearrangeWithOffset ixfun
  return (offset, Vec.toList $ Perm.apply perm $ Vec.unsafeFromList n [0..])

data SymSet = forall n . SymSet (SNat n) (SymSet.SymSet n)

instance FreeIn IxFun where
  freeIn (IxFun _ ixfun) = freeIn ixfun
