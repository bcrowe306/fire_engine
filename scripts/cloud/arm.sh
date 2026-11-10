#!/usr/bin/env bash
# ARM64 Linux test machine on AWS EC2 (Graviton), standing in for single-board
# computers like the Raspberry Pi. Kept between sessions and stopped when idle
# (only its disk is billed while stopped; `down` terminates).
#
#   ./scripts/cloud/arm.sh up        start (or create: Odin, clang, CMake, ALSA loopback, jackd)
#   ./scripts/cloud/arm.sh sync      copy the working tree to ~/fire_engine
#   ./scripts/cloud/arm.sh test [..] sync, then run ./scripts/test.sh there (args/env passed on)
#   ./scripts/cloud/arm.sh ssh [cmd] shell or command on the instance
#   ./scripts/cloud/arm.sh off       stop the instance (end of session)
#   ./scripts/cloud/arm.sh down      terminate it and delete its security group
#   ./scripts/cloud/arm.sh status
#
# Env: FIRE_AWS_REGION (us-east-2), FIRE_AWS_ARM_TYPE (t4g.small),
#      FIRE_SSH_KEY (~/.ssh/fire_engine_do; installed on the instance at creation)
# AWS keys come from secrets.env (AWS_ACCESS_KEY, AWS_SECRET_ACCESS_KEY).
#
# Only files git would consider (tracked, or untracked and not ignored) are
# copied, so ignored files (secrets.env, JUCE/, build output) never leave this machine.
# What `task deps` fetched and built there (.deps/, the static libraries) is kept across syncs.
set -euo pipefail

NAME="fire-engine-arm"
SG_NAME="fire-engine-arm-ssh"
TYPE="${FIRE_AWS_ARM_TYPE:-t4g.small}" # 2 vCPU, 2 GB, like a small Pi; Free-plan eligible
KEY="${FIRE_SSH_KEY:-$HOME/.ssh/fire_engine_do}"
ODIN_RELEASE="dev-2026-10" # keep in sync with .github/workflows/ci.yml
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Credentials: secrets.env names the key ID AWS_ACCESS_KEY.
set -a
# shellcheck disable=SC1091
. "$ROOT/secrets.env"
set +a
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY:-}}"
export AWS_DEFAULT_REGION="${FIRE_AWS_REGION:-us-east-2}" # the org policy allows EC2 only in us-east-2
unset DIGITAL_OCEAN_ACCESS_TOKEN

SSH_OPTS=(-i "$KEY" -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/fire_engine_known_hosts" -o ConnectTimeout=10 -o ServerAliveInterval=30)

instance_id() {
	aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" \
		"Name=instance-state-name,Values=pending,running,stopping,stopped" \
		--query 'Reservations[].Instances[].InstanceId' --output text
}

state() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].State.Name' --output text; }
ip() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

remote() {
	local id; id="$(instance_id)"
	[ -n "$id" ] || { echo "no instance named $NAME (run: $0 up)" >&2; exit 1; }
	ssh "${SSH_OPTS[@]}" "ubuntu@$(ip "$id")" "$@"
}

# Port 22 open to this machine's current public IP only.
security_group() {
	local sg my_ip
	sg="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
	if [ -z "$sg" ] || [ "$sg" = "None" ]; then
		sg="$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Fire Engine ARM test SSH" --query GroupId --output text)"
	fi
	my_ip="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
	aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$my_ip/32" >/dev/null 2>&1 || true
	echo "$sg"
}

