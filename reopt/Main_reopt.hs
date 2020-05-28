{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
module Main (main) where

import           Control.Exception
import           Control.Lens
import           Control.Monad
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import           Data.ElfEdit
import           Data.IORef
import           Data.List ((\\), nub, stripPrefix, intercalate)
import           Data.Maybe
import           Data.Parameterized.Some
import           Data.Version
import           Data.Word
import           Numeric
import           Numeric.Natural
import           System.Console.CmdArgs.Explicit
import           System.Environment (getArgs)
import           System.Exit (exitFailure)
import           System.IO
import           System.IO.Error
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (</>), (<>))

import           Data.Macaw.DebugLogging
import           Data.Macaw.Discovery
import           Data.Macaw.X86

import           Reopt
import           Reopt.CFG.FnRep.X86 ()
import qualified Reopt.CFG.LLVM as LLVM
import qualified Reopt.CFG.LLVM.X86 as LLVM
import qualified Reopt.VCG.Annotations as Ann

import           Paths_reopt (version)

reoptVersion :: String
reoptVersion = "Reopt binary reoptimizer (reopt) "  ++ versionString ++ "."
  where [h,l,r] = versionBranch version
        versionString = show h ++ "." ++ show l ++ "." ++ show r


-- | Write a builder object to a file if defined or standard out if not.
writeOutput :: Maybe FilePath -> (Handle -> IO a) -> IO a
writeOutput Nothing f = f stdout
writeOutput (Just nm) f =
  bracket (openBinaryFile nm WriteMode) hClose f

------------------------------------------------------------------------
-- Utilities

unintercalate :: String -> String -> [String]
unintercalate punct str = reverse $ go [] "" str
  where
    go acc "" [] = acc
    go acc thisAcc [] = (reverse thisAcc) : acc
    go acc thisAcc str'@(x : xs)
      | Just sfx <- stripPrefix punct str' = go ((reverse thisAcc) : acc) "" sfx
      | otherwise = go acc (x : thisAcc) xs

------------------------------------------------------------------------
-- Action

-- | Action to perform when running
data Action
   = DumpDisassembly -- ^ Print out disassembler output only.
   | ShowCFG         -- ^ Print out control-flow microcode.
   | ShowFunctions   -- ^ Print out generated functions
   | ShowLLVM        -- ^ Print out LLVM in textual format
   | ShowObject      -- ^ Print out the object file.
   | ShowHelp        -- ^ Print out help message
   | ShowVersion     -- ^ Print out version
   | Reopt           -- ^ Perform a full reoptimization
  deriving (Show)

------------------------------------------------------------------------
-- Args

-- | Command line arguments.
data Args
   = Args { _reoptAction  :: !Action
          , programPath  :: !FilePath
            -- ^ Path to input program to optimize/export
          , _debugKeys    :: [DebugClass]
            -- Debug information ^ TODO: See if we can omit this.
          , outputPath   :: !(Maybe FilePath)
            -- ^ Path to output
          , headerPath :: !(Maybe FilePath)
            -- ^ Filepath for C header file that helps provide
            -- information about program.
          , clangPath :: !FilePath
            -- ^ Path to `clang` command.
            --
            -- This is only used as a C preprocessor for parsing
            -- header files.
          , llvmVersion  :: !LLVMConfig
            -- ^ LLVM version to generate LLVM for.
            --
            -- Only used when generating LLVM.
          , llcPath :: !FilePath
            -- ^ Path to LLVM `llc` command
            --
            -- Only used when generating assembly file.
          , optPath      :: !FilePath
            -- ^ Path to LLVM opt command.
            --
            -- Only used when generating LLVM to be optimized.
          , optLevel     :: !Int
            -- ^ Optimization level to pass to opt and llc
            --
            -- This defaults to 2
          , llvmMcPath      :: !FilePath
            -- ^ Path to llvm-mc
            --
            -- Only used when generating object file from assembly generated by llc.
          , _includeAddrs   :: ![String]
            -- ^ List of entry points for translation
          , _excludeAddrs :: ![String]
            -- ^ List of function entry points that we exclude for translation.
          , loadBaseAddress :: !(Maybe Word64)
            -- ^ Address to load binary at if relocatable.
          , _discOpts :: !DiscoveryOptions
            -- ^ Options affecting discovery
          , unnamedFunPrefix :: !BS.ByteString
            -- ^ Prefix for unnamed functions identified in code discovery.
          , llvmGenOptions :: !LLVM.LLVMGenOptions
            -- ^ Generation options for LLVM
          , annotationsPath :: !(Maybe FilePath)
            -- ^ Path to write reopt-vcg annotations to.
            --
            -- If `Nothing` then annotations are not generated.
          }

