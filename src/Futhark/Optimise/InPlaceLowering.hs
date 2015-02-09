{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | This module implements an optimisation that moves in-place
-- updates into/before loops where possible, with the end goal of
-- minimising memory copies.  As an example, consider this program:
--
-- @
--   loop (r = r0) = for i < n do
--     let a = r[i] in
--     let r[i] = a * i in
--     r
--     in
--   ...
--   let x = y with [k] <- r in
--   ...
-- @
--
-- We want to turn this into the following:
--
-- @
--   let x0 = y with [k] <- r0
--   loop (x = x0) = for i < n do
--     let a = a[k,i] in
--     let x[k,i] = a * i in
--     x
--     in
--   ...
-- @
--
-- The intent is that we are also going to optimise the new data
-- movement (in the @x0@-binding), possibly by changing how @r0@ is
-- defined.  For the above transformation to be valid, a number of
-- conditions must be fulfilled:
--
--    (1) @r@ must not be consumed after the original in-place update.
--
--    (2) @k@ and @y@ must be available at the beginning of the loop.
--
--    (3) @x@ must be visible whenever @r@ is visible.  (This means
--    that both @x@ and @r@ must be bound in the same 'Body'.)
--
--    (4) If @x@ is consumed at a point after the loop, @r@ must not
--    be used after that point.
--
--    (5) The size of @r@ is invariant inside the loop.
--
--    (6) The value @r@ must come from something that we can actually
--    optimise (e.g. not a function parameter).
--
-- FIXME: the implementation is not finished yet.  Specifically, the
-- above conditions are not really checked.
module Futhark.Optimise.InPlaceLowering
       (
         optimiseProgram
       ) where

import Control.Applicative
import Control.Monad.RWS hiding (mapM_)
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.Foldable
import Data.Maybe

import Futhark.Analysis.Alias
import Futhark.Representation.Aliases
import qualified Futhark.Representation.Basic as Basic
import Futhark.Representation.Basic (Basic)
import Futhark.Optimise.InPlaceLowering.LowerIntoBinding
import Futhark.MonadFreshNames
import Futhark.Binder

import Prelude hiding (any, mapM_, elem, all)

optimiseProgram :: Basic.Prog -> Basic.Prog
optimiseProgram prog =
  runForwardingM src $
  liftM (removeProgAliases . Prog) .
  mapM optimiseFunDec . progFunctions . aliasAnalysis $
  prog
  where src = newNameSourceForProg prog

optimiseFunDec :: FunDec Basic -> ForwardingM (FunDec Basic)
optimiseFunDec fundec =
  bindingFParams (funDecParams fundec) $ do
    body <- optimiseBody $ funDecBody fundec
    return $ fundec { funDecBody = body }

optimiseBody :: Body Basic -> ForwardingM (Body Basic)
optimiseBody (Body als bnds res) = do
  bnds' <- deepen $ optimiseBindings bnds $
    mapM_ seen $ resultSubExps res
  return $ Body als bnds' res
  where seen (Constant {}) = return ()
        seen (Var v)       = seenIdent v

optimiseBindings :: [Binding Basic]
                 -> ForwardingM ()
                 -> ForwardingM [Binding Basic]
optimiseBindings [] m = m >> return []

optimiseBindings (bnd:bnds) m = do
  (bnds', bup) <- tapBottomUp $ bindingBinding bnd $ optimiseBindings bnds m
  bnd' <- optimiseInBinding bnd
  case filter ((`elem` boundHere) . identName . updateValue) $
       forwardThese bup of
    [] -> checkIfForwardableUpdate bnd' bnds'
    updates -> do
      let updateBindings = map updateBinding updates
      -- Condition (5) is assumed to be checked by lowerUpdate.
      case lowerUpdate bnd' updates of
        Just lowering -> do new_bnds <- lowering
                            new_bnds' <- optimiseBindings new_bnds $
                                         tell bup { forwardThese = [] }
                            return $ new_bnds' ++ bnds'
        Nothing       -> checkIfForwardableUpdate bnd' $
                         updateBindings ++ bnds'

  where boundHere = patternNames $ bindingPattern bnd

        checkIfForwardableUpdate bnd' bnds'
            | PrimOp (Update cs src [i] (Var ve)) <- bindingExp bnd',
              Pattern [bindee] <- bindingPattern bnd' = do
                forwarded <- maybeForward ve (bindeeIdent bindee) cs src i
                return $ if forwarded
                         then bnds'
                         else bnd' : bnds'
        checkIfForwardableUpdate bnd' bnds' =
          return $ bnd' : bnds'

optimiseInBinding :: Binding Basic
                  -> ForwardingM (Binding Basic)
optimiseInBinding (Let pat _ e) = do
  e' <- optimiseExp e
  return $ mkLet (patternIdents pat) e'

optimiseExp :: Exp Basic -> ForwardingM (Exp Basic)
optimiseExp (LoopOp (DoLoop res merge i bound body)) =
  bindingIdents [i] $
  bindingFParams (map fst merge) $ do
    body' <- optimiseBody body
    return $ LoopOp $ DoLoop res merge i bound body'
optimiseExp e = mapExpM traverse e
  where traverse = identityMapper { mapOnBody = optimiseBody
                                  , mapOnLambda = optimiseLambda
                                  }

optimiseLambda :: Lambda Basic
               -> ForwardingM (Lambda Basic)
optimiseLambda lam =
  bindingIdents (lambdaParams lam) $ do
    optbody <- optimiseBody $ lambdaBody lam
    return $ lam { lambdaBody = optbody }

data Entry = Entry { entryNumber :: Int
                   , entryAliases :: Names
                   , entryDepth :: Int
                   , entryOptimisable :: Bool
                   }

type VTable = HM.HashMap VName Entry

data TopDown = TopDown { topDownCounter :: Int
                       , topDownTable :: VTable
                       , topDownDepth :: Int
                       }

data BottomUp = BottomUp { bottomUpSeen :: Names
                         , forwardThese :: [DesiredUpdate]
                         }

instance Monoid BottomUp where
  BottomUp seen1 forward1 `mappend` BottomUp seen2 forward2 =
    BottomUp (seen1 `mappend` seen2) (forward1 `mappend` forward2)
  mempty = BottomUp mempty mempty

updateBinding :: DesiredUpdate -> Binding Basic
updateBinding fwd =
  mkLet [updateBindee fwd] $
  PrimOp $ Update (updateCertificates fwd) (updateSource fwd)
  (updateIndices fwd) (Var $ updateValue fwd)

newtype ForwardingM a = ForwardingM (RWS TopDown BottomUp VNameSource a)
                      deriving (Monad, Applicative, Functor,
                                MonadReader TopDown,
                                MonadWriter BottomUp,
                                MonadState VNameSource)

instance MonadFreshNames ForwardingM where
  getNameSource = get
  putNameSource = put

runForwardingM :: VNameSource -> ForwardingM a -> a
runForwardingM src (ForwardingM m) = fst $ evalRWS m emptyTopDown src
  where emptyTopDown = TopDown { topDownCounter = 0
                               , topDownTable = HM.empty
                               , topDownDepth = 0
                               }

bindingFParams :: [FParam Basic]
               -> ForwardingM a
               -> ForwardingM a
bindingFParams fparams = local $ \(TopDown n vtable d) ->
  let entry fparam =
        (bindeeName fparam,
         Entry n mempty d False)
      entries = HM.fromList $ map entry fparams
  in TopDown (n+1) (HM.union entries vtable) d

bindingBinding :: Binding Basic
               -> ForwardingM a
               -> ForwardingM a
bindingBinding (Let pat _ _) = local $ \(TopDown n vtable d) ->
  let entries = HM.fromList $ map entry $ patternBindees pat
      entry bindee =
        let (aliases, ()) = bindeeLore bindee
        in (bindeeName bindee,
            Entry n (unNames aliases) d True)
  in TopDown (n+1) (HM.union entries vtable) d

bindingIdents :: [Ident]
             -> ForwardingM a
             -> ForwardingM a
bindingIdents vs = local $ \(TopDown n vtable d) ->
  let entries = HM.fromList $ map entry vs
      entry v =
        (identName v,
         Entry n mempty d False)
  in TopDown (n+1) (HM.union entries vtable) d

bindingNumber :: VName -> ForwardingM Int
bindingNumber name = do
  res <- asks $ liftM entryNumber . HM.lookup name . topDownTable
  case res of Just n  -> return n
              Nothing -> fail $ "bindingNumber: variable " ++
                         pretty name ++ " not found."

deepen :: ForwardingM a -> ForwardingM a
deepen = local $ \env -> env { topDownDepth = topDownDepth env + 1 }

areAvailableBefore :: [SubExp] -> VName -> ForwardingM Bool
areAvailableBefore ses point = do
  pointN <- bindingNumber point
  nameNs <- mapM bindingNumber names
  return $ all (< pointN) nameNs
  where names = mapMaybe isVar ses
        isVar (Var v)       = Just $ identName v
        isVar (Constant {}) = Nothing

isInCurrentBody :: VName -> ForwardingM Bool
isInCurrentBody name = do
  current <- asks topDownDepth
  res <- asks $ liftM entryDepth . HM.lookup name . topDownTable
  case res of Just d  -> return $ d == current
              Nothing -> fail $ "isInCurrentBody: variable " ++
                         pretty name ++ " not found."

isOptimisable :: VName -> ForwardingM Bool
isOptimisable name = do
  res <- asks $ liftM entryOptimisable . HM.lookup name . topDownTable
  case res of Just b  -> return b
              Nothing -> fail $ "isOptimisable: variable " ++
                         pretty name ++ " not found."

seenIdent :: Ident -> ForwardingM ()
seenIdent ident = do
  aliases <- asks $
             maybe mempty entryAliases .
             HM.lookup name . topDownTable
  tell $ mempty { bottomUpSeen = HS.insert name aliases }
  where name = identName ident

tapBottomUp :: ForwardingM a -> ForwardingM (a, BottomUp)
tapBottomUp m = do (x,bup) <- listen m
                   return (x, bup)

maybeForward :: Ident
             -> Ident -> Certificates -> Ident -> SubExp
             -> ForwardingM Bool
maybeForward v dest cs src i = do
  -- Checks condition (2)
  available <- [i,Var src] `areAvailableBefore` identName v
  -- Check condition (3)
  samebody <- isInCurrentBody $ identName v
  -- Check condition (6)
  optimisable <- isOptimisable $ identName v
  if available && samebody && optimisable && not (basicType $ identType v) then do
    let fwd = DesiredUpdate dest cs src [i] v
    tell mempty { forwardThese = [fwd] }
    return True
    else return False