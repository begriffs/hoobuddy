{-# LANGUAGE DeriveGeneric #-}

import GHC.Generics
import System.Environment (getArgs)
import System.Exit
import Data.Aeson
import Data.Yaml
import Data.List
import Distribution.Package
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse
import System.Directory (doesFileExist, findExecutable, getCurrentDirectory, getDirectoryContents)
import System.FilePath.Posix
import Hoogle (defaultDatabaseLocation, mergeDatabase)
import Control.Applicative
import System.Process
import Control.Monad (filterM, liftM, unless)
import System.IO (hGetContents)
import Data.Maybe (isJust)


-- TODOs:
-- hoo-1 : use recent hoogle hackage dependency
-- hoo-2 : add comments & clean up (split up main & Hoobudy)
-- hoo-3 : actually use config file
-- hoo-4 : use reader monad for config ?
data Hoobuddy = Hoobuddy {
                           databases :: String
                         , useBase   :: Bool
                         , custom    :: [String]
                         } deriving (Generic, Show)


instance ToJSON Hoobuddy
instance FromJSON Hoobuddy

type StdOut = String
type StdErr = String

confPath :: String
confPath = "~/hoobuddy.conf"

hoogleMissingError :: String
hoogleMissingError =
    unlines [ "Error: hoogle is not installed or not in path"
            , "Please install hoogle and run `hoogle data`"]

basePackages :: [String]
basePackages = words "Cabal.hoo array.hoo base.hoo binary.hoo bytestring.hoo containers.hoo deepseq.hoo directory.hoo filepath.hoo haskell2010.hoo haskell98.hoo hoopl.hoo hpc.hoo old-locale.hoo old-time.hoo pretty.hoo process.hoo template-haskell.hoo time.hoo unix.hoo"

platformPackages :: [String]
platformPackages = words "GLURaw.hoo GLUT.hoo HTTP.hoo HUnit.hoo OpenGL.hoo OpenGLRaw.hoo QuickCheck.hoo async.hoo attoparsec.hoo case-insensitive.hoo cgi.hoo fgl.hoo hashable.hoo haskell-src.hoo html.hoo mtl.hoo network.hoo parallel.hoo parsec.hoo primitive.hoo random.hoo regex-base.hoo regex-compat.hoo regex-posix.hoo split.hoo stm.hoo syb.hoo text.hoo transformers.hoo unordered-containers.hoo vector.hoo xhtml.hoo zlib.hoo"

help :: IO ()
help = putStrLn $
    unlines [ "Usage : hoobuddy [deps|build]"
            , "                 [--help]"
            , ""
            , "deps         list configured dependencies"
            , "build        do stuff yet to be defined"
            ]

main :: IO ()
main = do
    exitIfHoogleMissing
    conf <- loadConfig
    args <- getArgs
    run conf args where
        run _ ["deps", file]          = deps file
        run conf  ["build", file]     = build file conf
        run _ ["--help"]              = help
        run _ _ = do
            help
            exitWith (ExitFailure 1)

-- | Exits with error code if hoogle isn't installed
exitIfHoogleMissing :: IO ()
exitIfHoogleMissing = do
    hoogleInstalled <- liftM isJust (findExecutable "hoogle")
    unless hoogleInstalled (putStrLn hoogleMissingError >> exitWith (ExitFailure 1))


-- | Loads configuration from file or creates&returns defaults
loadConfig :: IO Hoobuddy
loadConfig = decodeConfig >>= maybe defaultConfig return where
    defaultConfig = do
        location <- defaultDatabaseLocation
        return $ Hoobuddy location True []

unique :: (Ord a) => [a] -> [a]
unique = map head . group . sort

-- | Encodes configuration to JSON
encodeConfig :: Hoobuddy -> IO ()
encodeConfig  = encodeFile confPath

-- | Decodes configuration from JSON
decodeConfig :: IO (Maybe Hoobuddy)
decodeConfig = do
    parseResult <- decodeFileEither confPath
    return $ either (const Nothing) Just parseResult

-- | Returns a list of available ".hoo" files
getHooDatabases :: FilePath -> IO [String]
getHooDatabases p = do
    files <- getDirectoryContents p
    return $ filter (\x -> ".hoo" `isSuffixOf`  x) files

-- | Calls hoogle to fetch all packages specified
hoogleFetch :: [String] -> IO (Either (ExitCode, StdErr) StdOut)
hoogleFetch [] = return (Right "No data to fetch")
hoogleFetch pkgs =  do
    (_, Just hOut, Just hErr, pHandle) <- createProcess (proc "hoogle" ("data":pkgNames)) {std_out = CreatePipe, std_err = CreatePipe}
    exitCode <- waitForProcess pHandle
    stdOut <- hGetContents hOut
    stdErr <- hGetContents hErr
    return (if exitCode == ExitSuccess then Right stdOut else Left (exitCode, stdErr))
        where
            pkgNames = dropExtension <$> pkgs

build :: FilePath -> Hoobuddy -> IO ()
build cabalFile _ = do
    pkgs <- map (++ ".hoo") <$> getDeps cabalFile
    dbPath <- (<$>) (</> "databases") defaultDatabaseLocation
    dbs <- getHooDatabases dbPath

    let allPkgs = pkgs ++ basePackages ++ platformPackages
    let available = allPkgs `intersect` dbs
    let missing = filter (`notElem` available) allPkgs

    printInfo "Fetching databases for: " missing
    hoogleFetch missing >>= \x -> case x of
        Right _             -> return ()
        Left (code, stderr) -> putStrLn ("hoogle exited with error:\n" ++ stderr) >> exitWith code

    -- TODO: Process files sequentially
    -- forM_ files $ \f -> doesFileExist f >>= bool (return ()) doSomething
    -- note : use when instead of bool

    putStrLn "Merging databases ..."
    currDir <- getCurrentDirectory
    existingDbs <- filterM doesFileExist (fmap (dbPath </>) allPkgs)
    mergeDatabase  existingDbs (currDir </> "default.hoo")

-- | Pretty printer for info output
printInfo :: String -> [String] -> IO ()
printInfo _ [] = return ()
printInfo str xs = putStrLn $ str ++ "[" ++ intercalate "," xs ++ "]"

-- | Prints dependencies from cabal file
deps :: FilePath -> IO ()
deps  path = do
        pkgs <- getDeps path
        putStrLn $ unlines pkgs

-- | Returns list of dependencies from cabal file
getDeps :: FilePath -> IO [String]
getDeps cabal = do
        contents <- readFile cabal
        let depInfo = parsePackageDescription contents
        case depInfo of
            ParseFailed _ -> exitWith (ExitFailure 1)
            ParseOk _ d     -> return (packageNames $ extractDeps d)
        where
            packageNames :: [Dependency] -> [String]
            packageNames  = map (init . tail . head . tail . words . show . pkg)
            pkg :: Dependency -> PackageName
            pkg (Dependency x _) = x

extractDeps :: GenericPackageDescription -> [Dependency]
extractDeps d = ldeps ++ edeps
  where ldeps = case condLibrary d of
                Nothing -> []
                Just c -> condTreeConstraints c
        edeps = concatMap (condTreeConstraints . snd) $ condExecutables d
