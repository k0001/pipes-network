{-# LANGUAGE Rank2Types #-}

-- | This module exports functions that allow you safely use 'NS.Socket'
-- resources acquired and release within a 'P.Proxy' pipeline, using the
-- facilities provided by 'P.ExceptionP', from the @pipes-safe@ library.
--
-- Instead, if want acquire and release resources outside a 'P.Proxy' pipeline,
-- then you should use the similar functions exported by
-- "Control.Proxy.Network.TCP".

module Control.Proxy.Safe.Network.TCP (
  -- * Server side
  -- $server-side
  serve,
  serveFork,
  -- ** Quick one-time servers
  serveS,
  serveD,
  -- ** Listening
  listen,
  -- ** Accepting
  accept,
  acceptFork,
  -- * Client side
  -- $client-side
  connect,
  -- ** Quick one-time clients
  connectS,
  connectD,
  -- * Socket proxies
  -- $socket-proxies
  socketS,
  nsocketS,
  socketD,
  -- * Exports
  HostPreference(..),
  Timeout(..)
  ) where

import           Control.Concurrent            (forkIO, ThreadId)
import qualified Control.Exception             as E
import           Control.Monad
import qualified Control.Proxy                 as P
import           Control.Proxy.Network.Util
import qualified Control.Proxy.Network.TCP     as T
import qualified Control.Proxy.Safe            as P
import qualified Data.ByteString               as B
import           Data.Monoid
import qualified Network.Socket                as NS
import           Network.Socket.ByteString     (sendAll, recv)
import           System.Timeout                (timeout)

--------------------------------------------------------------------------------

-- $client-side
--
-- The following functions allow you to obtain 'NS.Socket's useful to the
-- client side of a TCP connection.

-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- If you would like to close the socket yourself, then use the 'T.connect'' and
-- 'NS.sClose' functions instead.
connect
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.HostName                   -- ^Server hostname.
  -> NS.ServiceName                -- ^Server service port.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Guarded computation taking the
                                   -- communication socket and the server
                                   -- address.
  -> P.ExceptionP p a' a b' b m r
connect morph host port =
    P.bracket morph (T.connect' host port) (NS.sClose . fst)

--------------------------------------------------------------------------------

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
-- > let session = connectS Nothing "127.0.0.1" "9000" >-> tryK printD
-- > runSafeIO . runProxy . runEitherK $ session
connectS
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> Int                -- ^Maximum number of bytes to receive at once.
  -> NS.HostName        -- ^Server host name.
  -> NS.ServiceName     -- ^Server service port.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
connectS mwait nbytes host port () = do
   connect id host port $ \(csock,_) -> do
     socketS mwait nbytes csock ()

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
-- > let session = fromListS ["He","llo\r\n"] >-> connectD Nothing "127.0.0.1" "9000"
-- > runSafeIO . runProxy . runEitherK $ session
connectD
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.HostName        -- ^Server host name.
  -> NS.ServiceName     -- ^Server service port.
  -> x -> (P.ExceptionP p) x B.ByteString x B.ByteString P.SafeIO ()
connectD mwait hp port x = do
   connect id hp port $ \(csock,_) ->
     socketD mwait csock x

--------------------------------------------------------------------------------

-- $server-side
--
-- The following functions allow you to obtain 'NS.Socket's useful to the
-- server side of a TCP connection.

-- | Bind a TCP listening socket and use it.
--
-- The listening socket is closed when done or in case of exceptions.
--
-- If you would like acquire and close the socket yourself, then use the
-- 'NS.listen' and 'NS.sClose' instead.
--
-- Note: 'N.maxListenQueue' is tipically 128, which is too small for high
-- performance servers. So, we use the maximum between 'N.maxListenQueue' and
-- 2048 as the default size of the listening queue.
listen
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> HostPreference                -- ^Preferred host to bind to.
  -> NS.ServiceName                -- ^Service port to bind to.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Guarded computation taking the listening
                                   -- socket and the address it's bound to.
  -> P.ExceptionP p a' a b' b m r
listen morph hp port = P.bracket morph listen' (NS.sClose . fst)
  where
    listen' = do x@(bsock,_) <- T.bind hp port
                 NS.listen bsock $ max 2048 NS.maxListenQueue
                 return x

-- | Start a TCP server that sequentially accepts and uses each incomming
-- connection.
--
-- Both the listening and connection socket are closed when done or in case of
-- exceptions.
serve
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> HostPreference                -- ^Preferred host to bind to.
  -> NS.ServiceName                -- ^Service port to bind to.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                  -- ^Guarded computatation to run once an
                                  -- incomming connection is accepted. Takes the
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
  -> HostPreference                -- ^Preferred host to bind to.
  -> NS.ServiceName                -- ^Service port to bind to.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                  -- ^Guarded computatation to run in a
                                  -- different thread once an incomming
                                  -- connection is accepted. Takes the
                                  -- connection socket and remote end address.
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
                                  -- ^Guarded computatation to run once an
                                  -- incomming connection is accepted. Takes the
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
                                  -- ^Guarded computatation to run in a
                                  -- different thread once an incomming
                                  -- connection is accepted. Takes the
                                  -- connection socket and remote end address.
  -> P.ExceptionP p a' a b' b m ThreadId
acceptFork morph lsock f = P.hoist morph . P.tryIO $ do
    client@(csock,_) <- NS.accept lsock
    forkIO $ E.finally (f client) (NS.sClose csock)

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
-- Both the listening and connection socket are closed when done or in case of
-- exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- prints whatever is received from a single TCP connection to port 9000:
--
-- > let session = serveS Nothing 4096 "127.0.0.1" "9000" >-> tryK printD
-- > runSafeIO . runProxy . runEitherK $ session
serveS
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> Int                -- ^Maximum number of bytes to receive at once.
  -> HostPreference     -- ^Preferred host to bind to.
  -> NS.ServiceName     -- ^Service port to bind to.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
serveS mwait nbytes hp port () = do
   listen id hp port $ \(lsock,_) -> do
     accept id lsock $ \(csock,_) -> do
       socketS mwait nbytes csock ()

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
-- Both the listening and connection socket are closed when done or in case of
-- exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- greets a TCP client connecting to port 9000:
--
-- > let session = fromListS ["He","llo\r\n"] >-> serveD "127.0.0.1" "9000"
-- > runSafeIO . runProxy . runEitherK $ session
serveD
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> HostPreference     -- ^Preferred host to bind to.
  -> NS.ServiceName     -- ^Service port to bind to.
  -> x -> (P.ExceptionP p) x B.ByteString x B.ByteString P.SafeIO ()
serveD mwait hp port x = do
   listen id hp port $ \(lsock,_) -> do
     accept id lsock $ \(csock,_) -> do
       socketD mwait csock x

--------------------------------------------------------------------------------

-- $socket-proxies
--
-- Once you have a connected 'NS.Socket', you can use the following 'P.Proxy's
-- to interact with the other connection end.

-- | Socket 'P.Producer' proxy. Receives bytes from the remote end and sends
-- them downstream.
--
-- If an optional timeout is given and receiveing data from the remote end takes
-- more time that such timeout, then throw a 'Timeout' exception in the
-- 'P.ExceptionP' proxy transformer.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
socketS
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> Int                -- ^Maximum number of bytes to receive at once.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
socketS Nothing nbytes sock () = loop where
    loop = do
      bs <- P.tryIO $ recv sock nbytes
      unless (B.null bs) $ P.respond bs >> loop
socketS (Just wait) nbytes sock () = loop where
    loop = do
      mbs <- P.tryIO . timeout wait $ recv sock nbytes
      case mbs of
        Nothing -> P.throw ex
        Just bs -> unless (B.null bs) $ P.respond bs >> loop
    ex = Timeout $ "recv: " <> show wait <> " microseconds."

-- | Socket 'P.Server' proxy similar to 'socketS', except each request
-- from downstream specifies the maximum number of bytes to receive.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
nsocketS
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Int -> P.Server (P.ExceptionP p) Int B.ByteString P.SafeIO ()
nsocketS Nothing sock = loop where
    loop nbytes = do
      bs <- P.tryIO $ recv sock nbytes
      unless (B.null bs) $ P.respond bs >>= loop
nsocketS (Just wait) sock = loop where
    loop nbytes = do
      mbs <- P.tryIO . timeout wait $ recv sock nbytes
      case mbs of
        Nothing -> P.throw ex
        Just bs -> unless (B.null bs) $ P.respond bs >>= loop
    ex = Timeout $ "recv: " <> show wait <> " microseconds."

-- | Sends to the remote end the bytes received from upstream and then forwards
-- such same bytes downstream.
--
-- If an optional timeout is given and sending data to the remote end takes
-- more time that such timeout, then throw a 'Timeout' exception in the
-- 'P.ExceptionP' proxy transformer.
--
-- Requests from downstream are forwarded upstream.
socketD
  :: P.Proxy p
  => Maybe Int          -- ^Optional timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> x -> (P.ExceptionP p) x B.ByteString x B.ByteString P.SafeIO r
socketD Nothing sock = loop where
    loop x = do
      a <- P.request x
      P.tryIO $ sendAll sock a
      P.respond a >>= loop
socketD (Just wait) sock = loop where
    loop x = do
      a <- P.request x
      m <- P.tryIO . timeout wait $ sendAll sock a
      case m of
        Nothing -> P.throw ex
        Just () -> P.respond a >>= loop
    ex = Timeout $ "sendAll: " <> show wait <> " microseconds."
