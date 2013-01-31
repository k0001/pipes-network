{-# LANGUAGE OverloadedStrings #-}


import           Control.Concurrent               (forkIO)
import           Control.Proxy
import           Control.Proxy.Network.TCP.Simple
import           Control.Proxy.Safe
import qualified Data.ByteString.Char8            as B8
import           Data.Char                        (toUpper)
import           Data.Monoid                      (mconcat)



main :: IO ()
main = do
  let hostname = "127.0.0.1"

  forkIO $ do
     let port = 9999
     runServer (Host hostname) port
       (\addr -> putStrLn $ "Started non-safe echo server on " ++ show addr)
       nonsafeEchoApp

  do let port = 9998
     runServer (Host hostname) port
       (\addr -> putStrLn $ "Started non-safe echo server on " ++ show addr)
       safeEchoApp

  return ()


-- | This 'Application' safely handles resource (socket) finalization.
safeEchoApp :: Application ProxyFast ()
safeEchoApp addr (src, dst) = do
    putStrLn $ "Incomming connection from " ++ show addr
    let upped = src >-> mapD (B8.map toUpper)
        proxy = (welcomeP (show addr) >=> upped) >-> dst
    runSafeIO . runProxy . runEitherK $ tryK proxy
    return ()


-- | This 'Application' doesn't safely handle resource (socket) finalization.
nonsafeEchoApp :: Application ProxyFast ()
nonsafeEchoApp addr (src, dst) = do
    putStrLn $ "Incomming connection from " ++ show addr
    let upped = src >-> mapD (B8.map toUpper)
        proxy = (welcomeP (show addr) >=> upped) >-> dst
    runProxy proxy
    return ()


-- | Send a greeting to 'who' downstream.
welcomeP :: (Monad m, Proxy p) => String -> () -> p a' a b' B8.ByteString m b'
welcomeP who () = respond $ mconcat
    [ "-- Welcome ", B8.pack who, "\r\n"
    , "-- Send some lines and I'll shout them back to you.\r\n"]


