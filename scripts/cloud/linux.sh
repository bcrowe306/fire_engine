#!/usr/bin/env bash
# Linux test machine on DigitalOcean (doctl must be authenticated). Kept between
# sessions and powered off when idle. A powered-off droplet is still billed;
# `down` destroys it.
#
#   ./scripts/cloud/linux.sh up        power on (or create: Odin, clang, CMake, ALSA loopback, jackd)
#   ./scripts/cloud/linux.sh sync      copy the working tree to ~/fire_engine
#   ./scripts/cloud/linux.sh test [..] sync, then run ./scripts/test.sh there (args/env passed on)
#   ./scripts/cloud/linux.sh ssh [cmd] shell or command on the droplet
#   ./scripts/cloud/linux.sh off       power off (end of session)
#   ./scripts/cloud/linux.sh down      destroy the droplet
#   ./scripts/cloud/linux.sh status
#
# Env: FIRE_DROPLET (name, default fire-engine-linux), FIRE_DO_REGION (nyc3),
#      FIRE_DO_SIZE (s-2vcpu-4gb), FIRE_DO_IMAGE (ubuntu-24-04-x64),
#      FIRE_SSH_KEY (~/.ssh/fire_engine_do; its .pub must be registered at DigitalOcean)
#
# Only files git would consider (tracked, or untracked and not ignored) are
# copied, so ignored files (secrets.env, JUCE/, build output) never leave this machine.
# What `task deps` fetched and built there (.deps/, the static libraries) is kept across syncs.
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

droplet_id() {
	doctl compute droplet list --format Name,ID --no-header | awk -v n="$NAME" '$1 == n { print $2 }'
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
echo "jackd2 jackd/tweak_rt_limits boolean false" | debconf-set-selections
apt-get install -y clang llvm g++ cmake python3 alsa-utils libasound2-dev jackd2 "linux-modules-extra-\$(uname -r)" || apt-get install -y clang llvm g++ cmake python3 alsa-utils libasound2-dev jackd2
# ALSA loopback: a virtual sound card whose playback reappears as capture,
# the Linux counterpart of BlackHole. Load now and at boot.
modprobe snd-aloop || true
modprobe snd-seq || true
printf "snd-aloop\nsnd-seq\n" > /etc/modules-load.d/snd-aloop.conf
# The app layer: SDL3's build dependencies, Mesa's software Vulkan (lavapipe)
# so headless UI tests can draw without a GPU, and Task.
apt-get install -y build-essential pkg-config ninja-build python3-venv libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev libxi-dev libxss-dev libxtst-dev libxkbcommon-dev libdrm-dev libgbm-dev libgl1-mesa-dev libgles2-mesa-dev libegl1-mesa-dev libdbus-1-dev libudev-dev libpulse-dev libwayland-dev libdecor-0-dev mesa-vulkan-drivers libvulkan1 libvulkan-dev
snap install task --classic
mkdir -p /opt/odin
curl -fsSL "https://github.com/odin-lang/Odin/releases/download/$ODIN_RELEASE/odin-linux-amd64-$ODIN_RELEASE.tar.gz" | tar -xz -C /opt/odin --strip-components=1
ln -sf /opt/odin/odin /usr/local/bin/odin
touch /root/fire_setup_done
EOF
}

case "${1:-}" in
up)
	if [ -n "$(ip)" ]; then
		status="$(doctl compute droplet list --format Name,Status --no-header | awk -v n="$NAME" '$1 == n { print $2 }')"
		if [ "$status" = "off" ]; then
			echo "powering on $NAME..."
			doctl compute droplet-action power-on "$(droplet_id)" --wait >/dev/null
		fi
		for _ in $(seq 1 60); do remote true 2>/dev/null && break; sleep 3; done
		echo "$NAME is up at $(ip)"
		remote 'lsmod | grep -q snd_aloop && echo "snd-aloop loaded" || echo "snd-aloop NOT loaded"'
		exit 0
	fi
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
	echo "copying working tree ($(git -C "$ROOT" rev-parse --short HEAD) + local changes) to $NAME..."
	(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard |
		while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done |
		COPYFILE_DISABLE=1 tar --null -T - -cf -) |
		remote 'cd ~ && (cd fire_engine 2>/dev/null && tar -cf ~/.fire_keep.tar vendor/sdl3/lib vendor/imgui/libimgui_* 2>/dev/null; [ -d .deps ] && rm -rf ~/.fire_deps && mv .deps ~/.fire_deps); rm -rf ~/fire_engine && mkdir -p ~/fire_engine && tar -x -C ~/fire_engine 2>/dev/null; [ -f ~/.fire_keep.tar ] && tar -xf ~/.fire_keep.tar -C ~/fire_engine && rm -f ~/.fire_keep.tar; [ -d ~/.fire_deps ] && mv ~/.fire_deps ~/fire_engine/.deps; true'
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
off)
	if [ -z "$(ip)" ]; then echo "no droplet named $NAME"; exit 0; fi
	doctl compute droplet-action power-off "$(droplet_id)" --wait >/dev/null
	echo "$NAME powered off (still billed while it exists; '$0 down' destroys it)"
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
	sed -n '2,16p' "$0"
	exit 1
	;;
esac
