-- | This module exports functions that allow you to safely use 'NS.Socket'
-- resources acquired and released outside a 'P.Proxy' pipeline.
--
-- Instead, if want to safely acquire and release resources within the
-- pipeline itself, then you should use the functions exported by
-- "Control.Proxy.TCP.Safe".
--
-- This module re-exports many functions from "Network.Simple.TCP"
-- module in the @network-simple@ package. You might refer to that
-- module for more documentation.


module Control.Proxy.TCP (
  -- * Server side
  -- $server-side
    S.serve
  -- ** Listening
  , S.listen
  -- ** Accepting
  , S.accept
  , S.acceptFork

  -- * Client side
  -- $client-side
  , S.connect

  -- * Socket streams
  -- $socket-streaming
  , socketReadS
  , nsocketReadS
  , socketWriteD
  -- ** Timeouts
  -- $socket-streaming-timeout
  , socketReadTimeoutS
  , nsocketReadTimeoutS
  , socketWriteTimeoutD

  -- * Exports
  , S.HostPreference(..)
  , Timeout(..)
  ) where

import           Control.Monad
import           Control.Monad.Trans.Class
import qualified Control.Proxy                  as P
import qualified Control.Proxy.Trans.Either     as PE
import           Control.Proxy.Network.Internal
import qualified Data.ByteString                as B
import           Data.Monoid
import qualified Network.Socket                 as NS
import           Network.Socket.ByteString      (recv, sendAll)
import qualified Network.Simple.TCP             as S
import           System.Timeout                 (timeout)

--------------------------------------------------------------------------------

-- $client-side
--
-- Here's how you could run a TCP client:
--
-- > connect "www.example.org" "80" $ \(connectionSocket, remoteAddr) -> do
-- >   putStrLn $ "Connection established to " ++ show remoteAddr
-- >   -- now you may use connectionSocket as you please within this scope.
-- >   -- possibly with any of the socketReadS, nsocketReadS or socketWriteD
-- >   -- proxies explained below.

--------------------------------------------------------------------------------

-- $server-side
--
-- Here's how you can run a TCP server that handles in different threads each
-- incoming connection to port @8000@ at IPv4 address @127.0.0.1@:
--
-- > serve (Host "127.0.0.1") "8000" $ \(connectionSocket, remoteAddr) -> do
-- >   putStrLn $ "TCP connection established from " ++ show remoteAddr
-- >   -- now you may use connectionSocket as you please within this scope.
-- >   -- possibly with any of the socketReadS, nsocketReadS or socketWriteD
-- >   -- proxies explained below.
--
-- If you need more control on the way your server runs, then you can use more
-- advanced functions such as 'listen', 'accept' and 'acceptFork'.

--------------------------------------------------------------------------------

-- $socket-streaming
--
-- Once you have a connected 'NS.Socket', you can use the following 'P.Proxy's
-- to interact with the other connection end using streams.

-- | Receives bytes from the remote end sends them downstream.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
socketReadS
  :: P.Proxy p
  => Int                -- ^Maximum number of bytes to receive at once.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer p B.ByteString IO ()
socketReadS nbytes sock () = P.runIdentityP loop where
    loop = do
      bs <- lift $ recv sock nbytes
      unless (B.null bs) $ P.respond bs >> loop
{-# INLINABLE socketReadS #-}

-- | Just like 'socketReadS', except each request from downstream specifies the
-- maximum number of bytes to receive.
nsocketReadS
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> Int -> P.Server p Int B.ByteString IO ()
nsocketReadS sock = P.runIdentityK loop where
    loop nbytes = do
      bs <- lift $ recv sock nbytes
      unless (B.null bs) $ P.respond bs >>= loop
{-# INLINABLE nsocketReadS #-}

-- | Sends to the remote end the bytes received from upstream, then forwards
-- such same bytes downstream.
--
-- Requests from downstream are forwarded upstream.
socketWriteD
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> x -> p x B.ByteString x B.ByteString IO r
socketWriteD sock = P.runIdentityK loop where
    loop x = do
      a <- P.request x
      lift $ sendAll sock a
      P.respond a >>= loop
{-# INLINABLE socketWriteD #-}

--------------------------------------------------------------------------------

-- $socket-streaming-timeout
--
-- These proxies behave like the similarly named ones above, except support for
-- timing out the interaction with the remote end is added.

-- | Like 'socketReadS', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if receiving data from the remote end takes
-- more time than specified.
socketReadTimeoutS
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> Int                -- ^Maximum number of bytes to receive at once.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer (PE.EitherP Timeout p) B.ByteString IO ()
socketReadTimeoutS wait nbytes sock () = loop where
    loop = do
      mbs <- lift . timeout wait $ recv sock nbytes
      case mbs of
        Nothing -> PE.throw ex
        Just bs -> unless (B.null bs) $ P.respond bs >> loop
    ex = Timeout $ "recv: " <> show wait <> " microseconds."
{-# INLINABLE socketReadTimeoutS #-}

-- | Like 'nsocketReadS', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if receiving data from the remote end takes
-- more time than specified.
nsocketReadTimeoutS
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Int -> P.Server (PE.EitherP Timeout p) Int B.ByteString IO ()
nsocketReadTimeoutS wait sock = loop where
    loop nbytes = do
      mbs <- lift . timeout wait $ recv sock nbytes
      case mbs of
        Nothing -> PE.throw ex
        Just bs -> unless (B.null bs) $ P.respond bs >>= loop
    ex = Timeout $ "recv: " <> show wait <> " microseconds."
{-# INLINABLE nsocketReadTimeoutS #-}

-- | Like 'socketWriteD', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if sending data to the remote end takes
-- more time than specified.
socketWriteTimeoutD
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> x -> (PE.EitherP Timeout p) x B.ByteString x B.ByteString IO r
socketWriteTimeoutD wait sock = loop where
    loop x = do
      a <- P.request x
      mbs <- lift . timeout wait $ sendAll sock a
      case mbs of
        Nothing -> PE.throw ex
        Just () -> P.respond a >>= loop
    ex = Timeout $ "recv: " <> show wait <> " microseconds."
{-# INLINABLE socketWriteTimeoutD #-}

