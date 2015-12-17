{-# LANGUAGE FlexibleContexts #-}
-- | This module implements facilities for determining whether a
-- reduction or fold can be expressed in a closed form (i.e. not as a
-- SOAC).
--
-- Right now, the module can detect only trivial cases.  In the
-- future, we would like to make it more powerful, as well as possibly
-- also being able to analyse sequential loops.
module Futhark.Optimise.Simplifier.ClosedForm
  ( foldClosedForm
  , loopClosedForm
  )
where

import Control.Monad
import Control.Applicative
import Data.Maybe
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.Monoid

import Prelude

import Futhark.Construct
import Futhark.Representation.AST
import Futhark.Transform.Rename
import Futhark.MonadFreshNames
import Futhark.Optimise.Simplifier.RuleM

-- | A function that, given a variable name, returns its definition.
-- XXX: This duplicates something in Futhark.Optimise.Simplification.
type VarLookup lore = VName -> Maybe (Exp lore)

{-
Motivation:

  let {*[int,x_size_27] map_computed_shape_1286} = replicate(x_size_27,
                                                             all_equal_shape_1044) in
  let {*[bool,x_size_27] map_size_checks_1292} = replicate(x_size_27, x_1291) in
  let {bool all_equal_checked_1298, int all_equal_shape_1299} =
    reduceT(fn {bool, int} (bool bacc_1293, int nacc_1294, bool belm_1295,
                            int nelm_1296) =>
              let {bool tuplit_elems_1297} = bacc_1293 && belm_1295 in
              {tuplit_elems_1297, nelm_1296},
            {True, 0}, map_size_checks_1292, map_computed_shape_1286)
-}

-- | @foldClosedForm look foldfun accargs arrargs@ determines whether
-- each of the results of @foldfun@ can be expressed in a closed form.
foldClosedForm :: MonadBinder m =>
                  VarLookup (Lore m)
               -> Pattern (Lore m)
               -> Lambda (Lore m)
               -> [SubExp] -> [VName]
               -> RuleM m ()

foldClosedForm look pat lam accs arrs = do
  inputsize <- arraysSize 0 <$> mapM lookupType arrs
  closedBody <- checkResults (patternNames pat) inputsize mempty knownBindings
                (map paramIdent $ lambdaParams lam) (lambdaBody lam) accs
  isEmpty <- newVName "fold_input_is_empty"
  letBindNames'_ [isEmpty] $
    PrimOp $ BinOp Equal inputsize (intconst 0) Bool
  letBind_ pat =<<
    eIf (eSubExp $ Var isEmpty)
    (resultBodyM accs)
    (renameBody closedBody)
  where knownBindings = determineKnownBindings look lam accs arrs

-- | @loopClosedForm pat respat merge bound bodys@ determines whether
-- the do-loop can be expressed in a closed form.
loopClosedForm :: MonadBinder m =>
                  PatternT attr
               -> [VName] -> [(FParam (Lore m),SubExp)]
               -> Names -> SubExp -> Body (Lore m)
               -> RuleM m ()
loopClosedForm pat respat merge i bound body
  | respat == mergenames = do
    closedBody <- checkResults respat bound i knownBindings
                  mergeidents body mergeexp
    isEmpty <- newVName "bound_is_zero"
    letBindNames'_ [isEmpty] $
      PrimOp $ BinOp Leq bound (intconst 0) Bool
    letBindNames'_ (patternNames pat) =<<
      eIf (eSubExp $ Var isEmpty)
      (resultBodyM mergeexp)
      (renameBody closedBody)
  | otherwise = cannotSimplify
  where (mergepat, mergeexp) = unzip merge
        mergeidents = map paramIdent mergepat
        mergenames = map identName mergeidents
        knownBindings = HM.fromList $ zip mergenames mergeexp

checkResults :: MonadBinder m =>
                [VName]
             -> SubExp
             -> Names
             -> HM.HashMap VName SubExp
             -> [Ident]
             -> Body (Lore m)
             -> [SubExp]
             -> RuleM m (Body (Lore m))
checkResults pat size untouchable knownBindings params body accs = do
  ((), bnds) <- collectBindings $
                zipWithM_ checkResult (zip pat res) (zip accparams accs)
  mkBodyM bnds $ map Var pat

  where bndMap = makeBindMap body
        (accparams, _) = splitAt (length accs) params
        res = bodyResult body

        nonFree = boundInBody body <>
                  HS.fromList (map identName params) <>
                  untouchable

        checkResult (p, e) _
          | Just e' <- asFreeSubExp e = letBindNames'_ [p] $ PrimOp $ SubExp e'
        checkResult (p, Var v) (accparam, acc) = do
          e@(PrimOp (BinOp bop x y rt)) <- liftMaybe $ HM.lookup v bndMap
          -- One of x,y must be *this* accumulator, and the other must
          -- be something that is free in the body.
          let isThisAccum = (==Var (identName accparam))
          (this, el) <- liftMaybe $
                        case ((asFreeSubExp x, isThisAccum y),
                              (asFreeSubExp y, isThisAccum x)) of
                          ((Just free, True), _) -> Just (acc, free)
                          (_, (Just free, True)) -> Just (acc, free)
                          _                      -> Nothing

          case bop of
              LogAnd -> do
                letBindNames'_ [v] e
                letBindNames'_ [p] $ PrimOp $ BinOp LogAnd this el rt
              Plus | Just properly_typed_size <- properSize rt -> do
                       size' <- properly_typed_size
                       letBindNames'_ [p] =<<
                         eBinOp Plus (eSubExp this)
                         (pure $ PrimOp $ BinOp Times el size' rt) rt
              Times | Just properly_typed_size <- properSize rt -> do
                        size' <- properly_typed_size
                        letBindNames'_ [p] =<<
                          eBinOp Times (eSubExp this)
                          (pure $ PrimOp $ BinOp Pow el size' rt) rt
              _ -> cannotSimplify -- Um... sorry.

        checkResult _ _ = cannotSimplify

        asFreeSubExp :: SubExp -> Maybe SubExp
        asFreeSubExp (Var v)
          | HS.member v nonFree = HM.lookup v knownBindings
        asFreeSubExp se = Just se

        properSize Int =
          Just $ return size
        properSize Float32 =
          Just $ letSubExp "converted_size" $
          Apply (nameFromString "toFloat32") [(size, Observe)] (basicRetType Float32)
        properSize Float64 =
          Just $ letSubExp "converted_size" $
          Apply (nameFromString "toFloat64") [(size, Observe)] (basicRetType Float64)
        properSize _ =
          Nothing

determineKnownBindings :: VarLookup lore -> Lambda lore -> [SubExp] -> [VName]
                       -> HM.HashMap VName SubExp
determineKnownBindings look lam accs arrs =
  accBindings <> arrBindings
  where (accparams, arrparams) =
          splitAt (length accs) $ lambdaParams lam
        accBindings = HM.fromList $
                      zip (map paramName accparams) accs
        arrBindings = HM.fromList $ mapMaybe isReplicate $
                      zip (map paramName arrparams) arrs

        isReplicate (p, v)
          | Just (PrimOp (Replicate _ ve)) <- look v = Just (p, ve)
        isReplicate _ = Nothing

makeBindMap :: Body lore -> HM.HashMap VName (Exp lore)
makeBindMap = HM.fromList . mapMaybe isSingletonBinding . bodyBindings
  where isSingletonBinding (Let pat _ e) = case patternNames pat of
          [v] -> Just (v,e)
          _   -> Nothing
