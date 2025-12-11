{ pkgs, lib, python, pythonEnv, nix, regionalAirflowPkgs }:

let
  # A single app to set up Airflow from stdin or command-line arguments
  setupScript = pkgs.writeShellApplication {
    name = "setup-airflow-from-script";
    runtimeInputs = [ pkgs.jq python pythonEnv nix ] ++ regionalAirflowPkgs;

    text = ''
      set -euo pipefail

      # Read from stdin only if it's being piped
      INPUT_JSON=""
      if ! [ -t 0 ]; then
        INPUT_JSON=$(cat -)
      fi

      # Determine ENV_NAME from command-line argument or stdin
      ENV_NAME=""

      if [ -n "''${1:-}" ]; then
          ENV_NAME="$1"
          echo "Using environment name from command-line argument: $ENV_NAME"
      elif [ -n "$INPUT_JSON" ] && echo "$INPUT_JSON" | jq -e '.env and .env != null' > /dev/null; then
          ENV_NAME=$(echo "$INPUT_JSON" | jq -r '.env')
          echo "Using environment name from stdin: $ENV_NAME"
      else
          echo "Error: Environment name not provided via command-line argument or stdin." >&2
          echo "Usage: nix run .#prep-airflow -- <env-name>" >&2
          echo "   or: cat config.json | nix run .#prep-airflow" >&2
          exit 1
      fi

      # Set up airflow home directory
      AIRFLOW_HOME_DIR="$(pwd)/airflow_home"
      export AIRFLOW_HOME="$AIRFLOW_HOME_DIR"
      mkdir -p "$AIRFLOW_HOME_DIR"

      # Create airflow.cfg to disable example DAGs
      cat > "$AIRFLOW_HOME_DIR/airflow.cfg" <<EOF
[core]
load_examples = False
EOF

      # Clean up and init DB
      if [ -f "$AIRFLOW_HOME_DIR/airflow.db" ]; then
        echo "Removing existing Airflow database..."
        rm -f "$AIRFLOW_HOME_DIR/airflow.db"
      fi
      echo "Executing: airflow db init"
      airflow db init

      # Create admin user
      echo "Creating admin user..."
      airflow users create \
        --username admin \
        --password admin \
        --firstname Admin \
        --lastname User \
        --role Admin \
        --email admin@localhost

      # Build Nix package for the environment
      echo "Building and staging DAGs for environment: $ENV_NAME"
      nix build ".#$ENV_NAME" --out-link result

      # --- Variable Merging Logic ---
      
      # Load variables from flake build output
      FLAKE_VARS_FILE="$(pwd)/result/variables.json"
      FLAKE_VARS="{}"
      if [ -f "$FLAKE_VARS_FILE" ]; then
        FLAKE_VARS=$(cat "$FLAKE_VARS_FILE")
      fi

      # Load variables from stdin
      STDIN_VARS="{}"
      if [ -n "$INPUT_JSON" ] && echo "$INPUT_JSON" | jq -e '.variables' > /dev/null; then
          STDIN_VARS=$(echo "$INPUT_JSON" | jq '.variables')
      fi

      # Merge variables (stdin overrides flake)
      echo "Merging variables from flake.nix and stdin..."
      MERGED_VARS=$(jq -s '.[0] * .[1]' <(echo "$FLAKE_VARS") <(echo "$STDIN_VARS"))

      # Set merged variables
      echo "Setting Airflow variables..."
      echo "$MERGED_VARS" | jq -r 'keys_unsorted[]' | while IFS= read -r key; do
        value=$(echo "$MERGED_VARS" | jq -r --arg key "$key" '.[$key]')
        echo "--> Setting variable: '$key'"
        airflow variables set "$key" "$value"
      done

      # --- Connection Logic ---
      CONNECTIONS_FILE="$(pwd)/result/connections.json"
      if [ -f "$CONNECTIONS_FILE" ]; then
        echo "Setting Airflow connections..."
        jq -c 'to_entries[]' "$CONNECTIONS_FILE" | while IFS= read -r entry; do
          conn_id=$(echo "$entry" | jq -r '.key')
          conn_json=$(echo "$entry" | jq -r '.value | .conn_type = .type | del(.type)')
          
          echo "--> Adding connection: '$conn_id'"
          # Delete connection if it exists to ensure a clean state, ignoring errors
          airflow connections delete "$conn_id" 2>/dev/null || true
          # Add the connection using the transformed JSON
          airflow connections add "$conn_id" --conn-json "$conn_json"
        done
      fi

      # --- DAG Staging and Override Logic ---
      DAGS_DIR="$AIRFLOW_HOME_DIR/dags"
      PACKAGED_DAGS_LINK="$DAGS_DIR/packaged_dags"

      # 1. Ensure the main dags directory exists and clean it
      mkdir -p "$DAGS_DIR"
      echo "Cleaning local dags directory..."
      find "$DAGS_DIR" -mindepth 1 -maxdepth 1 -not -path "$PACKAGED_DAGS_LINK" -exec rm -rf {} +

      # 2. Handle override dags
      OVERRIDE_DAGS_PATH_FILE="$(pwd)/result/override_dags.path"
      if [ -f "$OVERRIDE_DAGS_PATH_FILE" ]; then
        OVERRIDE_DAGS_SRC_PATH=$(cat "$OVERRIDE_DAGS_PATH_FILE")
        if [ -d "$OVERRIDE_DAGS_SRC_PATH" ]; then
          echo "Copying override DAGs from $OVERRIDE_DAGS_SRC_PATH..."
          # Copy contents of the source directory into the dags folder
          cp -r "$OVERRIDE_DAGS_SRC_PATH"/* "$DAGS_DIR/"
        fi
      fi

      # 3. Handle packaged dags (symlink)
      echo "Staging packaged DAGs..."
      if [ -e "$PACKAGED_DAGS_LINK" ]; then
        if [ -L "$PACKAGED_DAGS_LINK" ]; then
          rm -f "$PACKAGED_DAGS_LINK"
        else
          echo "Error: $PACKAGED_DAGS_LINK exists but is not a symlink." >&2
          exit 1
        fi
      fi
      ln -s "$(pwd)/result/dags" "$PACKAGED_DAGS_LINK"

      echo "✅ Environment setup complete!"
    '';
  };
in
{
  # This is now the main app
  prep-airflow = {
    type = "app";
    program = "${setupScript}/bin/setup-airflow-from-script";
  };
}
