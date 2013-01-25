{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import System.Environment (getArgs)

import Data.Maybe
import Control.Proxy
import Control.Proxy.Network.TCP

import Control.Applicative
import Control.Monad
import qualified Control.Exception as E


-- | Try to run a TCP client application.
runTCPClientErr :: Proxy p
                => ClientSettings
                -> TcpApplication p IO a
                -> IO (Either E.IOException a)
runTCPClientErr s a = E.handle (\(e :: E.IOException) -> return $ Left e)
                               (Right <$> runTCPClient s a)

-- | Try to connect to the hostname all the given TCP ports. On each
-- successfull connection run a 'TcpApplication'.
tcpPortsScan
 :: Proxy p
 => String                           -- ^ Hostname.
 -> [Int]                            -- ^ Ports to scan.
 -> (Int -> TcpApplication p IO ())  -- ^ Handle successful connection to the given port.
 -> IO [Int]                         -- ^ Returns open ports numbers.
tcpPortsScan host ports openk = fmap catMaybes $ forM ports $ \port -> do
   let settings = ClientSettings { clientHost = host
                                 , clientPort = port }
   e <- runTCPClientErr settings (openk port)
   return $ case e of Right _ -> Just port
                      Left  _ -> Nothing



main :: IO ()
main = do
  host <- maybe "127.0.0.1" id . parseArgs <$> getArgs

  ports <- tcpPortsScan host [1..65535] $ \port (src, _dst) -> do
     putStrLn $ "Open port: " ++ show port
     -- | no-op, just to keep the compiler happy.
     runProxy $ src >-> return

  putStrLn $ "All open ports: " ++ show ports


parseArgs :: [String] -> Maybe String
parseArgs [hostname] = Just hostname
parseArgs _          = Nothing

