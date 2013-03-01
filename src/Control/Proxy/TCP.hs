-- | This module exports functions that allow you to safely use 'NS.Socket'
-- resources acquired and released outside a 'P.Proxy' pipeline.
--
-- Instead, if want to safely acquire and release resources within the
-- pipeline itself, then you should use the functions exported by
-- "Control.Proxy.TCP.Safe".

-- Some code in this file was adapted from the @network-conduit@ library by
-- Michael Snoyman. Copyright (c) 2011. See its licensing terms (BSD3) at:
--   https://github.com/snoyberg/conduit/blob/master/network-conduit/LICENSE

module Control.Proxy.TCP (
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

  -- * Socket streams
  -- $socket-streaming
  socketReadS,
  nsocketReadS,
  socketWriteD,
  -- ** Timeouts
  -- $socket-streaming-timeout
  socketReadTimeoutS,
  nsocketReadTimeoutS,
  socketWriteTimeoutD,
  -- * Low level support
  bindSock,
  connectSock,
  -- * Exports
  HostPreference(..),
  Timeout(..)
  ) where

import           Control.Concurrent             (ThreadId, forkIO)
import qualified Control.Exception              as E
import           Control.Monad
import           Control.Monad.Trans.Class
import qualified Control.Proxy                  as P
import qualified Control.Proxy.Trans.Either     as PE
import           Control.Proxy.Network.Internal
import qualified Data.ByteString                as B
import           Data.Monoid
import           Data.List                      (partition)
import qualified Network.Socket                 as NS
import           Network.Socket.ByteString      (recv, sendAll)
import           System.Timeout                 (timeout)

--------------------------------------------------------------------------------

-- $client-side
--
-- The following functions allow you to obtain and use 'NS.Socket's useful to
-- the client side of a TCP connection.
--
-- Here's how you could run a TCP client:
--
-- > connect "www.example.org" "80" $ \(connectionSocket, remoteAddr) -> do
-- >   putStrLn $ "Connection established to " ++ show remoteAddr
-- >   -- now you may use connectionSocket as you please within this scope,
-- >   -- possibly with any of the socketReadS, nsocketReadS or socketWriteD
-- >   -- proxies explained below.

-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- If you prefer to acquire and close the socket yourself, then use
-- 'connectSock' and the 'NS.sClose' function from "Network.Socket" instead.
connect
  :: NS.HostName      -- ^Server hostname.
  -> NS.ServiceName   -- ^Server service port.
  -> ((NS.Socket, NS.SockAddr) -> IO r)
                      -- ^Computation taking the communication socket
                      -- and the server address.
  -> IO r
connect host port = E.bracket (connectSock host port) (NS.sClose . fst)

--------------------------------------------------------------------------------

-- $server-side
--
-- The following functions allow you to obtain and use 'NS.Socket's useful to
-- the server side of a TCP connection.
--
-- Here's how you could run a TCP server that handles in different threads each
-- incoming connection to port @8000@ at address @127.0.0.1@:
--
-- > listen (Host "127.0.0.1") "8000" $ \(listeningSocket, listeningAddr) -> do
-- >   putStrLn $ "Listening for incoming connections at " ++ show listeningAddr
-- >   forever . acceptFork listeningSocket $ \(connectionSocket, remoteAddr) -> do
-- >     putStrLn $ "Connection established from " ++ show remoteAddr
-- >     -- now you may use connectionSocket as you please within this scope,
-- >     -- possibly with any of the socketReadS, nsocketReadS or socketWriteD
-- >     -- proxies explained below.
--
-- If you keep reading you'll discover there are different ways to achieve
-- the same, some ways more general than others. The above one was just an
-- example using a pretty general approach, you are encouraged to use simpler
-- approaches such as 'serve' if those suit your needs.

-- | Bind a TCP listening socket and use it.
--
-- The listening socket is closed when done or in case of exceptions.
--
-- If you prefer to acquire and close the socket yourself, then use
-- 'bindSock' and the 'NS.listen' and 'NS.sClose' functions from
-- "Network.Socket" instead.
--
-- Note: 'N.maxListenQueue' is tipically 128, which is too small for high
-- performance servers. So, we use the maximum between 'N.maxListenQueue' and
-- 2048 as the default size of the listening queue.
listen
  :: HostPreference   -- ^Preferred host to bind.
  -> NS.ServiceName   -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> IO r)
                      -- ^Computation taking the listening socket and
                      -- the address it's bound to.
  -> IO r
listen hp port = E.bracket listen' (NS.sClose . fst)
  where
    listen' = do x@(bsock,_) <- bindSock hp port
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
  :: HostPreference   -- ^Preferred host to bind.
  -> NS.ServiceName   -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> IO r)
                      -- ^Computation to run once an incoming
                      -- connection is accepted. Takes the connection socket
                      -- and remote end address.
  -> IO r
