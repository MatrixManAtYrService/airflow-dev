{
  description = "Airflow DAGs and tasks for billing operations";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-25.05";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };

    billing-airflow = {
      url = "git+ssh://git@github.corp.clover.com/clover/billing-airflow.git?ref=main";
      flake = false;
    };
    billing-na-airflow = {
      url = "git+ssh://git@github.corp.clover.com/clover/billing-na-airflow.git?ref=main";
      flake = false;
    };
    billing-emea-airflow = {
      url = "git+ssh://git@github.corp.clover.com/clover/billing-emea-airflow.git?ref=main";
      flake = false;
    };
    billing-apac-airflow = {
      url = "git+ssh://git@github.corp.clover.com/clover/billing-apac-airflow.git?ref=main";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, uv2nix, pyproject-nix, pyproject-build-systems, billing-airflow, billing-na-airflow, billing-emea-airflow, billing-apac-airflow }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # Import Artifactory overlay functions
        artifactoryLib = import ./nix/artifactory.nix { inherit (nixpkgs) lib; };

        # Override Python packages in nixpkgs to redirect PyPI URLs to Artifactory
        nixpkgsArtifactoryOverlay = final: prev:
          let
            overlayFuncs = artifactoryLib.mkNixpkgsOverlay {
              inherit (final) cacert;
              inherit (nixpkgs) lib;
            };
          in
          {
            python312Packages = overlayFuncs.python312Packages prev.python312Packages;
            python313Packages = overlayFuncs.python313Packages prev.python313Packages;
            python311Packages = overlayFuncs.python311Packages prev.python311Packages;
          };

        # Override Python packages fetched via pypkg to redirect PyPI URLs to Artifactory
        pyprojectArtifactoryOverlay = final: prev:
          artifactoryLib.mkPyprojectOverlay
            {
              inherit (pkgs) cacert lib;
            }
            prev;

        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            nixpkgsArtifactoryOverlay
          ];
          config.allowUnfree = true;
        };


        python = pkgs.python311;
        workspace = uv2nix.lib.workspace.loadWorkspace {
          workspaceRoot = ./.;
        };

        pyprojectOverlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel";
        };

        pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope (
          nixpkgs.lib.composeManyExtensions ([
            pyproject-build-systems.overlays.default
            pyprojectOverlay
            pendulum-overlay
            unicodecsv-overlay
            google-re2-overlay
            python-nvd3-overlay
            starkbank-ecdsa-overlay
            pyprojectArtifactoryOverlay
          ])
        );

        editableOverlay = workspace.mkEditablePyprojectOverlay {
          root = "$REPO_ROOT";
        };

        pendulum-overlay = final: prev: {
          pendulum = prev.pendulum.overrideAttrs (oldAttrs: {
            nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [
              pkgs.rustc
              pkgs.cargo
            ];
            buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
              final.poetry-core
            ];
          });
        };

        unicodecsv-overlay = final: prev: {
          unicodecsv = prev.unicodecsv.overrideAttrs (oldAttrs: {
            buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
              final.setuptools
            ];
          });
        };

        google-re2-overlay = final: prev: {
          google-re2 = prev.google-re2.overrideAttrs (oldAttrs: {
            buildInputs = (oldAttrs.buildInputs or []) ++ [
              final.setuptools
            ];
            nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [
              pkgs.abseil-cpp
              final.pybind11
              pkgs.re2
            ];
          });
        };

        python-nvd3-overlay = final: prev: {
          python-nvd3 = prev.python-nvd3.overrideAttrs (oldAttrs: {
            buildInputs = (oldAttrs.buildInputs or []) ++ [
              final.setuptools
            ];
          });
        };

        starkbank-ecdsa-overlay = final: prev: {
          starkbank-ecdsa = prev.starkbank-ecdsa.overrideAttrs (oldAttrs: {
            buildInputs = (oldAttrs.buildInputs or []) ++ [
              final.setuptools
            ];
          });
        };

        editableBuildSystems = final: prev: {
          billing-airflow = prev.billing-airflow.overrideAttrs (old: {
            nativeBuildInputs =
              old.nativeBuildInputs
              ++ final.resolveBuildSystem {
                editables = [ ];
              };
          });
        };

        editablePythonSet = pythonSet.overrideScope (
          nixpkgs.lib.composeManyExtensions [
            editableOverlay
            editableBuildSystems
          ]
        );

        pythonEnv = pythonSet.mkVirtualEnv "billing-airflow" workspace.deps.default;
      in
      {
        packages = {
          default = pythonEnv;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            (editablePythonSet.mkVirtualEnv "billing-airflow" workspace.deps.all)
            uv
            ruff
            python311Packages.python-lsp-ruff
            pyright
            nixpkgs-fmt
          ];
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = python.interpreter;
            UV_PYTHON_DOWNLOADS = "never";
          };
          shellHook = ''
            export REPO_ROOT=$(pwd)
            # run `nix build .#na` to place the na dags here:
            export AIRFLOW_HOME=$(pwd)/result
          '';
        };
      });
}
