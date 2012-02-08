{-# LANGUAGE ScopedTypeVariables #-}
module Control.Pipe.Network (
  Application,
  sourceSocket,
  sinkSocket,
  ServerSettings(..),
  runTCPServer,
  ClientSettings(..),
  runTCPClient,
  ) where

import qualified Network.Socket as NS
import Network.Socket (Socket)
import Network.Socket.ByteString (sendAll, recv)
import Data.ByteString (ByteString)
import qualified Data.ByteString as S
import Control.Exception (bracketOnError, IOException, bracket, throwIO, SomeException, try)
import Control.Monad (forever)
import Control.Monad.State
import Control.Monad.Trans.Resource (ResourceT, runResourceT, register)
import Control.Pipe
import Control.Concurrent (forkIO)

-- adapted from conduit

-- | Stream data from the socket.
sourceSocket :: MonadIO m => Socket -> Producer ByteString m ()
sourceSocket socket = go
  where
    go = do
      bs <- lift . liftIO $ recv socket 4096
      if S.null bs
        then return ()
        else yield bs >> go

-- | Stream data to the socket.
sinkSocket :: MonadIO m => Socket -> Consumer ByteString m r
sinkSocket socket = forever $ await >>= lift . liftIO . sendAll socket

-- | A simple TCP application. It takes two arguments: the @Source@ to read
-- input data from, and the @Sink@ to send output data to.
type Application = Producer ByteString (ResourceT IO) ()
                -> Consumer ByteString (ResourceT IO) ()
                -> ResourceT IO ()

-- | Settings for a TCP server. It takes a port to listen on, and an optional
-- hostname to bind to.
data ServerSettings = ServerSettings
    { serverPort :: Int
    , serverHost :: Maybe String -- ^ 'Nothing' indicates no preference
    }

-- | Run an @Application@ with the given settings. This function will create a
-- new listening socket, accept connections on it, and spawn a new thread for
-- each connection.
runTCPServer :: ServerSettings -> Application -> IO ()
runTCPServer (ServerSettings port host) app = bracket
    (bindPort host port)
    NS.sClose
    (forever . serve)
  where
    serve lsocket = do
        (socket, _addr) <- NS.accept lsocket
        forkIO $ runResourceT $ do
            _ <- register $ NS.sClose socket
            app (sourceSocket socket) (sinkSocket socket)

-- | Settings for a TCP client, specifying how to connect to the server.
data ClientSettings = ClientSettings
    { clientPort :: Int
    , clientHost :: String
    }

-- | Run an @Application@ by connecting to the specified server.
runTCPClient :: ClientSettings -> Application -> IO ()
runTCPClient (ClientSettings port host) app = bracket
    (getSocket host port)
    NS.sClose
    (\s -> runResourceT $ app (sourceSocket s) (sinkSocket s))

-- | Attempt to connect to the given host/port.
getSocket :: String -> Int -> IO NS.Socket
getSocket host' port' = do
    let hints = NS.defaultHints {
                          NS.addrFlags = [NS.AI_ADDRCONFIG]
                        , NS.addrSocketType = NS.Stream
                        }
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host') (Just $ show port')
    sock <- NS.socket (NS.addrFamily addr) (NS.addrSocketType addr)
                      (NS.addrProtocol addr)
    ee <- try' $ NS.connect sock (NS.addrAddress addr)
    case ee of
        Left e -> NS.sClose sock >> throwIO e
        Right () -> return sock
  where
    try' :: IO a -> IO (Either SomeException a)
    try' = try

-- | Attempt to bind a listening @Socket@ on the given host/port. If no host is
-- given, will use the first address available.
bindPort :: Maybe String -> Int -> IO Socket
bindPort host p = do
    let hints = NS.defaultHints
            { NS.addrFlags =
                [ NS.AI_PASSIVE
                , NS.AI_NUMERICSERV
                , NS.AI_NUMERICHOST
                ]
            , NS.addrSocketType = NS.Stream
            }
        port = Just . show $ p
    addrs <- NS.getAddrInfo (Just hints) host port
    let
        tryAddrs (addr1:rest@(_:_)) =
                                      catch
                                      (theBody addr1)
                                      (\(_ :: IOException) -> tryAddrs rest)
        tryAddrs (addr1:[])         = theBody addr1
        tryAddrs _                  = error "bindPort: addrs is empty"
        theBody addr =
          bracketOnError
          (NS.socket
            (NS.addrFamily addr)
            (NS.addrSocketType addr)
            (NS.addrProtocol addr))
          NS.sClose
          (\sock -> do
              NS.setSocketOption sock NS.ReuseAddr 1
              NS.bindSocket sock (NS.addrAddress addr)
              NS.listen sock NS.maxListenQueue
              return sock
          )
    tryAddrs addrs

