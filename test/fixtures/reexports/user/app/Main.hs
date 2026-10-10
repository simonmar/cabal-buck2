module Main (main) where

import New.B (valueB)
import Orig.A (valueA)
import Sub.M (m)

main :: IO ()
main = print (valueA + valueB + m)
