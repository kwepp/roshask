{-# LANGUAGE PackageImports, MultiParamTypeClasses, ScopedTypeVariables, 
             TupleSections #-}
module Ros.Node (Node, runNode, advertise, advertiseIO, subscribe) where
import Control.Applicative ((<$>))
import Control.Concurrent.BoundedChan
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, readTVar, writeTVar, newTVarIO)
import "monads-fd" Control.Monad.State
import Data.Map (Map)
import qualified Data.Map as M
import Data.Set (Set)
import qualified Data.Set as S
import Data.Typeable (Typeable, TypeRep, typeOf)
import Control.Concurrent (forkIO, ThreadId)
import System.IO.Unsafe (unsafeInterleaveIO)
import Msg.MsgInfo
import Ros.RosBinary (BinaryCompact)
import Ros.BinaryIter
import Ros.RosTypes
import Ros.RosTcp
import Ros.SlaveAPI (RosSlave(..))
import qualified Ros.RunNode as RN

data Subscription = Subscription { knownPubs :: TVar (Set URI)
                                 , addPub    :: URI -> IO ThreadId
                                 , subType   :: TypeRep
                                 , subStats  :: Map URI (TVar SubStats) }

data Publication = Publication { subscribers :: TVar (Set URI)
                               , pubType     :: TypeRep
                               , pubPort     :: Int
                               , pubCleanup  :: IO ()
                               , pubStats    :: Map URI (TVar PubStats) }

data NodeState = NodeState { nodeName      :: String
                           , master        :: URI
                           , subscriptions :: Map String Subscription
                           , publications  :: Map String Publication }

newtype Node a = Node { unNode :: StateT NodeState IO a }

instance Monad Node where
    (Node s) >>= f = Node $ s >>= unNode . f
    return = Node . return

instance MonadIO Node where
    liftIO m = Node $ liftIO m

instance MonadState NodeState Node where
    get = Node get
    put = Node . put

instance RosSlave NodeState where
    getMaster = master
    getSubscriptions = mapM formatSub . M.toList . subscriptions
        where formatSub (name, sub) = let topicType = show $ subType sub
                                      in do stats <- mapM statSnapshot . 
                                                     M.toList $
                                                     subStats sub
                                            return (name, topicType, stats)
    getPublications = mapM formatPub . M.toList . publications
        where formatPub (name, pub) = let topicType = show $ pubType pub
                                      in do stats <- mapM statSnapshot .
                                                     M.toList $
                                                     pubStats pub
                                            return (name, topicType, stats)
    publisherUpdate ns name uris = 
        case M.lookup name (subscriptions ns) of
          Nothing -> return ()
          Just sub -> join . atomically $
                      do let add = addPub sub >=> \_ -> return ()
                         known <- readTVar (knownPubs sub) 
                         (act,known') <- foldM (connectToPub add)
                                               (return (), known)
                                               uris
                         writeTVar (knownPubs sub) known'
                         return act
    getTopicPortTCP = (liftM pubPort .) . flip M.lookup . publications
    stopNode = mapM_ (pubCleanup . snd) . M.toList . publications

statSnapshot :: (URI, TVar a) -> IO (URI, a)
statSnapshot (uri, stat) = (uri,) <$> atomically (readTVar stat)

-- If a given URI is not a part of a Set of known URIs, add an action
-- to effect a subscription to an accumulated action and add the URI
-- to the Set.
connectToPub :: Monad m => 
                (URI -> IO ()) -> (IO (), Set URI) -> URI -> m (IO (), Set URI)
connectToPub doSub (act, known) uri = if S.member uri known
                                      then return (act, known)
                                      else let known' = S.insert uri known
                                           in return (act >> doSub uri, known')

-- |Maximum number of items to buffer for a subscriber.
recvBufferSize :: Int
recvBufferSize = 10

-- |Spark a thread that funnels a Stream from a URI into the given
-- Chan.
addSource :: (BinaryIter a, MsgInfo a) => 
             String -> BoundedChan a -> URI -> IO ThreadId
addSource tname c uri = forkIO $ subStream uri tname >>= go
    where go (Stream x xs) = writeChan c x >> go xs

-- Create a new Subscription value that will act as a named input
-- channel with zero or more connected publishers.
mkSub :: forall a. (Typeable a, BinaryIter a, MsgInfo a) => 
         String -> IO (Stream a, Subscription)
mkSub tname = do c <- newBoundedChan recvBufferSize
                 stream <- list2stream <$> getChanContents c
                 known <- newTVarIO S.empty
                 let topicType = typeOf (undefined::a)
                     sub = Subscription known (addSource tname c) 
                                        topicType M.empty
                 return (stream, sub)
    where list2stream (x:xs) = Stream x (list2stream xs)

mkPub :: forall a. (Typeable a, BinaryCompact a, MsgInfo a) => 
         Stream a -> IO Publication
mkPub s = do (cleanup, port) <- runServer s
             known <- newTVarIO S.empty
             let trep = typeOf (undefined::a)
             return $ Publication known trep port cleanup M.empty

-- |Subscribe to the given Topic. Returns the @Stream@ of values
-- received on over the Topic.
subscribe :: (Typeable a, BinaryIter a, MsgInfo a) => 
             TopicName -> Node (Stream a)
subscribe name = do n <- get
                    let subs = subscriptions n
                    if M.member name subs
                       then error $ "Already subscribed to "++name
                       else do (stream, sub) <- liftIO (mkSub name)
                               put n { subscriptions = M.insert name sub subs }
                               return stream

-- |Advertise a Topic publishing a @Stream@ of pure values.
advertise :: (Typeable a, BinaryCompact a, MsgInfo a) => 
             TopicName -> Stream a -> Node ()
advertise name stream = 
    do n <- get
       let pubs = publications n
       if M.member name pubs 
         then error $ "Already advertised "++name
         else do pub <- liftIO $ mkPub stream 
                 put n { publications = M.insert name pub pubs }

streamIO :: Stream (IO a) -> IO (Stream a)
streamIO (Stream x xs) = do x' <- x
                            xs' <- unsafeInterleaveIO $ streamIO xs
                            return $ Stream x' xs'

-- |Advertise a Topic publishing a @Stream@ of @IO@ values.
advertiseIO :: (Typeable a, BinaryCompact a, MsgInfo a) => 
               TopicName -> Stream (IO a) -> Node ()
advertiseIO name stream = do s <- liftIO $ streamIO stream
                             advertise name s

-- |Run a ROS Node.
runNode :: NodeName -> Node a -> IO ()
runNode name (Node n) = go $ execStateT n (NodeState name "" M.empty M.empty)
    where go ns = ns >>= RN.runNode
