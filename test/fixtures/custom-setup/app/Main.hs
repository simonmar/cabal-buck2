module Main (main) where

import Custom.Dep (libdir)

main :: IO ()
main = putStrLn libdir
