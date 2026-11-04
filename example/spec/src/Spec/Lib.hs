{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
-- | The library component of the spec fixture: a CPP #include of a header
-- from the component's include-dirs, and a foreign call into a system
-- library named in extra-libraries.
module Spec.Lib (specVersion, zlibVersion) where

import Foreign.C.String (CString, peekCString)

#include "spec_version.h"

specVersion :: Int
specVersion = SPEC_VERSION

foreign import ccall "zlibVersion" c_zlibVersion :: IO CString

zlibVersion :: IO String
zlibVersion = c_zlibVersion >>= peekCString



