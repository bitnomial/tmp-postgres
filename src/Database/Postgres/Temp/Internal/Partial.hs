{-# OPTIONS_HADDOCK prune #-}
{-| This module provides types and functions for combining partial
    configs into a complete configs to ultimately make a 'CompletePlan'.

    This module has two classes of types.

    Types like 'ProcessConfig' that could be used by any
    library that  needs to combine process options.

    Finally it has types and functions for creating 'CompletePlan's that
    use temporary resources. This is used to create the default
    behavior of 'Database.Postgres.Temp.startConfig' and related
    functions.
|-}
module Database.Postgres.Temp.Internal.Partial where

import Database.Postgres.Temp.Internal.Core

import           Control.Applicative.Lift
import           Control.Exception
import           Control.Monad (join)
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Cont
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.Maybe
import           Data.Monoid
import           Data.Monoid.Generic
import           Data.Typeable
import qualified Database.PostgreSQL.Simple.Options as Client
import           GHC.Generics (Generic)
import           Network.Socket.Free (getFreePort)
import           System.Directory
import           System.Environment
import           System.IO
import           System.IO.Error
import           System.IO.Temp (createTempDirectory)
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

prettyMap :: (Pretty a, Pretty b) => Map a b -> Doc
prettyMap theMap =
  let xs = Map.toList theMap
  in vsep $ map (uncurry prettyKeyPair) xs

-- | The environment variables can be declared to
--   inherit from the running process or they
--   can be specifically added.
data EnvVars = EnvVars
  { partialEnvVarsInherit  :: Last Bool
  , partialEnvVarsSpecific :: Map String String
  }
  deriving stock (Generic, Show, Eq)

instance Semigroup EnvVars where
  x <> y = EnvVars
    { partialEnvVarsInherit  =
        partialEnvVarsInherit x <> partialEnvVarsInherit y
    , partialEnvVarsSpecific =
        partialEnvVarsSpecific y <> partialEnvVarsSpecific x
    }

instance Monoid EnvVars where
  mempty = EnvVars mempty mempty

instance Pretty EnvVars where
  pretty EnvVars {..}
    = text "partialEnvVarsInherit:"
        <+> pretty (getLast partialEnvVarsInherit)
    <> hardline
    <> text "partialEnvVarsSpecific:"
    <> softline
    <> indent 2 (prettyMap partialEnvVarsSpecific)

-- | Combine the current environment
--   (if indicated by 'partialEnvVarsInherit')
--   with 'partialEnvVarsSpecific'
completeEnvVars :: [(String, String)] -> EnvVars -> Either [String] [(String, String)]
completeEnvVars envs EnvVars {..} = case getLast partialEnvVarsInherit of
  Nothing -> Left ["Inherit not specified"]
  Just x -> Right $ (if x then envs else [])
    <> Map.toList partialEnvVarsSpecific

-- | A type to help combine command line arguments.
data CommandLineArgs = CommandLineArgs
  { partialCommandLineArgsKeyBased   :: Map String (Maybe String)
  -- ^ Arguments of the form @-h foo@, @--host=foo@ and @--switch@.
  --   The key is `mappend`ed with value so the key should include
  --   the space or equals (as shown in the first two examples
  --   respectively).
  --   The 'Dual' monoid is used so the last key wins.
  , partialCommandLineArgsIndexBased :: Map Int String
  -- ^ Arguments that appear at the end of the key based
  --   arguments.
  --   The 'Dual' monoid is used so the last key wins.
  }
  deriving stock (Generic, Show, Eq)
  deriving Monoid via GenericMonoid CommandLineArgs

instance Semigroup CommandLineArgs where
  x <> y = CommandLineArgs
    { partialCommandLineArgsKeyBased   =
        partialCommandLineArgsKeyBased y <> partialCommandLineArgsKeyBased x
    , partialCommandLineArgsIndexBased =
        partialCommandLineArgsIndexBased y <> partialCommandLineArgsIndexBased x
    }

instance Pretty CommandLineArgs where
  pretty p@CommandLineArgs {..}
    = text "partialCommandLineArgsKeyBased:"
    <> softline
    <> indent 2 (prettyMap partialCommandLineArgsKeyBased)
    <> hardline
    <> text "partialCommandLineArgsIndexBased:"
    <> softline
    <> indent 2 (prettyMap partialCommandLineArgsIndexBased)
    <> hardline
    <> text "completed:" <+> text (unwords (completeCommandLineArgs p))

-- Take values as long as the index is the successor of the
-- last index.
takeWhileInSequence :: [(Int, a)] -> [a]
takeWhileInSequence ((0, x):xs) = x : go 0 xs where
  go _ [] = []
  go prev ((next, a):rest)
    | prev + 1 == next = a : go next rest
    | otherwise = []
takeWhileInSequence _ = []

-- | This convert the 'CommandLineArgs' to '
completeCommandLineArgs :: CommandLineArgs -> [String]
completeCommandLineArgs CommandLineArgs {..}
  =  map (\(name, mvalue) -> maybe name (name <>) mvalue)
       (Map.toList partialCommandLineArgsKeyBased)
  <> takeWhileInSequence (Map.toList partialCommandLineArgsIndexBased)

-- | The monoidial version of 'ProcessConfig'. Used to combine overrides with
--   defaults when creating a 'ProcessConfig'.
data ProcessConfig = ProcessConfig
  { partialProcessConfigEnvVars :: EnvVars
  -- ^ A monoid for combine environment variables or replacing them.
  --   for the maps the 'Dual' monoid is used. So the last key wins.
  , partialProcessConfigCmdLine :: CommandLineArgs
  -- ^ A monoid for combine command line arguments or replacing them
  , partialProcessConfigStdIn   :: Last Handle
  -- ^ A monoid for configuring the standard input 'Handle'
  , partialProcessConfigStdOut  :: Last Handle
  -- ^ A monoid for configuring the standard output 'Handle'
  , partialProcessConfigStdErr  :: Last Handle
  -- ^ A monoid for configuring the standard error 'Handle'
  }
  deriving stock (Generic, Eq, Show)
  deriving Semigroup via GenericSemigroup ProcessConfig
  deriving Monoid    via GenericMonoid ProcessConfig

prettyHandle :: Handle -> Doc
prettyHandle _ = text "[HANDLE]"

instance Pretty ProcessConfig where
  pretty ProcessConfig {..}
    = text "partialProcessConfigEnvVars:"
    <> softline
    <> indent 2 (pretty partialProcessConfigEnvVars)
    <> hardline
    <> text "partialProcessConfigCmdLine:"
    <> softline
    <> indent 2 (pretty partialProcessConfigEnvVars)
    <> hardline
    <> text "partialProcessConfigStdIn:" <+>
        pretty (prettyHandle <$> getLast partialProcessConfigStdIn)
    <> hardline
    <> text "partialProcessConfigStdOut:" <+>
        pretty (prettyHandle <$> getLast partialProcessConfigStdOut)
    <> hardline
    <> text "partialProcessConfigStdErr:" <+>
        pretty (prettyHandle <$> getLast partialProcessConfigStdErr)


-- | The 'standardProcessConfig' sets the handles to 'stdin', 'stdout' and
--   'stderr' and inherits the environment variables from the calling
--   process.
standardProcessConfig :: ProcessConfig
standardProcessConfig = mempty
  { partialProcessConfigEnvVars = mempty
      { partialEnvVarsInherit = pure True
      }
  , partialProcessConfigStdIn  = pure stdin
  , partialProcessConfigStdOut = pure stdout
  , partialProcessConfigStdErr = pure stderr
  }

-- A helper to add more info to all the error messages.
addErrorContext :: String -> Either [String] a -> Either [String] a
addErrorContext cxt = either (Left . map (cxt <>)) Right

-- A helper for creating an error if a 'Last' is not defined.
getOption :: String -> Last a -> Errors [String] a
getOption optionName = \case
    Last (Just x) -> pure x
    Last Nothing  -> failure ["Missing " ++ optionName ++ " option"]

-- | Turn a 'ProcessConfig' into a 'ProcessConfig'. Fails if
--   any values are missing.
completeProcessConfig
  :: [(String, String)] -> ProcessConfig -> Either [String] CompleteProcessConfig
completeProcessConfig envs ProcessConfig {..} = runErrors $ do
  let completeProcessConfigCmdLine = completeCommandLineArgs partialProcessConfigCmdLine
  completeProcessConfigEnvVars <- eitherToErrors $
    completeEnvVars envs partialProcessConfigEnvVars
  completeProcessConfigStdIn  <-
    getOption "partialProcessConfigStdIn" partialProcessConfigStdIn
  completeProcessConfigStdOut <-
    getOption "partialProcessConfigStdOut" partialProcessConfigStdOut
  completeProcessConfigStdErr <-
    getOption "partialProcessConfigStdErr" partialProcessConfigStdErr

  pure CompleteProcessConfig {..}

-- | A type to track whether a file is temporary and needs to be cleaned up.
data CompleteDirectoryType = CPermanent FilePath | CTemporary FilePath
  deriving(Show, Eq, Ord)

-- | Get the file path of a 'CompleteDirectoryType', regardless if it is a
-- 'CPermanent' or 'CTemporary' type.
toFilePath :: CompleteDirectoryType -> FilePath
toFilePath = \case
  CPermanent x -> x
  CTemporary x -> x

instance Pretty CompleteDirectoryType where
  pretty = \case
    CPermanent x -> text "CPermanent" <+> pretty x
    CTemporary x -> text "CTemporary" <+> pretty x

makePermanent :: CompleteDirectoryType -> CompleteDirectoryType
makePermanent = \case
  CTemporary x -> CPermanent x
  x -> x

-- | The monoidial version of 'CompleteDirectoryType'. Used to combine overrides with
--   defaults when creating a 'CompleteDirectoryType'. The monoid instance treats
--   'PTemporary' as 'mempty' and takes the last 'PPermanent' value.
data DirectoryType
  = PPermanent FilePath
  -- ^ A permanent file that should not be generated.
  | PTemporary
  -- ^ A temporary file that needs to generated.
  deriving(Show, Eq, Ord)

instance Pretty DirectoryType where
  pretty = \case
    PPermanent x -> text "CPermanent" <+> pretty x
    PTemporary   -> text "CTemporary"

instance Semigroup DirectoryType where
  x <> y = case (x, y) of
    (a, PTemporary     ) -> a
    (_, a@PPermanent {}) -> a

instance Monoid DirectoryType where
  mempty = PTemporary

-- | Either create a'CTemporary' directory or do nothing to a 'CPermanent'
--   one.
setupDirectoryType :: String -> DirectoryType -> IO CompleteDirectoryType
setupDirectoryType p = \case
  PTemporary -> CTemporary <$> createTempDirectory "/tmp" p
  PPermanent x  -> pure $ CPermanent x

-- Either create a temporary directory or do nothing
rmDirIgnoreErrors :: FilePath -> IO ()
rmDirIgnoreErrors mainDir = do
  let ignoreDirIsMissing e
        | isDoesNotExistError e = return ()
        | otherwise = throwIO e
  removeDirectoryRecursive mainDir `catch` ignoreDirIsMissing

-- | Either remove a 'CTemporary' directory or do nothing to a 'CPermanent'
-- one.
cleanupDirectoryType :: CompleteDirectoryType -> IO ()
cleanupDirectoryType = \case
  CPermanent _ -> pure ()
  CTemporary filePath -> rmDirIgnoreErrors filePath

-- | A type for configuring the listening address of the @postgres@ process.
--   @postgres@ can listen on several types of sockets simulatanously but we
--   don't support that behavior. One can either listen on a IP based socket
--   or a UNIX domain socket.
data CompleteSocketClass
  = CIpSocket String
  -- ^ IP socket type. The 'String' is either an IP address or
  -- a host that will resolve to an IP address.
  | CUnixSocket CompleteDirectoryType
  -- ^ UNIX domain socket
  deriving (Show, Eq, Ord, Generic, Typeable)

instance Pretty CompleteSocketClass where
  pretty = \case
    CIpSocket x   -> text "CIpSocket:" <+> pretty x
    CUnixSocket x -> text "CUnixSocket:" <+> pretty x

-- | Create the extra config lines for listening based on the 'CompleteSocketClass'
socketClassToConfig :: CompleteSocketClass -> [String]
socketClassToConfig = \case
  CIpSocket ip    -> ["listen_addresses = '" <> ip <> "'"]
  CUnixSocket dir ->
    [ "listen_addresses = ''"
    , "unix_socket_directories = '" <> toFilePath dir <> "'"
    ]

-- | Many processes require a \"host\" flag. We can generate one from the
--   'CompleteSocketClass'.
socketClassToHostFlag :: CompleteSocketClass -> [(String, Maybe String)]
socketClassToHostFlag x = [("-h", Just (socketClassToHost x))]

-- | Get the IP address, host name or UNIX domain socket directory
--   as a 'String'
socketClassToHost :: CompleteSocketClass -> String
socketClassToHost = \case
  CIpSocket ip    -> ip
  CUnixSocket dir -> toFilePath dir

-- | The monoidial version of 'CompleteSocketClass'. Used to combine overrides with
--   defaults when creating a 'CompleteSocketClass'. The monoid instance treats
--   'PUnixSocket mempty' as 'mempty' and combines the
data SocketClass
  = PIpSocket (Last String)
  -- ^ The monoid for combining IP address configuration
  | PUnixSocket DirectoryType
  -- ^ The monoid for combining UNIX socket configuration
    deriving stock (Show, Eq, Ord, Generic, Typeable)

instance Pretty SocketClass where
  pretty = \case
    PIpSocket x -> "CIpSocket:" <+> pretty (getLast x)
    PUnixSocket x -> "CUnixSocket" <+> pretty x

instance Semigroup SocketClass where
  x <> y = case (x, y) of
    (PIpSocket   a, PIpSocket b) -> PIpSocket $ a <> b
    (a@(PIpSocket _), PUnixSocket _) -> a
    (PUnixSocket _, a@(PIpSocket _)) -> a
    (PUnixSocket a, PUnixSocket b) -> PUnixSocket $ a <> b

instance Monoid SocketClass where
 mempty = PUnixSocket mempty

-- | Turn a 'SocketClass' to a 'CompleteSocketClass'. If the 'PIpSocket' is
--   'Nothing' default to \"127.0.0.1\". If the is a 'PUnixSocket'
--    optionally create a temporary directory if configured to do so.
setupSocketClass :: SocketClass -> IO CompleteSocketClass
setupSocketClass theClass = case theClass of
  PIpSocket mIp -> pure $ CIpSocket $ fromMaybe "127.0.0.1" $
    getLast mIp
  PUnixSocket mFilePath ->
    CUnixSocket <$> setupDirectoryType "tmp-postgres-socket" mFilePath

-- | Cleanup the UNIX socket temporary directory if one was created.
cleanupSocketConfig :: CompleteSocketClass -> IO ()
cleanupSocketConfig = \case
  CIpSocket   {}  -> pure ()
  CUnixSocket dir -> cleanupDirectoryType dir

-- | @postgres@ process config and corresponding client connection
--   'Client.Options'.
data PostgresPlan = PostgresPlan
  { partialPostgresPlanProcessConfig :: ProcessConfig
  -- ^ Monoid for the @postgres@ ProcessConfig.
  , partialPostgresPlanClientConfig  :: Client.Options
  -- ^ Monoid for the @postgres@ client connection options.
  }
  deriving stock (Generic)
  deriving Semigroup via GenericSemigroup PostgresPlan
  deriving Monoid    via GenericMonoid PostgresPlan

instance Pretty PostgresPlan where
  pretty PostgresPlan {..}
    = text "partialPostgresPlanProcessConfig:"
    <> softline
    <> indent 2 (pretty partialPostgresPlanProcessConfig)
    <> hardline
    <> text "partialPostgresPlanClientConfig:"
    <> softline
    <> indent 2 (prettyOptions partialPostgresPlanClientConfig)

-- | Turn a 'PostgresPlan' into a 'CompletePostgresPlan'. Fails if any
--   values are missing.
completePostgresPlan :: [(String, String)] -> PostgresPlan -> Either [String] CompletePostgresPlan
completePostgresPlan envs PostgresPlan {..} = runErrors $ do
  let completePostgresPlanClientOptions = partialPostgresPlanClientConfig
  completePostgresPlanProcessConfig <-
    eitherToErrors $ addErrorContext "partialPostgresPlanProcessConfig: " $
      completeProcessConfig envs partialPostgresPlanProcessConfig

  pure CompletePostgresPlan {..}
-------------------------------------------------------------------------------
-- Plan
-------------------------------------------------------------------------------
-- | The monoidial version of 'CompletePlan'. Used to combine overrides with defaults
--   when creating a plan.
data Plan = Plan
  { partialPlanLogger        :: Last Logger
  , partialPlanInitDb        :: Maybe ProcessConfig
  , partialPlanCreateDb      :: Maybe ProcessConfig
  , partialPlanPostgres      :: PostgresPlan
  , partialPlanConfig        :: [String]
  , partialPlanDataDirectory :: Last String
  }
  deriving stock (Generic)
  deriving Semigroup via GenericSemigroup Plan
  deriving Monoid    via GenericMonoid Plan

instance Pretty Plan where
  pretty Plan {..}
    =  text "partialPlanInitDb:"
    <> softline
    <> indent 2 (pretty partialPlanInitDb)
    <> hardline
    <> text "partialPlanInitDb:"
    <> softline
    <> indent 2 (pretty partialPlanCreateDb)
    <> hardline
    <> text "partialPlanPostgres:"
    <> softline
    <> indent 2 (pretty partialPlanPostgres)
    <> hardline
    <> text "partialPlanConfig:"
    <> softline
    <> indent 2 (vsep $ map text partialPlanConfig)
    <> hardline
    <> text "partialPlanDataDirectory:" <+> pretty (getLast partialPlanDataDirectory)

-- | Turn a 'Plan' into a 'CompletePlan'. Fails if any values are missing.
completePlan :: [(String, String)] -> Plan -> Either [String] CompletePlan
completePlan envs Plan {..} = runErrors $ do
  completePlanLogger   <- getOption "partialPlanLogger" partialPlanLogger
  completePlanInitDb   <- eitherToErrors $ addErrorContext "partialPlanInitDb: " $
    traverse (completeProcessConfig envs) partialPlanInitDb
  completePlanCreateDb <- eitherToErrors $ addErrorContext "partialPlanCreateDb: " $
    traverse (completeProcessConfig envs) partialPlanCreateDb
  completePlanPostgres <- eitherToErrors $ addErrorContext "partialPlanPostgres: " $
    completePostgresPlan envs partialPlanPostgres
  let completePlanConfig = unlines partialPlanConfig
  completePlanDataDirectory <- getOption "partialPlanDataDirectory"
    partialPlanDataDirectory

  pure CompletePlan {..}

-- Returns 'True' if the 'Plan' has a
-- 'Just' 'partialPlanInitDb'
hasInitDb :: Plan -> Bool
hasInitDb Plan {..} = isJust partialPlanInitDb

-- Returns 'True' if the 'Plan' has a
-- 'Just' 'partialPlanCreateDb'
hasCreateDb :: Plan -> Bool
hasCreateDb Plan {..} = isJust partialPlanCreateDb

-- | 'Resources' holds a description of the temporary folders (if there are any)
--   and includes the final 'CompletePlan' that can be used with 'startPlan'.
--   See 'setupConfig' for an example of how to create a 'Resources'.
data Resources = Resources
  { resourcesPlan    :: CompletePlan
  -- ^ Final 'CompletePlan'. See 'startPlan' for information on 'CompletePlan's
  , resourcesSocket  :: CompleteSocketClass
  -- ^ The 'CompleteSocketClass'. Used to track if a temporary directory was made
  --   as the socket location.
  , resourcesDataDir :: CompleteDirectoryType
  -- ^ The data directory. Used to track if a temporary directory was used.
  }

instance Pretty Resources where
  pretty Resources {..}
    =   text "resourcePlan:"
    <>  softline
    <>  indent 2 (pretty resourcesPlan)
    <>  hardline
    <>  text "resourcesSocket:"
    <+> pretty resourcesSocket
    <>  hardline
    <>  text "resourcesDataDir:"
    <+> pretty resourcesDataDir

-- | Make the 'resourcesDataDir' 'CPermanent' so it will not
--   get cleaned up.
makeResourcesDataDirPermanent :: Resources -> Resources
makeResourcesDataDirPermanent r = r
  { resourcesDataDir = makePermanent $ resourcesDataDir r
  }

-- | The high level options for overriding default behavior.
data Config = Config
  { configPlan    :: Plan
  -- ^ Extend or replace any of the configuration used to create a final
  --   'CompletePlan'
  , configSocket  :: SocketClass
  -- ^ Override the default 'CompleteSocketClass' by setting this.
  , configDataDir :: DirectoryType
  -- ^ Override the default temporary data directory by passing in
  -- 'CPermanent DIRECTORY'
  , configPort    :: Last (Maybe Int)
  -- ^ A monoid for using an existing port (via 'Just PORT_NUMBER') or
  -- requesting a free port (via a 'Nothing')
  }
  deriving stock (Generic)
  deriving Semigroup via GenericSemigroup Config
  deriving Monoid    via GenericMonoid Config

instance Pretty Config where
  pretty Config {..}
    =  text "configPlan:"
    <> softline
    <> pretty configPlan
    <> hardline
    <> text "configSocket:"
    <> softline
    <> pretty configSocket
    <> hardline
    <> text "configDataDir:"
    <> softline
    <> pretty configDataDir
    <> hardline
    <> text "configPort:" <+> pretty (getLast configPort)

-- | Create a 'Plan' that sets the command line options of all processes
--   (@initdb@, @postgres@ and @createdb@) using a
toPlan
  :: Bool
  -- ^ Make @initdb@ options
  -> Bool
  -- ^ Make @createdb@ options
  -> Int
  -- ^ port
  -> CompleteSocketClass
  -- ^ Whether to listen on a IP address or UNIX domain socket
  -> FilePath
  -- ^ The @postgres@ data directory
  -> Plan
toPlan makeInitDb makeCreateDb port socketClass dataDirectory = mempty
  { partialPlanConfig = socketClassToConfig socketClass
  , partialPlanDataDirectory = pure dataDirectory
  , partialPlanPostgres = mempty
      { partialPostgresPlanProcessConfig = mempty
          { partialProcessConfigCmdLine = mempty
              { partialCommandLineArgsKeyBased = Map.fromList
                  [ ("-p", Just $ show port)
                  , ("-D", Just dataDirectory)
                  ]
              }
          }
      , partialPostgresPlanClientConfig = mempty
          { Client.host   = pure $ socketClassToHost socketClass
          , Client.port   = pure port
          , Client.dbname = pure "postgres"
          }
      }
  , partialPlanCreateDb = if makeCreateDb
      then pure $ mempty
        { partialProcessConfigCmdLine = mempty
            { partialCommandLineArgsKeyBased = Map.fromList $
                socketClassToHostFlag socketClass <>
                [("-p ", Just $ show port)]
            }
        }
      else Nothing
  , partialPlanInitDb = if makeInitDb
      then pure $ mempty
        { partialProcessConfigCmdLine = mempty
            { partialCommandLineArgsKeyBased = Map.fromList
                [("--pgdata=", Just dataDirectory)]
            }

        }
      else Nothing
  }


-- | Create all the temporary resources from a 'Config'. This also combines the
-- 'Plan' from 'toPlan' with the @extraConfig@ passed in.
setupConfig
  :: Config
  -- ^ @extraConfig@ to 'mappend' after the default config
  -> IO Resources
setupConfig Config {..} = evalContT $ do
  envs <- lift getEnvironment
  port <- lift $ maybe getFreePort pure $ join $ getLast configPort
  resourcesSocket <- ContT $ bracketOnError
    (setupSocketClass configSocket) cleanupSocketConfig
  resourcesDataDir <- ContT $ bracketOnError
    (setupDirectoryType "tmp-postgres-data" configDataDir) cleanupDirectoryType
  let hostAndDir = toPlan
          (hasInitDb configPlan)
          (hasCreateDb configPlan)
          port
          resourcesSocket
          (toFilePath resourcesDataDir)
      finalPlan = hostAndDir <> configPlan
  resourcesPlan <- lift $
    either (throwIO . CompletePlanFailed (show $ pretty finalPlan)) pure $
      completePlan envs finalPlan
  pure Resources {..}

-- | Free the temporary resources created by 'setupConfig'
cleanupConfig :: Resources -> IO ()
cleanupConfig Resources {..} = do
  cleanupSocketConfig resourcesSocket
  cleanupDirectoryType resourcesDataDir
-------------------------------------------------------------------------------
-- Config Generation
-------------------------------------------------------------------------------
-- | Attempt to create a config from a 'Client.Options'. This is useful if
--   want to create a database owned by a specific user you will also log in as
--   among other use cases. It is possible some 'Client.Options' are not
--   supported so don't hesitate to open an issue on github if you find one.
optionsToConfig :: Client.Options -> Config
optionsToConfig opts@Client.Options {..}
  =  ( mempty
       { configPlan = optionsToPlan opts
       , configPort = maybe (Last Nothing) (pure . pure) $ getLast port
       , configSocket = maybe mempty hostToSocketClass $ getLast host
       }
     )
-- Convert the 'Client.Options' to a 'Plan' that can
-- be connected to with the 'Client.Options'.
optionsToPlan :: Client.Options -> Plan
optionsToPlan opts@Client.Options {..}
  =  maybe mempty dbnameToPlan (getLast dbname)
  <> maybe mempty userToPlan (getLast user)
  <> clientOptionsToPlan opts

-- Wrap the 'Client.Options' in an appropiate
-- 'PostgresPlan'
clientOptionsToPlan :: Client.Options -> Plan
clientOptionsToPlan opts = mempty
  { partialPlanPostgres = mempty
    { partialPostgresPlanClientConfig = opts
    }
  }

-- Create a 'Plan' given a user
userToPlan :: String -> Plan
userToPlan user = mempty
  { partialPlanCreateDb = pure $ mempty
    { partialProcessConfigCmdLine = mempty
        { partialCommandLineArgsKeyBased = Map.singleton "--username=" $ Just user
        }
    }
  , partialPlanInitDb = pure $ mempty
    { partialProcessConfigCmdLine = mempty
        { partialCommandLineArgsKeyBased = Map.singleton "--username=" $ Just user
        }
    }
  }

-- Adds a @createdb@ ProcessPlan with the argument
-- as the database name.
dbnameToPlan :: String -> Plan
dbnameToPlan dbName = mempty
  { partialPlanCreateDb = pure $ mempty
    { partialProcessConfigCmdLine = mempty
      { partialCommandLineArgsIndexBased = Map.singleton 0 dbName
      }
    }
  }

-- Parse a host string as either an UNIX domain socket directory
-- or a domain or IP.
hostToSocketClass :: String -> SocketClass
hostToSocketClass hostOrSocketPath = case hostOrSocketPath of
  '/' : _ -> PUnixSocket $ PPermanent hostOrSocketPath
  _ -> PIpSocket $ pure hostOrSocketPath

-------------------------------------------------------------------------------
-- Lenses
-- Most this code was generated with microlens-th
-------------------------------------------------------------------------------
-- | Local Lens alias
type Lens s t a b = forall f. Functor f => (a -> f b) -> s -> f t
-- | Local Lens' alias
type Lens' s a = Lens s s a a

-- | Lens for 'partialEnvVarsInherit'
partialEnvVarsInheritL :: Lens' EnvVars (Last Bool)
partialEnvVarsInheritL f_aj5e (EnvVars x_aj5f x_aj5g)
  = fmap (`EnvVars` x_aj5g)
      (f_aj5e x_aj5f)
{-# INLINE partialEnvVarsInheritL #-}

-- | Lens for 'partialEnvVarsSpecific'
partialEnvVarsSpecificL :: Lens' EnvVars (Map String String)
partialEnvVarsSpecificL f_aj5i (EnvVars x_aj5j x_aj5k)
  = fmap (EnvVars x_aj5j)
      (f_aj5i x_aj5k)
{-# INLINE partialEnvVarsSpecificL #-}

-- | Lens for 'partialProcessConfigCmdLine'
partialProcessConfigCmdLineL ::
  Lens' ProcessConfig CommandLineArgs
partialProcessConfigCmdLineL
  f_allv
  (ProcessConfig x_allw x_allx x_ally x_allz x_allA)
  = fmap
       (\ y_allB
          -> ProcessConfig x_allw y_allB x_ally x_allz
               x_allA)
      (f_allv x_allx)
{-# INLINE partialProcessConfigCmdLineL #-}

-- | Lens for 'partialProcessConfigEnvVars'
partialProcessConfigEnvVarsL ::
  Lens' ProcessConfig EnvVars
partialProcessConfigEnvVarsL
  f_allC
  (ProcessConfig x_allD x_allE x_allF x_allG x_allH)
  = fmap
       (\ y_allI
          -> ProcessConfig y_allI x_allE x_allF x_allG
               x_allH)
      (f_allC x_allD)
{-# INLINE partialProcessConfigEnvVarsL #-}

-- | Lens for 'partialProcessConfigStdErr'
partialProcessConfigStdErrL ::
  Lens' ProcessConfig (Last Handle)
partialProcessConfigStdErrL
  f_allJ
  (ProcessConfig x_allK x_allL x_allM x_allN x_allO)
  = fmap
       (ProcessConfig x_allK x_allL x_allM x_allN)
      (f_allJ x_allO)

-- | Lens for 'partialProcessConfigStdIn'
{-# INLINE partialProcessConfigStdErrL #-}
partialProcessConfigStdInL ::
  Lens' ProcessConfig (Last Handle)
partialProcessConfigStdInL
  f_allQ
  (ProcessConfig x_allR x_allS x_allT x_allU x_allV)
  = fmap
       (\ y_allW
          -> ProcessConfig x_allR x_allS y_allW x_allU
               x_allV)
      (f_allQ x_allT)
{-# INLINE partialProcessConfigStdInL #-}

-- | Lens for 'partialProcessConfigStdOut'
partialProcessConfigStdOutL ::
  Lens' ProcessConfig (Last Handle)
partialProcessConfigStdOutL
  f_allX
  (ProcessConfig x_allY x_allZ x_alm0 x_alm1 x_alm2)
  = fmap
       (\ y_alm3
          -> ProcessConfig x_allY x_allZ x_alm0 y_alm3
               x_alm2)
      (f_allX x_alm1)
{-# INLINE partialProcessConfigStdOutL #-}

-- | Lens for 'partialPostgresPlanClientConfig'
partialPostgresPlanClientConfigL ::
  Lens' PostgresPlan Client.Options
partialPostgresPlanClientConfigL
  f_am1y
  (PostgresPlan x_am1z x_am1A)
  = fmap (PostgresPlan x_am1z)
      (f_am1y x_am1A)
{-# INLINE partialPostgresPlanClientConfigL #-}

-- | Lens for 'partialPostgresPlanProcessConfig'
partialPostgresPlanProcessConfigL ::
  Lens' PostgresPlan ProcessConfig
partialPostgresPlanProcessConfigL
  f_am1C
  (PostgresPlan x_am1D x_am1E)
  = fmap (`PostgresPlan` x_am1E)
      (f_am1C x_am1D)
{-# INLINE partialPostgresPlanProcessConfigL #-}

-- | Lens for 'partialPlanConfig'
partialPlanConfigL :: Lens' Plan [String]
partialPlanConfigL
  f_amcw
  (Plan x_amcx x_amcy x_amcz x_amcA x_amcB x_amcC)
  = fmap
       (\ y_amcD
          -> Plan x_amcx x_amcy x_amcz x_amcA y_amcD
               x_amcC)
      (f_amcw x_amcB)
{-# INLINE partialPlanConfigL #-}

-- | Lens for 'partialPlanCreateDb'
partialPlanCreateDbL ::
  Lens' Plan (Maybe ProcessConfig)
partialPlanCreateDbL
  f_amcE
  (Plan x_amcF x_amcG x_amcH x_amcI x_amcJ x_amcK)
  = fmap
       (\ y_amcL
          -> Plan x_amcF x_amcG y_amcL x_amcI x_amcJ
               x_amcK)
      (f_amcE x_amcH)
{-# INLINE partialPlanCreateDbL #-}

-- | Lens for 'partialPlanDataDirectory'
partialPlanDataDirectoryL :: Lens' Plan (Last String)
partialPlanDataDirectoryL
  f_amcM
  (Plan x_amcN x_amcO x_amcP x_amcQ x_amcR x_amcS)
  = fmap
       (Plan x_amcN x_amcO x_amcP x_amcQ x_amcR)
      (f_amcM x_amcS)
{-# INLINE partialPlanDataDirectoryL #-}

-- | Lens for 'partialPlanInitDb'
partialPlanInitDbL ::
  Lens' Plan (Maybe ProcessConfig)
partialPlanInitDbL
  f_amcU
  (Plan x_amcV x_amcW x_amcX x_amcY x_amcZ x_amd0)
  = fmap
       (\ y_amd1
          -> Plan x_amcV y_amd1 x_amcX x_amcY x_amcZ
               x_amd0)
      (f_amcU x_amcW)
{-# INLINE partialPlanInitDbL #-}

-- | Lens for 'partialPlanLogger'
partialPlanLoggerL :: Lens' Plan (Last Logger)
partialPlanLoggerL
  f_amd2
  (Plan x_amd3 x_amd4 x_amd5 x_amd6 x_amd7 x_amd8)
  = fmap
       (\ y_amd9
          -> Plan y_amd9 x_amd4 x_amd5 x_amd6 x_amd7
               x_amd8)
      (f_amd2 x_amd3)
{-# INLINE partialPlanLoggerL #-}

-- | Lens for 'partialPlanPostgres'
partialPlanPostgresL :: Lens' Plan PostgresPlan
partialPlanPostgresL
  f_amda
  (Plan x_amdb x_amdc x_amdd x_amde x_amdf x_amdg)
  = fmap
       (\ y_amdh
          -> Plan x_amdb x_amdc x_amdd y_amdh x_amdf
               x_amdg)
      (f_amda x_amde)
{-# INLINE partialPlanPostgresL #-}

-- | Lens for 'resourcesDataDir'
resourcesDataDirL :: Lens' Resources CompleteDirectoryType
resourcesDataDirL f_ampd (Resources x_ampe x_ampf x_ampg)
  = fmap (Resources x_ampe x_ampf)
      (f_ampd x_ampg)
{-# INLINE resourcesDataDirL #-}

-- | Lens for 'resourcesPlan'
resourcesPlanL :: Lens' Resources CompletePlan
resourcesPlanL f_ampi (Resources x_ampj x_ampk x_ampl)
  = fmap (\ y_ampm -> Resources y_ampm x_ampk x_ampl)
      (f_ampi x_ampj)
{-# INLINE resourcesPlanL #-}

-- | Lens for 'resourcesSocket'
resourcesSocketL :: Lens' Resources CompleteSocketClass
resourcesSocketL f_ampn (Resources x_ampo x_ampp x_ampq)
  = fmap (\ y_ampr -> Resources x_ampo y_ampr x_ampq)
      (f_ampn x_ampp)
{-# INLINE resourcesSocketL #-}

-- | Lens for 'configDataDir'
configDataDirL :: Lens' Config DirectoryType
configDataDirL f_amyD (Config x_amyE x_amyF x_amyG x_amyH)
  = fmap (\ y_amyI -> Config x_amyE x_amyF y_amyI x_amyH)
      (f_amyD x_amyG)
{-# INLINE configDataDirL #-}

-- | Lens for 'configPlan'
configPlanL :: Lens' Config Plan
configPlanL f_amyJ (Config x_amyK x_amyL x_amyM x_amyN)
  = fmap (\ y_amyO -> Config y_amyO x_amyL x_amyM x_amyN)
      (f_amyJ x_amyK)
{-# INLINE configPlanL #-}

-- | Lens for 'configPort'
configPortL :: Lens' Config (Last (Maybe Int))
configPortL f_amyP (Config x_amyQ x_amyR x_amyS x_amyT)
  = fmap (Config x_amyQ x_amyR x_amyS)
      (f_amyP x_amyT)
{-# INLINE configPortL #-}

-- | Lens for 'configSocket'
configSocketL :: Lens' Config SocketClass
configSocketL f_amyV (Config x_amyW x_amyX x_amyY x_amyZ)
  = fmap (\ y_amz0 -> Config x_amyW y_amz0 x_amyY x_amyZ)
      (f_amyV x_amyX)
{-# INLINE configSocketL #-}

-- | Lens for 'partialCommandLineArgsIndexBased'
partialCommandLineArgsIndexBasedL ::
  Lens' CommandLineArgs (Map Int String)
partialCommandLineArgsIndexBasedL
  f_amNr
  (CommandLineArgs x_amNs x_amNt)
  = fmap (CommandLineArgs x_amNs)
      (f_amNr x_amNt)
{-# INLINE partialCommandLineArgsIndexBasedL #-}

-- | Lens for 'partialCommandLineArgsKeyBased'
partialCommandLineArgsKeyBasedL ::
  Lens' CommandLineArgs (Map String (Maybe String))
partialCommandLineArgsKeyBasedL
  f_amNv
  (CommandLineArgs x_amNw x_amNx)
  = fmap (`CommandLineArgs` x_amNx)
      (f_amNv x_amNw)
{-# INLINE partialCommandLineArgsKeyBasedL #-}
