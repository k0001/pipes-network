{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Applicative
import qualified Control.Exception                as E
import           Control.Monad
import qualified Control.Monad.Reader             as R
import qualified Control.Monad.State              as S
import           Control.Monad.Trans.Class
import           Control.Proxy                    ((>->))
import qualified Control.Proxy                    as P
import qualified Control.Proxy.Safe.Network.TCP   as PN
import qualified Control.Proxy.Network.TCP.Simple as PN
import qualified Control.Proxy.Safe               as P
import qualified Data.ByteString.Char8            as B8
import           Data.Monoid                      ((<>), mconcat)
import           Data.Maybe                       (isJust)
import qualified Network.Socket                   as NS


main :: IO ()
main = do
  PN.runServer "127.0.0.1" "9999"
    (\addr -> logMsg "INFO" $ "Started TCP server listening on " <> show addr)
    interactive

type Connection = (NS.Socket, NS.SockAddr)
type Connections = [(Int, Connection)]

newtype InteractionT m a = InteractionT
        { unInteractionT :: R.ReaderT NS.SockAddr (S.StateT Connections m) a }
        deriving (Functor, Applicative, Monad)


interactive :: PN.Application P.ProxyFast ()
interactive addr (src, dst) = do
  logClient' addr "INFO" "Starting interactive session"

  let firstTimeS = welcomeP (show addr) >=> usageP
      interactD  = linesD >-> parseInputD >-> handleInputD
      psession   = (firstTimeS >=> (src' >-> interactD)) >-> dst'
      src'       = (P.raiseK . P.tryK) src
      dst'       = (P.raiseK . P.tryK) dst
  (eio, conns) <- P.trySafeIO . runInteractionT addr []
                              . P.runProxy . P.runEitherK $ psession
  case eio of
    Left ex  -> logClient' addr "ERR"  $ "Session exception: " <> show ex
    Right _  -> logClient' addr "INFO" $ "Session successfully ended."

  logClient' addr "INFO" "Closing remaining connections..."
  mapM_ (closeConnection . snd) conns




--------------------------------------------------------------------------------
-- Client requests interpreter

type ConnectionId = Int

data Request
  = Exit
  | Help
  | Connect NS.HostName NS.ServiceName
  | Disconnect ConnectionId
  | Connections
  | Send ConnectionId String
  | Receive ConnectionId Int
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
  :: (P.CheckP p)
  => () -> P.Pipe (P.ExceptionP p) (Either B8.ByteString Request) B8.ByteString (InteractionT P.SafeIO) ()
handleInputD () = loop where
  loop = do
    er <- P.request ()
    case er of
      Left _  -> do
        logClient "INFO" $ "Bad request"
        sendLine $ ["Bad request. See 'Help' for usage instructions."]
        loop
      Right r -> do
        logClient "INFO" $ "Request: " <> show r
        (const (P.respond r) >-> runRequestD) ()
        case r of
          Exit -> return ()
          _    -> loop

-- | Analogous to 'Control.Exception.try' from @Control.Exception@
exTry :: (Monad m, E.Exception e, P.Proxy p)
      => P.EitherP P.SomeException p a' a b' b m r
      -> P.ExceptionP p a' a b' b m (Either e r)
exTry m = P.catch (liftM Right m) (return . Left)


runRequestD
  :: (P.CheckP p)
  => () -> P.Pipe (P.ExceptionP p) Request B8.ByteString (InteractionT P.SafeIO) ()
runRequestD () = do
    r <- P.request ()
    case r of
      Exit -> sendLine [ "Bye." ]
      Help -> usageP ()
      Crash -> do
        sendLine [ "Crashing. Connection will drop. Try connecting again." ]
        io . E.throwIO $ userError "Crash request"
      Connect host port -> do
        econn <- P.raise . exTry $ PN.connect host port
        case econn of
          Left (ex :: E.SomeException) -> do
            let msg = "Can't connect " <> show (host,port) <> ": " <> show ex
            logClient "WARN" msg
            sendLine [msg]
          Right conn@(_,addr) -> do
            connId <- lift $ addConnection conn
            let msg = "Connected to " <> show addr <> ". ID " <> show connId
            logClient "INFO" msg
            sendLine [msg]
      Disconnect connId -> do
        mconn <- lift $ popConnection connId
        case mconn of
          Nothing -> sendLine [ "No such connection ID." ]
          Just conn@(_,a) -> do
            io $ closeConnection conn
            sendLine ["Closed connection ID ", show connId, " to ", show a]
      Connections -> do
        let showConn (n,(_,a)) = "  " <> show n <> ": " <> show a
        conns <- lift $ S.get
        case conns of
          [] -> sendLine  $ ["No connections."]
          _  -> sendLines $ ["Connections:"] : fmap (pure . showConn) conns
      Send connId msg -> do
        mconn <- lift $ getConnection connId
        case mconn of
          Nothing -> sendLine [ "No such connection ID." ]
          Just (sock,addr) -> do
            let bytes = B8.pack msg
            sendLine ["Sending ", show (B8.length bytes)," bytes to ",show addr]
            (const (P.respond bytes)
               >-> P.raiseK (PN.socketC sock)
               >-> P.unitU) ()
            sendLine ["Sent."]
      Receive connId len -> do
        mconn <- lift $ getConnection connId
        case mconn of
          Nothing -> sendLine [ "No such connection ID." ]
          Just (sock,addr) -> do
            sendLine ["Receiving up to ", show len, " bytes from ", show addr]
            let src = P.unitD >-> P.raiseK (PN.socketP len sock)
            (src >-> takeBytesD len) ()
            P.respond "\r\n"
            -- FIXME use countBytesD to get the number of received bytes
            sendLine ["Received <unknown> bytes. (FIXME)"]



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
  , "  Send <ID> \"<MESSAGE>\""
  , "    Sends <MESSAGE> followed to the established TCP connection"
  , "    identified by <ID>."
  , "  Receive <ID> <MAX-BYTES>"
  , "    Receive up to <MAX-BYTES> from the established TCP connection"
  , "    identified by <ID>. Any response is shown."
  , "  Exit"
  , "    Exit this interactive session."
  ]


parseRequest :: String -> Maybe Request
parseRequest s = case reads s of
  [(r,"")] -> Just r
  _        -> Nothing


-- | Split raw input flowing downstream into individual lines.
--
-- XXX Probably innefficient and wrong.
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

logClient' :: NS.SockAddr -> String -> String -> IO ()
logClient' addr level msg = logMsg level msg' where
    msg' = "<Client session " <> show addr <> "> " <> msg


--------------------------------------------------------------------------------
-- InteractionT stuff

runInteractionT :: Monad m => NS.SockAddr -> Connections
                -> InteractionT m a -> m (a, Connections)
runInteractionT e s (InteractionT m) = S.runStateT (R.runReaderT m e) s

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


--------------------------------------------------------------------------------
-- API for our precarious 'Connections' container within 'InteractionT'.
-- addConnection :: Monad m => Connection -> InteractionT m a

addConnection :: Monad m => Connection -> InteractionT m ConnectionId
addConnection conn = do
  conns <- S.get
  case conns of
    []         -> S.put [(1, conn)]         >> return 1
    ((n,_):_)  -> S.put ((n+1, conn):conns) >> return (n+1)

getConnection :: Monad m => ConnectionId -> InteractionT m (Maybe Connection)
getConnection connId = lookup connId `liftM` S.get

popConnection :: Monad m => ConnectionId -> InteractionT m (Maybe Connection)
popConnection connId = do -- dggggh
    mx <- getConnection connId
    when (isJust mx) $ do
      S.modify $ filter ((/=connId) . fst)
    return mx


--------------------------------------------------------------------------------

io :: P.Proxy p => IO r -> (P.ExceptionP p) a' a b' b (InteractionT P.SafeIO) r
io = P.raise . P.tryIO

logClient :: P.Proxy p => String -> String -> (P.ExceptionP p) a' a b' b (InteractionT P.SafeIO) ()
logClient level msg = lift R.ask >>= \addr -> io $ logClient' addr level msg


closeConnection :: Connection -> IO ()
closeConnection (sock,addr) = do
  logMsg "INFO" $ "Closing connection to " <> show addr
  E.catch (NS.sClose sock) $ \(ex :: E.SomeException) -> do
      logMsg "ERR" $ mconcat [ "Exception closing connection to "
                             , show addr, ": ", show ex ]


--------------------------------------------------------------------------------

-- | Pipe bytes flowing downstream up to length @n@.
takeBytesD
  :: (Monad m, P.Proxy p)
  => Int -> () -> P.Pipe p B8.ByteString B8.ByteString m ()
takeBytesD = P.runIdentityK . go where
  go n ()
    | n <= 0    = return ()
    | otherwise = do
        bs <- B8.take n <$> P.request ()
        void $ P.respond bs
        go (n - B8.length bs) ()

-- | Count bytes flowing downstream.
countBytesD
  :: (Monad m, P.Proxy p)
  => () -> P.Pipe p B8.ByteString B8.ByteString (S.StateT Int m) r
countBytesD () = P.runIdentityP . forever $ do
    bs <- P.request ()
    lift . S.modify $ (+) (B8.length bs)
    P.respond bs

