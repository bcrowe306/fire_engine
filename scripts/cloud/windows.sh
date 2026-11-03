#!/usr/bin/env bash
# Windows Server test machine on AWS EC2, for WASAPI. Kept between sessions and
# stopped when idle (only its disk is billed while stopped; `down` terminates).
# AWS keys come from secrets.env (AWS_ACCESS_KEY, AWS_SECRET_ACCESS_KEY).
#
#   ./scripts/cloud/windows.sh up        start (or create: OpenSSH, VS Build Tools, Git, Odin, VB-CABLE)
#   ./scripts/cloud/windows.sh sync      copy the working tree to C:\fire
#   ./scripts/cloud/windows.sh test [..] sync, then run scripts/test.sh there (args/env passed on)
#   ./scripts/cloud/windows.sh ssh [cmd] PowerShell command (or shell) on the instance
#   ./scripts/cloud/windows.sh off       stop the instance (end of session)
#   ./scripts/cloud/windows.sh down      terminate it and delete its security group
#   ./scripts/cloud/windows.sh status
#
# Env: FIRE_AWS_REGION (us-east-2), FIRE_AWS_TYPE (m7i-flex.large),
#      FIRE_SSH_KEY (~/.ssh/fire_engine_do; its .pub is installed on the instance)
#
# Only files git would consider (tracked, or untracked and not ignored) are
# copied, so ignored files (secrets.env, JUCE/, build output) never leave this machine.
set -euo pipefail

NAME="fire-engine-windows"
SG_NAME="fire-engine-ssh"
TYPE="${FIRE_AWS_TYPE:-m7i-flex.large}" # 2 vCPU, 8 GB; Free-plan eligible (t3.large is not)
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

SSH_OPTS=(-i "$KEY" -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/fire_engine_known_hosts" -o ConnectTimeout=10)

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
	ssh "${SSH_OPTS[@]}" "Administrator@$(ip "$id")" "$@"
}

# Port 22 open to this machine's current public IP only.
security_group() {
	local sg my_ip
	sg="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
	if [ -z "$sg" ] || [ "$sg" = "None" ]; then
		sg="$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Fire Engine test SSH" --query GroupId --output text)"
	fi
	my_ip="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
	aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$my_ip/32" >/dev/null 2>&1 || true
	echo "$sg"
}

user_data() {
	local pubkey; pubkey="$(cat "$KEY.pub")"
	cat <<EOF
<powershell>
\$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\\fire_setup.log -Append
# SSH: key auth for Administrator, PowerShell as the default shell.
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue
Set-Content -Path C:\\ProgramData\\ssh\\administrators_authorized_keys -Value "$pubkey" -Encoding ascii
icacls C:\\ProgramData\\ssh\\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
New-ItemProperty -Path "HKLM:\\SOFTWARE\\OpenSSH" -Name DefaultShell -Value "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -PropertyType String -Force
# Audio services are disabled on Windows Server.
Set-Service AudioEndpointBuilder -StartupType Automatic
Set-Service Audiosrv -StartupType Automatic
Start-Service AudioEndpointBuilder
Start-Service Audiosrv
# Toolchain: MSVC linker + Windows SDK (Odin needs them), Git (bash for test.sh), Python (plots).
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
C:\\ProgramData\\chocolatey\\bin\\choco.exe install -y --no-progress git python3
C:\\ProgramData\\chocolatey\\bin\\choco.exe install -y --no-progress visualstudio2022buildtools --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart"
# Odin
Invoke-WebRequest -UseBasicParsing "https://github.com/odin-lang/Odin/releases/download/$ODIN_RELEASE/odin-windows-amd64-$ODIN_RELEASE.zip" -OutFile C:\\odin.zip
Expand-Archive C:\\odin.zip C:\\odin_unpack -Force
\$odin = (Get-ChildItem C:\\odin_unpack -Recurse -Filter odin.exe | Select-Object -First 1).DirectoryName
\$path = [Environment]::GetEnvironmentVariable("Path", "Machine")
[Environment]::SetEnvironmentVariable("Path", "\$path;\$odin;C:\\Program Files\\Git\\bin", "Machine")
# VB-CABLE: a virtual playback→recording cable (the counterpart of BlackHole).
# Trust its signer first so the silent install doesn't wait on a prompt.
Invoke-WebRequest -UseBasicParsing "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip" -OutFile C:\\vbcable.zip
Expand-Archive C:\\vbcable.zip C:\\vbcable -Force
Get-ChildItem C:\\vbcable -Filter *.cat | ForEach-Object {
	\$cert = (Get-AuthenticodeSignature \$_.FullName).SignerCertificate
	if (\$cert) {
		\$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
		\$store.Open("ReadWrite"); \$store.Add(\$cert); \$store.Close()
	}
}
Start-Process -FilePath C:\\vbcable\\VBCABLE_Setup_x64.exe -ArgumentList "-i","-h" -Wait
New-Item -ItemType File -Path C:\\fire_setup_done -Force
Stop-Transcript
Restart-Computer -Force
</powershell>
EOF
}

wait_ssh() {
	for _ in $(seq 1 120); do remote 'exit 0' >/dev/null 2>&1 && return 0; sleep 10; done
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
		exit 0
	fi
	sg="$(security_group)"
	ami="$(aws ssm get-parameter --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base --query Parameter.Value --output text)"
	echo "creating $NAME ($TYPE, $ami)..."
	id="$(aws ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --security-group-ids "$sg" \
		--block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3}' \
		--user-data "$(user_data)" \
		--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=project,Value=fire-engine}]" \
		--query 'Instances[0].InstanceId' --output text)"
	aws ec2 wait instance-running --instance-ids "$id"
	echo "$id running at $(ip "$id"); first-boot setup takes ~30 min (VS Build Tools)..."
	wait_ssh
	for _ in $(seq 1 120); do
		remote 'if (Test-Path C:\fire_setup_done) { exit 0 } else { exit 1 }' >/dev/null 2>&1 && break
		sleep 30
	done
	sleep 60 # the setup ends with a reboot
	wait_ssh
	remote 'odin version; Get-PnpDevice -Class AudioEndpoint | Select-Object -ExpandProperty FriendlyName'
	;;
sync)
	echo "copying working tree ($(git -C "$ROOT" rev-parse --short HEAD) + local changes) to $NAME..."
	tmp="$(mktemp -t fire_sync).tar"
	(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard |
		while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done |
		tar --null -T - -cf "$tmp")
	scp -q "${SSH_OPTS[@]}" "$tmp" "Administrator@$(ip "$(instance_id)"):C:/fire.tar"
	rm -f "$tmp"
	remote 'if (Test-Path C:\fire) { Remove-Item -Recurse -Force C:\fire }; New-Item -ItemType Directory C:\fire | Out-Null; tar.exe -xf C:\fire.tar -C C:\fire'
	;;
test)
	shift
	"$0" sync
	remote "\$env:FIRE_OPT='${FIRE_OPT:-none speed}'; \$env:FIRE_NO_PLOT='1'; cd C:\\fire; & 'C:\\Program Files\\Git\\bin\\bash.exe' scripts/test.sh $*"
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
	echo "$NAME stopped (its 60 GB disk is still billed; '$0 down' terminates it)"
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
	aws ec2 describe-instances --filters "Name=tag:project,Values=fire-engine" \
		--query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,InstanceType,PublicIpAddress]' --output table
	;;
*)
	sed -n '2,16p' "$0"
	exit 1
	;;
esac