-- | Action to perform when running
reoptAction :: Lens' Args Action
reoptAction = lens _reoptAction (\s v -> s { _reoptAction = v })

-- | Which debug keys (if any) to output
debugKeys :: Lens' Args [DebugClass]
debugKeys = lens _debugKeys (\s v -> s { _debugKeys = v })

-- | Function entry points to translate (overrides notrans if non-empty)
includeAddrs :: Lens' Args [String]
includeAddrs = lens _includeAddrs (\s v -> s { _includeAddrs = v })

-- | Function entry points that we exclude for translation.
excludeAddrs :: Lens' Args [String]
excludeAddrs = lens _excludeAddrs (\s v -> s { _excludeAddrs = v })

-- | Options for controlling discovery
discOpts :: Lens' Args DiscoveryOptions
discOpts = lens _discOpts (\s v -> s { _discOpts = v })

defaultLLVMGenOptions :: LLVM.LLVMGenOptions
defaultLLVMGenOptions =
  LLVM.LLVMGenOptions { LLVM.mcExceptionIsUB = False }

-- | Initial arguments if nothing is specified.
defaultArgs :: Args
defaultArgs = Args { _reoptAction = Reopt
                   , programPath = ""
                   , _debugKeys = []
                   , outputPath = Nothing
                   , headerPath = Nothing
                   , llvmVersion = latestLLVMConfig
                   , clangPath = "clang"
                   , llcPath = "llc"
                   , optPath = "opt"
                   , optLevel  = 2
                   , llvmMcPath = "llvm-mc"
                   , _includeAddrs = []
                   , _excludeAddrs  = []
                   , loadBaseAddress = Nothing
                   , _discOpts     = defaultDiscoveryOptions
                   , unnamedFunPrefix = "reopt"
                   , llvmGenOptions = defaultLLVMGenOptions
                   , annotationsPath = Nothing
                   }

------------------------------------------------------------------------
-- Loading flags

resolveHex :: String -> Maybe Word64
resolveHex ('0':x:wval)
  | x `elem` ['x', 'X']
  , [(w,"")] <- readHex wval
  , fromInteger w <= toInteger (maxBound :: Word64)  =
    Just $! fromInteger w
resolveHex _ = Nothing

-- | Define a flag that tells reopt to load the binary at a particular
-- base address.
--
-- Primarily used for loading shared libraries at a fixed address.
loadBaseAddressFlag :: Flag Args
loadBaseAddressFlag = flagReq [ "load-at-addr" ] upd "OFFSET" help
  where help = "Load a relocatable file at the given base address."
        upd :: String -> Args -> Either String Args
        upd val args =
          case resolveHex val of
            Just off -> Right $
               args { loadBaseAddress = Just off }
            Nothing -> Left $
              "Expected a hexadecimal address of form '0x???', passsed "
              ++ show val

------------------------------------------------------------------------
-- Other Flags

disassembleFlag :: Flag Args
disassembleFlag = flagNone [ "disassemble", "d" ] upd help
  where upd  = reoptAction .~ DumpDisassembly
        help = "Show raw disassembler output."

cfgFlag :: Flag Args
cfgFlag = flagNone [ "c", "cfg" ] upd help
  where upd  = reoptAction .~ ShowCFG
        help = "Show recovered control-flow graphs."

