{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main where

import           Control.Applicative
import           Control.Exception                (throwIO)
import           Control.Monad
import qualified Control.Monad.Reader             as R
import qualified Control.Monad.State              as S
import           Control.Monad.Trans.Class
import           Control.Proxy                    ((>->))
import qualified Control.Proxy                    as P
import           Control.Proxy.Network.TCP        (ServerSettings (..))
import           Control.Proxy.Network.TCP.Simple (Application, runServer)
import qualified Control.Proxy.Safe               as P
import qualified Data.ByteString.Char8            as B8
import           Data.Monoid                      ((<>), mconcat)
import qualified Network.Socket                   as NS (SockAddr)


main :: IO ()
main = do
  logMsg "OK" "TCP server listening on 127.0.0.1:9999"
  runServer (ServerSettings (Just "127.0.0.1") 9999) interactive

type Connections = [(Int, (String, Int))]

newtype InteractionT m a = InteractionT
        { unInteractionT :: R.ReaderT NS.SockAddr (S.StateT Connections m) a }
        deriving (Functor, Applicative, Monad)


interactive :: Application P.ProxyFast ()
interactive (addr, src, dst) = do
  let saddr = show addr
  logMsg "OK" $ "Starting interactive session with " <> saddr

  let firstTimeS = welcomeP (show addr) >=> usageP
      interactD  = linesD >-> parseInputD >-> handleInputD
      psession   = (firstTimeS >=> (src' >-> interactD)) >-> dst'
      src'       = (P.raiseK . P.tryK) src
      dst'       = (P.raiseK . P.tryK) dst
  eio <- P.trySafeIO . evalInteractionT addr []
                     . P.runProxy . P.runEitherK $ psession
  case eio of
    Left e  -> do
      logMsg "ERR" $ "Failure in session with " <> saddr <> ": " <> show e
    Right _ -> do
      logMsg "ERR" $ "Closing session with " <> saddr



--------------------------------------------------------------------------------
-- Client requests interpreter

type ConnectionId = Int

data Request
  = Exit
  | Help
  | Connect String Int
  | Disconnect ConnectionId
  | Connections
  | Send ConnectionId String
  | Crash
  deriving (Read, Show, Eq)


-- | Parse proper input flowing downstream into a 'Request'.
parseInputD
  :: (P.Proxy p, Monad m)
  => () -> P.Pipe p B8.ByteString (Either B8.ByteString Request) m r
parseInputD = P.runIdentityK . P.foreverK $ \() -> do
  line <- P.request ()
  let (line',_) = B8.breakSubstring "\r\n" line
  case parseRequest (B8.unpack line') of
    Nothing -> P.respond $ Left line'
    Just r  -> P.respond $ Right r

handleInputD
  :: (P.Proxy p)
  => () -> P.Pipe (P.ExceptionP p) (Either B8.ByteString Request) B8.ByteString (InteractionT P.SafeIO) ()
handleInputD () = loop where
  loop = do
    er <- P.request ()
    addr <- lift R.ask
    case er of
      Left _  -> do
        io . logMsg "INFO" $ "Bad request from " <> show addr
        sendLine $ ["Bad request. See 'Help' for usage instructions."]
        loop
      Right r -> do
        io . logMsg "INFO" $ "Request from " <> show addr <> ": " <> show r
        (const (P.respond r) >-> runRequestD) ()
        case r of
          Exit -> return ()
          _    -> loop
  io = P.raise . P.tryIO

runRequestD
  :: (P.Proxy p)
  => () -> P.Pipe (P.ExceptionP p) Request B8.ByteString (InteractionT P.SafeIO) ()
runRequestD () = do
    r <- P.request ()
    case r of
      Exit -> sendLine [ "Bye." ]
      Help -> usageP ()
      Crash -> do
        sendLine [ "Crashing. Connection will drop. Try connecting again." ]
        io . throwIO $ userError "Crash request"
      Connect h p -> do
        connId <- addConnection h p
        sendLine [ "Added connection ID ", show connId, " to ", show (h, p) ]
        io . throwIO $ userError "TODO"
      Disconnect connId -> do
        remConnection connId
        sendLine [ "Removed connection ID ", show connId ]
        io . throwIO $ userError "TODO"
      Connections -> do
        conns <- lift $ S.get
        sendLine [ "Connections [(ID, (IPv4, PORT-NUMBER))]:" ]
        sendLines [ ("  "<>) . show <$> conns ]
      Send connId line -> do
        sendLine [ "Sending to connection ID ", show connId ]
        io . throwIO $ userError "TODO"
  where
    io = P.raise . P.tryIO
    addConnection host port = lift $ do
      conns <- S.get
      case conns of
        []    -> S.put [(1, (host, port))] >> return 1
        (x:_) -> do let connId = fst x + 1
                    S.put $ (connId, (host, port)):conns
                    return connId
    remConnection connId = lift . S.modify $ \conns ->
      filter ((/=connId) . fst) conns -- meh.


--------------------------------------------------------------------------------
-- Mostly boring stuff below here.

-- | Send a greeting message to @who@ downstream.
welcomeP :: (Monad m, P.Proxy p) => String -> () -> p a' a () B8.ByteString m ()
welcomeP who () = sendLine [ "Welcome to the non-magical TCP client, ", who ]

-- | Send a usage instructions downstream.
usageP :: (Monad m, P.Proxy p) => () -> p a' a () B8.ByteString m ()
usageP () = sendLines . map pure $
  [ "Enter one of the following commands:"
  , "  Help"
  , "    Show this message."
  , "  Crash"
  , "    Force an unexpected crash in the server end of this TCP session."
  , "  Connect \"<IPv4>\" <PORT-NUMBER>"
  , "    Establish a TCP connection to the given TCP server."
  , "    The ID of the new connection is shown on success."
  , "  Disconnect <ID>"
  , "    Close a the established TCP connection identified by <ID>."
  , "  Connections"
  , "    Shows all established TCP connections and their <ID>s."
  , "  Send <ID> \"<LINE>\""
  , "    Sends <LINE> followed by \\r\\n to the established TCP"
  , "    connection identified by <ID>. Any response is shown."
  , "  Exit"
  , "    Exit this interactive session."
  ]


parseRequest :: String -> Maybe Request
parseRequest s = case reads s of
  [(r,"")] -> Just r
  _        -> Nothing


-- | Split raw input flowing downstream into individual lines.
--
-- XXX Probably not an efficient implementation, and maybe even wrong.
linesD :: (P.Proxy p, Monad m) => () -> P.Pipe p B8.ByteString B8.ByteString m r
linesD = P.runIdentityK (go B8.empty) where
  go buf () = P.request () >>= use . (buf <>)
  use buf = do
    let (p,s) = B8.breakSubstring "\r\n" buf
    case (B8.length p, B8.length s) of
      (_,0) -> go p () -- no more input in buffer, request more
      (_,2) -> P.respond p >> go B8.empty () -- 2 suffix chars are \r\n
      (0,_) -> P.respond B8.empty >> use (B8.drop 2 s) -- leading newline
      (_,_) -> P.respond p >> use (B8.drop 2 s) -- 2 first suffix chars are \r\n


showLine :: [String] -> B8.ByteString
showLine xs = "| " <> mconcat xs' <> "\r\n"
  where xs' = B8.pack <$> xs

sendLine :: (P.Proxy p, Monad m) => [String] -> p a' a b' B8.ByteString m b'
sendLine = P.respond . showLine

sendLines :: (P.Proxy p, Monad m) => [[String]] -> p a' a b' B8.ByteString m b'
sendLines = P.respond . mconcat . fmap showLine

logMsg :: String -> String -> IO ()
logMsg level msg = putStrLn $ "[" <> level <> "] " <> msg

-- InteractionT stuff

runInteractionT :: Monad m => NS.SockAddr -> Connections
                -> InteractionT m a -> m (a, Connections)
runInteractionT e s (InteractionT m) = S.runStateT (R.runReaderT m e) s

evalInteractionT :: Monad m => NS.SockAddr -> Connections
                 -> InteractionT m b -> m b
evalInteractionT e s = liftM fst . runInteractionT e s

instance MonadTrans InteractionT where
  lift = InteractionT . lift . lift

instance Monad m => R.MonadReader (InteractionT m) where
  type EnvType (InteractionT m) = NS.SockAddr
  ask = InteractionT $ R.ask
  local f (InteractionT m) = InteractionT $ R.local f m

instance Monad m => S.MonadState (InteractionT m) where
  type StateType (InteractionT m) = Connections
  get = InteractionT . lift $ S.get
  put = InteractionT . lift . S.put

