-- | A splice that reads one of the package's data-files, so the test project
-- exercises finding them at compile time as well as when it runs.
module Example.Embed (embedDataFile) where

import Language.Haskell.TH (Exp, Q, runIO, stringE)
import Paths_example (getDataFileName)

embedDataFile :: FilePath -> Q Exp
embedDataFile path = runIO (readFile =<< getDataFileName path) >>= stringE
