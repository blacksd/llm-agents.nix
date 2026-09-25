{
  lib,
  stdenv,
  flake,
  python3,
  fetchFromGitHub,
  fetchPnpmDeps,
  nodejs,
  pnpm_10,
  pnpmConfigHook,
  versionCheckHook,
  versionCheckHomeHook,
}:

let
  version = "0.15.0";

  src = fetchFromGitHub {
    owner = "omnigent-ai";
    repo = "omnigent";
    tag = "v${version}";
    hash = "sha256-cuM3c2H7/3TTl1954oGx9QbfZlffcN2H+qPo18sX9Us=";
  };

  # CEL (Common Expression Language) evaluator; used by omnigent's policy
  # engine. Not in nixpkgs yet.
  cel-python = python3.pkgs.buildPythonPackage rec {
    pname = "cel-python";
    version = "0.5.0";
    pyproject = true;

    src = python3.pkgs.fetchPypi {
      pname = "cel_python";
      inherit version;
      hash = "sha256-PrCmGejfDzONBDDNoBQnp0LnfjxDOhx8Pr1AnNgExFo=";
    };

    build-system = with python3.pkgs; [ hatchling ];

    dependencies = with python3.pkgs; [
      google-re2
      jmespath
      lark
      pendulum
      pyyaml
    ];

    pythonImportsCheck = [ "celpy" ];

    meta = with lib; {
      description = "Pure Python implementation of Google Common Expression Language";
      homepage = "https://github.com/cloud-custodian/cel-python";
      license = licenses.asl20;
      sourceProvenance = with sourceTypes; [ fromSource ];
      platforms = platforms.all;
    };
  };

  # Sibling SDK workspace members. Both hard-pin the root ``omnigent``
  # package (client) / each other (ui-sdk) at ``==${version}``, forming a
  # dependency cycle with the app. They are built here without the self /
  # cross pins so the cycle breaks; the final application closure provides
  # every module regardless.
  omnigent-client = python3.pkgs.buildPythonPackage {
    pname = "omnigent-client";
    inherit version src;
    pyproject = true;

    sourceRoot = "${src.name}/sdks/python-client";

    build-system = with python3.pkgs; [ hatchling ];

    # Drop the ``omnigent==${version}`` self-pin: the runtime env supplies it,
    # and honouring it here would recurse into the app being built.
    pythonRemoveDeps = [ "omnigent" ];

    dependencies = with python3.pkgs; [
      httpx
      pydantic
    ];

    # Importing the client pulls the omnigent server package, absent while
    # building the SDK in isolation.
    dontUsePythonImportsCheck = true;

    meta = with lib; {
      description = "Python client SDK for the omnigent server API";
      homepage = "https://github.com/omnigent-ai/omnigent";
      license = licenses.asl20;
      sourceProvenance = with sourceTypes; [ fromSource ];
      platforms = platforms.all;
    };
  };

  omnigent-ui-sdk = python3.pkgs.buildPythonPackage {
    pname = "omnigent-ui-sdk";
    inherit version src;
    pyproject = true;

    sourceRoot = "${src.name}/sdks/ui";

    build-system = with python3.pkgs; [ hatchling ];

    pythonRemoveDeps = [ "omnigent-client" ];

    dependencies = with python3.pkgs; [
      rich
      prompt-toolkit
      pyyaml
    ];

    dontUsePythonImportsCheck = true;

    meta = with lib; {
      description = "Terminal UI components for building omnigent frontends";
      homepage = "https://github.com/omnigent-ai/omnigent";
      license = licenses.asl20;
      sourceProvenance = with sourceTypes; [ fromSource ];
      platforms = platforms.all;
    };
  };

  # React/Vite web console. The pnpm workspace root is the repo root; the
  # ``web`` member's vite build writes straight into
  # ``omnigent/server/static/web-ui`` (web/vite.config.ts), which the server
  # serves at ``/`` when present (else the API-only landing page).
  web-ui = stdenv.mkDerivation (finalAttrs: {
    pname = "omnigent-web-ui";
    inherit version src;

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pnpm_10;
      pnpmWorkspaces = [ "web" ];
      hash = "sha256-abl0gd/yDVqrFF0y1AQAYuhgXGU+VrmOtqM9F8nlv34=";
      fetcherVersion = 3;
    };

    pnpmWorkspaces = [ "web" ];

    nativeBuildInputs = [
      nodejs
      pnpm_10
      pnpmConfigHook
    ];

    buildPhase = ''
      runHook preBuild
      pnpm --filter web build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -r omnigent/server/static/web-ui $out
      runHook postInstall
    '';
  });

  # openai-agents 0.18.1 promoted websockets to a core runtime dependency
  # (websockets<17,>=15.0, no extra marker), but nixpkgs' expression still
  # lists it only under the realtime/voice extras, so its own
  # pythonRuntimeDepsCheck fails with "websockets not installed". Add it back.
  openai-agents' = python3.pkgs.openai-agents.overridePythonAttrs (old: {
    dependencies = (old.dependencies or [ ]) ++ [ python3.pkgs.websockets ];
  });

  omnigentDeps = with python3.pkgs; [
    alembic
    anyio
    argon2-cffi
    cachetools
    cel-python
    certifi
    claude-agent-sdk
    click
    # Upstream declares ``PyJWT[crypto]`` (the crypto extra pulls cryptography)
    # and omnigent.inner.egress.ca imports ``cryptography`` directly to mint the
    # egress proxy CA. nixpkgs' pyjwt has no such extra, so add it explicitly;
    # without it the server dies on startup with ModuleNotFoundError.
    cryptography
    fastapi
    ftfy
    httpx
    json5
    keyring
    mcp
    omnigent-client
    omnigent-ui-sdk
    openai
    openai-agents'
    opentelemetry-api
    packaging
    pexpect
    pillow
    prompt-toolkit
    protobuf
    psutil
    pydantic
    pyjwt
    pyte
    python-dateutil
    pyyaml
    rich
    sqlalchemy
    starlette
    tiktoken
    tomlkit
    tzdata
    uvicorn
    websockets
    zstandard
  ];
  # omnigent's importable module: the app built as a plain python package, with
  # no self-referential wrapper. Kept separate from the wrapped application below
  # so it can go into ``pythonEnv`` (via withPackages) without a build-time cycle
  # — the app's wrapper references the env, the env references this, and this
  # references neither.
  omnigent-pymod = python3.pkgs.buildPythonPackage {
    pname = "omnigent";
    inherit version src;
    pyproject = true;

    build-system = with python3.pkgs; [ setuptools ];

    dependencies = omnigentDeps;

    # Ship the built web console so the server serves it at ``/`` instead of the
    # API-only landing page.
    preBuild = ''
      cp -r ${web-ui}/. omnigent/server/static/web-ui/
      chmod -R u+w omnigent/server/static/web-ui
    '';

    # The Claude/Cursor/etc. harness bridges register a hook + MCP command in the
    # target agent's settings.json as ``<python> -I -m omnigent.harnesses.*`` and
    # default ``<python>`` to ``sys.executable``. That command is run by the agent
    # (a sibling process), so it inherits none of omni's wrapper env, and ``-I``
    # additionally ignores PYTHONPATH — so under Nix it starts as the bare
    # interpreter and dies with "No module named 'omnigent'" (e.g. the Claude stop
    # hook). Teach the shared ``python_executable or sys.executable`` fallback to
    # honour OMNIGENT_PYTHON_EXECUTABLE, which the wrapper points at pythonEnv (an
    # interpreter that resolves omnigent even under ``-I``). Read via __import__
    # so files that don't already import os need no extra edit.
    #
    # The hook settings are built inside the *runner*, which the host daemon
    # spawns with an env allowlist (_RUNNER_ENV_ALLOWLIST in host/connect.py),
    # not the full environment — so OMNIGENT_PYTHON_EXECUTABLE set on the wrapper
    # is stripped before it reaches the code above unless it is on the allowlist.
    # Add it so the runner sees it and the observer/stop hooks resolve omnigent.
    postPatch = ''
      substituteInPlace $(grep -rl "python_executable or sys.executable" omnigent/harnesses omnigent/native) \
        --replace-fail \
          "python_executable or sys.executable" \
          "python_executable or __import__(\"os\").environ.get(\"OMNIGENT_PYTHON_EXECUTABLE\") or sys.executable"

      substituteInPlace omnigent/host/connect.py \
        --replace-fail \
          '_RUNNER_ENV_ALLOWLIST: frozenset[str] = frozenset(' \
          '_RUNNER_ENV_ALLOWLIST: frozenset[str] = frozenset({"OMNIGENT_PYTHON_EXECUTABLE"}) | frozenset('

      # ``omni upgrade`` has no env-var opt-out and dead-ends on a Nix install
      # ("No automatic upgrade command is known ... reinstall omnigent from your
      # original source"). Point the user at the flake instead. replace-all: the
      # identical message is raised at three call sites in cli.py.
      substituteInPlace omnigent/cli.py \
        --replace-warn \
          'f"No automatic upgrade command is known for this install. {suggestion.command}."' \
          'f"This omnigent is managed by Nix (llm-agents.nix); upgrade it there, not with omni upgrade."'
    '';

    # Upstream hard-pins the sibling SDKs and several runtime deps at exact
    # versions; nixpkgs has moved past some. The closure supplies them all.
    pythonRelaxDeps = [
      "omnigent-client"
      "omnigent-ui-sdk"
      "openai"
      "openai-agents"
      "claude-agent-sdk"
      "pydantic"
      "fastapi"
      "starlette"
      "uvicorn"
      "websockets"
      "mcp"
      "tiktoken"
      "cel-python"
      # nixpkgs-unstable has moved past upstream's upper bounds.
      "rich"
      "cachetools"
      "argon2-cffi"
      "packaging"
    ];

    pythonImportsCheck = [
      "omnigent"
      "omnigent.cli"
      # Import the server app module, not just the package __init__: it
      # transitively pulls the egress CA path (cryptography) that the daemon
      # needs at startup, so a missing runtime dep fails the build instead of
      # the first ``omni`` run.
      "omnigent.server.app"
    ];

    postInstallCheck = ''
      test -f $out/${python3.sitePackages}/omnigent/server/static/web-ui/index.html
    '';

    meta.mainProgram = "omnigent";
  };

  # A single interpreter whose *own* site-packages carry omnigent and its whole
  # closure. The ``-I`` harness-bridge commands need the closure on the
  # interpreter's built-in path (env vars, incl. PYTHONPATH, are ignored under
  # ``-I``). Built from omnigent-pymod, so no cycle with the wrapped app.
  pythonEnv = python3.withPackages (_: [ omnigent-pymod ]);
