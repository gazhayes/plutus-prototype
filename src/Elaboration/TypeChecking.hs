{-# OPTIONS -Wall #-}







-- | A unification-based type checker. It's worth noting that this language is
-- not System F, as it lacks syntax for type abstraction and type application.
-- Instead, it's more like Haskell with @RankNTypes@.

module Elaboration.TypeChecking where

import Utils.ABT
import Utils.Elaborator
import Utils.Pretty
import Utils.Unifier
import Utils.Vars
import Plutus.ConSig
import Plutus.Term
import Plutus.Type
import qualified PlutusCore.Term as Core
import Elaboration.Elaborator
import Elaboration.Unification ()

import Control.Monad.Except
import Control.Monad.State







-- | We can check that a type constructor exists by looking in the signature.
-- This corresponds to the judgment @Σ ∋ n : *^k@

tyconExists :: String -> TypeChecker TyConSig
tyconExists n =
  do tycons <- getElab (signature.typeConstructors)
     case lookup n tycons of
       Nothing -> throwError $ "Unknown type constructor: " ++ n
       Just sig -> return sig


-- | We can get the consig of a constructor by looking in the signature.
-- This corresponds to the judgment @Σ ∋ n : S@

typeInSignature :: String -> TypeChecker ConSig
typeInSignature n =
  do consigs <- getElab (signature.dataConstructors)
     case lookup n consigs of
       Nothing -> throwError $ "Unknown constructor: " ++ n
       Just t  -> return t


-- | We can get the signature of a built-in by looking in the signature.
-- This corresponds to the judgment @Σ ∋ !n : S@

builtinInSignature :: String -> TypeChecker ConSig
builtinInSignature n =
  do consigs <- getElab (signature.builtins)
     case lookup n consigs of
       Nothing -> throwError $ "Unknown builtin: " ++ n
       Just t  -> return t


-- | We can get the type of a declared name by looking in the definitions.
-- This corresponds to the judgment @Δ ∋ n : A@

typeInDefinitions :: String -> TypeChecker Type
typeInDefinitions n =
  do defs <- getElab definitions
     case lookup n defs of
       Nothing -> throwError $ "Unknown constant/defined term: " ++ n
       Just (_,t) -> return t


-- | We can get the type of a generated variable by looking in the context.
-- This corresponds to the judgment @Γ ∋ x : A@

typeInContext :: FreeVar -> TypeChecker Type
typeInContext x@(FreeVar n) =
  do ctx <- getElab context
     case lookup x ctx of
       Nothing -> throwError $ "Unbound variable: " ++ n
       Just t -> return t


-- | We can check if a type variable is in scope. This corresponds to the
-- judgment @Γ ∋ α type@

tyVarExists :: FreeVar -> TypeChecker ()
tyVarExists x@(FreeVar n) =
  do tyVarCtx <- getElab tyVarContext
     unless (x `elem` tyVarCtx)
       $ throwError $ "Unbound type variable: " ++ n





-- | Type well-formedness corresponds to the judgment @A type@. This throws a
-- Haskell error if it encounters a variable because there should be no
-- vars in this type checker. That would only be possible for types coming
-- from outside the parser. Same for metavariables.
--
-- The judgment @Σ;Γ ⊢ A type@ is defined inductively as follows:
--
-- @
--   Γ ∋ α type
--   ----------
--   Γ ⊢ α type
--  
--   A type   B type
--   ---------------
--     A → B type
--
--   Σ ∋ n : *^k   Σ ⊢ Ai type
--   -------------------------
--     Σ ⊢ n A0 ... Ak type
--
--   Γ, α type ⊢ A type
--   ------------------
--     Γ ⊢ ∀α. A type
-- @

isType :: Type -> TypeChecker ()
isType (Var (Free x)) =
  tyVarExists x
isType (Var (Bound _ _)) =
  error "Bound type variables should not be the subject of type checking."
isType (Var (Meta _)) =
  error "Metavariables should not be the subject of type checking."
isType (In (TyCon c as)) =
  do TyConSig ar <- tyconExists c
     let las = length as
     unless (ar == las)
       $ throwError $ c ++ " expects " ++ show ar ++ " "
                   ++ (if ar == 1 then "arg" else "args")
                   ++ " but was given " ++ show las
     mapM_ (isType.instantiate0) as
isType (In (Fun a b)) =
  do isType (instantiate0 a)
     isType (instantiate0 b)
isType (In (Forall sc)) =
  do ns <- freshRelTo (names sc) context
     let xs = map (Var . Free) ns
     extendElab tyVarContext ns
       $ isType (instantiate sc xs)
isType (In (Comp a)) =
  isType (instantiate0 a)





-- | We can instantiate the argument and return types for a constructor
-- signature with variables.

instantiateParams :: [Scope TypeF] -> Scope TypeF -> TypeChecker ([Type],Type)
instantiateParams argscs retsc =
  do metas <- replicateM
               (length (names retsc))
               (nextElab nextMeta)
     let ms = map (Var . Meta) metas
     return ( map (\sc -> instantiate sc ms) argscs
            , instantiate retsc ms
            )





-- | We can instantiate a universally quantified type with metavariables
-- eliminating all the initial quantifiers. For example, the type
-- @∀α,β. (α → β) → α@ would become @(?0 → ?1) → ?0@, while the type
-- @∀α. (∀β. α → β) → α@ would become @(∀β. ?0 → β) → ?0@ and the type
-- @A → ∀β. A → β@ would be unchanged.

instantiateQuantifiers :: Type -> TypeChecker Type
instantiateQuantifiers (In (Forall sc)) =
  do meta <- nextElab nextMeta
     let m = Var (Meta meta)
     instantiateQuantifiers (instantiate sc [m])
instantiateQuantifiers t = return t





-- | Type synthesis corresponds to the judgment @Γ ⊢ M ▹ M' ∈ A@. This throws
-- a Haskell error when trying to synthesize the type of a bound variable,
-- because all bound variables should be replaced by free variables during
-- this part of type checking.
--
-- The judgment @Γ ⊢ M ▹ M' ∈ A@ is defined inductively as follows:
--
-- @
--      Γ ∋ x : A
--    ------------- variable
--    Γ ⊢ x ▹ x ∈ A
--
--          Δ ∋ n : A
--    ---------------------- definition
--    Δ ⊢ n ▹ decname[n] ∈ A
--
--    A type   A ∋ M ▹ M'
--    ------------------- annotation
--      M : A ▹ M' ∈ A
--
--    M ▹ M' ∈ A → B   A ∋ N ▹ N'
--    --------------------------- application
--        M N ▹ app(M';N') ∈ B
--
--    Mi ▹ M'i ∈ Ai   Pj → Nj ▹ N'j from A0,...,Am to B
--    -------------------------------------------------- case
--    case M0 | ... | Mm of { P0 → N0; ...; Pn → Nn }
--    ▹ case(M'0,...,M'm; cl(P0,N'0),...,cl(Pn;N'n)) ∈ B
--
--    Σ ∋ n : [α*](A0,...,Ak)B
--    [σ]B = B'
--    Σ ⊢ [σ]Ai ∋ Mi ▹ M'
--    ---------------------------------------------- builtin
--    Σ ⊢ !n M0 ... Mk ▹ builtin[n](M'0,...,M'k) ∈ B
-- @
--
-- Functions are not officially synthesizable but they're supported here to be
-- as user friendly as possible. Successful synthesis relies on the
-- unification mechanism to fully instantiate the variable's type. The
-- pseudo-rule that is used below is
--
-- @
--       Γ, x : A ⊢ M ▹ M' ∈ B
--    ---------------------------- function
--    Γ ⊢ λx → M ▹ λ(x.M') ∈ A → B
-- @
--
-- The same is true of constructed data, which is given by the pseudo-rule
--
-- @
--    Σ ∋ n : [α*](A0,...,An)B
--    [σ]B = B'
--    Σ ⊢ [σ]Ai ∋ Mi ▹ M'i
--    ------------------------------------------ constructed data
--    Σ ⊢ B' ∋ n M0 ... Mn ▹ con[n](M'0,...,M'n)
-- @

synthify :: Term -> TypeChecker (Core.Term, Type)
synthify (Var (Bound _ _)) =
  error "A bound variable should never be the subject of type synthesis."
synthify (Var (Free n)) =
  do t <- typeInContext n
     return (Var (Free n), t)
synthify (Var (Meta _)) =
  error "Metavariables should not be the subject of type synthesis."
synthify (In (Decname x)) =
  do t <- typeInDefinitions x
     return (Core.decnameH x, t)
synthify (In (Ann m t)) =
  do isType t
     m' <- checkify (instantiate0 m) t
     subs <- getElab substitution
     return (m', substMetas subs t)
synthify m@(In (Let _ _ _)) =
  throwError $ "Cannot synthesize the type of the let expression: "
            ++ pretty m
synthify (In (Lam sc)) =
  do [n@(FreeVar v)] <- freshRelTo (names sc) context
     meta <- nextElab nextMeta
     let arg = Var (Meta meta)
     (m,ret) <- extendElab context [(n, arg)]
                $ synthify (instantiate sc [Var (Free n)])
     subs <- getElab substitution
     return (Core.lamH v m, funH (substMetas subs arg) ret)
synthify (In (App f a)) =
  do (f', t) <- synthify (instantiate0 f)
     t' <- instantiateQuantifiers t
     case t' of
       In (Fun arg ret) -> do
         a' <- checkify (instantiate0 a) (instantiate0 arg)
         subs <- getElab substitution
         return (Core.appH f' a', substMetas subs (instantiate0 ret))
       _ -> throwError $ "Expected a function type when checking"
                      ++ " the expression: " ++ pretty (instantiate0 f)
                      ++ "\nbut instead found: " ++ pretty t'
synthify (In (Con c as)) =
  do ConSig argscs retsc <- typeInSignature c
     (args',ret') <- instantiateParams argscs retsc
     let las = length as
         largs' = length args'
     unless (las == largs')
       $ throwError $ c ++ " expects " ++ show largs' ++ " "
                 ++ (if largs' == 1 then "arg" else "args")
                 ++ " but was given " ++ show las
     as' <- checkifyMulti (map instantiate0 as) args'
     subs <- getElab substitution
     return (Core.conH c as', substMetas subs ret')
synthify (In (Case ms cs)) =
  do (ms', as) <- unzip <$> mapM (synthify.instantiate0) ms
     (cs', b) <- synthifyClauses as cs
     return (Core.caseH ms' cs', b)
synthify m@(In (Success _)) =
  throwError $ "Cannot synthesize the type of the success expression: "
            ++ pretty m
synthify m@(In Failure) =
  throwError $ "Cannot synthesize the type of the failure expression: "
            ++ pretty m
synthify m@(In (Bind _ _)) =
  throwError $ "Cannot synthesize the type of the bind expression: "
            ++ pretty m
synthify (In (Builtin n as)) =
  do ConSig argscs retsc <- builtinInSignature n
     (args',ret') <- instantiateParams argscs retsc
     let las = length as
         largs' = length args'
     unless (las == largs')
       $ throwError $ n ++ " expects " ++ show largs' ++ " "
                 ++ (if largs' == 1 then "arg" else "args")
                 ++ " but was given " ++ show las
     as' <- checkifyMulti (map instantiate0 as) args'
     subs <- getElab substitution
     return (Core.builtinH n as', substMetas subs ret')





-- | Type synthesis for clauses corresponds to the judgment
-- @Σ;Δ;Γ ⊢ P* → M ▹ M' from A* to B@.
--
-- The judgment @Σ;Δ;Γ ⊢ P* → M ▹ M' from A* to B@ is defined as follows:
--
-- @
--    Σ ⊢ Ai pattern Pi ⊣ Γ'i
--    Σ ; Δ ; Γ, Γ'0, ..., Γ'k ⊢ B ∋ M ▹ M'
--    ------------------------------------------------------ clause
--    Σ ; Δ ; Γ ⊢ P0 | ... | Pk → M ▹ M' from A0,...,Ak to B
-- @

synthifyClause :: [Type] -> Clause -> TypeChecker (Core.Clause, Type)
synthifyClause patTys (Clause pscs sc) =
  do let lps = length pscs
     unless (length patTys == lps)
       $ throwError $ "Mismatching number of patterns. Expected "
                   ++ show (length patTys)
                   ++ " but found " ++ show lps
     ns <- freshRelTo (names sc) context
     let xs1 = map (Var . Free) ns
         xs2 = map (Var . Free) ns
         ps = map (\psc -> instantiate psc xs1) pscs
     ctx' <- forM ns $ \n -> do
               m <- nextElab nextMeta
               return (n,Var (Meta m))
     (m',a) <- extendElab context ctx' $ do
                 zipWithM_ checkifyPattern ps patTys
                 synthify (instantiate sc xs2)
     return ( Core.clauseH [ n | FreeVar n <- ns ]
                           (map convertPattern ps)
                           m'
            , a
            )
  where
    convertPattern :: Pattern -> Core.Pattern
    convertPattern (Var x) = Var x
    convertPattern (In (ConPat n ps)) =
      Core.conPatH n (map (convertPattern.instantiate0) ps)





-- | The monadic generalization of 'synthClause', ensuring that there's at
-- least one clause to check, and that all clauses have the same result type.

synthifyClauses :: [Type] -> [Clause] -> TypeChecker ([Core.Clause], Type)
synthifyClauses patTys cs =
  do (cs',ts) <- unzip <$> mapM (synthifyClause patTys) cs
     case ts of
       [] -> throwError "Empty clauses."
       t:ts' -> do
         catchError (mapM_ (unify substitution context t) ts') $ \e ->
           throwError $ "Clauses do not all return the same type:\n"
                     ++ unlines (map pretty ts) ++ "\n"
                     ++ "Unification failed with error: " ++ e
         subs <- getElab substitution
         return ( cs'
                , substMetas subs t
                )





-- | Type checking corresponds to the judgment @Γ ⊢ A ∋ M ▹ M'e@.
--
-- The judgment @Γ ⊢ A ∋ M ▹ M'@ is defined inductively as follows:
--
-- @
--    Γ, ⊢ A type
--    Γ ⊢ A ∋ M ▹ M'
--    Γ, x : A ⊢ B ∋ N ▹ N'
--    ------------------------------------------- let
--    Γ ⊢ B ∋ let x : B { M } in N ▹ let(M';x.N')
--
--       Γ, x : A ⊢ B ∋ M ▹ M'
--    --------------------------- lambda
--    Γ ⊢ A → B ∋ λx → M ▹ λ(x.M')
--
--    Σ ∋ n : [α*](A0,...,Ak)B
--    [σ]B = B'
--    Σ ⊢ [σ]Ai ∋ Mi ▹ M'i
--    ------------------------------------------ constructed data
--    Σ ⊢ B' ∋ n M0 ... Mn ▹ con[n](M'0,...,M'k)
--
--               A ∋ M ▹ M'
--    -------------------------------- success
--    Comp A ∋ success M ▹ success(M')
--
--    -------------------------- failure
--    Comp A ∋ failure ▹ failure
--
--    Γ ⊢ M ▹ M' ∈ Comp A   Γ, x : A ⊢ Comp B ∋ N ▹ N'
--    ------------------------------------------------ bind
--     Γ ⊢ Comp B ∋ do { x  ← M ; N } ▹ bind(M';x.N')
--
--    Γ, α type ⊢ A ∋ M ▹ M'
--    ---------------------- forall
--      Γ ⊢ ∀α.A ∋ M ▹ M'
--
--    M ▹ M' ∈ A   A ⊑ B
--    ------------------ direction change
--        B ∋ M ▹ M'
-- @

checkify :: Term -> Type -> TypeChecker Core.Term
checkify m (In (Forall sc)) =
  do [n] <- freshRelTo (names sc) context
     extendElab tyVarContext [n]
       $ checkify m (instantiate sc [Var (Free n)])
checkify (In (Let a m sc)) b =
  do [n@(FreeVar x)] <- freshRelTo (names sc) context
     m' <- checkify (instantiate0 m) a
     n' <- extendElab context [(n, a)]
           $ checkify (instantiate sc [Var (Free n)]) b
     return $ Core.letH m' x n'
checkify (In (Lam sc)) (In (Fun arg ret)) =
  do [n@(FreeVar x)] <- freshRelTo (names sc) context
     m' <- extendElab context [(n, instantiate0 arg)]
           $ checkify
               (instantiate sc [Var (Free n)])
               (instantiate0 ret)
     return $ Core.lamH x m'
checkify (In (Lam sc)) t =
  throwError $ "Cannot check term: " ++ pretty (In (Lam sc)) ++ "\n"
            ++ "Against non-function type: " ++ pretty t
checkify (In (Con c as)) b =
  do ConSig argscs retsc <- typeInSignature c
     (args',ret') <- instantiateParams argscs retsc
     let las = length as
         largs' = length args'
     unless (las == largs')
       $ throwError $ c ++ " expects " ++ show largs' ++ " "
                 ++ (if largs' == 1 then "arg" else "args")
                 ++ " but was given " ++ show las
     unify substitution context b ret'
     subs <- getElab substitution
     as' <- checkifyMulti (map instantiate0 as)
                          (map (substMetas subs) args')
     return $ Core.conH c as'
checkify (In (Success m)) (In (Comp a)) =
  do m' <- checkify (instantiate0 m) (instantiate0 a)
     return $ Core.successH m'
checkify (In (Success m)) a =
  throwError $ "Cannot check term: " ++ pretty (In (Success m)) ++ "\n"
            ++ "Against non-computation type: " ++ pretty a
checkify (In Failure) (In (Comp _)) =
  return Core.failureH
checkify (In Failure) a =
  throwError $ "Cannot check term: " ++ pretty (In Failure) ++ "\n"
            ++ "Against non-computation type: " ++ pretty a
checkify (In (Bind m sc)) (In (Comp b)) =
  do (m',ca) <- synthify (instantiate0 m)
     case ca of
       In (Comp a) -> do
         [v@(FreeVar x)] <- freshRelTo (names sc) context
         n' <- extendElab context [(v, instantiate0 a)]
               $ checkify
                   (instantiate sc [Var (Free v)])
                   (instantiate0 b)
         return $ Core.bindH m' x n'
       _ -> throwError $ "Expected a computation type but found " ++ pretty ca
                      ++ "When checking term " ++ pretty (instantiate0 m)
checkify (In (Bind m sc)) b =
  throwError $ "Cannot check term: " ++ pretty (In (Bind m sc)) ++ "\n"
            ++ "Against non-computation type: " ++ pretty b
checkify m t =
  do (m',t') <- synthify m
     subtype t' t
     return m'





-- | Checkifying a sequence of terms involves chaining substitutions
-- appropriately. This doesn't correspond to a particular judgment so much
-- as a by product of the need to explicitly propagate the effects of
-- unification.

checkifyMulti :: [Term] -> [Type] -> TypeChecker [Core.Term]
checkifyMulti [] [] = return []
checkifyMulti (m:ms) (t:ts) =
  do subs <- getElab substitution
     m' <- checkify m (substMetas subs t)
     ms' <- checkifyMulti ms ts
     return $ m':ms'
checkifyMulti _ _ =
  throwError "Mismatched constructor signature lengths."






-- | This function checks if the first type is a subtype of the second. This
-- corresponds to the judgment @S ⊑ T@ which is defined inductively as:
--
-- @
--     S ⊑ T
--    --------
--    S ⊑ ∀α.T
--
--    [A/α]S ⊑ T
--    ----------
--     ∀α.S ⊑ T
--
--    A' ⊑ A   B ⊑ B'
--    ---------------
--    A → B ⊑ A' → B'
--
--    -----
--    A ⊑ A
-- @

subtype :: Type -> Type -> TypeChecker ()
subtype t (In (Forall sc')) =
  do [n] <- freshRelTo (names sc') context
     subtype t (instantiate sc' [Var (Free n)])
subtype (In (Forall sc)) t' =
  do meta <- nextElab nextMeta
     let x2 = Var (Meta meta)
     subtype (instantiate sc [x2]) t'
subtype (In (Fun arg ret)) (In (Fun arg' ret')) =
  do subtype (instantiate0 arg') (instantiate0 arg)
     subtype (instantiate0 ret) (instantiate0 ret')
subtype t t' =
  unify substitution context t t'





-- | Type checking for patterns corresponds to the judgment
-- @Σ ⊢ A pattern P ⊣ Γ'@, where @Γ'@ is an output context.
--
-- The judgment @Σ ⊢ A pattern P ⊣ Γ'@ is defined inductively as follows:
--
-- @
--    -----------------------
--    Σ ⊢ A pattern x ⊣ x : A
--
--    Σ ∋ n : [α*](A0,...,Ak)B
--    [σ]B = B'
--    Σ ⊢ Ai pattern Pi ⊣ Γ'i
--    ----------------------------------------
--    Σ ⊢ B' pattern n P0 ... Pk ⊣ Γ'0,...,Γ'k
-- @

checkifyPattern :: Pattern -> Type -> TypeChecker ()
checkifyPattern (Var (Bound _ _)) _ =
  error "A bound variable should not be the subject of pattern type checking."
checkifyPattern (Var (Meta _)) _ =
  error "Metavariables should not be the subject of type checking."
checkifyPattern (Var (Free n)) t =
  do t' <- typeInContext n
     unify substitution context t t'
checkifyPattern (In (ConPat c ps)) t =
  do ConSig argscs retsc <- typeInSignature c
     (args',ret') <- instantiateParams argscs retsc
     let lps = length ps
         largs' = length args'
     unless (lps == largs')
       $ throwError $ c ++ " expects " ++ show largs' ++ " "
                 ++ (if largs' == 1 then "arg" else "args")
                 ++ " but was given " ++ show lps
     unify substitution context t ret'
     subs <- getElab substitution
     zipWithM_
       checkifyPattern
       (map instantiate0 ps)
       (map (substMetas subs) args')





-- | Type checking of constructor signatures corresponds to the judgment
-- @Γ ⊢ [α*](A0,...,Ak)B consig@ which is defined as
--
-- @
--    Γ, α* type ⊢ Ai type   Γ, α* type ⊢ B type
--    ------------------------------------------
--           Γ ⊢ [α*](A0,...,An)B consig
-- @
--
-- Because of the ABT representation, however, the scope is pushed down inside
-- the 'ConSig' constructor, onto its arguments.
--
-- This synthesis rule is not part of the spec proper, but rather is a
-- convenience method for the elaboration process because constructor
-- signatures are already a bunch of information in the implementation.

checkifyConSig :: ConSig -> TypeChecker ()
checkifyConSig (ConSig argscs retsc) =
  do ns <- freshRelTo (names retsc) context
     let xs = map (Var . Free) ns
     extendElab tyVarContext ns $ do
       forM_ argscs $ \sc -> isType (instantiate sc xs)
       isType (instantiate retsc xs)





-- | All metavariables have been solved when the next metavar to produces is
-- the number of substitutions we've found.

metasSolved :: TypeChecker ()
metasSolved = do s <- get
                 unless (_nextMeta s == MetaVar (length (_substitution s)))
                   $ throwError "Not all metavariables have been solved."





-- | Checking is just checkifying with a requirement that all metas have been
-- solved.

check :: Term -> Type -> TypeChecker Core.Term
check m t = do m' <- checkify m t
               metasSolved
               return m'





-- | Synthesis is just synthifying with a requirement that all metas have been
-- solved. The returned type is instantiated with the solutions.

synth :: Term -> TypeChecker (Core.Term,Type)
synth m = do (m',t) <- synthify m
             metasSolved
             subs <- getElab substitution
             return (m', substMetas subs t)