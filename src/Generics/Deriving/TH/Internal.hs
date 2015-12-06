{-# LANGUAGE CPP #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Generics.Deriving.TH.Internal
-- Copyright   :  (c) 2008--2009 Universiteit Utrecht
-- License     :  BSD3
--
-- Maintainer  :  generics@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable
--
-- Template Haskell-related utilities.
-----------------------------------------------------------------------------

module Generics.Deriving.TH.Internal where

import           Data.Function (on)
import           Data.List
import qualified Data.Map as Map
import           Data.Map as Map (Map)
import qualified Data.Set as Set
import           Data.Set (Set)

import           Language.Haskell.TH.Lib
import           Language.Haskell.TH.Syntax

#ifndef CURRENT_PACKAGE_KEY
import           Data.Version (showVersion)
import           Paths_generic_deriving (version)
#endif

-------------------------------------------------------------------------------
-- Expanding type synonyms
-------------------------------------------------------------------------------

-- | Expands all type synonyms in a type. Written by Dan Rosén in the
-- @genifunctors@ package (licensed under BSD3).
expandSyn :: Type -> Q Type
expandSyn (ForallT tvs ctx t) = fmap (ForallT tvs ctx) $ expandSyn t
expandSyn t@AppT{}            = expandSynApp t []
expandSyn t@ConT{}            = expandSynApp t []
expandSyn (SigT t _)          = expandSyn t   -- Ignore kind synonyms
expandSyn t                   = return t

expandSynApp :: Type -> [Type] -> Q Type
expandSynApp (AppT t1 t2) ts = do
    t2' <- expandSyn t2
    expandSynApp t1 (t2':ts)
expandSynApp (ConT n) ts | nameBase n == "[]" = return $ foldl' AppT ListT ts
expandSynApp t@(ConT n) ts = do
    info <- reify n
    case info of
        TyConI (TySynD _ tvs rhs) ->
            let (ts', ts'') = splitAt (length tvs) ts
                subs = mkSubst tvs ts'
                rhs' = subst subs rhs
             in expandSynApp rhs' ts''
        _ -> return $ foldl' AppT t ts
expandSynApp t ts = do
    t' <- expandSyn t
    return $ foldl' AppT t' ts

type Subst = Map Name Type

mkSubst :: [TyVarBndr] -> [Type] -> Subst
mkSubst vs ts =
   let vs' = map tyVarBndrToName vs
   in Map.fromList $ zip vs' ts

subst :: Subst -> Type -> Type
subst subs (ForallT v c t) = ForallT v c $ subst subs t
subst subs t@(VarT n)      = Map.findWithDefault t n subs
subst subs (AppT t1 t2)    = AppT (subst subs t1) (subst subs t2)
subst subs (SigT t k)      = SigT (subst subs t) k
subst _ t                  = t

-------------------------------------------------------------------------------
-- NameBase
-------------------------------------------------------------------------------

-- | A wrapper around Name which only uses the nameBase (not the entire Name)
-- to compare for equality. For example, if you had two Names a_123 and a_456,
-- they are not equal as Names, but they are equal as NameBases.
--
-- This is useful when inspecting type variables, since a type variable in an
-- instance context may have a distinct Name from a type variable within an
-- actual constructor declaration, but we'd want to treat them as the same
-- if they have the same nameBase (since that's what the programmer uses to
-- begin with).
newtype NameBase = NameBase { getName :: Name }

getNameBase :: NameBase -> String
getNameBase = nameBase . getName

instance Eq NameBase where
    (==) = (==) `on` getNameBase

instance Ord NameBase where
    compare = compare `on` getNameBase

-------------------------------------------------------------------------------
-- Assorted utilities
-------------------------------------------------------------------------------

-- | Is the given type a type family constructor (and not a data family constructor)?
isTyFamily :: Type -> Q Bool
isTyFamily (ConT n) = do
    info <- reify n
    return $ case info of
#if MIN_VERSION_template_haskell(2,11,0)
         FamilyI OpenTypeFamilyD{} _       -> True
#elif MIN_VERSION_template_haskell(2,7,0)
         FamilyI (FamilyD TypeFam _ _ _) _ -> True
#else
         TyConI  (FamilyD TypeFam _ _ _)   -> True
#endif
#if MIN_VERSION_template_haskell(2,9,0)
         FamilyI ClosedTypeFamilyD{} _     -> True
#endif
         _ -> False
isTyFamily _ = return False

-- | Construct a type via curried application.
applyTyToTys :: Type -> [Type] -> Type
applyTyToTys = foldl' AppT

-- | Apply a type constructor name to type variable binders.
applyTyToTvbs :: Name -> [TyVarBndr] -> Type
applyTyToTvbs = foldl' (\a -> AppT a . VarT . tyVarBndrToName) . ConT

-- | Split an applied type into its individual components. For example, this:
--
-- @
-- Either Int Char
-- @
--
-- would split to this:
--
-- @
-- [Either, Int, Char]
-- @
unapplyTy :: Type -> [Type]
unapplyTy = reverse . go
  where
    go :: Type -> [Type]
    go (AppT t1 t2) = t2:go t1
    go (SigT t _)   = go t
    go t            = [t]

-- | Split a type signature by the arrows on its spine. For example, this:
--
-- @
-- (Int -> String) -> Char -> ()
-- @
--
-- would split to this:
--
-- @
-- [Int -> String, Char, ()]
-- @
uncurryTy :: Type -> [Type]
uncurryTy (AppT (AppT ArrowT t1) t2) = t1:uncurryTy t2
uncurryTy (SigT t _)                 = uncurryTy t
uncurryTy t                          = [t]

-- | Like uncurryType, except on a kind level.
uncurryKind :: Kind -> [Kind]
#if MIN_VERSION_template_haskell(2,8,0)
uncurryKind = uncurryTy
#else
uncurryKind (ArrowK k1 k2) = k1:uncurryKind k2
uncurryKind k              = [k]
#endif

canRealizeKindStar :: Kind -> Bool
canRealizeKindStar k = case uncurryKind k of
    [k'] -> case k' of
#if MIN_VERSION_template_haskell(2,8,0)
                 StarT    -> True
                 VarT{}   -> True -- Kind k can be instantiated with *
#else
                 StarK    -> True
#endif
                 _ -> False
    _ -> False

wellKinded :: [Kind] -> Bool
wellKinded = all canRealizeKindStar

-- | Replace the Name of a TyVarBndr with one from a Type (if the Type has a Name).
replaceTyVarName :: TyVarBndr -> Type -> TyVarBndr
replaceTyVarName tvb            (SigT t _) = replaceTyVarName tvb t
replaceTyVarName PlainTV{}      (VarT n)   = PlainTV  n
replaceTyVarName (KindedTV _ k) (VarT n)   = KindedTV n k
replaceTyVarName tvb            _          = tvb

tyVarBndrToName :: TyVarBndr -> Name
tyVarBndrToName (PlainTV  name)   = name
tyVarBndrToName (KindedTV name _) = name

tyVarBndrToNameBase :: TyVarBndr -> NameBase
tyVarBndrToNameBase = NameBase . tyVarBndrToName

tyVarBndrToKind :: TyVarBndr -> Kind
tyVarBndrToKind PlainTV{}      = starK
tyVarBndrToKind (KindedTV _ k) = k

stripRecordNames :: Con -> Con
stripRecordNames (RecC n f) =
  NormalC n (map (\(_, s, t) -> (s, t)) f)
stripRecordNames c = c

-- | Checks to see if the last types in a data family instance can be safely eta-
-- reduced (i.e., dropped), given the other types. This checks for three conditions:
--
-- (1) All of the dropped types are type variables
-- (2) All of the dropped types are distinct
-- (3) None of the remaining types mention any of the dropped types
canEtaReduce :: [Type] -> [Type] -> Bool
canEtaReduce remaining dropped =
       all isTyVar dropped
    && allDistinct nbs -- Make sure not to pass something of type [Type], since Type
                       -- didn't have an Ord instance until template-haskell-2.10.0.0
    && not (any (`mentionsNameBase` nbs) remaining)
  where
    nbs :: [NameBase]
    nbs = map varTToNameBase dropped

-- | Extract the Name from a type variable.
varTToName :: Type -> Name
varTToName (VarT n)   = n
varTToName (SigT t _) = varTToName t
varTToName _          = error "Not a type variable!"

-- | Extract the NameBase from a type variable.
varTToNameBase :: Type -> NameBase
varTToNameBase = NameBase . varTToName

-- | Is the given type a variable?
isTyVar :: Type -> Bool
isTyVar VarT{}     = True
isTyVar (SigT t _) = isTyVar t
isTyVar _          = False

-- | Peel off a kind signature from a Type (if it has one).
unSigT :: Type -> Type
unSigT (SigT t _) = t
unSigT t          = t

-- | Peel off a kind signature from a TyVarBndr (if it has one).
unKindedTV :: TyVarBndr -> TyVarBndr
unKindedTV (KindedTV n _) = PlainTV n
unKindedTV tvb            = tvb

-- | Does the given type mention any of the NameBases in the list?
mentionsNameBase :: Type -> [NameBase] -> Bool
mentionsNameBase = go Set.empty
  where
    go :: Set NameBase -> Type -> [NameBase] -> Bool
    go foralls (ForallT tvbs _ t) nbs =
        go (foralls `Set.union` Set.fromList (map tyVarBndrToNameBase tvbs)) t nbs
    go foralls (AppT t1 t2) nbs = go foralls t1 nbs || go foralls t2 nbs
    go foralls (SigT t _)   nbs = go foralls t nbs
    go foralls (VarT n)     nbs = varNb `elem` nbs && not (varNb `Set.member` foralls)
      where
        varNb = NameBase n
    go _       _            _   = False

-- | Are all of the items in a list (which have an ordering) distinct?
--
-- This uses Set (as opposed to nub) for better asymptotic time complexity.
allDistinct :: Ord a => [a] -> Bool
allDistinct = allDistinct' Set.empty
  where
    allDistinct' :: Ord a => Set a -> [a] -> Bool
    allDistinct' uniqs (x:xs)
        | x `Set.member` uniqs = False
        | otherwise            = allDistinct' (Set.insert x uniqs) xs
    allDistinct' _ _           = True

trd :: (a, b, c) -> c
trd (_,_,c) = c

-- | Variant of foldr1 which returns a special element for empty lists
foldr1' :: (a -> a -> a) -> a -> [a] -> a
foldr1' _ x [] = x
foldr1' _ _ [x] = x
foldr1' f x (h:t) = f h (foldr1' f x t)

-- | Extracts the name of a constructor.
constructorName :: Con -> Name
constructorName (NormalC name      _  ) = name
constructorName (RecC    name      _  ) = name
constructorName (InfixC  _    name _  ) = name
constructorName (ForallC _    _    con) = constructorName con

#if MIN_VERSION_template_haskell(2,7,0)
-- | Extracts the constructors of a data or newtype declaration.
dataDecCons :: Dec -> [Con]
dataDecCons (DataInstD    _ _ _ cons _) = cons
dataDecCons (NewtypeInstD _ _ _ con  _) = [con]
dataDecCons _ = error "Must be a data or newtype declaration."
#endif

-------------------------------------------------------------------------------
-- Manually quoted names
-------------------------------------------------------------------------------

-- By manually generating these names we avoid needing to use the
-- TemplateHaskell language extension when compiling the generic-deriving library.
-- This allows the library to be used in stage1 cross-compilers.

gdPackageKey :: String
#ifdef CURRENT_PACKAGE_KEY
gdPackageKey = CURRENT_PACKAGE_KEY
#else
gdPackageKey = "generic-deriving-" ++ showVersion version
#endif

mkGD7'1_d :: String -> Name
#if __GLASGOW_HASKELL__ >= 705
mkGD7'1_d = mkNameG_d "base" "GHC.Generics"
#elif __GLASGOW_HASKELL__ >= 701
mkGD7'1_d = mkNameG_d "ghc-prim" "GHC.Generics"
#else
mkGD7'1_d = mkNameG_d gdPackageKey "Generics.Deriving.Base"
#endif

mkGD7'11_d :: String -> Name
#if __GLASGOW_HASKELL__ >= 711
mkGD7'11_d = mkNameG_d "base" "GHC.Generics"
#else
mkGD7'11_d = mkNameG_d gdPackageKey "Generics.Deriving.Base"
#endif

mkGD7'1_tc :: String -> Name
#if __GLASGOW_HASKELL__ >= 705
mkGD7'1_tc = mkNameG_tc "base" "GHC.Generics"
#elif __GLASGOW_HASKELL__ >= 701
mkGD7'1_tc = mkNameG_tc "ghc-prim" "GHC.Generics"
#else
mkGD7'1_tc = mkNameG_tc gdPackageKey "Generics.Deriving.Base"
#endif

mkGD7'11_tc :: String -> Name
#if __GLASGOW_HASKELL__ >= 711
mkGD7'11_tc = mkNameG_tc "base" "GHC.Generics"
#else
mkGD7'11_tc = mkNameG_tc gdPackageKey "Generics.Deriving.Base"
#endif

mkGD7'1_v :: String -> Name
#if __GLASGOW_HASKELL__ >= 705
mkGD7'1_v = mkNameG_v "base" "GHC.Generics"
#elif __GLASGOW_HASKELL__ >= 701
mkGD7'1_v = mkNameG_v "ghc-prim" "GHC.Generics"
#else
mkGD7'1_v = mkNameG_v gdPackageKey "Generics.Deriving.Base"
#endif

mkGD7'11_v :: String -> Name
#if __GLASGOW_HASKELL__ >= 711
mkGD7'11_v = mkNameG_v "base" "GHC.Generics"
#else
mkGD7'11_v = mkNameG_v gdPackageKey "Generics.Deriving.Base"
#endif

comp1DataName :: Name
comp1DataName = mkGD7'1_d "Comp1"

infixDataName :: Name
infixDataName = mkGD7'1_d "Infix"

k1DataName :: Name
k1DataName = mkGD7'1_d "K1"

l1DataName :: Name
l1DataName = mkGD7'1_d "L1"

leftAssociativeDataName :: Name
leftAssociativeDataName = mkGD7'1_d "LeftAssociative"

m1DataName :: Name
m1DataName = mkGD7'1_d "M1"

notAssociativeDataName :: Name
notAssociativeDataName = mkGD7'1_d "NotAssociative"

par1DataName :: Name
par1DataName = mkGD7'1_d "Par1"

prefixDataName :: Name
prefixDataName = mkGD7'1_d "Prefix"

productDataName :: Name
productDataName = mkGD7'1_d ":*:"

r1DataName :: Name
r1DataName = mkGD7'1_d "R1"

rec1DataName :: Name
rec1DataName = mkGD7'1_d "Rec1"

rightAssociativeDataName :: Name
rightAssociativeDataName = mkGD7'1_d "RightAssociative"

u1DataName :: Name
u1DataName = mkGD7'1_d "U1"

uAddrDataName :: Name
uAddrDataName = mkGD7'11_d "UAddr"

uCharDataName :: Name
uCharDataName = mkGD7'11_d "UChar"

uDoubleDataName :: Name
uDoubleDataName = mkGD7'11_d "UDouble"

uFloatDataName :: Name
uFloatDataName = mkGD7'11_d "UFloat"

uIntDataName :: Name
uIntDataName = mkGD7'11_d "UInt"

uWordDataName :: Name
uWordDataName = mkGD7'11_d "UWord"

c1TypeName :: Name
c1TypeName = mkGD7'1_tc "C1"

composeTypeName :: Name
composeTypeName = mkGD7'1_tc ":.:"

constructorTypeName :: Name
constructorTypeName = mkGD7'1_tc "Constructor"

d1TypeName :: Name
d1TypeName = mkGD7'1_tc "D1"

genericTypeName :: Name
genericTypeName = mkGD7'1_tc "Generic"

generic1TypeName :: Name
generic1TypeName = mkGD7'1_tc "Generic1"

datatypeTypeName :: Name
datatypeTypeName = mkGD7'1_tc "Datatype"

noSelectorTypeName :: Name
noSelectorTypeName = mkGD7'1_tc "NoSelector"

par1TypeName :: Name
par1TypeName = mkGD7'1_tc "Par1"

productTypeName :: Name
productTypeName = mkGD7'1_tc ":*:"

rec0TypeName :: Name
rec0TypeName = mkGD7'1_tc "Rec0"

rec1TypeName :: Name
rec1TypeName = mkGD7'1_tc "Rec1"

repTypeName :: Name
repTypeName = mkGD7'1_tc "Rep"

rep1TypeName :: Name
rep1TypeName = mkGD7'1_tc "Rep1"

s1TypeName :: Name
s1TypeName = mkGD7'1_tc "S1"

selectorTypeName :: Name
selectorTypeName = mkGD7'1_tc "Selector"

sumTypeName :: Name
sumTypeName = mkGD7'1_tc ":+:"

u1TypeName :: Name
u1TypeName = mkGD7'1_tc "U1"

uAddrTypeName :: Name
uAddrTypeName = mkGD7'11_tc "UAddr"

uCharTypeName :: Name
uCharTypeName = mkGD7'11_tc "UChar"

uDoubleTypeName :: Name
uDoubleTypeName = mkGD7'11_tc "UDouble"

uFloatTypeName :: Name
uFloatTypeName = mkGD7'11_tc "UFloat"

uIntTypeName :: Name
uIntTypeName = mkGD7'11_tc "UInt"

uWordTypeName :: Name
uWordTypeName = mkGD7'11_tc "UWord"

v1TypeName :: Name
v1TypeName = mkGD7'1_tc "V1"

conFixityValName :: Name
conFixityValName = mkGD7'1_v "conFixity"

conIsRecordValName :: Name
conIsRecordValName = mkGD7'1_v "conIsRecord"

conNameValName :: Name
conNameValName = mkGD7'1_v "conName"

datatypeNameValName :: Name
datatypeNameValName = mkGD7'1_v "datatypeName"

#if __GLASGOW_HASKELL__ >= 708
isNewtypeValName :: Name
isNewtypeValName = mkGD7'1_v "isNewtype"
#endif

fromValName :: Name
fromValName = mkGD7'1_v "from"

from1ValName :: Name
from1ValName = mkGD7'1_v "from1"

moduleNameValName :: Name
moduleNameValName = mkGD7'1_v "moduleName"

selNameValName :: Name
selNameValName = mkGD7'1_v "selName"

toValName :: Name
toValName = mkGD7'1_v "to"

to1ValName :: Name
to1ValName = mkGD7'1_v "to1"

uAddrHashValName :: Name
uAddrHashValName = mkGD7'11_v "uAddr#"

uCharHashValName :: Name
uCharHashValName = mkGD7'11_v "uChar#"

uDoubleHashValName :: Name
uDoubleHashValName = mkGD7'11_v "uDouble#"

uFloatHashValName :: Name
uFloatHashValName = mkGD7'11_v "uFloat#"

uIntHashValName :: Name
uIntHashValName = mkGD7'11_v "uInt#"

uWordHashValName :: Name
uWordHashValName = mkGD7'11_v "uWord#"

unComp1ValName :: Name
unComp1ValName = mkGD7'1_v "unComp1"

unK1ValName :: Name
unK1ValName = mkGD7'1_v "unK1"

unPar1ValName :: Name
unPar1ValName = mkGD7'1_v "unPar1"

unRec1ValName :: Name
unRec1ValName = mkGD7'1_v "unRec1"

trueDataName :: Name
#if __GLASGOW_HASKELL__ >= 701
trueDataName = mkNameG_d "ghc-prim" "GHC.Types" "True"
#else
trueDataName = mkNameG_d "ghc-prim" "GHC.Bool" "True"
#endif

mkGHCPrim_tc :: String -> Name
mkGHCPrim_tc = mkNameG_tc "ghc-prim" "GHC.Prim"

addrHashTypeName :: Name
addrHashTypeName = mkGHCPrim_tc "Addr#"

charHashTypeName :: Name
charHashTypeName = mkGHCPrim_tc "Char#"

doubleHashTypeName :: Name
doubleHashTypeName = mkGHCPrim_tc "Double#"

floatHashTypeName :: Name
floatHashTypeName = mkGHCPrim_tc "Float#"

intHashTypeName :: Name
intHashTypeName = mkGHCPrim_tc "Int#"

wordHashTypeName :: Name
wordHashTypeName = mkGHCPrim_tc "Word#"

composeValName :: Name
composeValName = mkNameG_v "base" "GHC.Base" "."

errorValName :: Name
errorValName = mkNameG_v "base" "GHC.Err" "error"

fmapValName :: Name
fmapValName = mkNameG_v "base" "GHC.Base" "fmap"

undefinedValName :: Name
undefinedValName = mkNameG_v "base" "GHC.Err" "undefined"

#if __GLASGOW_HASKELL__ >= 711
infixIDataName :: Name
infixIDataName = mkGD7'11_d "InfixI"

metaConsDataName :: Name
metaConsDataName = mkGD7'11_d "MetaCons"

metaDataDataName :: Name
metaDataDataName = mkGD7'11_d "MetaData"

metaNoSelDataName :: Name
metaNoSelDataName = mkGD7'11_d "MetaNoSel"

metaSelDataName :: Name
metaSelDataName = mkGD7'11_d "MetaSel"

prefixIDataName :: Name
prefixIDataName = mkGD7'11_d "PrefixI"

packageNameValName :: Name
packageNameValName = mkGD7'1_v "packageName"
#endif
