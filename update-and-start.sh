#!/bin/bash
# Copyright 2026 Jordy Slagter
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e  # Exit immediately if any command fails

# --- Argument Checking ---
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <Xms_in_M> <Xmx_in_M> <repo_path_or_url>"
    echo "Example (GitHub): $0 1000 8000 https://github.com/SlagterJ/geertenjordy-server.git"
    echo "Example (Local Dev): $0 1000 8000 /home/user/my-local-repo"
    exit 1
fi

MEM_MIN="$1"
MEM_MAX="$2"
REPO_SOURCE="$3"
REPO_DIR="git-repo"
CONFIG_DIR="config"
SCRIPT_NAME="update-and-start.sh"
SERVER_PROPERTIES="server.properties"

# --- Repository Setup (Handle Local and Remote Repos) ---
if [ -d "$REPO_SOURCE/.git" ]; then
    echo "Using local Git repository: $REPO_SOURCE"
    rm -rf "$REPO_DIR"
    cp -r "$REPO_SOURCE" "$REPO_DIR"
elif [[ "$REPO_SOURCE" =~ ^https?:// ]]; then
    echo "Using remote Git repository: $REPO_SOURCE"
    if [ ! -d "$REPO_DIR" ]; then
        git clone "$REPO_SOURCE" "$REPO_DIR"
    else
        cd "$REPO_DIR" && git pull && cd ..
    fi
else
    echo "Error: '$REPO_SOURCE' is not a valid Git repository path or URL!"
    exit 1
fi

# --- Update the script ---
if [ -f "git-repo/update-and-start.sh" ]; then
    cp git-repo/update-and-start.sh update-and-start.sh
fi

# --- Load secrets ---
if [ -f "./secrets.sh" ]; then
    source ./secrets.sh
    export $(grep -oP '^\w+' secrets.sh)
fi

# --- Download packwiz-installer-bootstrap.jar if missing ---
if [ ! -f packwiz-installer-bootstrap.jar ]; then
    echo "Downloading packwiz-installer-bootstrap.jar..."
    wget -O packwiz-installer-bootstrap.jar "https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar"
fi

# --- Update Mods ---
echo "Running packwiz installer..."
java -jar packwiz-installer-bootstrap.jar -g -s server "$REPO_DIR/pack.toml"

# --- Extract Minecraft Version from pack.toml ---
MINECRAFT_VERSION=$(grep -E '^\s*minecraft\s*=' "$REPO_DIR/pack.toml" | head -n1 | cut -d'"' -f2)
if [ -z "$MINECRAFT_VERSION" ]; then
    echo "Error: Could not extract Minecraft version."
    exit 1
fi
echo "Extracted Minecraft version: $MINECRAFT_VERSION"

# --- Update Fabric Server ---
FABRIC_JAR_URL="https://jars.arcadiatech.org/fabric/${MINECRAFT_VERSION}/fabric.jar"
echo "Checking for updates to fabric.jar..."
wget -N -O fabric.jar "$FABRIC_JAR_URL"

# --- Replace Environment Variables in Config Files ---
process_file() {
    local file="$1"
    echo "Processing $file"
    tmp_file=$(mktemp) || { echo "Failed to create temporary file"; exit 1; }

    gawk -f - "$file" > "$tmp_file" << 'AWK_EOF'
{
    line = $0
    output = ""
    pos = 1
    # Match only unbraced variables: $ followed immediately by a letter or underscore.
    while (match(substr(line, pos), /\$[A-Za-z_][A-Za-z0-9_]*/)) {
        rstart = pos + RSTART - 1
        # Append text before the match.
        output = output substr(line, pos, RSTART - 1)
        # Extract the variable name (skip the $).
        var = substr(line, rstart+1, RLENGTH-1)
        if (var in ENVIRON) {
            # Replace with the environment variable's value.
            output = output ENVIRON[var]
        } else {
            # Leave unchanged if not found.
            output = output substr(line, rstart, RLENGTH)
        }
        pos = rstart + RLENGTH
    }
    # Append the remainder of the line.
    output = output substr(line, pos)
    print output
}
AWK_EOF

    mv "$tmp_file" "$file"
}

# Process all files in CONFIG_DIR
while IFS= read -r -d '' file; do
    process_file "$file"
done < <(find "$CONFIG_DIR" -type f -print0)

# Process server.properties
if [[ -n "$SERVER_PROPERTIES" && -f "$SERVER_PROPERTIES" ]]; then
    process_file "$SERVER_PROPERTIES"
fi

echo "Environment variable substitution complete."

# --- Start the Server ---
echo "Starting the Fabric server..."
java -Xms"${MEM_MIN}M" -Xmx"${MEM_MAX}M" -jar fabric.jar nogui

