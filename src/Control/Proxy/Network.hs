{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE KindSignatures #-}

module Control.Proxy.Network (
   TcpApplication,
   socketReader,
   socketWriter,
   ServerSettings(..),
   runTCPServer,
   ClientSettings(..),
   runTCPClient,
   ) where

import           Control.Concurrent                        (forkIO)
import qualified Control.Exception                         as E
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.IO.Class
import qualified Control.Proxy                             as P
import qualified Data.ByteString                           as B
import qualified Network.Socket                            as NS
import           Network.Socket.ByteString                 (sendAll, recv)


-- adapted from conduit

-- | Stream data from the socket.
socketReader :: (P.Proxy p, MonadIO m)
             => Int -> NS.Socket -> () -> P.Producer p B.ByteString m ()
socketReader bufsize socket () = P.runIdentityP loop
  where loop = do bs <- lift . liftIO $ recv socket bufsize
                  unless (B.null bs) $ P.respond bs >> loop

-- | Stream data to the socket.
socketWriter :: (P.Proxy p, MonadIO m)
             => NS.Socket -> () -> P.Consumer p B.ByteString m ()
socketWriter socket = P.runIdentityK . P.foreverK $ loop
  where loop = P.request >=> lift . liftIO . sendAll socket


-- | A simple TCP application.
--
-- It takes a continuation that recieves a 'Producer' to read input data
-- from, and a 'Consumer' to send output data to.
type TcpApplication (p :: * -> * -> * -> * -> (* -> *) -> * -> *) m r
  = (() -> P.Producer p B.ByteString m (), () -> P.Consumer p B.ByteString m ())
  -> m r


-- | Settings for a TCP server. It takes a port to listen on, and an optional
-- hostname to bind to.
data ServerSettings = ServerSettings
    { serverPort :: Int
    , serverHost :: Maybe String -- ^ 'Nothing' indicates no preference
    }

-- | Run a 'TcpApplication' with the given settings. This function will
-- create a new listening socket, accept connections on it, and spawn a
-- new thread for each connection.
runTCPServer :: P.Proxy p => ServerSettings -> TcpApplication p IO r -> IO r
runTCPServer (ServerSettings port host) app = E.bracket
    (listen host port)
    (NS.sClose . fst)
    (forever . serve)
  where
    serve (listeningSock,_) = do
      (clientSock,_) <- NS.accept listeningSock
      forkIO $ do
        E.finally
          (app (socketReader 4096 clientSock, socketWriter clientSock))
          (NS.sClose clientSock)
        return ()


-- | Settings for a TCP client, specifying how to connect to the server.
data ClientSettings = ClientSettings
    { clientPort :: Int
    , clientHost :: String
    }

-- | Run a 'TcpApplication' by connecting to the specified server.
runTCPClient :: P.Proxy p => ClientSettings -> TcpApplication p IO r -> IO r
runTCPClient (ClientSettings port host) app = E.bracket
    (connect host port)
    (NS.sClose . fst)
    (\(s,_) -> app (socketReader 4096 s, socketWriter s))

-- | Attempt to connect to the given host/port.
connect :: String -> Int -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
connect host port = do
    let hints = NS.defaultHints {
                          NS.addrFlags = [NS.AI_ADDRCONFIG]
                        , NS.addrSocketType = NS.Stream
                        }
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host) (Just $ show port)
    E.bracketOnError
      (NS.socket (NS.addrFamily addr)
                 (NS.addrSocketType addr)
                 (NS.addrProtocol addr))
      NS.sClose
      (\sock -> do let sockAddr = NS.addrAddress addr
                   NS.connect sock sockAddr
                   return (sock, sockAddr))


-- | Attempt to bind a listening @Socket@ on the given host and port.
-- If no explicit host is given, will use the first address available.
listen :: Maybe String -> Int -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
listen host port = do
    let hints = NS.defaultHints
            { NS.addrFlags =
                [ NS.AI_PASSIVE
                , NS.AI_NUMERICSERV
                , NS.AI_NUMERICHOST
                ]
            , NS.addrSocketType = NS.Stream
            }
        port' = Just . show $ port
    addrs <- NS.getAddrInfo (Just hints) host port'
    let
        tryAddrs (addr1:rest@(_:_)) = E.catch
                                      (theBody addr1)
                                      (\(_ :: E.IOException) -> tryAddrs rest)
        tryAddrs (addr1:[])         = theBody addr1
        tryAddrs _                  = error "listen: addrs is empty"
        theBody addr =
          E.bracketOnError
          (NS.socket
            (NS.addrFamily addr)
            (NS.addrSocketType addr)
            (NS.addrProtocol addr))
          NS.sClose
          (\sock -> do
              let sockAddr = NS.addrAddress addr
              NS.setSocketOption sock NS.ReuseAddr 1
              NS.bindSocket sock sockAddr
              NS.listen sock NS.maxListenQueue
              return (sock, sockAddr)
          )
    tryAddrs addrs
