{-# LANGUAGE KindSignatures #-}
{-# OPTIONS_HADDOCK not-home #-}

-- | This module exports an API for simple TCP applications in which the entire
-- life-cycle of a TCP server or client runs as a single 'IO' action.

module Control.Proxy.Network.TCP.Simple (
   -- * Simple TCP Application API
   Application,
   -- ** Client side
   runClient,
   -- ** Server side
   runServer,
   HostPreference(..)
   ) where

import qualified Control.Exception         as E
import           Control.Monad             (forever, void)
import qualified Control.Proxy             as P
import           Control.Proxy.Network.TCP
import qualified Data.ByteString           as B
import qualified Network.Socket            as NS


-- | A simple TCP application in which the entire life-cycle of a TCP server or
-- client runs as a single 'IO' action.
--
-- It takes a continuation that recieves the other connection endpoint address,
-- a 'Producer' to read input data from and a 'Consumer' to send output data to.
type Application (p :: * -> * -> * -> * -> (* -> *) -> * -> *) r
  = NS.SockAddr
  -> (() -> P.Producer p B.ByteString IO (),
      () -> P.Consumer p B.ByteString IO ())
  -> IO r


-- | Run a simple TCP 'Application' client connecting to the specified server.
runClient
  :: P.Proxy p
  => NS.HostName       -- ^Server hostname.
  -> NS.ServiceName    -- ^Server service name (port).
  -> Application p r   -- ^Applicatoin
  -> IO r
runClient host port app = E.bracket conn close' use
  where
    conn = connect host port
    close' (sock,_) = close sock
    use (sock,addr) = app addr (socketP 4096 sock, socketC sock)


-- | Run a simple 'Application' TCP server handling each incomming connection
-- in a different thread.
runServer
  :: P.Proxy p
  => HostPreference          -- ^Preferred host to bind to.
  -> NS.ServiceName          -- ^Service name (port) to bind to.
  -> (NS.SockAddr -> IO ())  -- ^Computation to run once after the listening
                             --  socket has been bound.
  -> Application p r         -- ^Application handling an incomming connection.
  -> IO r
runServer hp port afterBind app = E.bracket bind close' use
  where
    bind = listen hp port
    close' (lsock,_) = close lsock
    use (lsock,laddr) = do
      afterBind laddr
      forever . acceptFork lsock $ \(csock,caddr) -> do
        void $ app caddr (socketP 4096 csock, socketC csock)

