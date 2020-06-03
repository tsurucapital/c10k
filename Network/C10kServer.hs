{-|
  Network server library to handle over 10,000 connections. Since
  GHC 6.12 or earlier uses select(), it cannot handle connections over
  1,024. This library uses the \"prefork\" technique to get over the
  barrier. Each process handles 'threadNumberPerProcess' connections.
  'preforkProcessNumber' child server processes are preforked. So, this
  server can handle 'preforkProcessNumber' * 'threadNumberPerProcess'
  connections.

  GHC 7 supports kqueue or epoll() but it is difficult
  to balance over multi-core. So, this library can be used to
  make a process for each core and to set limitation of the number
  to accept connections.

  To stop all server, send SIGTERM to the parent process.
  (e.g. @kill `cat PIDFILE`@ where the PID file name is
  specified by 'pidFile')
-}
module Network.C10kServer (
    C10kConfig(..)
  , C10kServer,  runC10kServer
  , C10kServerH, runC10kServerH
  ) where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.IORef
import Network.BSD
import Network.Socket
import qualified Network.TCPInfo as T (accept)
import Network.TCPInfo hiding (accept)
import System.Exit
import System.IO
import System.Posix.Process
import System.Posix.Signals
import System.Posix.Types
import System.Posix.User

----------------------------------------------------------------

{-|
  The type of the first argument of 'runC10kServer'.
-}
type C10kServer = Socket -> IO ()

{-|
  The type of the first argument of 'runC10kServerH'.
-}
type C10kServerH = Handle -> TCPInfo -> IO ()

{-|
  The type of configuration given to 'runC10kServer' as the second
  argument.
-}
data C10kConfig = C10kConfig {
  -- | A hook called initialization time. This is used topically to
  --   initialize syslog.
    initHook :: IO ()
  -- | A hook called when the server exits due to an error.
  , exitHook :: String -> IO ()
  -- | A hook to be called in the parent process when all child
  --   process are preforked successfully.
  , parentStartedHook :: IO ()
  -- | A hook to be called when each child process is started
  --   successfully.
  , startedHook :: IO ()
  -- | The time in seconds that a main thread of each child process
  --   to sleep when the number of connection reaches
  --   'threadNumberPerProcess'.
  , sleepTimer :: Int
  -- | The number of child process.
  , preforkProcessNumber :: Int
  -- | The number of thread which a process handle.
  , threadNumberPerProcess :: Int
  -- | A port name. e.g. \"http\" or \"80\"
  , portName :: ServiceName
  -- | A numeric IP address. e.g. \"127.0.0.1\"
  , ipAddr :: Maybe HostName
  -- | A file where the process ID of the parent process is written.
  , pidFile :: FilePath
  -- | A user name. When the program linked with this library runs
  --   in the root privilege, set user to this value. Otherwise,
  --   this value is ignored.
  , user :: String
  -- | A group name. When the program linked with this library runs
  --   in the root privilege, set group to this value. Otherwise,
  --   this value is ignored.
  , group :: String
}

----------------------------------------------------------------

{-|
  Run 'C10kServer' with 'C10kConfig'.
-}
runC10kServer :: C10kServer -> C10kConfig -> IO ()
runC10kServer srv cnf = runC10kServer' (dispatchS srv) cnf `catch` errorHandle cnf

{-|
  Run 'C10kServerH' with 'C10kConfig'.
-}
runC10kServerH :: C10kServerH -> C10kConfig -> IO ()
runC10kServerH srv cnf = runC10kServer' (dispatchH srv) cnf `catch` errorHandle cnf

errorHandle :: C10kConfig -> SomeException -> IO ()
errorHandle cnf e = do
    exitHook cnf (show e)
    exitFailure

----------------------------------------------------------------

runC10kServer' :: (Socket -> Dispatch) -> C10kConfig -> IO ()
runC10kServer' sDispatch cnf = do
    initHook cnf `catch` ignore
    if onlyOne
       then stay sDispatch cnf
       else prefork sDispatch cnf
  where
    onlyOne = preforkProcessNumber cnf == 1

----------------------------------------------------------------

stay :: (Socket -> Dispatch) -> C10kConfig -> IO ()
stay sDispatch cnf = do
    parentStartedHook cnf `catch` ignore
    s <- listenTo addr port
    writePidFile cnf
    setGroupUser cnf
    runServer (sDispatch s) cnf
    close s
  where
    port = portName cnf
    addr = ipAddr cnf

