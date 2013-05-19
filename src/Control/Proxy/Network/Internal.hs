{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_HADDOCK hide #-}

-- | This module doesn't belong to this namespace, but really, I don't
-- know where it belongs. Suggestions welcome.
--
-- There's a @data-timeout@ package, maybe we should depend on that.

module Control.Proxy.Network.Internal (
    Timeout(..)
  , recv
  , send
  ) where

import qualified Data.ByteString               as B
import qualified Control.Exception             as E
import           Data.Typeable                 (Typeable)
import qualified GHC.IO.Exception              as Eg
import qualified Network.Socket                as NS
import qualified Network.Socket.ByteString


-- |Exception thrown when a timeout has elapsed.
data Timeout
  = Timeout String -- ^Timeouted with an additional explanatory message.
  deriving (Eq, Show, Typeable)

instance E.Exception Timeout where


--------------------------------------------------------------------------------

-- | Read up to a limited number of bytes from a socket.
--
-- Returns `Nothing` if the remote end closed the connection (“Broken Pipe”) or
-- EOF was reached.
recv :: NS.Socket -> Int -> IO (Maybe B.ByteString)
recv sock nbytes =
    E.handle (\Eg.IOError{Eg.ioe_type=Eg.ResourceVanished} -> return Nothing)
             (do bs <- Network.Socket.ByteString.recv sock nbytes
                 if B.null bs then return Nothing
                              else return (Just bs))
{-# INLINE recv #-}

-- | Writes the given bytes to the socket.
--
-- Returns `False` if the remote end closed the connection (“Broken Pipe”),
-- otherwise `True`.
send :: NS.Socket -> B.ByteString -> IO Bool
send sock bs =
    E.handle (\Eg.IOError{Eg.ioe_type=Eg.ResourceVanished} -> return False)
             (do Network.Socket.ByteString.sendAll sock bs
                 return True)
{-# INLINE send #-}
