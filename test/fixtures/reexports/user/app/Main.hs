module Main (main) where

import New.B (valueB)
import New.X (x)
import Orig.A (valueA)
import Sub.M (m)

main :: IO ()
main = print (valueA + valueB + m + x)
