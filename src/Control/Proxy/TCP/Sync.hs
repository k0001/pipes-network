{-# LANGUAGE OverloadedStrings #-}

-- | This module exports 'P.Proxy's that allow implementing synchronous RPC-like
-- communication with a remote end by using a simple protocol on their
-- downstream interface.
--
-- As opposed to the similar proxies found in
-- "Control.Proxy.TCP.Safe.Sync", these don't use the exception handling
-- facilities provided by 'P.ExceptionP'.
--
-- You may prefer the more general and efficient proxies from
-- "Control.Proxy.TCP".

module Control.Proxy.TCP.Sync (
  -- * Socket proxies
  socketSyncServer,
  socketSyncProxy,
  -- ** Timeouts
  -- $timeouts
  socketSyncServerTimeout,
  socketSyncProxyTimeout,
  -- * RPC support
  syncDelimit,
  -- * Protocol types
  Request(..),
  Response(..),
  ) where

import           Control.Monad
import           Control.Monad.Trans.Class
import qualified Control.Proxy                    as P
import           Control.Proxy.Network.Internal
import qualified Control.Proxy.Trans.Either       as PE
import qualified Data.ByteString.Char8            as B
import           Data.Monoid
import qualified Network.Socket                   as NS
import           System.Timeout                   (timeout)


-- | A request made to one of the @socketSync*@ proxies.
data Request t = Send t | Receive Int
  deriving (Eq, Read, Show)

-- | A response received from one of the @socketSync*@ proxies.
data Response = Sent | Received B.ByteString
  deriving (Eq, Read, Show)

--------------------------------------------------------------------------------

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
socketSyncServer
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> Request B.ByteString
  -> P.Server p (Request B.ByteString) Response IO ()
socketSyncServer sock = P.runIdentityK loop where
    loop (Send bs) = do
        ok <- lift (send sock bs)
        when ok (P.respond Sent >>= loop)
    loop (Receive nbytes) = do
        mbs <- lift (recv sock nbytes)
        case mbs of
          Just bs -> P.respond (Received bs) >>= loop
          Nothing -> return ()
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
-- If the remote peer closes its side of the connection, this proxy returns.
socketSyncProxy
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> Request a'
  -> p a' B.ByteString (Request a') Response IO ()
socketSyncProxy sock = P.runIdentityK loop where
    loop (Send a') = do
        ok <- lift . send sock =<< P.request a'
        when ok (P.respond Sent >>= loop)
    loop (Receive nbytes) = do
        mbs <- lift (recv sock nbytes)
        case mbs of
          Just bs -> P.respond (Received bs) >>= loop
          Nothing -> return ()
{-# INLINABLE socketSyncProxy #-}

--------------------------------------------------------------------------------

-- $timeouts
--
-- These proxies behave like the similarly named ones above, except support for
-- timing out the interaction with the remote end is added.

-- | Like 'socketSyncServer', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if interacting with the remote end takes
-- more time than specified.
socketSyncServerTimeout
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Request B.ByteString
  -> P.Server (PE.EitherP Timeout p) (Request B.ByteString) Response IO ()
socketSyncServerTimeout wait sock = loop where
    loop (Send bs) = do
        mok <- lift (timeout wait (send sock bs))
        case mok of
          Just True  -> P.respond Sent >>= loop
          Just False -> return ()
          Nothing    -> PE.throw ex
    loop (Receive nbytes) = do
        mmbs <- lift (timeout wait (recv sock nbytes))
        case mmbs of
          Just (Just bs) -> P.respond (Received bs) >>= loop
          Just Nothing   -> return ()
          Nothing        -> PE.throw ex
    ex = Timeout $ "socketSyncServerTimeout: " <> show wait <> " microseconds."
{-# INLINABLE socketSyncServerTimeout #-}

-- | Like 'socketSyncProxy', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if interacting with the remote end takes
-- more time than specified.
socketSyncProxyTimeout
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Request a'
  -> (PE.EitherP Timeout p) a' B.ByteString (Request a') Response IO ()
socketSyncProxyTimeout wait sock = loop where
    loop (Send a') = do
        mok <- lift . timeout wait . send sock =<< P.request a'
        case mok of
          Just True  -> P.respond Sent >>= loop
          Just False -> return ()
          Nothing    -> PE.throw ex
    loop (Receive nbytes) = do
        mmbs <- lift (timeout wait (recv sock nbytes))
        case mmbs of
          Just (Just bs) -> P.respond (Received bs) >>= loop
          Just Nothing   -> return ()
          Nothing        -> PE.throw ex
    ex = Timeout $ "socketSyncProxyTimeout: " <> show wait <> " microseconds."
{-# INLINABLE socketSyncProxyTimeout #-}

--------------------------------------------------------------------------------

-- | When used together with one of the @socketSync*@ proxies upstream, this
-- proxy sends a single 'B.ByteString' to the remote end and then repeatedly
-- receives bytes from the remote end until the given delimiter is found.
-- Finally, a single 'B.ByteString' up to the given delimiter (inclusive) is
-- sent downstream and then the whole process is repeated.
--
-- This proxy works cooperatively with any @socketSync*@ proxy immediately
-- upstream, so read their documentation to understand the purpose of the
-- @b'@ value received from downstream.
--
-- For example, if you'd like to convert a 'NS.Socket' into an synchronous
-- line-oriented RPC client implemented as a 'P.Server' in which RPC calls are
-- received via the downstream interface and RPC responses are sent downstream,
-- then you could use this proxy as:
--
-- > socketSyncServer ... >-> syncDelimit 4096 "\r\n"
--
-- Otherwise, if you'd like to convert a 'NS.Socket' into an synchronous
-- line-oriented RPC client implemented as a 'P.Proxy' in which RPC calls are
-- received via the upstream interface and RPC responses are sent downstream,
-- then you could use this proxy as:
--
-- > socketSyncProxy ... >-> syncDelimit 4096 "\r\n"
syncDelimit
  :: (Monad m, P.Proxy p)
  => Int                -- ^Maximum number of bytes to receive at once.
  -> B.ByteString       -- ^Delimiting bytes.
  -> b'-> p (Request b') Response b' B.ByteString m r
syncDelimit nbytes delim b' =
    -- XXX this implementation might be inefficient.
    P.runIdentityP $ use =<< more mempty (Send b')
  where
    more buf req = do
      a <- P.request req
      case a of
        Received bs -> return (buf <> bs)
        Sent        -> more buf (Receive nbytes)
    use buf = do
      let (pre,suf) = B.breakSubstring delim buf
      case B.length suf of
        0 -> use =<< more buf (Receive nbytes)
        _ -> do b'2 <- P.respond (pre <> delim)
                use =<< more (B.drop (B.length delim) suf) (Send b'2)
{-# INLINABLE syncDelimit #-}

