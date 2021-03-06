module SystemTest where

import Test.Tasty.Hspec

import GHC.Debug.Client
import GHC.Debug.Types.Graph
import GHC.Debug.Types.Closures
import GHC.Vis
import Data.Text (unpack)
import System.IO
import Data.Dwarf.ADT

import Server

import Control.Monad

import Control.Concurrent.Async
import Control.Concurrent
import Control.Monad.Extra

import Data.Word
import Data.IORef
import GHC.Clock
import System.Timeout
import Data.List.Extra

spec :: SpecWith ()
spec = do
  describe "debuggeeDwarf" $
    it "should return Dwarf of the executeable" $
      withStartedDebuggee "debug-test" $ \ _ d ->
        case debuggeeDwarf d of
              Just dwarf -> dwarf `shouldContainCuName` "Test.hs"
              Nothing -> error "No Dwarf"

  describe "request" $ do
    describe "RequestVersion" $
      it "should return the correct version" $
        withStartedDebuggee "debug-test" $ \ _ d -> do
          version <- request d RequestVersion
          version `shouldBe` 0

    describe "RequestRoots" $
      it "should return a non-empty result" $
        withStartedDebuggee "debug-test" $ \ _ d -> do
          request d RequestPause
          roots <- request d RequestRoots
          roots `shouldSatisfy` notNull

    describe "RequestClosures" $
      it "should return a non-empty result" $
        withStartedDebuggee "debug-test" $ \ _ d -> do
          request d RequestPause
          roots <- request d RequestRoots
          closures <- request d $ RequestClosures roots
          closures `shouldSatisfy` notNull

    describe "RequestSavedObjects" $
      it "should return saved object" $
        withStartedDebuggee "save-one-pause" $ \ h d -> do
          waitForSync $ Server.stdout h
          withAsync (pipeStreamThread (Server.stdout h)) $ \_ -> do
            request d RequestPoll
            os@(o:_) <- request d RequestSavedObjects
            length os `shouldBe` 1
            hg <- buildHeapGraph (derefBox d) 20 () o
            ppHeapGraph hg `shouldBe` "I# 1"

    describe "RequestInfoTables" $
      it "should return decodable RawInfoTables" $
        withStartedDebuggee "save-one-pause" $ \ h d -> do
          waitForSync $ Server.stdout h
          request d RequestPoll
          sos <- request d RequestSavedObjects
          closures <- request d $ RequestClosures sos
          let itptrs = map getInfoTblPtr closures
          its <- request d $ RequestInfoTables itptrs
          let stgits = map decodeInfoTable its
          length stgits `shouldBe` 1

    describe "RequestConstrDesc" $
      it "should return ConstrDesc of saved value (I# 1)" $
        withStartedDebuggee "save-one-pause" $ \ h d -> do
          waitForSync $ Server.stdout h
          request d RequestPoll
          (s:_) <- request d RequestSavedObjects
          cd <- request d $ RequestConstrDesc s
          cd `shouldBe` ConstrDesc {pkg = "ghc-prim", modl = "GHC.Types", name = "I#"}

    describe "RequestFindPtr" $
      it "should return ClosurePtrs that can be dereferenced" $
        withStartedDebuggee "save-one-pause" $ \ h d -> do
          waitForSync $ Server.stdout h
          request d RequestPoll
          (s:_) <- request d RequestSavedObjects
          ptrs <- request d $ RequestFindPtr s
          closures <- dereferenceClosures d ptrs
          closures `shouldSatisfy` notNull

    describe "RequestResume" $
      it "should resume a paused debugee" $
        withStartedDebuggee "clock" $ \ h d -> do
          waitForSync $ Server.stdout h
          ref <- newIORef []
          withAsync (pipeStreamToListThread ref (Server.stdout h)) $ \_ -> do
            request d RequestPause
            (t:_) <- readIORef ref
            assertNoNewClockTimes ref t

            request d RequestResume

            assertNewClockTime ref
            where
              oneSecondInMicros = 1000000

              assertNoNewClockTimes :: IORef [ClockTime] -> ClockTime -> Expectation
              assertNoNewClockTimes ref t0 = do
                result <- timeout fiveSecondsInMicros $ whileM $ do
                  threadDelay oneSecondInMicros
                  (t1:_) <- readIORef ref
                  return $ t0 == t1

                result `shouldBe` Nothing

              assertNewClockTime :: IORef [ClockTime] -> Expectation
              assertNewClockTime ref = do
                now <- getMonotonicTimeNSec
                result <- timeout fiveSecondsInMicros $ whileM $ do
                  threadDelay 5000
                  (t:_) <- readIORef ref
                  return $ t < now

                result `shouldBe` Just ()

fiveSecondsInMicros :: Int
fiveSecondsInMicros = 5000000

waitForSync :: Handle -> IO ()
waitForSync h = do
  result <- timeout fiveSecondsInMicros $ do
    hSetBuffering h LineBuffering
    l <- hGetLine h
    if l == "\"sync\"" then
      return ()
    else
      waitForSync h

  case result of
    Nothing -> error "Can not sync!"
    _ -> return ()

pipeStreamThread :: Handle -> IO ()
pipeStreamThread h = forever $ do
        l <- hGetLine h
        print l

type ClockTime = Word64

pipeStreamToListThread :: IORef [ClockTime] -> Handle -> IO ()
pipeStreamToListThread ref h = forever $ do
  l <- hGetLine h
  timesList <- readIORef ref
  writeIORef ref $ toClockTime l : timesList
  where
    toClockTime :: String -> ClockTime
    toClockTime = read . trim

shouldContainCuName :: Dwarf -> String -> Expectation
shouldContainCuName dwarf name = allCuNames `shouldContain` [name]
  where
    allCuNames :: [String]
    allCuNames =  map (unpack . cuName . bData) boxedCompilationUnits

    boxedCompilationUnits :: [Boxed CompilationUnit]
    boxedCompilationUnits = dwarfCompilationUnits dwarf
