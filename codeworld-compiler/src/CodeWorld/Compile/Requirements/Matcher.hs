{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ViewPatterns #-}

{-
  Copyright 2018 The CodeWorld Authors. All rights reserved.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-}

module CodeWorld.Compile.Requirements.Matcher where

import Control.Monad
import Data.Generics
import Data.Generics.Twins
import Data.List
import Data.Maybe
import Language.Haskell.Exts

class (Data a, Typeable a) => Template a where
  toSplice :: a -> Maybe (Splice SrcSpanInfo)
  fromBracket :: Bracket SrcSpanInfo -> Maybe a

  toParens :: a -> Maybe a
  toTuple :: a -> Maybe [a]
  toVar :: a -> Maybe a
  toCon :: a -> Maybe a
  toLit :: a -> Maybe a
  toNum :: a -> Maybe a
  toChar :: a -> Maybe a
  toStr :: a -> Maybe a

instance Template (Pat SrcSpanInfo) where
  toSplice (PSplice _ s) = Just s
  toSplice _ = Nothing

  fromBracket (PatBracket _ p) = Just p
  fromBracket _ = Nothing

  toParens (PParen _ x) = Just x
  toParens _ = Nothing

  toTuple (PTuple _ _ ps) = Just ps
  toTuple _ = Nothing

  toVar x@(PVar _ _) = Just x
  toVar _ = Nothing

  toCon x@(PApp _ _ []) = Just x
  toCon _ = Nothing

  toLit x@(PLit _ _ _) = Just x
  toLit _ = Nothing

  toNum x@(PLit _ _ (Int _ _ _)) = Just x
  toNum x@(PLit _ _ (Frac _ _ _)) = Just x
  toNum x@(PLit _ _ (PrimInt _ _ _)) = Just x
  toNum x@(PLit _ _ (PrimWord _ _ _)) = Just x
  toNum x@(PLit _ _ (PrimFloat _ _ _)) = Just x
  toNum x@(PLit _ _ (PrimDouble _ _ _)) = Just x
  toNum _ = Nothing

  toChar x@(PLit _ _ (Char _ _ _)) = Just x
  toChar x@(PLit _ _ (PrimChar _ _ _)) = Just x
  toChar _ = Nothing

  toStr x@(PLit _ _ (String _ _ _)) = Just x
  toStr x@(PLit _ _ (PrimString _ _ _)) = Just x
  toStr _ = Nothing

instance Template (Exp SrcSpanInfo) where
  toSplice (SpliceExp _ s) = Just s
  toSplice _ = Nothing

  fromBracket (ExpBracket _ e) = Just e
  fromBracket _ = Nothing

  toParens (Paren _ x) = Just x
  toParens _ = Nothing

  toTuple (Tuple _ _ es) = Just es
  toTuple _ = Nothing

  toVar x@(Var _ _) = Just x
  toVar _ = Nothing

  toCon x@(Con _ _) = Just x
  toCon _ = Nothing

  toLit x@(Lit _ _) = Just x
  toLit x@(NegApp _ (Lit _ _)) = Just x
  toLit _ = Nothing

  toNum x@(Lit _ (Int _ _ _)) = Just x
  toNum x@(Lit _ (Frac _ _ _)) = Just x
  toNum x@(Lit _ (PrimInt _ _ _)) = Just x
  toNum x@(Lit _ (PrimWord _ _ _)) = Just x
  toNum x@(Lit _ (PrimFloat _ _ _)) = Just x
  toNum x@(Lit _ (PrimDouble _ _ _)) = Just x
  toNum x@(NegApp _ (toNum -> Just _)) = Just x
  toNum _ = Nothing

  toChar x@(Lit _ (Char _ _ _)) = Just x
  toChar x@(Lit _ (PrimChar _ _ _)) = Just x
  toChar _ = Nothing

  toStr x@(Lit _ (String _ _ _)) = Just x
  toStr x@(Lit _ (PrimString _ _ _)) = Just x
  toStr _ = Nothing

match :: Data a => a -> a -> Bool
match tmpl val = matchQ tmpl val

matchQ :: GenericQ (GenericQ Bool)
matchQ = matchesSrcSpanInfo
     ||| (matchesSpecials :: Pat SrcSpanInfo -> Pat SrcSpanInfo -> Maybe Bool)
     ||| (matchesSpecials :: Exp SrcSpanInfo -> Exp SrcSpanInfo -> Maybe Bool)
     ||| matchesPatWildcard ||| matchesExpWildcard
     ||| structuralEq

matchesSrcSpanInfo :: SrcSpanInfo -> SrcSpanInfo -> Maybe Bool
matchesSrcSpanInfo _ _ = Just True

matchesSpecials :: Template a => a -> a -> Maybe Bool
matchesSpecials (toParens -> Just x) y = Just (matchQ x y)
matchesSpecials x (toParens -> Just y) = Just (matchQ x y)
matchesSpecials (toSplice -> Just (IdSplice _ "any")) _ = Just True
matchesSpecials (toSplice -> Just (IdSplice _ "var")) x =
    case toVar x of Just _ -> Just True; Nothing -> Just False
matchesSpecials (toSplice -> Just (IdSplice _ "con")) x =
    case toCon x of Just _ -> Just True; Nothing -> Just False
matchesSpecials (toSplice -> Just (IdSplice _ "lit")) x =
    case toLit x of Just _ -> Just True; Nothing -> Just False
matchesSpecials (toSplice -> Just (IdSplice _ "num")) x =
    case toNum x of Just _ -> Just True; Nothing -> Just False
matchesSpecials (toSplice -> Just (IdSplice _ "char")) x =
    case toChar x of Just _ -> Just True; Nothing -> Just False
matchesSpecials (toSplice -> Just (IdSplice _ "str")) x =
    case toStr x of Just _ -> Just True; Nothing -> Just False
matchesSpecials (toSplice -> Just (ParenSplice _ (App _ op (BracketExp _ (fromBracket -> Just tmpl))))) x
  = case op of
      Var _ (UnQual _ (Ident _ "tupleOf")) ->
          case toTuple x of
            Just xs -> Just (all (match tmpl) xs)
            Nothing -> Just False
      Var _ (UnQual _ (Ident _ "contains")) ->
          Just (everything (||) (mkQ False (match tmpl)) x)
      _ -> Nothing
matchesSpecials _ _ = Nothing

matchesPatWildcard :: Pat SrcSpanInfo -> Pat SrcSpanInfo -> Maybe Bool
matchesPatWildcard (PVar _ (Ident _ "__any")) _ = Just True
matchesPatWildcard (PVar _ (Ident _ "__var")) p = Just (isVar p)
  where isVar (PVar _ _) = True
        isVar _ = False
matchesPatWildcard (PVar _ (Ident _ "__num")) p = Just (isNum p)
  where isNum (PLit _ _ (Int _ _ _)) = True
        isNum (PLit _ _ (Frac _ _ _)) = True
        isNum _ = False
matchesPatWildcard (PVar _ (Ident _ "__str")) p = Just (isStr p)
  where isStr (PLit _ _ (String _ _ _)) = True
        isStr _ = False
matchesPatWildcard (PVar _ (Ident _ "__char")) p = Just (isChr p)
  where isChr (PLit _ _ (Char _ _ _)) = True
        isChr _ = False
matchesPatWildcard (PApp _ (UnQual _ (Ident _ "TupleOf_")) pat) p = Just (allMatch pat p)
  where allMatch pat (PTuple _ _ pats) = all (matchQ pat) pats
        allMatch _ _ = False
matchesPatWildcard (PApp _ (UnQual _ (Ident _ "Contains_")) pat) p = Just (subMatch pat p)
  where subMatch pat = everything (||) (mkQ False (match pat))
matchesPatWildcard _ _ = Nothing

matchesExpWildcard :: Exp SrcSpanInfo -> Exp SrcSpanInfo -> Maybe Bool
matchesExpWildcard (Var _ (UnQual _ (Ident _ "__any"))) _ = Just True
matchesExpWildcard (Var _ (UnQual _ (Ident _ "__var"))) e = Just (isVar e)
  where isVar (Var _ _) = True
        isVar _ = False
matchesExpWildcard (Var _ (UnQual _ (Ident _ "__num"))) e = Just (isNum e)
  where isNum (Lit _ (Int _ _ _)) = True
        isNum (Lit _ (Frac _ _ _)) = True
        isNum _ = False
matchesExpWildcard (Var _ (UnQual _ (Ident _ "__str"))) e = Just (isStr e)
  where isStr (Lit _ (String _ _ _)) = True
        isStr _ = False
matchesExpWildcard (Var _ (UnQual _ (Ident _ "__char"))) e = Just (isChr e)
  where isChr (Lit _ (Char _ _ _)) = True
        isChr _ = False
matchesExpWildcard (App _ (Var _ (UnQual _ (Ident _ "tupleOf_"))) exp) e = Just (allMatch exp e)
  where allMatch exp (Tuple _ _ exps) = all (matchQ exp) exps
        allMatch _ _ = False
matchesExpWildcard (App _ (Var _ (UnQual _ (Ident _ "contains_"))) exp) e = Just (subMatch exp e)
  where subMatch exp = everything (||) (mkQ False (match exp))
matchesExpWildcard _ _ = Nothing

structuralEq :: (Data a, Data b) => a -> b -> Bool
structuralEq x y = toConstr x == toConstr y && and (gzipWithQ matchQ x y)

(|||) :: (Typeable a, Typeable b, Typeable x)
    => (x -> x -> Maybe Bool)
    -> (a -> b -> Bool)
    -> (a -> b -> Bool)
f ||| g = \x y -> fromMaybe (g x y) (join (f <$> cast x <*> cast y))
infixr 0 |||
