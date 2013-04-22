{-# LANGUAGE Rank2Types #-}

-- | This module exports functions that allow you to safely use 'NS.Socket'
-- resources within a 'P.Proxy' pipeline, possibly acquiring and releasing such
-- resources within the pipeline itself, using the facilities provided by
-- 'P.ExceptionP' from the @pipes-safe@ library.
--
-- Instead, if just want to use resources already acquired or released outside
-- the pipeline, then you could use the simpler functions exported by
-- "Control.Proxy.TCP".

module Control.Proxy.TCP.Safe (
  -- * Server side
  -- $server-side
  serve,
  serveFork,
  -- ** Listening
  listen,
  -- ** Accepting
  accept,
  acceptFork,
  -- ** Streaming
  -- $server-streaming
  serveReadS,
  serveWriteD,

  -- * Client side
  -- $client-side
  connect,
  -- ** Streaming
  -- $client-streaming
  connectReadS,
  connectWriteD,

  -- * Socket streams
  -- $socket-streaming
  socketReadS,
  nsocketReadS,
  socketWriteD,

  -- * Exports
  S.HostPreference(..),
  Timeout(..)
  ) where

import           Control.Concurrent             (forkIO, ThreadId)
import qualified Control.Exception              as E
import           Control.Monad
import qualified Control.Proxy                  as P
import           Control.Proxy.Network.Internal
import qualified Control.Proxy.Safe             as P
import qualified Data.ByteString                as B
import           Data.Monoid
import qualified Network.Socket                 as NS
import           Network.Socket.ByteString      (sendAll, recv)
import qualified Network.Simple.TCP             as S
import           System.Timeout                 (timeout)

--------------------------------------------------------------------------------

-- $client-side
--
-- The following functions allow you to obtain and use 'NS.Socket's useful to
-- the client side of a TCP connection.
--
-- Here's how you could run a TCP client:
--
-- > connect id "www.example.org" "80" $ \(connectionSocket, remoteAddr) -> do
-- >   tryIO . putStrLn $ "Connection established to " ++ show remoteAddr
-- >   -- now you may use connectionSocket as you please within this scope,
-- >   -- possibly with any of the socketReadS, nsocketReadS or socketWriteD
-- >   -- proxies explained below.
--
-- You might instead prefer the simpler but less general solutions offered by
-- 'connectReadS' and 'connectWriteD', so check those too.

-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- If you prefer to acquire close the socket yourself, then use
-- 'S.connectSock' and the 'NS.sClose' from "Network.Socket" instead.
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
    P.bracket morph (S.connectSock host port) (NS.sClose . fst)

--------------------------------------------------------------------------------

-- $client-streaming
--
-- The following proxies allow you to easily connect to a TCP server and
-- immediately interact with it using streams, all at once, instead of
-- having to perform the individual steps separately.

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

--------------------------------------------------------------------------------

-- $server-side
--
-- The following functions allow you to obtain and use 'NS.Socket's useful to
-- the server side of a TCP connection.
--
-- Here's how you could run a TCP server that handles in different threads each
-- incoming connection to port @8000@ at address @127.0.0.1@:
--
-- > listen id (Host "127.0.0.1") "8000" $ \(listeningSocket, listeningAddr) -> do
-- >   tryIO . putStrLn $ "Listening for incoming connections at " ++ show listeningAddr
-- >   forever . acceptFork id listeningSocket $ \(connectionSocket, remoteAddr) -> do
-- >     putStrLn $ "Connection established from " ++ show remoteAddr
-- >     -- now you may use connectionSocket as you please within this scope,
-- >     -- possibly with any of the socketReadS, nsocketReadS or socketWriteD
-- >     -- proxies explained below.
--
-- If you keep reading you'll discover there are different ways to achieve
-- the same, some ways more general than others. The above one was just an
-- example using a pretty general approach, you are encouraged to use simpler
-- approaches such as 'serve' or 'serveReadS' if those suit your needs.

-- | Bind a TCP listening socket and use it.
--
-- The listening socket is closed when done or in case of exceptions.
--
-- If you prefer to acquire and close the socket yourself, then use
-- 'S.bindSock' and the 'NS.listen' and 'NS.sClose' functions from
-- "Network.Socket" instead.
--
-- Note: 'N.maxListenQueue' is tipically 128, which is too small for high
-- performance servers. So, we use the maximum between 'N.maxListenQueue' and
-- 2048 as the default size of the listening queue.
listen
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> S.HostPreference              -- ^Preferred host to bind.
  -> NS.ServiceName                -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation taking the listening
                                   -- socket and the address it's bound to.
  -> P.ExceptionP p a' a b' b m r
listen morph hp port = P.bracket morph listen' (NS.sClose . fst)
  where
    listen' = do x@(bsock,_) <- S.bindSock hp port
                 NS.listen bsock $ max 2048 NS.maxListenQueue
                 return x

-- | Start a TCP server that sequentially accepts and uses each incoming
-- connection.
--
-- Both the listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Note: You don't need to use 'listen' nor 'accept' if you use this function.
serve
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> S.HostPreference              -- ^Preferred host to bind.
  -> NS.ServiceName                -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation to run once an incoming
                                   -- connection is accepted. Takes the
                                   -- connection socket and remote end address.
  -> P.ExceptionP p a' a b' b m r
serve morph hp port k = do
   listen morph hp port $ \(lsock,_) -> do
     forever $ accept morph lsock k

-- | Start a TCP server that accepts incoming connections and uses them
-- concurrently in different threads.
--
-- The listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Note: You don't need to use 'listen' nor 'acceptFork' if you use this
-- function.
serveFork
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> S.HostPreference              -- ^Preferred host to bind.
  -> NS.ServiceName                -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                   -- ^Computation to run in a different thread
                                   -- once an incoming connection is accepted.
                                   -- Takes the connection socket and remote end
                                   -- address.
  -> P.ExceptionP p a' a b' b m r
serveFork morph hp port k = do
   listen morph hp port $ \(lsock,_) -> do
     forever $ acceptFork morph lsock k

-- | Accept a single incoming connection and use it.
--
-- The connection socket is closed when done or in case of exceptions.
accept
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation to run once an incoming
                                   -- connection is accepted. Takes the
                                   -- connection socket and remote end address.
  -> P.ExceptionP p a' a b' b m r
accept morph lsock k = do
    conn@(csock,_) <- P.hoist morph . P.tryIO $ NS.accept lsock
    P.finally morph (NS.sClose csock) (k conn)
{-# INLINABLE accept #-}

-- | Accept a single incoming connection and use it in a different thread.
--
-- The connection socket is closed when done or in case of exceptions.
acceptFork
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                  -- ^Computation to run in a different thread
                                  -- once an incoming connection is accepted.
                                  -- Takes the connection socket and remote end
                                  -- address.
  -> P.ExceptionP p a' a b' b m ThreadId
acceptFork morph lsock f = P.hoist morph . P.tryIO $ do
    client@(csock,_) <- NS.accept lsock
    forkIO $ E.finally (f client) (NS.sClose csock)
{-# INLINABLE acceptFork #-}

--------------------------------------------------------------------------------

-- $server-streaming
--
-- The following proxies allow you to easily run a TCP server and immediately
-- interact with incoming connections using streams, all at once, instead of
-- having to perform the individual steps separately.

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
  -> S.HostPreference   -- ^Preferred host to bind.
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
  -> S.HostPreference   -- ^Preferred host to bind.
  -> NS.ServiceName     -- ^Service port to bind.
  -> x -> (P.ExceptionP p) x B.ByteString x B.ByteString P.SafeIO ()
serveWriteD mwait hp port x = do
   listen id hp port $ \(lsock,_) -> do
     accept id lsock $ \(csock,_) -> do
       socketWriteD mwait csock x

--------------------------------------------------------------------------------

-- $socket-streaming
--
-- Once you have a connected 'NS.Socket', you can use the following 'P.Proxy's
-- to interact with the other connection end using streams.

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
{-# INLINABLE socketReadS #-}

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
{-# INLINABLE nsocketReadS #-}

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
{-# INLINABLE socketWriteD #-}



