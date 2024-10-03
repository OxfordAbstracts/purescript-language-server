module IdePurescript.Build where

import Prelude

import Control.Monad.Error.Class (throwError)
import Data.Array (intercalate, uncons, (:))
import Data.Array as Array
import Data.Bifunctor (bimap)
import Data.Either (Either(..), either)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String (Pattern(Pattern), indexOf, joinWith, split)
import Data.String as String
import Data.Traversable (traverse_)
import Effect (Effect)
import Effect.Aff (Aff, error, makeAff)
import Effect.Class (liftEffect)
import Effect.Exception (catchException)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Foreign.Object as Object
import IdePurescript.Exec (findBins, getPathVar, whichSync)
import IdePurescript.PscErrors (PscResult(..), parsePscOutput)
import IdePurescript.PscIdeServer (ErrorLevel(..), Notify)
import Node.Buffer (Buffer)
import Node.Buffer as Buffer
import Node.ChildProcess (ChildProcess)
import Node.ChildProcess as CP
import Node.ChildProcess.Types (Exit(..), enableShell)
import Node.Encoding as Encoding
import Node.Errors.SystemError (toError)
import Node.EventEmitter (on_, once_)
import Node.Process (getEnv)
import Node.Stream as S
import PscIde as P
import PscIde.Command (CodegenTarget, RebuildResult(..))
import PscIde.Server (Executable(Executable))

type BuildOptions =
  { command :: Command
  , directory :: String
  , useNpmDir :: Boolean
  }

data Command = Command String (Array String)

type BuildResult =
  { errors :: PscResult
  , success :: Boolean
  }

-- check if retrieved (copied) env object has "PATH" property, then use it,
-- otherwise use "Path" (for windows)
getPathProp :: Object.Object String -> String
getPathProp env =
  if Object.member "PATH" env then "PATH" else "Path"

spawn :: BuildOptions -> Effect ChildProcess
spawn { command: Command cmd args, directory, useNpmDir } = do
  { env, path } <-
    if useNpmDir then do
      pathVar <- getPathVar useNpmDir directory
      env <- getEnv
      pure
        { env: Just $ Object.insert (getPathProp env)
            (either identity identity pathVar)
            env
        , path: either (const Nothing) Just pathVar
        }
    else
      pure { env: Nothing, path: Nothing }

  cmd' <- (fromMaybe cmd <<< Array.head) <$> whichSync
    { path, pathExt: Nothing }
    cmd
  CP.spawn' cmd' args
    (_ { cwd = Just directory, env = env, shell = Just enableShell })

-- Spawn with npm path, "which" call (windows support) and version info gathering
spawnWithVersion ::
  BuildOptions -> Aff { cmdBins :: Array Executable, cp :: Maybe ChildProcess }
spawnWithVersion { command: Command cmd args, directory, useNpmDir } = do
  pathVar <- liftEffect $ getPathVar useNpmDir directory
  cmdBins <- findBins pathVar cmd
  cp <-
    liftEffect
      $ case uncons cmdBins of
          Just { head: Executable cmdBin _ } -> do
            env <- liftEffect getEnv
            let
              childEnv = Object.insert (getPathProp env)
                (either identity identity pathVar)
                env
            Just <$> CP.spawn' cmdBin args
              ( _
                  { cwd = Just directory, env = Just childEnv, shell = Just enableShell }
              )
          _ -> pure Nothing
  pure { cmdBins, cp }

build :: Notify -> BuildOptions -> Aff (Either String BuildResult)
build logCb buildOptions@{ command: Command cmd args } = do
  { cmdBins, cp: cp' } <- spawnWithVersion buildOptions
  makeAff
    $ \cb -> do
        let
          succ = cb <<< Right
          err = cb <<< Left
        logCb Info $ "Resolved build command (1st is used): "
        traverse_
          ( \(Executable x vv) -> do
              logCb Info $ x <> maybe "" (": " <> _) vv
          )
          cmdBins
        case cp' of
          Nothing -> succ $ Left $ "Didn't find command in PATH: " <> cmd
          Just cp -> do
            logCb Info $ "Running build command: " <> intercalate " "
              (cmd : args)
            cp # once_ CP.errorH (cb <<< Left <<< toError)
            errOutput <- Ref.new []
            outOutput <- Ref.new []
            let
              res :: Ref (Array Buffer) -> Buffer -> Effect Unit
              res r s = Ref.modify_ (_ `Array.snoc` s) r
            catchException err $ (CP.stderr cp) # on_ S.dataH (res errOutput)
            catchException err $ (CP.stdout cp) # on_ S.dataH (res outOutput)
            cp # once_ CP.closeH
              ( \exit -> case exit of
                  Normally n
                    | n == 0 || n == 1 -> do
                        pursError <- Ref.read errOutput >>= Buffer.concat >>=
                          Buffer.toString Encoding.UTF8
                        pursOutput <- Ref.read outOutput >>= Buffer.concat >>=
                          Buffer.toString Encoding.UTF8
                        let
                          lines = split (Pattern "\n") $ pursError <> pursOutput
                          { yes: json, no: toLog } = Array.partition
                            (\s -> indexOf (Pattern "{\"") s == Just 0)
                            lines
                        logCb Info $ joinWith "\n" toLog
                        case parsePscOutput <$> json of
                          [ Left e ] -> succ $ Left $
                            "Couldn't parse build output: " <> e
                          [ Right r ] -> succ $ Right
                            { errors: r, success: n == 0 }
                          [] ->
                            succ
                              $ Left
                              $ "Problem running build: "
                                  <>
                                    if String.length pursError > 0 then
                                      String.take 500 pursError
                                    else
                                      "didn't find JSON output"
                          _ -> succ $ Left
                            "Found multiple lines of JSON output, don't know what to do"
                  _ -> succ $ Left "Build process exited abnormally"
              )
        pure mempty

rebuild ::
  Int ->
  String ->
  Maybe String ->
  Maybe (Array CodegenTarget) ->
  Aff BuildResult
rebuild port file actualFile targets = do
  res <- P.rebuild port file actualFile targets
  either
    (throwError <<< error)
    (pure <<< onResult)
    res
  where

  onResult :: Either RebuildResult RebuildResult -> BuildResult
  onResult =
    either
      (\errors -> { errors: PscResult { errors, warnings: [] }, success: true })
      ( \warnings ->
          { errors: PscResult { errors: [], warnings }, success: true }
      )
      <<< bimap unwrap unwrap
    where
    unwrap (RebuildResult r) = r
