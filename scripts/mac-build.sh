#!/usr/bin/env bash
# Sync the project to a Mac (or macOS VM) over SSH and compile it there, unsigned.
# Usage: MAC_HOST=admin@192.168.1.50 scripts/mac-build.sh
#    or, through a reverse tunnel: MAC_HOST=admin@localhost MAC_PORT=2222 scripts/mac-build.sh
set -euo pipefail

HOST=${MAC_HOST:?set MAC_HOST=user@host}
KEY=${MAC_KEY:-$HOME/.ssh/cstimer_build}
PORT=${MAC_PORT:-22}
SSH="ssh -p $PORT -i $KEY -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

cd "$(dirname "$0")/.."

if ! $SSH "$HOST" true 2>/dev/null; then
	echo "Mac build host $HOST is unreachable (asleep, offline, or IP changed)." >&2
	exit 2
fi

rsync -az --delete -e "$SSH" --exclude .git --exclude '*.xcodeproj' ./ "$HOST":cstimer-ios/

# Output is also appended to ~/build.log in the VM, so `tail -f ~/build.log` there shows builds live.
$SSH "$HOST" 'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
	set -o pipefail
	{ echo "=== build $(date) ==="
	cd cstimer-ios &&
	xcodegen generate --quiet &&
	xcodebuild -project CstimerBT.xcodeproj -scheme CstimerBT \
		-destination generic/platform=iOS -configuration Debug \
		CODE_SIGNING_ALLOWED=NO build -quiet; } 2>&1 | tee -a ~/build.log'