funFlag :: Flag Args
funFlag = flagNone [ "fns", "functions" ] upd help
  where upd  = reoptAction .~ ShowFunctions
        help = "Show recovered functions."

llvmFlag :: Flag Args
llvmFlag = flagNone [ "llvm" ] upd help
  where upd  = reoptAction .~ ShowLLVM
        help = "Show generated LLVM."

objFlag :: Flag Args
objFlag = flagNone [ "object" ] upd help
  where upd  = reoptAction .~ ShowObject
        help = "Write recompiled object code to output file."

outputFlag :: Flag Args
outputFlag = flagReq [ "o", "output" ] upd "PATH" help
  where upd s old = Right $ old { outputPath = Just s }
        help = "Path to write new binary."

headerFlag :: Flag Args
headerFlag = flagReq [ "header" ] upd "PATH" help
  where upd s old = Right $ old { headerPath = Just s }
        help = "Optional header with function declarations."

llvmVersionFlag :: Flag Args
llvmVersionFlag = flagReq [ "llvm-version" ] upd "VERSION" help
  where upd :: String -> Args -> Either String Args
        upd s old = do
          v <- case versionOfString s of
                 Just v -> Right v
                 Nothing -> Left $ "Could not interpret LLVM version."
          cfg <- case getLLVMConfig v of
                   Just c -> pure c
                   Nothing -> Left $ "Unsupported LLVM version " ++ show s ++ "."
          pure $ old { llvmVersion = cfg }

        help = "LLVM version (e.g. 3.5.2)"

-- | Path to write LLVM annotations to.
annotationsFlag :: Flag Args
annotationsFlag = flagReq [ "annotations" ] upd "PATH" help
  where upd s old = Right $ old { annotationsPath = Just s }
        help = "Name of file for writing reopt-vcg annotations."

parseDebugFlags ::  [DebugClass] -> String -> Either String [DebugClass]
parseDebugFlags oldKeys cl =
  case cl of
    '-' : cl' -> do ks <- getKeys cl'
                    return (oldKeys \\ ks)
    cl'       -> do ks <- getKeys cl'
                    return (nub $ oldKeys ++ ks)
  where
    getKeys "all" = Right allDebugKeys
    getKeys str = case parseDebugKey str of
                    Nothing -> Left $ "Unknown debug key `" ++ str ++ "'"
                    Just k  -> Right [k]

debugFlag :: Flag Args
debugFlag = flagOpt "all" [ "debug", "D" ] upd "FLAGS" help
  where upd s old = do let ks = unintercalate "," s
                       new <- foldM parseDebugFlags (old ^. debugKeys) ks
                       Right $ (debugKeys .~ new) old
        help = "Debug keys to enable.  This flag may be used multiple times, "
            ++ "with comma-separated keys.  Keys may be preceded by a '-' which "
            ++ "means disable that key.\n"
            ++ "Supported keys: all, " ++ intercalate ", " (map debugKeyName allDebugKeys)

-- | Flag to set clang path.
clangPathFlag :: Flag Args
clangPathFlag = flagReq [ "clang" ] upd "PATH" help
  where upd s old = Right $ old { clangPath = s }
        help = "Path to LLVM \"clang\" compiler."

-- | Flag to set llc path.
llcPathFlag :: Flag Args
llcPathFlag = flagReq [ "llc" ] upd "PATH" help
  where upd s old = Right $ old { llcPath = s }
        help = "Path to LLVM \"llc\" command for compiling LLVM to native assembly."

-- | Flag to set path to opt.
optPathFlag :: Flag Args
optPathFlag = flagReq [ "opt" ] upd "PATH" help
  where upd s old = Right $ old { optPath = s }
        help = "Path to LLVM \"opt\" command for optimization."

-- | Flag to set path to llvm-mc
llvmMcPathFlag :: Flag Args
llvmMcPathFlag = flagReq [ "llvm-mc" ] upd "PATH" help
  where upd s old = Right $ old { llvmMcPath = s }
        help = "Path to llvm-mc"

