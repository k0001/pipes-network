{-# LANGUAGE Rank2Types #-}

-- | This module exports functions that allow you safely use 'NS.Socket'
-- resources acquired and release within a 'P.Proxy' pipeline, using the
-- facilities provided by 'P.ExceptionP' from the @pipes-safe@ library.
--
-- Instead, if you want acquire and release resources outside a 'P.Proxy'
-- pipeline, then you should use the functions exported by
-- "Control.Proxy.Network.TCP".
--
-- The module "Control.Proxy.Network.TCP.Safe.Quick" offers simpler
-- solutions to one-time streaming interactions with a remote end that might
-- readily satisfy your needs.

module Control.Proxy.Network.TCP.Safe (
  -- * Server side
  -- $server-side
  serve,
  serveFork,
  -- ** Listening
  listen,
  -- ** Accepting
  accept,
  acceptFork,
  -- * Client side
  -- $client-side
  connect,
  -- * Streaming proxies
  -- $socket-proxies
  socketReadS,
  nsocketReadS,
  socketWriteD,
  -- * Exports
  HostPreference(..),
  Timeout(..)
  ) where

import           Control.Concurrent             (forkIO, ThreadId)
import qualified Control.Exception              as E
import           Control.Monad
import qualified Control.Proxy                  as P
import           Control.Proxy.Network.Internal
import qualified Control.Proxy.Network.TCP      as T
import qualified Control.Proxy.Safe             as P
import qualified Data.ByteString                as B
import           Data.Monoid
import qualified Network.Socket                 as NS
import           Network.Socket.ByteString      (sendAll, recv)
import           System.Timeout                 (timeout)

--------------------------------------------------------------------------------

-- $client-side
--
-- The following functions allow you to obtain and use 'NS.Socket's useful to
-- the client side of a TCP connection.

-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- If you prefer to acquire close the socket yourself, then use
-- 'T.connectSock' and the 'NS.sClose' from "Network.Socket" instead.
connect
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.HostName                   -- ^Server hostname.
  -> NS.ServiceName                -- ^Server service port.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation taking the
                                   -- communication socket and the server
                                   -- address.
  -> P.ExceptionP p a' a b' b m r
connect morph host port =
    P.bracket morph (T.connectSock host port) (NS.sClose . fst)

--------------------------------------------------------------------------------

-- $server-side
--
-- The following functions allow you to obtain and use 'NS.Socket's useful to
-- the server side of a TCP connection.

-- | Bind a TCP listening socket and use it.
--
-- The listening socket is closed when done or in case of exceptions.
--
-- If you prefer to acquire and close the socket yourself, then use
-- 'T.bindSock' and the 'NS.listen' and 'NS.sClose' functions from
-- "Network.Socket" instead.
--
-- Note: 'N.maxListenQueue' is tipically 128, which is too small for high
-- performance servers. So, we use the maximum between 'N.maxListenQueue' and
-- 2048 as the default size of the listening queue.
listen
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> HostPreference                -- ^Preferred host to bind.
  -> NS.ServiceName                -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation taking the listening
                                   -- socket and the address it's bound to.
  -> P.ExceptionP p a' a b' b m r
listen morph hp port = P.bracket morph listen' (NS.sClose . fst)
  where
    listen' = do x@(bsock,_) <- T.bindSock hp port
                 NS.listen bsock $ max 2048 NS.maxListenQueue
                 return x

-- | Start a TCP server that sequentially accepts and uses each incomming
-- connection.
--
-- Both the listening and connection sockets are closed when done or in case of
-- exceptions.
serve
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> HostPreference                -- ^Preferred host to bind.
  -> NS.ServiceName                -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation to run once an incomming
                                   -- connection is accepted. Takes the
                                   -- connection socket and remote end address.
  -> P.ExceptionP p a' a b' b m r
serve morph hp port k = do
   listen morph hp port $ \(lsock,_) -> do
     forever $ accept morph lsock k

-- | Start a TCP server that accepts incomming connections and uses them
-- concurrently in different threads.
--
-- The listening and connection sockets are closed when done or in case of
-- exceptions.
serveFork
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> HostPreference                -- ^Preferred host to bind.
  -> NS.ServiceName                -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                   -- ^Computation to run in a different thread
                                   -- once an incomming connection is accepted.
                                   -- Takes the connection socket and remote end
                                   -- address.
  -> P.ExceptionP p a' a b' b m r
serveFork morph hp port k = do
   listen morph hp port $ \(lsock,_) -> do
     forever $ acceptFork morph lsock k

-- | Accept a single incomming connection and use it.
--
-- The connection socket is closed when done or in case of exceptions.
accept
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation to run once an incomming
                                   -- connection is accepted. Takes the
                                   -- connection socket and remote end address.
  -> P.ExceptionP p a' a b' b m r
accept morph lsock k = do
    conn@(csock,_) <- P.hoist morph . P.tryIO $ NS.accept lsock
    P.finally morph (NS.sClose csock) (k conn)

-- | Accept a single incomming connection and use it in a different thread.
--
-- The connection socket is closed when done or in case of exceptions.
acceptFork
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                  -- ^Computation to run in a different thread
                                  -- once an incomming connection is accepted.
                                  -- Takes the connection socket and remote end
                                  -- address.
  -> P.ExceptionP p a' a b' b m ThreadId
acceptFork morph lsock f = P.hoist morph . P.tryIO $ do
    client@(csock,_) <- NS.accept lsock
    forkIO $ E.finally (f client) (NS.sClose csock)

--------------------------------------------------------------------------------

-- $socket-proxies
--
-- Once you have a connected 'NS.Socket', you can use the following 'P.Proxy's
-- to interact with the other connection end.

-- | Receives bytes from the remote end and sends them downstream.
--
-- If an optional timeout is given and receiveing data from the remote end takes
-- more time that such timeout, then throw a 'Timeout' exception in the
-- 'P.ExceptionP' proxy transformer.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
socketReadS
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> Int                -- ^Maximum number of bytes to receive at once.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
socketReadS Nothing nbytes sock () = loop where
    loop = do
      bs <- P.tryIO $ recv sock nbytes
      unless (B.null bs) $ P.respond bs >> loop
socketReadS (Just wait) nbytes sock () = loop where
    loop = do
      mbs <- P.tryIO . timeout wait $ recv sock nbytes
      case mbs of
        Nothing -> P.throw ex
        Just bs -> unless (B.null bs) $ P.respond bs >> loop
    ex = Timeout $ "recv: " <> show wait <> " microseconds."

-- | Just like 'socketReadS', except each request from downstream specifies the
-- maximum number of bytes to receive.
nsocketReadS
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Int -> P.Server (P.ExceptionP p) Int B.ByteString P.SafeIO ()
nsocketReadS Nothing sock = loop where
    loop nbytes = do
      bs <- P.tryIO $ recv sock nbytes
      unless (B.null bs) $ P.respond bs >>= loop
nsocketReadS (Just wait) sock = loop where
    loop nbytes = do
      mbs <- P.tryIO . timeout wait $ recv sock nbytes
      case mbs of
        Nothing -> P.throw ex
        Just bs -> unless (B.null bs) $ P.respond bs >>= loop
    ex = Timeout $ "recv: " <> show wait <> " microseconds."

-- | Sends to the remote end the bytes received from upstream, then forwards
-- such same bytes downstream.
--
-- If an optional timeout is given and sending data to the remote end takes
-- more time that such timeout, then throw a 'Timeout' exception in the
-- 'P.ExceptionP' proxy transformer.
--
-- Requests from downstream are forwarded upstream.
socketWriteD
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> x -> (P.ExceptionP p) x B.ByteString x B.ByteString P.SafeIO r
socketWriteD Nothing sock = loop where
    loop x = do
      a <- P.request x
      P.tryIO $ sendAll sock a
      P.respond a >>= loop
socketWriteD (Just wait) sock = loop where
    loop x = do
      a <- P.request x
      m <- P.tryIO . timeout wait $ sendAll sock a
      case m of
        Nothing -> P.throw ex
        Just () -> P.respond a >>= loop
    ex = Timeout $ "sendAll: " <> show wait <> " microseconds."
