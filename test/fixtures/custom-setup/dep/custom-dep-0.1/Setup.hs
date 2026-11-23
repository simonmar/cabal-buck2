import Distribution.Simple
import System.Directory (createDirectoryIfMissing)

-- This generates Custom.Generated, the module that autogen-modules lists, so
-- that cabal can build the package into the store. With --enable-custom-setup,
-- cabal buck2 doesn't run this file, so the project has to provide the module.
main :: IO ()
main =
  defaultMainWithHooks
    simpleUserHooks
      { preBuild = \args flags -> do
          createDirectoryIfMissing True "Custom"
          writeFile "Custom/Generated.hs" "module Custom.Generated where\n"
          preBuild simpleUserHooks args flags
      }
