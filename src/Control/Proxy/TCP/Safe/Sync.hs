-- | This module exports 'P.Proxy's that allow implementing synchronous RPC-like
-- communication with a remote end by using a simple protocol on their
-- downstream interface.
--
-- As opposed to the similar proxies found in "Control.Proxy.TCP.Sync",
-- these use the exception handling facilities provided by 'P.ExceptionP'.
--
-- You may prefer the more general proxies from
-- "Control.Proxy.TCP.Safe".

module Control.Proxy.TCP.Safe.Sync (
  -- * Socket proxies
  socketSyncServer,
  socketSyncProxy,
  -- * RPC support
  syncDelimit,
  -- * Protocol
  Request(..),
  Response(..),
  ) where

import           Control.Monad
import qualified Control.Proxy                    as P
import           Control.Proxy.TCP.Sync
                    (Request(..), Response(..), syncDelimit)
import           Control.Proxy.Network.Internal
import qualified Control.Proxy.Safe               as P
import qualified Data.ByteString                  as B
import           Data.Monoid
import qualified Network.Socket                   as NS
import           System.Timeout                   (timeout)


-- | 'P.Server' able to send and receive bytes through a 'NS.Socket'.
--
-- If downstream requests @'Send' bytes@, then such @bytes@ are sent to the
-- remote end and then this proxy responds 'Sent' downstream.
--
-- If downstream requests @'Receive' num@, then at most @num@ bytes are received
-- from the remote end. This proxy then responds downstream such received
-- bytes as @'Received' bytes@. Less than the specified maximum number of bytes
-- might be received at once.
--
-- If an optional timeout is given and interactions with the remote end
-- take more time that such timeout, then throw a 'Timeout' exception in
-- the 'P.ExceptionP' proxy transformer.
--
-- If the remote peer closes its side of the connection, this proxy returns.
socketSyncServer
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Request B.ByteString
  -> P.Server (P.ExceptionP p) (Request B.ByteString) Response P.SafeIO ()
socketSyncServer Nothing sock = loop where
    loop (Send bs) = do
        ok <- P.tryIO (send sock bs)
        when ok (P.respond Sent >>= loop)
    loop (Receive nbytes) = do
        mbs <- P.tryIO (recv sock nbytes)
        case mbs of
          Just bs -> P.respond (Received bs) >>= loop
          Nothing -> return ()
socketSyncServer (Just wait) sock = loop where
    loop (Send bs) = do
        mok <- P.tryIO (timeout wait (send sock bs))
        case mok of
          Just True  -> P.respond Sent >>= loop
          Just False -> return ()
          Nothing    -> P.throw ex
    loop (Receive nbytes) = do
        mmbs <- P.tryIO (timeout wait (recv sock nbytes))
        case mmbs of
          Just (Just bs) -> P.respond (Received bs) >>= loop
          Just Nothing   -> return ()
          Nothing        -> P.throw ex
    ex = Timeout $ "socketSyncServer: " <> show wait <> " microseconds."
{-# INLINABLE socketSyncServer #-}

-- | 'P.Proxy' able to send and receive bytes through a 'NS.Socket'.
--
-- If downstream requests @'Send' a'@, then such @a'@ request is forwarded
-- upstream, which in return responds a 'B.ByteString' that this proxy sends to
-- the remote end. After sending to the remote end, this proxy responds 'Sent'
-- downstream.
--
-- If downstream requests @'Receive' num@, then at most @num@ bytes are received
-- from the remote end. This proxy then responds downstream such received
-- bytes as @'Received' bytes@. Less than the specified maximum number of bytes
-- might be received at once.
--
-- If an optional timeout is given and interactions with the remote end
-- take more time that such timeout, then throw a 'Timeout' exception in
-- the 'P.ExceptionP' proxy transformer.
--
-- If the remote peer closes its side of the connection, this proxy returns.
socketSyncProxy
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Request a'
  -> (P.ExceptionP p) a' B.ByteString (Request a') Response P.SafeIO ()
socketSyncProxy Nothing sock = loop where
    loop (Send a') = do
        ok <- P.tryIO . send sock =<< P.request a'
        when ok (P.respond Sent >>= loop)
    loop (Receive nbytes) = do
        mbs <- P.tryIO (recv sock nbytes)
        case mbs of
          Just bs -> P.respond (Received bs) >>= loop
          Nothing -> return ()
socketSyncProxy (Just wait) sock = loop where
    loop (Send a') = do
        bs <- P.request a'
        mok <- P.tryIO (timeout wait (send sock bs))
        case mok of
          Just True  -> P.respond Sent >>= loop
          Just False -> return ()
          Nothing    -> P.throw ex
    loop (Receive nbytes) = do
        mmbs <- P.tryIO (timeout wait (recv sock nbytes))
        case mmbs of
          Just (Just bs) -> P.respond (Received bs) >>= loop
          Just Nothing   -> return ()
          Nothing        -> P.throw ex
    ex = Timeout $ "socketSyncProxy: " <> show wait <> " microseconds."
{-# INLINABLE socketSyncProxy #-}


