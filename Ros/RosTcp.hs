{-# LANGUAGE ScopedTypeVariables #-}
module Ros.RosTcp (subStream, runServer) where
import Control.Applicative ((<$>))
import Control.Arrow ((***))
import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.BoundedChan
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (forever, forM_)
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet, getWord32le)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Network.BSD (getHostByName, hostAddress)
import Network.Socket hiding (send, sendTo, recv, recvFrom, Stream)
import qualified Network.Socket as Sock
import Network.Socket.ByteString.Lazy
import System.IO (IOMode(ReadMode))
import Unsafe.Coerce (unsafeCoerce)

import Ros.BinaryIter
import Ros.RosTypes
import Ros.RosBinary
import Ros.ConnectionHeader
import Msg.MsgInfo

-- |Maximum number of items to buffer for each client.
sendBufferSize :: Int
sendBufferSize = 10

-- |Push each item from this client's buffer over the connected
-- socket.
serviceClient :: BoundedChan ByteString -> Socket -> IO ()
serviceClient c s = go
    where go = readChan c >>= sendAll s >> go

negotiatePub :: String -> String -> Socket -> IO ()
negotiatePub ttype md5 sock = 
    do headerLength <- runGet (unsafeCoerce <$> getWord32le) <$>
                       recv sock 4
       headerBytes <- recv sock headerLength
       let connHeader = parseHeader headerBytes
       case lookup "type" connHeader of
         Just t | t == ttype -> return ()
                | otherwise -> error $ "Disagreeing Topic types: " ++
                                       "publisher expected "++ttype++
                                       ", but client asked for "++t
         Nothing -> error $ "Client did not include the topic type in its "++
                            "connection request."
       case lookup "md5sum" connHeader of
         Just s | s == md5 -> return ()
                | otherwise -> error "Disagreement on Topic type MD5"
         Nothing -> error $ "Client did not include MD5 sum in its request."
       return ()

-- |Accept new client connections. A new send buffer is allocated for
-- each new client and added to the client list along with an action
-- for cleaning up the client connection.
acceptClients :: Socket -> TVar [(IO (), BoundedChan ByteString)] -> 
                 (Socket -> IO ()) -> IO ()
acceptClients sock clients negotiate = forever acceptClient
    where acceptClient = do (client,_) <- accept sock
                            negotiate sock
                            chan <- newBoundedChan sendBufferSize
                            t <- forkIO $ serviceClient chan client
                            let cleanup = shutdown client ShutdownBoth >>
                                          killThread t
                            atomically $ readTVar clients >>= 
                                         writeTVar clients . ((cleanup,chan) :)

-- |Publish each item obtained from a Stream to each connected client.
pubStream :: BinaryCompact a => 
             Stream a -> TVar [(b, BoundedChan ByteString)] -> IO ()
pubStream s clients = forever $ go s
    where go (Stream x xs) = let bytes = runPut (put x)
                             in atomically (readTVar clients) >>=
                                mapM_ (flip writeChan bytes . snd)

-- Negotiate a TCPROS subscriber connection.
negotiateSub :: Socket -> String -> String -> String -> IO ()
negotiateSub sock tname ttype md5 = 
    do send sock $ genHeader [ ("callerid", "roshask"), ("topic", tname)
                             , ("md5sum", md5), ("type", ttype) ]
       responseLength <- runGet (unsafeCoerce <$> getWord32le) <$>
                         recv sock 4
       headerBytes <- recv sock responseLength
       let connHeader = parseHeader headerBytes
       case lookup "type" connHeader of
         Just t | t == ttype -> return ()
                | otherwise -> error $ "Disagreeing Topic types: " ++
                                       "subscriber expected "++ttype++
                                       ", but server replied with "++t
         Nothing -> error $ "Server did not include the topic type "++
                            "in its response."
       case lookup "md5sum" connHeader of
         Just s | s == md5 -> return ()
                | otherwise -> error "Disagreement on Topic type MD5"
         Nothing -> error "Server did not include MD5 sum in its response."
       return ()

-- |Connect to a publisher and return the stream of data it is
-- publishing.
subStream :: forall a. (BinaryIter a, MsgInfo a) => 
             URI -> String -> IO (Stream a)
subStream target tname = 
    do sock <- socket AF_INET Sock.Stream defaultProtocol
       ip <- hostAddress <$> getHostByName host
       connect sock $ SockAddrInet port ip
       let md5 = sourceMD5 (undefined::a)
           ttype = msgTypeName (undefined::a)
       negotiateSub sock tname ttype md5
       h <- socketToHandle sock ReadMode
       streamIn h
    where (host, port) = parseLocation target
          parseLocation = (id *** fromIntegral.read) . break (== ':')

-- |The server starts a thread that peels elements off the stream as
-- they become available and sends them to all connected
-- clients. Returns an action for cleanup up resources allocated by
-- this publication server along with the port the server is listening
-- on.
runServer :: forall a. (BinaryCompact a, MsgInfo a) => 
             Stream a -> IO (IO (), Int)
runServer stream = withSocketsDo $ do
                     sock <- socket AF_INET Sock.Stream defaultProtocol
                     bindSocket sock (SockAddrInet aNY_PORT iNADDR_ANY)
                     port <- fromIntegral <$> socketPort sock
                     listen sock 5
                     clients <- newTVarIO []
                     let ttype = msgTypeName (undefined::a)
                         md5 = sourceMD5 (undefined::a)
                         negotiate = negotiatePub ttype md5
                     acceptThread <- forkIO $ 
                                     acceptClients sock clients negotiate
                     pubThread <- forkIO $ pubStream stream clients
                     let cleanup = atomically (readTVar clients) >>= 
                                   sequence_ . map fst >> 
                                   shutdown sock ShutdownBoth >>
                                   killThread acceptThread
                     return (cleanup, port)