-- | Flag to set llc optimization level.
optLevelFlag :: Flag Args
optLevelFlag = flagReq [ "O", "opt-level" ] upd "PATH" help
  where upd s old =
          case reads s of
            [(lvl, "")] | 0 <= lvl && lvl <= 3 -> Right $ old { optLevel = lvl }
            _ -> Left "Expected optimization level to be a number between 0 and 3."
        help = "Optimization level."

-- | Used to add a new function to ignore translation of.
includeAddrFlag :: Flag Args
includeAddrFlag = flagReq [ "include" ] upd "ADDR" help
  where upd s old = Right $ old & includeAddrs %~ (words s ++)
        help = "Address of function to include in analysis (may be repeated)."

-- | Used to add a new function to ignore translation of.
excludeAddrFlag :: Flag Args
excludeAddrFlag = flagReq [ "exclude" ] upd "ADDR" help
  where upd s old = Right $ old & excludeAddrs %~ (s:)
        help = "Address of function to exclude in analysis (may be repeated)."

-- | Print out a trace message when we analyze a function
logAtAnalyzeFunctionFlag :: Flag Args
logAtAnalyzeFunctionFlag = flagBool [ "trace-function-discovery" ] upd help
  where upd b = discOpts %~ \o -> o { logAtAnalyzeFunction = b }
        help = "Report when starting analysis of each function."

-- | Print out a trace message when we analyze a function
logAtAnalyzeBlockFlag :: Flag Args
logAtAnalyzeBlockFlag = flagBool [ "trace-block-discovery" ] upd help
  where upd b = discOpts %~ \o -> o { logAtAnalyzeBlock = b }
        help = "Report when starting analysis of each basic block with a function."

exploreFunctionSymbolsFlag :: Flag Args
exploreFunctionSymbolsFlag = flagBool [ "include-syms" ] upd help
  where upd b = discOpts %~ \o -> o { exploreFunctionSymbols = b }
        help = "Include function symbols in discovery."

exploreCodeAddrInMemFlag :: Flag Args
exploreCodeAddrInMemFlag = flagBool [ "include-mem" ] upd help
  where upd b = discOpts %~ \o -> o { exploreCodeAddrInMem = b }
        help = "Include memory code addresses in discovery."

-- | This flag if set allows the LLVM generator to treat
-- trigger a undefined-behavior in cases like instructions
-- throwing exceptions or errors.
allowLLVMUB :: Flag Args
allowLLVMUB = flagBool [ "allow-undef-llvm" ] upd help
  where upd b s = s { llvmGenOptions =
                        LLVM.LLVMGenOptions { LLVM.mcExceptionIsUB = b } }
        help = "Generate LLVM instead of inline assembly even when LLVM may result in undefined behavior."

arguments :: Mode Args
arguments = mode "reopt" defaultArgs help filenameArg flags
  where help = reoptVersion ++ "\n" ++ copyrightNotice
        flags = [ -- General purpose options
                  flagHelpSimple (reoptAction .~ ShowHelp)
                , flagVersion (reoptAction .~ ShowVersion)
                , debugFlag
                  -- Redirect output to file.
                , outputFlag
                  -- Explicit Modes
                , disassembleFlag
                , cfgFlag
                , funFlag
                , llvmFlag
                , objFlag
                  -- Discovery options
                , logAtAnalyzeFunctionFlag
                , logAtAnalyzeBlockFlag
                , exploreFunctionSymbolsFlag
                , exploreCodeAddrInMemFlag
                , includeAddrFlag
                , excludeAddrFlag
                  -- Function options
                , headerFlag
                  -- Loading options
                , loadBaseAddressFlag
                  -- LLVM options
                , llvmVersionFlag
                , annotationsFlag
                , allowLLVMUB
                  -- Compilation options
                , clangPathFlag
                , llcPathFlag
                , optLevelFlag
                , optPathFlag
                , llvmMcPathFlag
                ]

