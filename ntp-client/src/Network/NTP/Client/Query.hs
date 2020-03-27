-- TODO: provide a corrss platform  network bindings using `network` or
-- `Win32-network`, to get rid of CPP.
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.NTP.Client.Query (
    NtpSettings(..)
  , NtpStatus(..)
  , ntpQuery
  ) where

import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Exception (IOException, bracket, catch)
import           System.IO.Error (userError, ioError)
import           Control.Monad (foldM, forM_, replicateM_, when)
import           Control.Tracer
import           Data.Binary (decodeOrFail, encode)
import           Data.Bifunctor (bimap)
import qualified Data.ByteString.Lazy as LBS
import           Data.Either (partitionEithers)
import           Data.Functor (void)
import           Data.Maybe
import           Network.Socket (Socket, SockAddr (..), AddrInfo (..))
import qualified Network.Socket as Socket
#if !defined(mingw32_HOST_OS)
import qualified Network.Socket.ByteString as Socket.ByteString (recvFrom, sendManyTo)
#else
import qualified System.Win32.Async.Socket.ByteString as Win32.Async
#endif
import           System.IOManager
import           Network.NTP.Client.Packet ( mkNtpPacket
                                    , ntpPacketSize
                                    , Microsecond
                                    , NtpOffset (..)
                                    , getCurrentTime
                                    , clockOffsetPure
                                    , mkResultOrFailure
                                    , IPVersion (..)
                                    )
import           Network.NTP.Client.Trace (NtpTrace (..))

-- | Settings of the ntp client.
--
data NtpSettings = NtpSettings
    { ntpServers                 :: [String]
      -- ^ List of server addresses. At least three servers are needed.

    , ntpRequiredNumberOfResults :: Int
      -- ^ minimum number of results to compute the offset, this should be less
      -- or equal to the length of 'ntpServers' (each server is send a single
      -- @ntp@ query).

    , ntpResponseTimeout         :: Microsecond
      -- ^ Timeout between sending NTP requests and response collection.

    , ntpPollDelay               :: Microsecond
      -- ^ How long to wait between two rounds of requests.
    }


-- | The Ntp client state: either cached results is availbale, or the ntp
-- client is engaged in ntp-protocol or there was a failure: e.g. connection
-- lost, or dns lookups did not return at least `ntpRequiredNumberOfResults`
-- addresses. 
--
data NtpStatus =
      -- | The difference between NTP time and local system time
      NtpDrift !NtpOffset
      -- | NTP client has send requests to the servers
    | NtpSyncPending
      -- | NTP is not available: the client has not received any respond within
      -- `ntpResponseTimeout` from at least `ntpRequiredNumberOfResults`
      -- servers.
    | NtpSyncUnavailable deriving (Eq, Show)


-- | Wait for at least three replies and report the minimum of the reported
-- offsets.
--
minimumOfSome :: Int -> [NtpOffset] -> Maybe NtpOffset
minimumOfSome threshold l
    = if length l >= threshold
        then Just $ minimum l
        else Nothing


-- | Get a list local udp addresses.
--
udpLocalAddresses :: IO [AddrInfo]
udpLocalAddresses = Socket.getAddrInfo (Just hints) Nothing (Just $ show port)
  where
    hints = Socket.defaultHints
          { addrFlags = [Socket.AI_PASSIVE]
          , addrSocketType = Socket.Datagram
          }
    port = Socket.defaultPort

