{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE ScopedTypeVariables       #-}

module Language.Haskell.Liquid.Types.Visitors (

  CBVisitable (..)

  -- * visitors
  , coreVisitor
  , CoreVisitor (..)

  ) where

import           Data.Hashable

import           Data.List                        ((\\), delete)
import qualified Data.HashSet                     as S
import           Prelude                          hiding (error)
import           Language.Fixpoint.Misc
import           Liquid.GHC.API
import           Language.Haskell.Liquid.GHC.Misc ()


------------------------------------------------------------------------------
-------------------------------- A CoreBind Visitor --------------------------
------------------------------------------------------------------------------

-- TODO: syb-shrinkage

class CBVisitable a where
  freeVars :: S.HashSet Var -> a -> [Var]
  readVars :: a -> [Var]
  letVars  :: a -> [Var]
  literals :: a -> [Literal]

instance CBVisitable [CoreBind] where
  freeVars env cbs = sortNub xs \\ ys
    where xs = concatMap (freeVars env) cbs
          ys = concatMap bindings cbs

  readVars = concatMap readVars
  letVars  = concatMap letVars
  literals = concatMap literals

instance CBVisitable CoreBind where
  freeVars env (NonRec x e) = freeVars (extendEnv env [x]) e
  freeVars env (Rec xes)    = concatMap (freeVars env') es
                              where (xs,es) = unzip xes
                                    env'    = extendEnv env xs

  readVars (NonRec _ e)     = readVars e
  readVars (Rec xes)        = concat [x `delete` nubReadVars e |(x, e) <- xes]
    where nubReadVars = sortNub . readVars

  letVars (NonRec x e)      = x : letVars e
  letVars (Rec xes)         = xs ++ concatMap letVars es
    where
      (xs, es)              = unzip xes

  literals (NonRec _ e)      = literals e
  literals (Rec xes)         = concatMap (literals . snd) xes

instance CBVisitable (Expr Var) where
  freeVars = exprFreeVars
  readVars = exprReadVars
  letVars  = exprLetVars
  literals = exprLiterals

exprFreeVars :: S.HashSet Id -> Expr Id -> [Id]
exprFreeVars = go
  where
    go env (Var x)         = [x | not (x `S.member` env)]
    go env (App e a)       = go env e ++ go env a
    go env (Lam x e)       = go (extendEnv env [x]) e
    go env (Let b e)       = freeVars env b ++ go (extendEnv env (bindings b)) e
    go env (Tick _ e)      = go env e
    go env (Cast e _)      = go env e
    go env (Case e x _ cs) = go env e ++ concatMap (freeVars (extendEnv env [x])) cs
    go _   _               = []

exprReadVars :: (CBVisitable (Alt t), CBVisitable (Bind t)) => Expr t -> [Id]
exprReadVars = go
  where
    go (Var x)             = [x]
    go (App e a)           = concatMap go [e, a]
    go (Lam _ e)           = go e
    go (Let b e)           = readVars b ++ go e
    go (Tick _ e)          = go e
    go (Cast e _)          = go e
    go (Case e _ _ cs)     = go e ++ concatMap readVars cs
    go _                   = []

exprLetVars :: Expr Var -> [Var]
exprLetVars = go
  where
    go (Var _)             = []
    go (App e a)           = concatMap go [e, a]
    go (Lam x e)           = x : go e
    go (Let b e)           = letVars b ++ go e
    go (Tick _ e)          = go e
    go (Cast e _)          = go e
    go (Case e x _ cs)     = x : go e ++ concatMap letVars cs
    go _                   = []

exprLiterals :: (CBVisitable (Alt t), CBVisitable (Bind t))
             => Expr t -> [Literal]
exprLiterals = go
  where
    go (Lit l)             = [l]
    go (App e a)           = concatMap go [e, a]
    go (Let b e)           = literals b ++ go e
    go (Lam _ e)           = go e
    go (Tick _ e)          = go e
    go (Cast e _)          = go e
    go (Case e _ _ cs)     = go e ++ concatMap literals cs
    go (Type t)            = go' t
    go _                   = []

    go' (LitTy tl)         = [tyLitToLit tl]
    go' _                  = []


    tyLitToLit (CharTyLit c) = LitChar c
    tyLitToLit (StrTyLit fs) = LitString (bytesFS fs)
    tyLitToLit (NumTyLit i)  = LitNumber LitNumInt (fromIntegral i)



instance CBVisitable (Alt Var) where
  freeVars env (Alt a xs e) = freeVars env a ++ freeVars (extendEnv env xs) e
  readVars (Alt _ _ e)       = readVars e
  letVars  (Alt _ xs e)       = xs ++ letVars e
  literals (Alt c _ e)       = literals c ++ literals e

instance CBVisitable AltCon where
  freeVars _ (DataAlt dc) = [ x | AnId x <- dataConImplicitTyThings dc]
  freeVars _ _            = []
  readVars _              = []
  letVars  _              = []
  literals (LitAlt l)     = [l]
  literals _              = []

extendEnv :: (Eq a, Hashable a) => S.HashSet a -> [a] -> S.HashSet a
extendEnv = foldl' (flip S.insert)

bindings :: Bind t -> [t]
bindings (NonRec x _) = [x]
bindings (Rec  xes  ) = map fst xes

----------------------------------------------------------------------------------------
-- | @BindVisitor@ allows for generic, context sensitive traversals over the @CoreBinds@ 
----------------------------------------------------------------------------------------
data CoreVisitor env acc = CoreVisitor
  { envF  :: env -> Var             -> env
  , bindF :: env -> acc -> Var      -> acc
  , exprF :: env -> acc -> CoreExpr -> acc
  }

coreVisitor :: CoreVisitor env acc -> env -> acc -> [CoreBind] -> acc
coreVisitor vis cenv cacc cbs = snd (foldl' step (cenv, cacc) cbs)
  where
    stepXE (env, acc) (x,e)   = (env', stepE env' acc'   e)
      where
        env'                  = envF  vis env     x
        acc'                  = bindF vis env acc x

    step ea (NonRec x e)      = stepXE ea (x, e)
    step ea (Rec    xes)      = foldl' stepXE ea xes

    -- step (env, acc) (NonRec x e) = stepXE env acc x e 
    -- step (env, acc) (Rec    xes) = (env', foldl' (stepE env') acc' es) 
      -- where 
        -- acc'                     = foldl' (bindF vis env') acc xs
        -- env'                     = foldl' (envF  vis)      env xs 
        -- xs                       = fst <$> xes 
        -- es                       = snd <$> xes
        -- foldl' (\(env, acc) (x, e) ->  )

    stepE env acc e              = goE env (exprF vis env acc e) e

    goE _   acc (Var _)          = acc
    goE env acc (App e1 e2)      = stepE  env (stepE env acc e1) e2
    goE env acc (Tick _ e)       = stepE  env acc e
    goE env acc (Cast e _)       = stepE  env acc e
    goE env acc (Lam x e)        = snd (stepXE (env, acc) (x, e))
    goE env acc (Let b e)        = stepE env' acc' e where (env', acc') = step (env, acc) b
    goE env acc (Case e _ _ cs)  = foldl' (goC env) (stepE env acc e) cs
    goE _   acc _                = acc

    goC env acc (Alt _ xs e)     = stepE  env' acc' e
      where
        env'                     = foldl' (envF  vis)     env xs
        acc'                     = foldl' (bindF vis env) acc xs