-- | Flag to set the path to the binary to analyze.
filenameArg :: Arg Args
filenameArg = Arg { argValue = setFilename
                  , argType = "FILE"
                  , argRequire = False
                  }
  where setFilename :: String -> Args -> Either String Args
        setFilename nm a = Right (a { programPath = nm })

getCommandLineArgs :: IO Args
getCommandLineArgs = do
  argStrings <- getArgs
  case process arguments argStrings of
    Left msg -> do
      hPutStrLn stderr msg
      exitFailure
    Right v -> return v

-- | Print out the disassembly of all executable sections.
--
-- Note.  This does not apply relocations.
dumpDisassembly :: Args -> IO ()
dumpDisassembly args = do
  bs <- checkedReadFile (programPath args)
  e <- parseElf64 (programPath args) bs
  let sections = filter isCodeSection $ e^..elfSections
  when (null sections) $ do
    hPutStrLn stderr "Binary contains no executable sections."
    exitFailure
  writeOutput (outputPath args) $ \h -> do
    forM_ sections $ \s -> do
      printX86SectionDisassembly h (elfSectionName s) (elfSectionAddr s) (elfSectionData s)

loadOptions :: Args -> LoadOptions
loadOptions args = LoadOptions { loadOffset = loadBaseAddress args }

-- | Discovery symbols in program and show function CFGs.
showCFG :: Args -> IO String
showCFG args = do
  Some discState <-
    discoverBinary (programPath args) (loadOptions args) (args^.discOpts) (args^.includeAddrs) (args^.excludeAddrs)
  pure $ show $ ppDiscoveryStateBlocks discState

-- | This parses function argument information from a user-provided header file.
resolveHeader :: Args -> IO Header
resolveHeader args =
  case headerPath args of
    Nothing -> pure emptyHeader
    Just p -> parseHeader (clangPath args) p

-- | Function for recovering log information.
--
-- This has a side effect where it increments an IORef so
-- that the number of errors can be recorded.
recoverLogError :: IORef Natural -- ^ Counter
                -> GetFnsLogEvent  -- ^ Message to log
                -> IO ()
recoverLogError ref msg = do
  modifyIORef' ref (+1)
  hPutStrLn stderr (show msg)

-- | Parse arguments to get information needed for function representation.
getFunctions :: Args -> IO (X86OS, RecoveredModule X86_64, Natural)
getFunctions args = do
  hdrAnn <- resolveHeader args
  let funPrefix :: BSC.ByteString
      funPrefix = unnamedFunPrefix args
  errorRef <- newIORef 0
  (_, os, _, _, recMod) <-
    discoverX86Elf (recoverLogError errorRef)
                   (programPath args)
                   (loadOptions args)
                   (args^.discOpts)
                   (args^.includeAddrs)
                   (args^.excludeAddrs)
                   hdrAnn
                   funPrefix
  errorCnt <- readIORef errorRef
  pure (os, recMod, errorCnt)

------------------------------------------------------------------------
--

-- | Rendered a recovered X86_64 module as LLVM bitcode
renderLLVMBitcode :: Args -- ^ Arguments passed
                  -> X86OS -- ^ Operating system
                  -> RecoveredModule X86_64 -- ^ Recovered module
                  -> (Builder.Builder, [Ann.FunctionAnn])
renderLLVMBitcode args os recMod =
  let archOps = LLVM.x86LLVMArchOps (show os)
   in llvmAssembly archOps (llvmGenOptions args) recMod (llvmVersion args)

