{-# LANGUAGE ForeignFunctionInterface #-}
-- | A library with no C sources of its own that calls a system library
-- found through pkgconfig-depends.
module Spec.PC (zlibCompileFlags) where

import Foreign.C.Types (CULong (..))

foreign import ccall "zlibCompileFlags" c_zlibCompileFlags :: IO CULong

zlibCompileFlags :: IO Integer
zlibCompileFlags = fromIntegral <$> c_zlibCompileFlags