in
# Wrap the module into the CLI application, adding the two spawn fixes:
#  * PYTHONPATH (--prefix): omnigent daemonizes via ``sys.executable -m
#    omnigent.host._daemon_entry`` (cli.py) as a child of this wrapper; the Nix
#    wrapper injects the closure through an in-process ``site.addsitedir`` call
#    rather than the env var, so without this the detached daemon starts bare.
#  * OMNIGENT_PYTHON_EXECUTABLE (--set): the ``-I`` harness-bridge commands, run
#    by a sibling agent, need a full interpreter path (see omnigent-pymod's
#    postPatch); point it at pythonEnv.
(python3.pkgs.toPythonApplication omnigent-pymod).overrideAttrs (old: {
  doInstallCheck = true;
  nativeInstallCheckInputs = (old.nativeInstallCheckInputs or [ ]) ++ [
    versionCheckHook
    versionCheckHomeHook
  ];
  versionCheckProgramArg = "--version";

  makeWrapperArgs = (old.makeWrapperArgs or [ ]) ++ [
    "--prefix"
    "PYTHONPATH"
    ":"
    "${placeholder "out"}/${python3.sitePackages}:${python3.pkgs.makePythonPath omnigentDeps}"
    "--set"
    "OMNIGENT_PYTHON_EXECUTABLE"
    "${pythonEnv}/bin/python3"
    # Silence the passive "a new release is available" banner on every launch:
    # the Nix store path is read-only and upgrades come from the flake, not the
    # in-tool upgrader. (omnigent-pymod's postPatch turns an explicit
    # ``omni upgrade`` into a Nix-aware hint instead of the generic dead end.)
    "--set"
    "OMNIGENT_NO_UPDATE_CHECK"
    "1"
  ];

  # Updated with ``nix-update --flake omnigent`` (the repo default): the inline
  # version/hash above is what it rewrites. Upstream also pushes daily
  # ``vX.Y.Z.devYYYYMMDD`` / ``vX.Y.Zrc1`` tags that appear in the tag list and
  # releases.atom, so the ``nix-update-args`` file pins ``--use-github-releases``
  # plus a plain-semver ``--version-regex`` to keep those out. The pnpm/PyPI
  # sub-hashes only move on a version bump and are NOT touched by nix-update;
  # refresh them by hand (rebuild, copy the reported ``got:`` hash).
  passthru = (old.passthru or { }) // {
    category = "AI Coding Agents";
    inherit
      web-ui
      cel-python
      omnigent-client
      omnigent-ui-sdk
      omnigent-pymod
      pythonEnv
      ;
  };

  meta = with lib; {
    description = "Multi-agent coding CLI with a local web console";
    homepage = "https://github.com/omnigent-ai/omnigent";
    changelog = "https://github.com/omnigent-ai/omnigent/releases/tag/v${version}";
    license = licenses.asl20;
    sourceProvenance = with sourceTypes; [ fromSource ];
    maintainers = with flake.lib.maintainers; [ blacksd ];
    mainProgram = "omnigent";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
})
