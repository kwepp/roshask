{-# LANGUAGE BangPatterns #-}
module Ros.StreamCombinators where
import Control.Applicative
import Control.Concurrent
import Data.Stream (Stream(..))
import qualified Data.Stream as S

-- |Turn a stream of values into a stream of pairs of consecutive
-- values.
consecutive :: Stream a -> Stream (a,a)
consecutive s = (,) <$> s <*> S.tail s

-- |Return pairs of items from two streams advancing through the
-- streams in lockstep. If data is being generated by one stream much
-- faster than the other, this is a bad fit.
lockstep :: Stream a -> Stream b -> Stream (a,b)
lockstep s1 s2 = (,) <$> s1 <*> s2

-- |Stream a new pair every time either of the component 'Stream's
-- produces a new value. The value of the other element of the pair
-- will be the newest available value.
everyNew :: Stream a -> Stream b -> IO (Stream (IO (a,b)))
everyNew s t = do mvx <- newEmptyMVar
                  mvy <- newEmptyMVar
                  c <- newChan
                  let feedX stream = 
                          let go (Cons x xs) = do swapMVar mvx x
                                                  y <- readMVar mvy
                                                  writeChan c (x,y)
                                                  go xs
                          in go stream
                      feedY stream = 
                          let go (Cons y ys) = do swapMVar mvy y
                                                  x <- readMVar mvx
                                                  writeChan c (x,y)
                                                  go ys
                          in go stream
                  t1 <- forkIO $ feedX s
                  t2 <- forkIO $ feedY t
                  let merged = Cons (readChan c) merged
                  return merged

-- |Apply a function to each consecutive pair of elements from a
-- 'Stream'. This can be useful for finite difference analyses.
finiteDifference :: (a -> a -> b) -> Stream a -> Stream b
finiteDifference f s = fmap (uncurry f) $ consecutive s

-- |Perform numerical integration of a 'Stream' using Simpson's rule
-- applied at three consecutive points. This requires a function for
-- adding values from the 'Stream', and a function for scaling values
-- by a fractional number.
simpsonsRule :: Fractional n => 
                (a -> a -> a) -> (n -> a -> a) -> Stream a -> Stream a
simpsonsRule plus scale s = go s
    where go stream = Cons (simpson (S.take 3 stream)) (go (S.tail stream))
          c = 1 / 6
          simpson [a,mid,b] = scale c $ plus (plus a (scale 4 mid)) b

-- |Compute a running \"average\" of a 'Stream' by summing the product
-- of @alpha@ and the current average with the product of @1 - alpha@
-- and the newest value. The first parameter is the constant @alpha@,
-- the second is an addition function, the third a scaling function,
-- and the fourth the input 'Stream'.
weightedMean :: Num n => 
                n -> (a -> a -> a) -> (n -> a -> a) -> Stream a -> Stream a
weightedMean alpha plus scale = weightedMean2 alpha (1 - alpha) plus scale
{-# INLINE weightedMean #-}

-- |Compute a running \"average\" of a 'Stream' by summing the product
-- of @alpha@ and the current average with the product of @invAlpha@
-- and the newest value. The first parameter is the constant @alpha@,
-- the second is the constant @invAlpha@, the third is an addition
-- function, the fourth a scaling function, and the fifth the input
-- 'Stream'.
weightedMean2 :: n -> n -> (a -> a -> a) -> (n -> a -> a) -> Stream a -> Stream a
weightedMean2 alpha invAlpha plus scale = warmup
    where warmup (Cons x xs) = go x xs
          go avg (Cons x xs) = let !savg = scale alpha avg
                                   !sx = scale invAlpha x
                                   !avg' = plus savg sx
                               in Cons avg' (go avg' xs)
{-# INLINE weightedMean2 #-}

-- |Compute a running \"average\" of a 'Stream' using a user-provided
-- normalization function applied to the sum of products. The
-- arguments are a constat @alpha@ that is used to scale the current
-- average, a constant @invAlpha@ used to scale the newest value, a
-- function for adding two scaled values, a function for scaling
-- input values, a function for normalizing the sum of scaled values,
-- and finally the stream to average. Parameterizing over all the
-- arithmetic to this extent allows for the use of denormalizing
-- scaling factors, as might be used to keep all arithmetic
-- integral. An example would be scaling the average by the integer
-- 7, the new value by the integer 1, then normalizing by dividing
-- the sum of scaled values by 8.
weightedMeanNormalized :: n -> n -> (b -> b -> c) -> (n -> a -> b) -> 
                          (c -> a) -> Stream a -> Stream a
weightedMeanNormalized alpha invAlpha plus scale normalize = warmup
    where warmup (Cons x xs) = go x xs
          go avg (Cons x xs) = let !avg' = normalize $ plus (scale alpha avg)
                                                            (scale invAlpha x)
                               in Cons avg' (go avg' xs)
{-# INLINE weightedMeanNormalized #-}

                                    
