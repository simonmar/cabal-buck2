-- | A module that imports one from another library and is imported by
-- one that uses Template Haskell. GHC compiles a module like this the
-- dynamic way too, in case a splice runs it, and so needs the dynamic
-- interfaces of the modules it imports - even though no splice here
-- does. This is what makes a library's builds for static linking (opt
-- and prof) need dynamic interfaces as well as static ones.
module Example.Greeters (makeGreeters) where

import Example.TH (makeGreeter)
import Language.Haskell.TH (Dec, Q)

makeGreeters :: [String] -> Q [Dec]
makeGreeters = fmap concat . traverse makeGreeter