serve hp port k = do
    listen hp port $ \(lsock,_) -> do
      forever $ accept lsock k

-- | Start a TCP server that accepts incoming connections and uses them
-- concurrently in different threads.
--
-- The listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Note: You don't need to use 'listen' nor 'acceptFork' if you use this
-- function.
serveFork
  :: HostPreference   -- ^Preferred host to bind.
  -> NS.ServiceName   -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                      -- ^Computation to run in a different thread
                      -- once an incoming connection is accepted. Takes the
                      -- connection socket and remote end address.
  -> IO ()
serveFork hp port k = do
    listen hp port $ \(lsock,_) -> do
      forever $ acceptFork lsock k

-- | Accept a single incoming connection and use it.
--
-- The connection socket is closed when done or in case of exceptions.
accept
  :: NS.Socket        -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO b)
                      -- ^Computation to run once an incoming
                      -- connection is accepted. Takes the connection socket
                      -- and remote end address.
  -> IO b
accept lsock k = do
    conn@(csock,_) <- NS.accept lsock
    E.finally (k conn) (NS.sClose csock)
{-# INLINABLE accept #-}

-- | Accept a single incoming connection and use it in a different thread.
--
-- The connection socket is closed when done or in case of exceptions.
acceptFork
  :: NS.Socket        -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                      -- ^Computation to run in a different thread
                      -- once an incoming connection is accepted. Takes the
                      -- connection socket and remote end address.
  -> IO ThreadId
acceptFork lsock f = do
    client@(csock,_) <- NS.accept lsock
    forkIO $ E.finally (f client) (NS.sClose csock)
{-# INLINABLE acceptFork #-}

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

--------------------------------------------------------------------------------

-- | Obtain a 'NS.Socket' connected to the given host and TCP service port.
--
-- The obtained 'NS.Socket' should be closed manually using 'NS.sClose' when
-- it's not needed anymore, otherwise you risk having the socket open for much
-- longer than needed.
--
-- Prefer to use 'connect' if you will be using the socket within a limited
-- scope and would like it to be closed immediately after its usage or in case
-- of exceptions.
connectSock :: NS.HostName -> NS.ServiceName -> IO (NS.Socket, NS.SockAddr)
connectSock host port = do
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host) (Just port)
    E.bracketOnError (newSocket addr) NS.sClose $ \sock -> do
       let sockAddr = NS.addrAddress addr
       NS.connect sock sockAddr
       return (sock, sockAddr)
  where
    hints = NS.defaultHints { NS.addrFlags = [NS.AI_ADDRCONFIG]
                            , NS.addrSocketType = NS.Stream }

-- | Obtain a 'NS.Socket' bound to the given host name and TCP service port.
--
-- The obtained 'NS.Socket' should be closed manually using 'NS.sClose' when
-- it's not needed anymore.
--
-- Prefer to use 'listen' if you will be listening on this socket and using it
-- within a limited scope, and would like it to be closed immediately after its
-- usage or in case of exceptions.
bindSock :: HostPreference -> NS.ServiceName -> IO (NS.Socket, NS.SockAddr)
bindSock hp port = do
    addrs <- NS.getAddrInfo (Just hints) (hpHostName hp) (Just port)
    let addrs' = case hp of
          HostIPv4 -> prioritize isIPv4addr addrs
          HostIPv6 -> prioritize isIPv6addr addrs
          _        -> addrs
    tryAddrs addrs'
  where
    hints = NS.defaultHints { NS.addrFlags = [NS.AI_PASSIVE]
                            , NS.addrSocketType = NS.Stream }

    tryAddrs []     = error "listen: no addresses available"
    tryAddrs [x]    = useAddr x
    tryAddrs (x:xs) = E.catch (useAddr x)
                              (\e -> let _ = e :: E.IOException in tryAddrs xs)

    useAddr addr = E.bracketOnError (newSocket addr) NS.sClose $ \sock -> do
      let sockAddr = NS.addrAddress addr
      NS.setSocketOption sock NS.NoDelay 1
      NS.setSocketOption sock NS.ReuseAddr 1
      NS.bindSocket sock sockAddr
      return (sock, sockAddr)

--------------------------------------------------------------------------------

-- Misc

newSocket :: NS.AddrInfo -> IO NS.Socket
newSocket addr = NS.socket (NS.addrFamily addr)
                           (NS.addrSocketType addr)
                           (NS.addrProtocol addr)

isIPv4addr, isIPv6addr :: NS.AddrInfo -> Bool
isIPv4addr x = NS.addrFamily x == NS.AF_INET
isIPv6addr x = NS.addrFamily x == NS.AF_INET6

-- | Move the elements that match the predicate closer to the head of the list.
-- Preserve relative order.
prioritize :: (a -> Bool) -> [a] -> [a]
prioritize p = uncurry (++) . partition p
