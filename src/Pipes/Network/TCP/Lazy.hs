{-# LANGUAGE RankNTypes #-}

module Pipes.Network.TCP.Lazy (
  -- * Sending
  -- $sending
    toSocket
  , toSocketTimeout
  ) where

import qualified Data.ByteString.Lazy           as BL
import           Foreign.C.Error                (errnoToIOError, eTIMEDOUT)
import           Network.Socket                 (Socket)
import qualified Network.Socket.ByteString.Lazy as NSBL
import           Pipes
import           System.Timeout                 (timeout)
--------------------------------------------------------------------------------

-- $sending
--
-- The following pipes allow you to send bytes to the remote end.
--
-- | Sends to the remote end each 'BL.ByteString' received from upstream.
toSocket
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Consumer' BL.ByteString m r
toSocket sock = for cat $ \a -> liftIO (NSBL.sendAll sock a)
{-# INLINABLE toSocket #-}

-- | Like 'toSocket', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then an 'IOError' exception is
-- thrown. The time is specified in microseconds (1 second = 1e6 microseconds).
toSocketTimeout
  :: MonadIO m
  => Int -> Socket -> Consumer' BL.ByteString m r
toSocketTimeout wait sock = for cat $ \a -> do
    mu <- liftIO (timeout wait (NSBL.sendAll sock a))
    case mu of
       Just () -> return ()
       Nothing -> liftIO $ ioError $ errnoToIOError
          "Pipes.Network.TCP.Lazy.toSocketTimeout" eTIMEDOUT Nothing Nothing
{-# INLINABLE toSocketTimeout #-}

--------------------------------------------------------------------------------
