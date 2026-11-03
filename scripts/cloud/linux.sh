#!/usr/bin/env bash
# Temporary Linux test machine on DigitalOcean (doctl must be authenticated).
# Create per session, destroy afterwards.
#
#   ./scripts/cloud/linux.sh up        create the droplet and install Odin, clang, ALSA loopback
#   ./scripts/cloud/linux.sh sync      copy the committed tree (git archive HEAD) to ~/fire_engine
#   ./scripts/cloud/linux.sh test [..] sync, then run ./scripts/test.sh there (args/env passed on)
#   ./scripts/cloud/linux.sh ssh [cmd] shell or command on the droplet
#   ./scripts/cloud/linux.sh down      destroy the droplet
#   ./scripts/cloud/linux.sh status
#
# Env: FIRE_DROPLET (name, default fire-engine-linux), FIRE_DO_REGION (nyc3),
#      FIRE_DO_SIZE (s-2vcpu-4gb), FIRE_DO_IMAGE (ubuntu-24-04-x64),
#      FIRE_SSH_KEY (~/.ssh/fire_engine_do; its .pub must be registered at DigitalOcean)
#
# Only `git archive HEAD` is copied: untracked files (secrets.env, JUCE/, ...)
# never leave this machine. Commit before testing.
set -euo pipefail

NAME="${FIRE_DROPLET:-fire-engine-linux}"
REGION="${FIRE_DO_REGION:-nyc3}"
SIZE="${FIRE_DO_SIZE:-s-2vcpu-4gb}"
IMAGE="${FIRE_DO_IMAGE:-ubuntu-24-04-x64}"
KEY="${FIRE_SSH_KEY:-$HOME/.ssh/fire_engine_do}"
ODIN_RELEASE="dev-2026-10" # keep in sync with .github/workflows/ci.yml
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/fire_engine_known_hosts" -o ConnectTimeout=10)

ip() {
	doctl compute droplet list --format Name,PublicIPv4 --no-header | awk -v n="$NAME" '$1 == n { print $2 }'
}

remote() {
	local addr; addr="$(ip)"
	[ -n "$addr" ] || { echo "no droplet named $NAME (run: $0 up)" >&2; exit 1; }
	ssh "${SSH_OPTS[@]}" "root@$addr" "$@"
}

cloud_init() {
	cat <<EOF
#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y clang llvm python3 alsa-utils libasound2-dev "linux-modules-extra-\$(uname -r)" || apt-get install -y clang llvm python3 alsa-utils libasound2-dev
# ALSA loopback: a virtual sound card whose playback reappears as capture,
# the Linux counterpart of BlackHole. Load now and at boot.
modprobe snd-aloop || true
echo snd-aloop > /etc/modules-load.d/snd-aloop.conf
mkdir -p /opt/odin
curl -fsSL "https://github.com/odin-lang/Odin/releases/download/$ODIN_RELEASE/odin-linux-amd64-$ODIN_RELEASE.tar.gz" | tar -xz -C /opt/odin --strip-components=1
ln -sf /opt/odin/odin /usr/local/bin/odin
touch /root/fire_setup_done
EOF
}

case "${1:-}" in
up)
	if [ -n "$(ip)" ]; then echo "$NAME already exists at $(ip)"; exit 0; fi
	fp="$(ssh-keygen -l -E md5 -f "$KEY.pub" | awk '{print $2}' | sed 's/^MD5://')"
	echo "creating $NAME ($SIZE, $IMAGE, $REGION)..."
	doctl compute droplet create "$NAME" --region "$REGION" --size "$SIZE" --image "$IMAGE" \
		--ssh-keys "$fp" --tag-name fire-engine --user-data "$(cloud_init)" --wait --format Name,PublicIPv4,Status
	echo "waiting for SSH and setup..."
	for _ in $(seq 1 90); do
		if remote test -f /root/fire_setup_done 2>/dev/null; then break; fi
		sleep 5
	done
	remote 'odin version && clang --version | head -1 && (lsmod | grep -q snd_aloop && echo "snd-aloop loaded" || echo "snd-aloop NOT loaded")'
	;;
sync)
	echo "copying HEAD ($(git -C "$ROOT" rev-parse --short HEAD)) to $NAME..."
	git -C "$ROOT" diff --quiet HEAD || echo "note: uncommitted changes are not copied"
	git -C "$ROOT" archive --format=tar HEAD | remote 'rm -rf ~/fire_engine && mkdir -p ~/fire_engine && tar -x -C ~/fire_engine'
	;;
test)
	shift
	"$0" sync
	remote "cd ~/fire_engine && FIRE_OPT='${FIRE_OPT:-none speed}' FIRE_NO_PLOT=1 ./scripts/test.sh $*"
	;;
ssh)
	shift
	remote "$@"
	;;
down)
	if [ -z "$(ip)" ]; then echo "no droplet named $NAME"; exit 0; fi
	doctl compute droplet delete "$NAME" --force
	echo "destroyed $NAME"
	;;
status)
	doctl compute droplet list --tag-name fire-engine --format Name,PublicIPv4,Status,Memory,VCPUs,Region
	;;
*)
	sed -n '2,15p' "$0"
	exit 1
	;;
esac
