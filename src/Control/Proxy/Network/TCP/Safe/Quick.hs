-- | This module offers straightforward solutions to one-time streaming
-- interactions with a remote end.
--
-- If these proxies don't satisfy your needs, you might need to use the more
-- general features from "Control.Proxy.Network.TCP.Safe".

module Control.Proxy.Network.TCP.Safe.Quick (
  -- * Server side
  serveReadS,
  serveWriteD,
  -- * Client side
  connectReadS,
  connectWriteD,
  -- * Exports
  HostPreference(..),
  Timeout(..)
  ) where

import           Control.Proxy.Network.TCP.Safe
import qualified Control.Proxy                   as P
import qualified Control.Proxy.Safe              as P
import qualified Network.Socket                  as NS
import qualified Data.ByteString                 as B

--------------------------------------------------------------------------------

-- | Binds a listening socket, accepts a single connection and sends downstream
-- any bytes received from the remote end.
--
-- If an optional timeout is given and receiveing data from the remote end takes
-- more time that such timeout, then throw a 'Timeout' exception in the
-- 'P.ExceptionP' proxy transformer.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
--
-- Both the listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- prints whatever is received from a single TCP connection to port 9000:
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeIO . runProxy . runEitherK $ serveReadS Nothing 4096 "127.0.0.1" "9000" >-> tryK printD
serveReadS
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> Int                -- ^Maximum number of bytes to receive at once.
  -> HostPreference     -- ^Preferred host to bind.
  -> NS.ServiceName     -- ^Service port to bind.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
serveReadS mwait nbytes hp port () = do
   listen id hp port $ \(lsock,_) -> do
     accept id lsock $ \(csock,_) -> do
       socketReadS mwait nbytes csock ()

-- | Binds a listening socket, accepts a single connection, sends to the remote
-- end the bytes received from upstream, then forwards such sames bytes
-- downstream.
--
-- Requests from downstream are forwarded upstream.
--
-- If an optional timeout is given and sending data to the remote end takes
-- more time that such timeout, then throw a 'Timeout' exception in the
-- 'P.ExceptionP' proxy transformer.
--
-- Both the listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- greets a TCP client connecting to port 9000:
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeIO . runProxy . runEitherK $ fromListS ["He","llo\r\n"] >-> serveWriteD Nothing "127.0.0.1" "9000"
serveWriteD
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> HostPreference     -- ^Preferred host to bind.
  -> NS.ServiceName     -- ^Service port to bind.
  -> x -> (P.ExceptionP p) x B.ByteString x B.ByteString P.SafeIO ()
serveWriteD mwait hp port x = do
   listen id hp port $ \(lsock,_) -> do
     accept id lsock $ \(csock,_) -> do
       socketWriteD mwait csock x

-- | Connect to a TCP server and send downstream the bytes received from the
-- remote end.
--
-- If an optional timeout is given and receiveing data from the remote end takes
-- more time that such timeout, then throw a 'Timeout' exception in the
-- 'P.ExceptionP' proxy transformer.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- prints whatever is received from a single TCP connection to a given server
-- listening locally on port 9000:
--
-- >>> runSafeIO . runProxy . runEitherK $ connectReadS Nothing 4096 "127.0.0.1" "9000" >-> tryK printD
connectReadS
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> Int                -- ^Maximum number of bytes to receive at once.
  -> NS.HostName        -- ^Server host name.
  -> NS.ServiceName     -- ^Server service port.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
connectReadS mwait nbytes host port () = do
   connect id host port $ \(csock,_) -> do
     socketReadS mwait nbytes csock ()

-- | Connects to a TCP server, sends to the remote end the bytes received from
-- upstream, then forwards such same bytes downstream.
--
-- Requests from downstream are forwarded upstream.
--
-- If an optional timeout is given and sending data to the remote end takes
-- more time that such timeout, then throw a 'Timeout' exception in the
-- 'P.ExceptionP' proxy transformer.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- greets a TCP client listening locally at port 9000:
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeIO . runProxy . runEitherK $ fromListS ["He","llo\r\n"] >-> connectWriteD Nothing "127.0.0.1" "9000"
connectWriteD
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.HostName        -- ^Server host name.
  -> NS.ServiceName     -- ^Server service port.
  -> x -> (P.ExceptionP p) x B.ByteString x B.ByteString P.SafeIO ()
connectWriteD mwait hp port x = do
   connect id hp port $ \(csock,_) ->
     socketWriteD mwait csock x
