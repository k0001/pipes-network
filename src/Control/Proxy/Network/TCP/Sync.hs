-- | This module exports 'P.Proxy's that allow implementing synchronous RPC-like
-- communication with a remote end by using a simple protocol on their
-- downstream interface.
--
-- As opposed to the similar proxies found in
-- "Control.Proxy.Safe.Network.TCP.Sync", these don't use the exception handling
-- facilities provided by 'P.ExceptionP'.
--
-- You may prefer the more general and efficient proxies from
-- "Control.Proxy.Network.TCP".

module Control.Proxy.Network.TCP.Sync (
  -- * Socket proxies
  socketServer,
  socketProxy,
  -- ** Timeouts
  -- $timeouts
  socketServerTimeout,
  socketProxyTimeout,
  -- * Protocol types
  Request(..),
  Response(..),
  ) where

import           Control.Monad
import           Control.Monad.Trans.Class
import qualified Control.Proxy                    as P
import           Control.Proxy.Network.Util
import qualified Control.Proxy.Trans.Either       as PE
import qualified Data.ByteString                  as B
import           Data.Monoid
import qualified Network.Socket                   as NS
import           Network.Socket.ByteString        (recv, sendAll)
import           System.Timeout                   (timeout)


-- | A request made to one of 'socketServer' or 'socketProxy'.
data Request t = Send t | Receive Int
  deriving (Eq, Read, Show)

-- | A response received from one of 'socketServer' or 'socketProxy'.
data Response = Sent | Received B.ByteString
  deriving (Eq, Read, Show)

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
-- If the remote peer closes its side of the connection, this proxy returns.
socketServer
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> Request B.ByteString
  -> P.Server p (Request B.ByteString) Response IO ()
socketServer sock = P.runIdentityK loop where
    loop (Send bs) = do
        lift $ sendAll sock bs
        P.respond Sent >>= loop
    loop (Receive nbytes) = do
        bs <- lift $ recv sock nbytes
        unless (B.null bs) $ P.respond (Received bs) >>= loop


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
-- If the remote peer closes its side of the connection, this proxy returns.
socketProxy
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> Request a'
  -> p a' B.ByteString (Request a') Response IO ()
socketProxy sock = P.runIdentityK loop where
    loop (Send a') = do
        P.request a' >>= lift . sendAll sock
        P.respond Sent >>= loop
    loop (Receive nbytes) = do
        bs <- lift $ recv sock nbytes
        unless (B.null bs) $ P.respond (Received bs) >>= loop



-- $timeouts
--
-- These proxies behave like the similarly named ones above, except support for
-- timing out the interaction with the remote end is added.

-- | Like 'socketServer', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if interacting with the remote end takes
-- more time than specified.
socketServerTimeout
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Request B.ByteString
  -> P.Server (PE.EitherP Timeout p) (Request B.ByteString) Response IO ()
socketServerTimeout wait sock = loop where
    loop (Send bs) = do
        m <- lift . timeout wait $ sendAll sock bs
        case m of
          Nothing -> PE.throw $ ex "sendAll"
          Just () -> P.respond Sent >>= loop
    loop (Receive nbytes) = do
        mbs <- lift . timeout wait $ recv sock nbytes
        case mbs of
          Nothing -> PE.throw $ ex "recv"
          Just bs -> unless (B.null bs) $ P.respond (Received bs) >>= loop
    ex s = Timeout $ s <> ": " <> show wait <> " microseconds."

-- | Like 'socketProxy', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if interacting with the remote end takes
-- more time than specified.
socketProxyTimeout
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Request a'
  -> (PE.EitherP Timeout p) a' B.ByteString (Request a') Response IO ()
socketProxyTimeout wait sock = loop where
    loop (Send a') = do
        bs <- P.request a'
        m <- lift . timeout wait $ sendAll sock bs
        case m of
          Nothing -> PE.throw $ ex "sendAll"
          Just () -> P.respond Sent >>= loop
    loop (Receive nbytes) = do
        mbs <- lift . timeout wait $ recv sock nbytes
        case mbs of
          Nothing -> PE.throw $ ex "recv"
          Just bs -> unless (B.null bs) $ P.respond (Received bs) >>= loop
    ex s = Timeout $ s <> ": " <> show wait <> " microseconds."