-- | Resolve dns names, return valid ntp 'SockAddr'es.
--
lookupNtpServers :: Tracer IO NtpTrace -> NtpSettings -> IO ([SockAddr], [SockAddr])
lookupNtpServers tracer NtpSettings { ntpServers, ntpRequiredNumberOfResults } = do
    addrs@(ipv4s, ipv6s) <- foldM fn ([], []) ntpServers
    when (length (ipv4s ++ ipv6s) < ntpRequiredNumberOfResults) $ do
      traceWith tracer $ NtpTraceLookupsFails
      ioError $ userError "lookup NTP servers failed"
    pure addrs
  where
    fn (as, bs) host = do
      addrs <- Socket.getAddrInfo (Just hints) (Just host) Nothing
      case bimap listToMaybe listToMaybe $ partitionAddrInfos addrs of
          (mipv4, mipv6) ->
            pure $
              ( (setNtpPort . Socket.addrAddress <$> maybeToList mipv4) ++ as
              , (setNtpPort . Socket.addrAddress <$> maybeToList mipv6) ++ bs
              )

    setNtpPort :: SockAddr ->  SockAddr
    setNtpPort addr = case addr of
        (SockAddrInet  _ host)            -> SockAddrInet  ntpPort host
        (SockAddrInet6 _ flow host scope) -> SockAddrInet6 ntpPort flow host scope
        sockAddr                          -> sockAddr
      where
        ntpPort :: Socket.PortNumber
        ntpPort = 123

    -- The library uses 'Socket.AI_ADDRCONFIG' as simple test if IPv4 or IPv6 are configured.
    -- According to the documentation, 'Socket.AI_ADDRCONFIG' is not available on all platforms,
    -- but it is expected to work on win32, Mac OS X and Linux.
    hints =
      Socket.defaultHints
            { addrSocketType = Socket.Datagram
            , addrFlags =
                if Socket.addrInfoFlagImplemented Socket.AI_ADDRCONFIG
                  then [Socket.AI_ADDRCONFIG]
                  else []
            }


-- | Partition 'AddrInfo` into ipv4 and ipv6 addresses.
--
partitionAddrInfos :: [AddrInfo] -> ([AddrInfo], [AddrInfo])
partitionAddrInfos = partitionEithers . mapMaybe fn
  where
    fn :: AddrInfo -> Maybe (Either AddrInfo AddrInfo)
    fn a | Socket.addrFamily a == Socket.AF_INET  = Just (Left a)
         | Socket.addrFamily a == Socket.AF_INET6 = Just (Right a)
         | otherwise                              = Nothing

-- | Perform a series of NTP queries: one for each dns name.  Resolve each dns
-- name, get local addresses: both IPv4 and IPv6 and engage in ntp protocol
-- towards one ip address per address family per dns name, but only for address
-- families for which we have a local address.  This is to avoid trying to send
-- IPv4/6 requests if IPv4/6 gateway is not configured.
--
-- It may throw an `IOException`:
--
-- * if neither IPv4 nor IPv6 address is configured
-- * if network I/O errors 
--
ntpQuery
    :: IOManager
    -> Tracer IO NtpTrace
    -> NtpSettings
    -> IO NtpStatus
ntpQuery ioManager tracer ntpSettings@NtpSettings { ntpRequiredNumberOfResults } = do
    traceWith tracer NtpTraceClientStartQuery
    (v4Servers,   v6Servers) <- lookupNtpServers tracer ntpSettings
    localAddrs <- udpLocalAddresses
    (v4LocalAddr, v6LocalAddr)
      <- case partitionAddrInfos localAddrs of
          ([], []) -> do
            traceWith tracer NtpTraceNoLocalAddr
            ioError $ userError "no local address IPv4 and IPv6"
          (ipv4s, ipv6s) -> pure $
            -- head :: [a] -> Maybe a
            ( listToMaybe ipv4s
            , listToMaybe ipv6s
            )
    withAsync (runProtocol IPv4 v4LocalAddr v4Servers) $ \ipv4Async ->
      withAsync (runProtocol IPv6 v6LocalAddr v6Servers) $ \ipv6Async -> do
        results <- mkResultOrFailure
                    <$> waitCatch ipv4Async
                    <*> waitCatch ipv6Async
        traceWith tracer (NtpTraceRunProtocolResults results)
        handleResults (foldMap id results)
  where
    runProtocol :: IPVersion -> Maybe AddrInfo -> [SockAddr] -> IO [NtpOffset]
    -- no addresses to sent to
    runProtocol _protocol _localAddr  []      = return []
    -- local address is not configured, e.g. no IPv6 or IPv6 gateway.
    runProtocol _protocol Nothing     _       = return []
    -- local address is configured, remote address list is non empty
    runProtocol protocol  (Just addr) servers = do
       runNtpQueries ioManager tracer protocol ntpSettings addr servers

    handleResults :: [NtpOffset] -> IO NtpStatus
    handleResults results = case minimumOfSome ntpRequiredNumberOfResults results of
      Nothing -> do
          traceWith tracer NtpTraceReportPolicyQueryFailed
          return NtpSyncUnavailable
      Just offset -> do
          traceWith tracer $ NtpTraceQueryResult $ getNtpOffset offset
          return $ NtpDrift offset


