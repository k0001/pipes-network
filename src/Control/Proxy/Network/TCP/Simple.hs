{-# LANGUAGE KindSignatures #-}

-- | This module exports an API for simple TCP applications in which the entire
-- life-cycle of a TCP server or client runs as a single IO action.

module Control.Proxy.Network.TCP.Simple (
   -- * Simple TCP Application API
   Application,
   -- ** Client side
   PNT.ClientSettings(..),
   runClient,
   -- ** Server side
   PNT.ServerSettings(..),
   runServer,
   ) where

import qualified Control.Exception         as E
import           Control.Monad             (forever)
import qualified Control.Proxy             as P
import qualified Control.Proxy.Network.TCP as PNT
import qualified Data.ByteString           as B
import qualified Network.Socket            as NS


-- | A simple TCP application in which the entire life-cycle of a TCP server or
-- client runs as a single 'IO' action.
--
-- It takes a continuation that recieves the other connection endpoint address,
-- a 'Producer' to read input data from and a 'Consumer' to send output data to.
type Application (p :: * -> * -> * -> * -> (* -> *) -> * -> *) r
  = (NS.SockAddr,
     () -> P.Producer p B.ByteString IO (),
     () -> P.Consumer p B.ByteString IO ())
  -> IO r


-- | Run a TCP 'Application' by connecting to the specified server.
--
-- This function will connect to a TCP server specified in the given settings
-- and run the given 'Application'.
runClient :: P.Proxy p => PNT.ClientSettings -> Application p r -> IO r
runClient (PNT.ClientSettings host port) app = E.bracket
    (PNT.connect host port)
    (NS.sClose . fst)
    (\(s,a) -> app (a, PNT.socketProducer 4096 s, PNT.socketConsumer s))


-- | Run a TCP 'Application' with the given settings.
--
-- This function will create a new listening socket using the given settings,
-- accept connections on it, and handle each incomming connection running the
-- given 'Application' on a new thread.
runServer :: P.Proxy p => PNT.ServerSettings -> Application p r -> IO r
runServer (PNT.ServerSettings host port) app = E.bracket
    (PNT.listen host port)
    (NS.sClose . fst)
    (forever . serve)
  where
    serve (listeningSock,_) = do
      PNT.acceptFork listeningSock $ \(s,a) -> do
        app (a, PNT.socketProducer 4096 s, PNT.socketConsumer s)
        return ()

