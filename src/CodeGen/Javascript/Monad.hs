{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleInstances #-}
module CodeGen.Javascript.Monad (
  JSGen, genJS, emit, dependOn, getModName, pushBinding, popBinding,
  getCurrentBinding, isolate, addLocal) where
import Control.Monad.State
import Bag
import CodeGen.Javascript.AST hiding (code, deps)
import qualified Data.Set as S
import Control.Applicative
import GhcPlugins (Var)

data GenState = GenState {
    code         :: !(Bag JSStmt),
    deps         :: !(S.Set JSVar),
    locals       :: !(S.Set JSVar),
    modName      :: JSLabel,
    bindingStack :: [Var]
  }

initialState :: GenState
initialState = GenState {
    code         = emptyBag,
    deps         = S.empty,
    locals       = S.empty,
    modName      = undefined,
    bindingStack = []
  }

newtype JSGen a =
  JSGen (State GenState a)
  deriving (Monad, Functor, Applicative)

class Dependency a where
  -- | Add a dependency to the function currently being generated.
  dependOn :: a -> JSGen ()
  -- | Mark a symbol as local, excluding it from the dependency graph.
  addLocal :: a -> JSGen ()

instance Dependency JSVar where
  dependOn var = JSGen $ do
    st <- get
    put st {deps = S.insert var (deps st)}

  addLocal var = JSGen $ do
    st <- get
    put st {locals = S.insert var (locals st)}

instance Dependency (S.Set JSVar) where
  dependOn vars = JSGen $ do
    st <- get
    put st {deps = S.union vars (deps st)}

  addLocal vars = JSGen $ do
    st <- get
    put st {locals = S.union vars (locals st)}

genJS :: JSLabel     -- ^ Name of the module being compiled.
      -> JSGen a     -- ^ The code generation computation.
      -> (a, S.Set JSVar, S.Set JSVar, Bag JSStmt)
genJS myModName (JSGen gen) =
  case runState gen initialState {modName = myModName} of
    (a, GenState stmts dependencies loc _ _) -> (a, dependencies, loc, stmts)

-- | Emit a JS statement to the code stream
emit :: JSStmt -> JSGen ()
emit stmt = JSGen $ do
  st <- get
  put st {code = code st `snocBag` stmt}

getModName :: JSGen JSLabel
getModName = JSGen $ modName <$> get

-- | Get the Var for the binding currently being generated.
getCurrentBinding :: JSGen Var
getCurrentBinding = JSGen $ (head . bindingStack) <$> get

-- | Push a new var onto the stack, indicating that we're generating code
--   for a new binding.
pushBinding :: Var -> JSGen ()
pushBinding var = JSGen $ do
  st <- get
  put st {bindingStack = var : bindingStack st}

-- | Pop a var from the stack, indicating that we're done generating code
--   for that binding.
popBinding :: JSGen ()
popBinding = JSGen $ do
  st <- get
  put st {bindingStack = tail $ bindingStack st}

-- | Run a GenJS computation in isolation, returning its results rather than
--   writing them to the output stream. Dependencies and locals are still
--   updated, however.
--   In addition to the return value and the code, all variables accessed
--   within the computation are returned.
isolate :: JSGen a -> JSGen (a, Bag JSStmt, S.Set JSVar)
isolate gen = do
  myMod <- getModName
  myBnd <- getCurrentBinding
  let (x, dep, loc, stmts) = genJS myMod $ do
        pushBinding myBnd >> gen
  dependOn dep
  addLocal loc
  return (x, stmts, dep)
