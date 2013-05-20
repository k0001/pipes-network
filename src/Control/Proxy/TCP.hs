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
  -- * Client side
  -- $client-side
    S.connect

  -- * Server side
  -- $server-side
  , S.serve
  -- ** Listening
  , S.listen
  -- ** Accepting
  , S.accept
  , S.acceptFork

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

import           Control.Monad.Trans.Class
import qualified Control.Proxy                  as P
import qualified Control.Proxy.Trans.Either     as PE
import           Control.Proxy.Network.Internal
import qualified Data.ByteString                as B
import           Data.Monoid
import qualified Network.Socket                 as NS
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
-- This proxy returns if the remote peer closes its side of the connection or
-- EOF is received.
socketReadS
  :: P.Proxy p
  => Int                -- ^Maximum number of bytes to receive and send
                        -- dowstream at once. Any positive value is fine, the
                        -- optimal value depends on how you deal with the
                        -- received data. Try using @4096@ if you don't care.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer p B.ByteString IO ()
socketReadS nbytes sock () = P.runIdentityP loop where
    loop = do
      mbs <- lift (recv sock nbytes)
      case mbs of
        Just bs -> P.respond bs >> loop
        Nothing -> return ()
{-# INLINABLE socketReadS #-}

-- | Just like 'socketReadS', except each request from downstream specifies the
-- maximum number of bytes to receive.
nsocketReadS
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> Int -> P.Server p Int B.ByteString IO ()
nsocketReadS sock = P.runIdentityK loop where
    loop nbytes = do
      mbs <- lift (recv sock nbytes)
      case mbs of
        Just bs -> P.respond bs >>= loop
        Nothing -> return ()
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
      lift (send sock a)
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
  -> Int                -- ^Maximum number of bytes to receive and send
                        -- dowstream at once. Any positive value is fine, the
                        -- optimal value depends on how you deal with the
                        -- received data. Try using @4096@ if you don't care.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer (PE.EitherP Timeout p) B.ByteString IO ()
socketReadTimeoutS wait nbytes sock () = loop where
    loop = do
      mmbs <- lift (timeout wait (recv sock nbytes))
      case mmbs of
        Just (Just bs) -> P.respond bs >> loop
        Just Nothing   -> return ()
        Nothing        -> PE.throw ex
    ex = Timeout $ "socketReadTimeoutS: " <> show wait <> " microseconds."
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
      mmbs <- lift (timeout wait (recv sock nbytes))
      case mmbs of
        Just (Just bs) -> P.respond bs >>= loop
        Just Nothing   -> return ()
        Nothing        -> PE.throw ex
    ex = Timeout $ "nsocketReadTimeoutS: " <> show wait <> " microseconds."
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
      m <- lift (timeout wait (send sock a))
      case m of
        Just () -> P.respond a >>= loop
        Nothing -> PE.throw ex
    ex = Timeout $ "socketWriteTimeoutD: " <> show wait <> " microseconds."
{-# INLINABLE socketWriteTimeoutD #-}