user_data() {
	local pubkey; pubkey="$(cat "$KEY.pub")"
	cat <<EOF
#!/bin/bash
set -eux
echo "$pubkey" >> /home/ubuntu/.ssh/authorized_keys
# 2 GB of memory: swap so parallel builds slow down instead of dying.
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
export DEBIAN_FRONTEND=noninteractive
apt-get update
echo "jackd2 jackd/tweak_rt_limits boolean false" | debconf-set-selections
apt-get install -y clang llvm g++ cmake python3 alsa-utils libasound2-dev jackd2 "linux-modules-extra-\$(uname -r)" || apt-get install -y clang llvm g++ cmake python3 alsa-utils libasound2-dev jackd2
# ALSA loopback: a virtual sound card whose playback reappears as capture.
# The AWS arm64 kernel may ship without it (no linux-modules-extra for it);
# then the ALSA device tests skip.
modprobe snd-aloop || true
modprobe snd-seq || true
printf "snd-aloop\nsnd-seq\n" > /etc/modules-load.d/snd-aloop.conf
usermod -aG audio ubuntu
# The app layer: SDL3's build dependencies, Mesa's software Vulkan (lavapipe)
# so headless UI tests can draw without a GPU, and Task.
apt-get install -y build-essential pkg-config ninja-build python3-venv libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev libxi-dev libxss-dev libxtst-dev libxkbcommon-dev libdrm-dev libgbm-dev libgl1-mesa-dev libgles2-mesa-dev libegl1-mesa-dev libdbus-1-dev libudev-dev libpulse-dev libwayland-dev libdecor-0-dev mesa-vulkan-drivers libvulkan1 libvulkan-dev
snap install task --classic
mkdir -p /opt/odin
curl -fsSL "https://github.com/odin-lang/Odin/releases/download/$ODIN_RELEASE/odin-linux-arm64-$ODIN_RELEASE.tar.gz" | tar -xz -C /opt/odin --strip-components=1
ln -sf /opt/odin/odin /usr/local/bin/odin
# miniaudio, for fire:audiofile/codecs.
(cd /tmp && bash /opt/odin/vendor/miniaudio/src/build_miniaudio.sh)
touch /home/ubuntu/fire_setup_done
EOF
}

wait_ssh() {
	for _ in $(seq 1 60); do remote 'exit 0' >/dev/null 2>&1 && return 0; sleep 10; done
	echo "SSH did not come up" >&2; return 1
}

case "${1:-}" in
up)
	id="$(instance_id)"
	if [ -n "$id" ]; then
		security_group >/dev/null # refresh the allowed IP
		if [ "$(state "$id")" = "stopped" ]; then
			echo "starting $NAME ($id)..."
			aws ec2 start-instances --instance-ids "$id" >/dev/null
			aws ec2 wait instance-running --instance-ids "$id"
		fi
		wait_ssh
		echo "$NAME is up at $(ip "$id")"
		remote 'lsmod | grep -q snd_aloop && echo "snd-aloop loaded" || echo "snd-aloop NOT loaded"'
		exit 0
	fi
	sg="$(security_group)"
	ami="$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)"
	echo "creating $NAME ($TYPE, $ami)..."
	id="$(aws ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --security-group-ids "$sg" \
		--block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
		--credit-specification CpuCredits=standard \
		--user-data "$(user_data)" \
		--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=project,Value=fire-engine}]" \
		--query 'Instances[0].InstanceId' --output text)"
	aws ec2 wait instance-running --instance-ids "$id"
	echo "$id running at $(ip "$id"); waiting for SSH and setup..."
	wait_ssh
	for _ in $(seq 1 90); do
		remote test -f /home/ubuntu/fire_setup_done 2>/dev/null && break
		sleep 10
	done
	remote 'odin version && clang --version | head -1 && uname -m && (lsmod | grep -q snd_aloop && echo "snd-aloop loaded" || echo "snd-aloop NOT loaded")'
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
	# 2 GB of memory: two packages at a time, and swap as a backstop.
	remote "cd ~/fire_engine && FIRE_OPT='${FIRE_OPT:-none speed}' FIRE_NO_PLOT=1 FIRE_JOBS='${FIRE_JOBS:-2}' ./scripts/test.sh $*"
	;;
ssh)
	shift
	remote "$@"
	;;
off)
	id="$(instance_id)"
	[ -n "$id" ] || { echo "no instance named $NAME"; exit 0; }
	aws ec2 stop-instances --instance-ids "$id" >/dev/null
	aws ec2 wait instance-stopped --instance-ids "$id"
	echo "$NAME stopped (its 20 GB disk is still billed; '$0 down' terminates it)"
	;;
down)
	id="$(instance_id)"
	if [ -n "$id" ]; then
		aws ec2 terminate-instances --instance-ids "$id" >/dev/null
		aws ec2 wait instance-terminated --instance-ids "$id"
		echo "terminated $NAME"
	fi
	aws ec2 delete-security-group --group-name "$SG_NAME" 2>/dev/null && echo "deleted $SG_NAME" || true
	;;
status)
	aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" \
		--query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,InstanceType,PublicIpAddress]' --output table
	;;
*)
	sed -n '2,17p' "$0"
	exit 1
	;;
esac
