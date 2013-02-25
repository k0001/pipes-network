-- | This module exports 'P.Proxy's that allow synchronous communication with
-- a remote end using a simple RPC-like interface on their downstream end.
--
-- As opposed to the similar proxies found in "Control.Proxy.Network.TCP.Sync",
-- these use the exception handling facilities provided by 'P.ExceptionP'.
--
-- You may prefer the more general proxies from
-- "Control.Proxy.Safe.Network.TCP".

module Control.Proxy.Safe.Network.TCP.Sync (
  -- * Socket proxies
  socketServer,
  socketProxy,
  -- * Protocol
  Request(..),
  Response(..),
  ) where

import           Control.Monad
import qualified Control.Proxy             as P
import           Control.Proxy.Network.Util
import qualified Control.Proxy.Safe        as P
import qualified Data.ByteString           as B
import           Data.Monoid
import qualified Network.Socket            as NS
import           Network.Socket.ByteString (recv, sendAll)
import           System.Timeout            (timeout)

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
-- If an optional timeout is given and interactions with the remote end
-- take more time that such timeout, then throw a 'Timeout' exception in
-- the 'P.ExceptionP' proxy transformer.
--
-- If the remote peer closes its side of the connection, this proxy returns.
socketServer
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Request B.ByteString
  -> P.Server (P.ExceptionP p) (Request B.ByteString) Response P.SafeIO()
socketServer Nothing sock = loop where
    loop (Send bs) = do
        P.tryIO $ sendAll sock bs
        P.respond Sent >>= loop
    loop (Receive nbytes) = do
        bs <- P.tryIO $ recv sock nbytes
        unless (B.null bs) $ P.respond (Received bs) >>= loop
socketServer (Just wait) sock = loop where
    loop (Send bs) = do
        m <- P.tryIO . timeout wait $ sendAll sock bs
        case m of
          Nothing -> P.throw $ ex "sendAll"
          Just () -> P.respond Sent >>= loop
    loop (Receive nbytes) = do
        mbs <- P.tryIO . timeout wait $ recv sock nbytes
        case mbs of
          Nothing -> P.throw $ ex "recv"
          Just bs -> unless (B.null bs) $ P.respond (Received bs) >>= loop
    ex s = Timeout $ s <> ": " <> show wait <> " microseconds."

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
socketProxy
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Request a'
  -> (P.ExceptionP p) a' B.ByteString (Request a') Response P.SafeIO ()
socketProxy Nothing sock = loop where
    loop (Send a') = do
        P.request a' >>= P.tryIO . sendAll sock
        P.respond Sent >>= loop
    loop (Receive nbytes) = do
        bs <- P.tryIO $ recv sock nbytes
        unless (B.null bs) $ P.respond (Received bs) >>= loop
socketProxy (Just wait) sock = loop where
    loop (Send a') = do
        bs <- P.request a'
        m <- P.tryIO . timeout wait $ sendAll sock bs
        case m of
          Nothing -> P.throw $ ex "sendAll"
          Just () -> P.respond Sent >>= loop
    loop (Receive nbytes) = do
        mbs <- P.tryIO . timeout wait $ recv sock nbytes
        case mbs of
          Nothing -> P.throw $ ex "recv"
          Just bs -> unless (B.null bs) $ P.respond (Received bs) >>= loop
    ex s = Timeout $ s <> ": " <> show wait <> " microseconds."
