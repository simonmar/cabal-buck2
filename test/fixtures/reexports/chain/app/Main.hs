module Main (main) where

import Newer.B (valueB)
import Orig.A (valueA)

main :: IO ()
main = print (valueA + valueB)
