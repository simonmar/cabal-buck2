{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import Control.Monad (unless)
import Language.Haskell.TH (litE, stringL, runIO)
import Spec.Lib (specVersion, zlibVersion)
import System.Exit (exitFailure)

-- Calling into the library at compile time makes GHC load its shared
-- object, which must therefore link against the system libraries the
-- library itself names in extra-libraries.
versionAtCompileTime :: String
versionAtCompileTime = $(runIO zlibVersion >>= litE . stringL)

main :: IO ()
main = do
  v <- zlibVersion
  unless (v == versionAtCompileTime && specVersion == 7) exitFailure
  putStrLn ("spec ok: zlib " ++ v)
