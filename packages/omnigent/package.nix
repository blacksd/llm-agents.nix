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
  version = "0.13.0";

  src = fetchFromGitHub {
    owner = "omnigent-ai";
    repo = "omnigent";
    tag = "v${version}";
    hash = "sha256-t/C48rTAO/fvSFjG/1DXDzGyZLCJ2bqSFekYsq9RpeM=";
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
      hash = "sha256-Mr7Fc0WvKk5Bve/FxPZ353kCif8hd+TVBnXITOLrdps=";
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
in
python3.pkgs.buildPythonApplication {
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

  # omnigent daemonizes its host process and spawns the local server via
  # ``sys.executable -m omnigent.n`` / ``-m omnigent.runner._zygote`` (cli.py,
  # host/runner_zygote.py). The Nix wrapper injects the closure through an
  # in-process ``site.addsitedir`` call, not the PYTHONPATH env var, so those
  # detached child interpreters start bare and fail with "No module named
  # 'omnigent'". Export PYTHONPATH so the spawns resolve the runtime deps.
  makeWrapperArgs = [
    "--prefix"
    "PYTHONPATH"
    ":"
    "${placeholder "out"}/${python3.sitePackages}:${python3.pkgs.makePythonPath omnigentDeps}"
  ];

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
    # Import the server app module, not just the package __init__: it transitively
    # pulls the egress CA path (cryptography) that the daemon needs at startup, so
    # a missing runtime dep fails the build instead of the first ``omni`` run.
    "omnigent.server.app"
  ];

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    versionCheckHook
    versionCheckHomeHook
  ];
  versionCheckProgramArg = "--version";

  postInstallCheck = ''
    test -f $out/${python3.sitePackages}/omnigent/server/static/web-ui/index.html
  '';

  # Updated with ``nix-update --flake omnigent`` (the repo default): the
  # inline version/hash above is what it rewrites. nix-update tracks GitHub
  # releases, which exclude the daily ``vX.Y.Z.devYYYYMMDD`` prereleases, so no
  # version-regex filtering is needed. The pnpm/PyPI sub-hashes only move on a
  # version bump and are refreshed the same way (rebuild, copy the reported
  # ``got:`` hash).
  passthru = {
    category = "AI Coding Agents";
    inherit
      web-ui
      cel-python
      omnigent-client
      omnigent-ui-sdk
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
}