-- | Run an ntp query towards each address
--
runNtpQueries
    :: IOManager
    -> Tracer IO NtpTrace
    -> IPVersion   -- ^ address family, it must afree with local and remote
                   -- addresses
    -> NtpSettings
    -> AddrInfo    -- ^ local address
    -> [SockAddr]  -- ^ remote addresses, they are assumed to have the same
                   -- family as the local address
    -> IO [NtpOffset]
runNtpQueries ioManager tracer protocol netSettings localAddr destAddrs
    = bracket acquire release action
  where
    acquire :: IO Socket
    acquire = Socket.socket (addrFamily localAddr) Socket.Datagram Socket.defaultProtocol

    release :: Socket -> IO ()
    release s = do
        Socket.close s
        traceWith tracer $ NtpTraceSocketClosed protocol

    action :: Socket -> IO [NtpOffset]
    action socket = do
        associateWithIOManager ioManager (Right socket)
        traceWith tracer $ NtpTraceSocketOpen protocol
        Socket.setSocketOption socket Socket.ReuseAddr 1
        Socket.bind socket (Socket.addrAddress localAddr)
        inQueue <- atomically $ newTVar []
        withAsync timeout $ \timeoutAsync ->
          withAsync (receiver socket inQueue) $ \receiverAsync -> do
            forM_ destAddrs $ \addr ->
              sendNtpPacket socket addr
              `catch`
              -- catch 'IOException's so we don't bring the loop down;
              \(e :: IOException) -> traceWith tracer (NtpTracePacketSendError addr e)
            void $ waitAny [timeoutAsync, receiverAsync]
        atomically $ readTVar inQueue

    --
    -- send a single ntp request towards one of the destination addresses
    --
    sendNtpPacket :: Socket -> SockAddr -> IO ()
    sendNtpPacket sock addr = do
        p <- mkNtpPacket
#if !defined(mingw32_HOST_OS)
        _ <- Socket.ByteString.sendManyTo sock (LBS.toChunks $ encode p) addr
#else
        -- TODO: add `sendManyTo` to `Win32-network`
        _ <- Win32.Async.sendAllTo sock (LBS.toStrict $ encode p) addr
#endif
        -- delay 100ms between sending requests, this avoids dealing with ntp
        -- results at the same time from various ntp servers, and thus we
        -- should get better results.
        threadDelay 100_000

    --
    -- timeout thread
    --
    timeout = do
        threadDelay
          $ (fromIntegral $ ntpResponseTimeout netSettings)
            + 100_000 * length destAddrs
        traceWith tracer $ NtpTraceWaitingForRepliesTimeout protocol

    --
    -- receiving thread
    --
    receiver :: Socket -> TVar [NtpOffset] -> IO ()
    receiver socket inQueue = replicateM_ (length destAddrs) $ do
        -- We don't catch exception here, we let them propagate.  This will
        -- reach top level handler in 'Network.NTP.Client.ntpClientThread' (see
        -- 'queryLoop' therein), which will be able to decide for how long to
        -- pause the the ntp-client.
#if !defined(mingw32_HOST_OS)
        (bs, _) <- Socket.ByteString.recvFrom socket ntpPacketSize
#else
        (bs, _) <- Win32.Async.recvFrom socket ntpPacketSize
#endif
        t <- getCurrentTime
        case decodeOrFail $ LBS.fromStrict bs of
            Left  (_, _, err) -> traceWith tracer $ NtpTracePacketDecodeError protocol err
            -- TODO : filter bad packets, i.e. late packets and spoofed packets
            Right (_, _, packet) -> do
                traceWith tracer $ NtpTracePacketReceived protocol
                let offset = (clockOffsetPure packet t)
                atomically $ modifyTVar' inQueue (offset :)
