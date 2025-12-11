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
      url = "path:/Users/matt.rixman/src/billing-airflow";
      flake = false;
    };
    billing-na-airflow = {
      url = "path:/Users/matt.rixman/src/billing-na-airflow";
      flake = false;
    };
    billing-emea-airflow = {
      url = "path:/Users/matt.rixman/src/billing-emea-airflow";
      flake = false;
    };
    billing-apac-airflow = {
      url = "path:/Users/matt.rixman/src/billing-apac-airflow";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, uv2nix, pyproject-nix, pyproject-build-systems, billing-airflow, billing-na-airflow, billing-emea-airflow, billing-apac-airflow }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # Import Artifactory overlay functions
        artifactoryLib = import ./nix/artifactory.nix { inherit (nixpkgs) lib; };

        # Import DAG staging functions
        dagLib = import ./nix/stage_dags.nix { inherit pkgs python; lib = nixpkgs.lib; };


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
            #nixpkgsArtifactoryOverlay
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
            #pyprojectArtifactoryOverlay
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
            buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
              final.setuptools
            ];
            nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [
              pkgs.abseil-cpp
              final.pybind11
              pkgs.re2
            ];
          });
        };

        python-nvd3-overlay = final: prev: {
          python-nvd3 = prev.python-nvd3.overrideAttrs (oldAttrs: {
            buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
              final.setuptools
            ];
          });
        };

        starkbank-ecdsa-overlay = final: prev: {
          starkbank-ecdsa = prev.starkbank-ecdsa.overrideAttrs (oldAttrs: {
            buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
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

        # Create a package for the billing-airflow flake input
        billing-airflow-pkg = pkgs.python311Packages.buildPythonPackage {
          pname = "billing-airflow";
          version = "0.1.0";
          src = billing-airflow;
          pyproject = true;
          build-system = [ pkgs.python311Packages.hatchling ];
          dontCheckRuntimeDeps = true;
        };
        billing-na-airflow-pkg = pkgs.python311Packages.buildPythonPackage {
          pname = "billing-na-airflow";
          version = "0.1.0";
          src = billing-na-airflow;

          # Add git to the build inputs so the setup_support.py script can run
          nativeBuildInputs = [ pkgs.git ];

          # Run setup_support.py before the build
          preBuild = ''
            python setup_support.py
          '';

          # Add the dependency on the billing-airflow package we just defined
          propagatedBuildInputs = [
            billing-airflow-pkg
          ];
        };

        billing-emea-airflow-pkg = pkgs.python311Packages.buildPythonPackage {
          pname = "billing-emea-airflow";
          version = "0.1.0";
          src = billing-emea-airflow;

          # Add git to the build inputs so the setup_support.py script can run
          nativeBuildInputs = [ pkgs.git ];

          # Run setup_support.py before the build
          preBuild = ''
            python setup_support.py
          '';

          # Add the dependency on the billing-airflow package we just defined
          propagatedBuildInputs = [
            billing-airflow-pkg
          ];
        };

        billing-apac-airflow-pkg = pkgs.python311Packages.buildPythonPackage {
          pname = "billing-apac-airflow";
          version = "0.1.0";
          src = billing-apac-airflow;

          # Add git to the build inputs so the setup_support.py script can run
          nativeBuildInputs = [ pkgs.git ];

          # Run setup_support.py before the build
          preBuild = ''
            python setup_support.py
          '';

          # Add the dependency on the billing-airflow package we just defined
          propagatedBuildInputs = [
            billing-airflow-pkg
          ];
        };

        # Create specific DAG packages matching environments.json
        dagPackages = {
          # APAC environments
          approd = dagLib.mkDagPackage { repo = billing-apac-airflow; region = "apac"; environment = "prod"; };
          apstaging = dagLib.mkDagPackage { repo = billing-apac-airflow; region = "apac"; environment = "stage"; };

          # NA environments  
          "dev-billing" = dagLib.mkDagPackage { repo = billing-na-airflow; region = "na"; environment = "dev"; };
          "whatif" = dagLib.mkDagPackage {
            repo = billing-na-airflow;
            region = "na";
            environment = "whatif";
            packageDags = false;
            override_dags = ./environment_dags/whatif;
            variables = {
              "whatif.nabilling_secret" = "unused";
              "whatif.billingevent_secret" = "unused";
              "whatif.bookkeeper_secret" = "unused";
            };
            connections = {
              whatif_url = {
                type = "http";
                host = "localhost";
                schema = "http";
                port = 9999;
              };
            };
          };
          prod = dagLib.mkDagPackage { repo = billing-na-airflow; region = "na"; environment = "prod"; };
          nastaging = dagLib.mkDagPackage { repo = billing-na-airflow; region = "na"; environment = "stage"; };

          # EMEA environments
          "euprod-alt" = dagLib.mkDagPackage { repo = billing-emea-airflow; region = "emea"; environment = "prod"; };

          # Developer environments
          "intercept-dev" = dagLib.mkDagPackage {
            repo = billing-na-airflow;
            region = "na";
            environment = "intercept-dev";
            variables = {
              "demo2.billingevent_secret" = "unused";
              "demo2.bookkeeper_secret" = "unused";
              "demo2.emeabilling_secret" = "unused";
              "dev1.billingevent_secret" = "unused";
              "dev1.bookkeeper_secret" = "unused";
              "dev1.emeabilling_secret" = "unused";
              "dev1.nabilling_secret" = "unused";
              "dev2.billingapac_secret" = "unused";
              "dev2.billingevent_secret" = "unused";
              "dev2.bookkeeper_secret" = "unused";
              "dev26.billingevent_secret" = "unused";
              "dev26.bookkeeper_secret" = "unused";
              "dev7.billingevent_secret" = "unused";
              "dev7.bookkeeper_secret" = "unused";
              "perf_test.billingevent_secret" = "unused";
              "perf_test.bookkeeper_secret" = "unused";
              "perf_test.nabilling_secret" = "unused";
              "stg2.billingevent_secret" = "unused";
              "stg2.bookkeeper_secret" = "unused";
              "stg3.billingevent_secret" = "unused";
              "stg3.bookkeeper_secret" = "unused";
              "stg3.emeabilling_secret" = "unused";
            };
            connections = {
              dev1_url = {
                type = "http";
                host = "localhost";
                schema = "http";
                port = 9998;
              };
            };
          };
        };

        # Import Airflow app
        airflowApp = import ./nix/airflow_apps.nix {
          inherit pkgs python pythonEnv;
          lib = nixpkgs.lib;
          nix = pkgs.nix;
          regionalAirflowPkgs = [
            billing-na-airflow-pkg
            billing-emea-airflow-pkg
            billing-apac-airflow-pkg
          ];
        };
      in
      {
        packages = {
          default = pythonEnv;
        } // dagPackages;

        apps = {
          prep-airflow = airflowApp.prep-airflow;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            (editablePythonSet.mkVirtualEnv "billing-airflow" workspace.deps.all)
            billing-airflow-pkg
            billing-na-airflow-pkg
            billing-emea-airflow-pkg
            billing-apac-airflow-pkg
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
              export AIRFLOW_HOME=$(pwd)/airflow_home
          '';
        };
      });
}
