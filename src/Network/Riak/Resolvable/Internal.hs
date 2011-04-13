{-# LANGUAGE BangPatterns, DeriveDataTypeable, GeneralizedNewtypeDeriving #-}
-- |
-- Module:      Network.Riak.Resolvable.Internal
-- Copyright:   (c) 2011 MailRank, Inc.
-- License:     Apache
-- Maintainer:  Bryan O'Sullivan <bos@mailrank.com>
-- Stability:   experimental
-- Portability: portable
--
-- Storage and retrieval of data with automatic conflict resolution.
--
-- The 'put' and 'putMany' functions will attempt to perform automatic
-- conflict resolution a large number of times.  If they give up due
-- to apparently being stuck in a loop, they will throw a
-- 'ResolutionFailure' exception.

module Network.Riak.Resolvable.Internal
    (
      Resolvable(..)
    , ResolvableMonoid(..)
    , ResolutionFailure(..)
    , get
    , getMany
    , put
    , put_
    , putMany
    , putMany_
    ) where

import Control.Arrow (first)
import Control.Exception (Exception, throwIO)
import Control.Monad (unless)
import Data.Aeson.Types (FromJSON, ToJSON)
import Data.Data (Data)
import Data.Either (partitionEithers)
import Data.Function (on)
import Data.List (foldl', sortBy)
import Data.Monoid (Monoid(mappend))
import Data.Typeable (Typeable)
import Network.Riak.Debug (debugValues)
import Network.Riak.Types.Internal hiding (MessageTag(..))

-- | Automated conflict resolution failed.
data ResolutionFailure = RetriesExceeded
    -- ^ Too many attempts were made to resolve a conflict, with each
    -- attempt resulting in another conflict.
    --
    -- The number of retries to attempt is high (64). This makes it
    -- extremely unlikely that this exception will be thrown during
    -- normal application operation.  Instead, this exception is most
    -- likely to arise as a result of a bug in your application code.
    --
    -- For example, this exception may be thrown if your 'Eq' instance
    -- is faulty, such that '==' gives false negatives.  This can
    -- easily occur if you are storing a structure containing 'Double'
    -- values where some are @NaN@ (the value used to represent the
    -- expression @0/0@), because two @NaN@ values are /not/
    -- considered equal in Haskell.
                         deriving (Eq, Show, Typeable)

instance Exception ResolutionFailure

-- | A type that can automatically resolve a vector clock conflict
-- between two or more versions of a value.
--
-- Instances must be symmetric in their behaviour, such that the
-- following law is obeyed:
--
-- > resolve a b == resolve b a
--
-- Otherwise, there are no restrictions on the behaviour of 'resolve'.
-- The result may be @a@, @b@, a value derived from @a@ and @b@, or
-- something else.
--
-- If several conflicting siblings are found, 'resolve' will be
-- applied over all of them using a fold, to yield a single
-- \"winner\".
class (Eq a, Show a) => Resolvable a where
    -- | Resolve a conflict between two values.
    resolve :: a -> a -> a

-- | A newtype wrapper that uses the 'mappend' method of a type's
-- 'Monoid' instance to perform vector clock conflict resolution.
newtype ResolvableMonoid a = RM { unRM :: a }
    deriving (Eq, Ord, Read, Show, Typeable, Data, Monoid, FromJSON, ToJSON)

instance (Eq a, Show a, Monoid a) => Resolvable (ResolvableMonoid a) where
    resolve = mappend
    {-# INLINE resolve #-}

instance (Resolvable a) => Resolvable (Maybe a) where
    resolve (Just a)   (Just b) = Just (resolve a b)
    resolve a@(Just _) _        = a
    resolve _          b        = b
    {-# INLINE resolve #-}

get :: (Resolvable a) =>
       (Connection -> Bucket -> Key -> R -> IO (Maybe ([a], VClock)))
       -> (Connection -> Bucket -> Key -> R -> IO (Maybe (a, VClock)))
get doGet conn bucket key r =
    fmap (first resolveMany) `fmap` doGet conn bucket key r
{-# INLINE get #-}

getMany :: (Resolvable a) =>
           (Connection -> Bucket -> [Key] -> R -> IO [Maybe ([a], VClock)])
        -> Connection -> Bucket -> [Key] -> R -> IO [Maybe (a, VClock)]
getMany doGet conn b ks r =
    map (fmap (first resolveMany)) `fmap` doGet conn b ks r
{-# INLINE getMany #-}

put :: (Resolvable a) =>
       (Connection -> Bucket -> Key -> Maybe VClock -> a -> W -> DW
                   -> IO ([a], VClock))
    -> Connection -> Bucket -> Key -> Maybe VClock -> a -> W -> DW
    -> IO (a, VClock)
put doPut conn bucket key mvclock0 val0 w dw = do
  let go !i val mvclock1
         | i == maxRetries = throwIO RetriesExceeded
         | otherwise       = do
        (xs, vclock) <- doPut conn bucket key mvclock1 val w dw
        case xs of
          []             -> return (val, vclock) -- not observed in the wild
          [v] | v == val -> return (val, vclock)
          ys             -> do debugValues "put" "conflict" ys
                               go (i+1) (resolveMany' val ys) (Just vclock)
  go (0::Int) val0 mvclock0
{-# INLINE put #-}

-- | The maximum number of times to retry conflict resolution.
maxRetries :: Int
maxRetries = 64
{-# INLINE maxRetries #-}

put_ :: (Resolvable a) =>
        (Connection -> Bucket -> Key -> Maybe VClock -> a -> W -> DW
                    -> IO ([a], VClock))
     -> Connection -> Bucket -> Key -> Maybe VClock -> a -> W -> DW
     -> IO ()
put_ doPut conn bucket key mvclock0 val0 w dw =
    put doPut conn bucket key mvclock0 val0 w dw >> return ()
{-# INLINE put_ #-}

putMany :: (Resolvable a) =>
           (Connection -> Bucket -> [(Key, Maybe VClock, a)] -> W -> DW
                       -> IO [([a], VClock)])
        -> Connection -> Bucket -> [(Key, Maybe VClock, a)] -> W -> DW
        -> IO [(a, VClock)]
putMany doPut conn bucket puts0 w dw = go (0::Int) [] . zip [(0::Int)..] $ puts0
 where
  go _ acc [] = return . map snd . sortBy (compare `on` fst) $ acc
  go !i acc puts
      | i == maxRetries = throwIO RetriesExceeded
      | otherwise = do
    rs <- doPut conn bucket (map snd puts) w dw
    let (conflicts, ok) = partitionEithers $ zipWith mush puts rs
    unless (null conflicts) $
      debugValues "putMany" "conflicts" conflicts
    go (i+1) (ok++acc) conflicts
  mush (i,(k,_,c)) (cs,v) =
      case cs of
        []           -> Right (i,(c,v)) -- not observed in the wild
        [x] | x == c -> Right (i,(c,v))
        _            -> Left (i,(k,Just v, resolveMany' c cs))
{-# INLINE putMany #-}

putMany_ :: (Resolvable a) =>
            (Connection -> Bucket -> [(Key, Maybe VClock, a)] -> W -> DW
                        -> IO [([a], VClock)])
         -> Connection -> Bucket -> [(Key, Maybe VClock, a)] -> W -> DW -> IO ()
putMany_ doPut conn bucket puts0 w dw =
    putMany doPut conn bucket puts0 w dw >> return ()
{-# INLINE putMany_ #-}

resolveMany' :: (Resolvable a) => a -> [a] -> a
resolveMany' = foldl' resolve
{-# INLINE resolveMany' #-}

resolveMany :: (Resolvable a) => [a] -> a
resolveMany (a:as) = resolveMany' a as
resolveMany _      = error "resolveMany: empty list"
{-# INLINE resolveMany #-}
