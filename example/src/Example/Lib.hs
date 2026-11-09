{-# LANGUAGE TemplateHaskell #-}

module Example.Lib (hello, greet, addPoints, greetFirst, makeGreeters, getDataFileContents, embeddedDataFile) where

import Acme.Box (box)
import Example.Embed (embedDataFile)
import Example.Greeters (makeGreeters)
import Example.Point (Point(..), addPoint)
import Example.TH (makeGreeter)
import Safe (headMay)
import Paths_example

$(makeGreeter "greet")

-- This splice uses the 'makeGreeters' TH defined in this library
-- itself.
$(makeGreeters ["hello"])

addPoints :: Int -> Int -> IO Int
addPoints x y = do
  -- 'box' comes from the source-repository-pacakge acme-box. It is
  -- defined as 'box = pure ()' and does nothing except for testing
  -- that source-repository-packages work correctly.
  box
  addPoint (Point (fromIntegral x) (fromIntegral y))

-- | Uses the `safe` package (not a GHC boot library) so that
-- gen-haskell-prebuilt.py has at least one real cabal-store package to
-- resolve, rather than only GHC-bundled ones.
greetFirst :: [String] -> String
greetFirst names = case headMay names of
  Just n -> greet n
  Nothing -> "Hello, stranger!"

-- | Test reading the contents of something in data-files
getDataFileContents :: IO String
getDataFileContents = readFile =<< getDataFileName "data/data-file.txt"

-- | Test reading the contents of something in data-files in a splice
embeddedDataFile :: String
embeddedDataFile = $(embedDataFile "data/data-file.txt")