-- | This command is called when reopt is called with no specific
-- action.
performReopt :: Args -> IO ()
performReopt args = do
  hdrAnn <- resolveHeader args
  let funPrefix :: BSC.ByteString
      funPrefix = unnamedFunPrefix args
  errorRef <- newIORef 0
  (origElf, os, discState, addrSymMap, recMod) <-
    discoverX86Elf (recoverLogError errorRef)
                   (programPath args)
                   (loadOptions args)
                   (args^.discOpts)
                   (args^.includeAddrs)
                   (args^.excludeAddrs)
                   hdrAnn
                   funPrefix
  errorCnt <- readIORef errorRef
  when (errorCnt > 0) $ do
    hPutStrLn stderr $ show errorCnt ++ " error(s) occured ."
    exitFailure
  let (objLLVM,_) = renderLLVMBitcode args os recMod
  objContents <-
    compileLLVM (optLevel args) (optPath args) (llcPath args) (llvmMcPath args)
                (osLinkName os) objLLVM

  new_obj <- parseElf64 "new object" objContents
  -- Convert binary to LLVM
  let tgts = discoveryControlFlowTargets discState
      redirs = addrRedirection tgts addrSymMap funPrefix <$> recoveredDefs recMod
  -- Merge and write out
  putStrLn $ "Performing final relinking."
  let outPath = fromMaybe "a.out" (outputPath args)
  mergeAndWrite outPath origElf new_obj redirs

main' :: IO ()
main' = do
  args <- getCommandLineArgs
  setDebugKeys (args ^. debugKeys)
  case args^.reoptAction of
    DumpDisassembly -> do
      dumpDisassembly args
    ShowCFG ->
      writeOutput (outputPath args) $ \h -> do
        hPutStrLn h =<< showCFG args

    -- Write function discovered
    ShowFunctions -> do
      (_,recMod, errorCnt) <- getFunctions args
      writeOutput (outputPath args) $ \h -> do
        mapM_ (hPutStrLn h . show . pretty) (recoveredDefs recMod)
      when (errorCnt > 0) $ do
        hPutStrLn stderr $
          if errorCnt == 1 then
            "1 error occured."
           else
            show errorCnt ++ " errors occured."
        exitFailure

    ShowLLVM -> do
      when (isJust (annotationsPath args) && isNothing (outputPath args)) $ do
        hPutStrLn stderr "Must specify --output for LLVM when generating annotations."
        exitFailure
      (os, recMod, errorCnt) <- getFunctions args
      let (llvmMod, funAnn) = renderLLVMBitcode args os recMod
      case annotationsPath args of
        Nothing -> pure ()
        Just annPath -> do
          let Just llvmPath = outputPath args
          let vcgAnn :: Ann.ModuleAnnotations
              vcgAnn = Ann.ModuleAnnotations
                { Ann.llvmFilePath = llvmPath
                , Ann.binFilePath = programPath args
                , Ann.pageSize = 4096
                , Ann.stackGuardPageCount = 1
                , Ann.functions = funAnn
                }
          BSL.writeFile annPath (Aeson.encode vcgAnn)
      writeOutput (outputPath args) $ \h -> do
        Builder.hPutBuilder h llvmMod
      when (errorCnt > 0) $ do
        hPutStrLn stderr $
          if errorCnt == 1 then
            "1 error occured."
           else
            show errorCnt ++ " errors occured."
        exitFailure
    ShowObject -> do
      outPath <-
        case outputPath args of
          Nothing -> do
            hPutStrLn stderr "Please specify output path for object."
            exitFailure
          Just p ->
            pure p
      (os, recMod, errorCnt) <- getFunctions args
      let (llvmMod, _) = renderLLVMBitcode args os recMod
      objContents <-
        compileLLVM (optLevel args)
                    (optPath args)
                    (llcPath args)
                    (llvmMcPath args)
                    (osLinkName os)
                    llvmMod
      BS.writeFile outPath objContents
      when (errorCnt > 0) $ do
        hPutStrLn stderr $
          if errorCnt == 1 then
            "1 error occured."
           else
            show errorCnt ++ " errors occured."
        exitFailure
    ShowHelp -> do
      print $ helpText [] HelpFormatAll arguments
    ShowVersion ->
      putStrLn (modeHelp arguments)
    Reopt -> do
      performReopt args

main :: IO ()
main = main' `catch` h
  where h e
          | isUserError e = do
            hPutStrLn stderr "User error"
            hPutStrLn stderr $ ioeGetErrorString e
          | otherwise = do
            hPutStrLn stderr "Other error"
            hPutStrLn stderr $ show e
            hPutStrLn stderr $ show (ioeGetErrorType e)
