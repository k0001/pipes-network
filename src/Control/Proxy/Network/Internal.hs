{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_HADDOCK hide #-}

-- | This module doesn't belong to this namespace, but really, I don't
-- know where it belongs. Suggestions welcome.
--
-- There's a @data-timeout@ package, maybe we should depend on that.

module Control.Proxy.Network.Internal (
  Timeout(..)
  ) where

import qualified Control.Exception             as E
import           Data.Typeable                 (Typeable)


-- |Exception thrown when a timeout has elapsed.
data Timeout
  = Timeout String -- ^Timeouted with an additional explanatory message.
  deriving (Eq, Show, Typeable)

instance E.Exception Timeout where
