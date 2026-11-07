module Main (main) where

import Example.Lib (getDataFileContents)

-- | Prints one of the package's data-files, to test that @buck2 run@ finds it.
main :: IO ()
main = getDataFileContents >>= putStr