----------------------------------------------------------------

prefork :: (Socket -> Dispatch) -> C10kConfig -> IO ()
prefork sDispatch cnf = do
    cids <- doPrefork sDispatch cnf
    parentStartedHook cnf `catch` ignore
    handleSignal cids
    pause
    terminateChildren cids
  where
    handleSignal cids = do
        ignoreSigChild
        mapM_ (terminator cids) [sigTERM,sigINT]
    pause = blockSignals reservedSignals >> awaitSignal Nothing >> yield
    initHandler func sig = installHandler sig func Nothing
    ignoreSigChild = initHandler Ignore sigCHLD
    terminator cids = initHandler (Catch (terminateChildren cids))
    terminateChildren cids = do
        ignoreSigChild
        mapM_ terminateChild cids
    terminateChild cid = signalProcess sigTERM cid `catch` ignore

----------------------------------------------------------------

doPrefork :: (Socket -> Dispatch) -> C10kConfig -> IO [ProcessID]
doPrefork sDispatch cnf = do
    s <- listenTo addr port
    writePidFile cnf
    setGroupUser cnf
    cids <- fork (sDispatch s)
    close s
    return cids
  where
    port = portName cnf
    addr = ipAddr cnf
    n = preforkProcessNumber cnf
    fork dispatch = replicateM n . forkProcess $ runServer dispatch cnf

----------------------------------------------------------------

setGroupUser :: C10kConfig -> IO ()
setGroupUser cnf = do
    uid <- getRealUserID
    when (uid == 0) $ do
        getGroupEntryForName (group cnf) >>= setGroupID . groupID
        getUserEntryForName (user cnf) >>= setUserID . userID

writePidFile :: C10kConfig -> IO ()
writePidFile cnf = do
    pid <- getProcessID
    writeFile (pidFile cnf) $ show pid ++ "\n"

----------------------------------------------------------------

runServer :: Dispatch -> C10kConfig -> IO ()
runServer dispatch cnf = do
    startedHook cnf
    ref <- newIORef 0 :: IO (IORef Int)
    dispatchOrSleep ref dispatch cnf

dispatchOrSleep :: IORef Int -> Dispatch -> C10kConfig -> IO ()
dispatchOrSleep ref dispatch cnf = do
    n <- howMany
    if n > threadNumberPerProcess cnf
        then sleep (sleepTimer cnf * microseconds)
        else dispatch increase decrease
    dispatchOrSleep ref dispatch cnf
  where
    howMany = readIORef ref
    increase = atomicModifyIORef ref (\n -> (n+1,()))
    decrease = atomicModifyIORef ref (\n -> (n-1,()))
    sleep = threadDelay

----------------------------------------------------------------

type Dispatch = IO () -> IO () -> IO ()

dispatchS :: C10kServer -> Socket -> Dispatch
dispatchS srv sock inc dec = do
    (connsock,_) <- accept sock
    inc
    forkIO $ srv connsock `finally` (dec >> close connsock)
    return ()

dispatchH :: C10kServerH -> Socket -> Dispatch
dispatchH srv sock inc dec = do
    (hdl,tcpi) <- T.accept sock
    inc
    forkIO $ srv hdl tcpi `finally` (dec >> hClose hdl)
    return ()

----------------------------------------------------------------

ignore :: SomeException -> IO ()
ignore _ = return ()

microseconds :: Int
microseconds = 1000000

----------------------------------------------------------------

listenTo :: Maybe HostName -> ServiceName -> IO Socket
listenTo maddr serv = do
    proto <- getProtocolNumber "tcp"
    let hints = defaultHints {
            addrFlags = [ AI_ADDRCONFIG, AI_NUMERICHOST
                        , AI_NUMERICSERV, AI_PASSIVE
                        ]
          , addrSocketType = Stream
          , addrProtocol = proto
          }
    addrs <- getAddrInfo (Just hints) maddr (Just serv)
    let addrs' = filter (\x -> addrFamily x == AF_INET6) addrs
        addr = if null addrs' then head addrs else head addrs'
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    setSocketOption sock ReuseAddr 1
    bind sock (addrAddress addr)
    listen sock maxListenQueue
    return sock
