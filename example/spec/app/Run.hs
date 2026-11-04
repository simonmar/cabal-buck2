module Run (main) where

import Main (helper)
import Spec.PC (zlibCompileFlags)

main :: IO ()
main = do
  flags <- zlibCompileFlags
  putStrLn (helper ++ " " ++ show flags)
