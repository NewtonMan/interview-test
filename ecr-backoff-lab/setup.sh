#!/bin/bash
# Builds a fake "ECR" (registry with TLS + basic auth) without apt-get:
# everything runs as containers via containerd (ctr), in a namespace that is
# invisible to kubelet/crictl. Host dependencies: bash, curl, openssl, ssh.
set -euo pipefail
exec > /var/log/scenario-setup.log 2>&1

# --- progress + timing ---
# /var/log/scenario-timing.log : one line per step with its duration (for you)
# /tmp/.setup-progress         : neutral step label shown to the candidate
TIMING=/var/log/scenario-timing.log
SETUP_START=$(date +%s)
STEP_NUM=0
TOTAL_STEPS=11
STEP_NAME=""
: > "$TIMING"
step() {  # $1 = detailed name (log only), $2 = neutral label (candidate)
  local now; now=$(date +%s)
  if [ -n "$STEP_NAME" ]; then
    echo "[$(date +%T)] done  ($((now - STEP_START))s) $STEP_NAME" >> "$TIMING"
  fi
  STEP_NUM=$((STEP_NUM + 1))
  STEP_NAME=$1
  STEP_START=$now
  echo "[$(date +%T)] start $STEP_NUM/$TOTAL_STEPS $1" >> "$TIMING"
  echo "==== [$(date +%T)] STEP $STEP_NUM/$TOTAL_STEPS: $1 ===="
  echo "Step $STEP_NUM/$TOTAL_STEPS: $2" > /tmp/.setup-progress
}
on_error() {
  local rc=$? line=$1 now; now=$(date +%s)
  echo "[$(date +%T)] FAIL  ($((now - STEP_START))s) $STEP_NAME (line $line, exit $rc)" >> "$TIMING"
  echo "Step $STEP_NUM/$TOTAL_STEPS" > /tmp/.setup-failed
}
trap 'on_error $LINENO' ERR

ACCOUNT=123456789012
REGION=us-east-1
HOST="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${HOST}/payments-api:1.4.2"
DIR=/opt/mock-ecr
WORKER=node01
SSH="ssh -o StrictHostKeyChecking=no"
SCP="scp -o StrictHostKeyChecking=no"
CTR="ctr -n lab"   # separate namespace: hidden from crictl and kubectl
CP_IP=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

mkdir -p "$DIR/data"
cd "$DIR"

step "install candidate tools (upterm, share-terminal, aws mock)" "Installing tools"
# Candidate tools first, so they exist even while (or if) the rest of setup runs.
# --- upterm (read-only terminal sharing; tmate's public servers are gone) ---
command -v upterm >/dev/null || {
  curl -fsSL https://github.com/owenthereal/upterm/releases/latest/download/upterm_linux_amd64.tar.gz \
    | tar xz -C /usr/local/bin upterm &&
  chmod +x /usr/local/bin/upterm
} || echo "warning: upterm not installed"

cat > /usr/local/bin/share-terminal <<'EOF'
#!/bin/bash
if [ -n "${UPTERM_ADMIN_SOCKET:-}" ]; then
  echo "You're already sharing. Session info:"
  upterm session current
  exit 0
fi
echo "Starting a read-only shared session."
echo "If asked about the host's authenticity, type: yes"
echo "Then copy the full 'ssh ...' line below and send it to your interviewer."
echo
exec upterm host --read-only --server wss://uptermd.upterm.dev -- bash
EOF
chmod +x /usr/local/bin/share-terminal

# --- simulated AWS CLI ---
cat > /usr/local/bin/aws <<EOF
#!/bin/bash
case "\$*" in
  *"ecr get-login-password"*)
    cat ${DIR}/.token; echo ;;
  *"sts get-caller-identity"*)
    echo '{"UserId":"AIDAXXXXXXXXXXXXXXXXX","Account":"${ACCOUNT}","Arn":"arn:aws:iam::${ACCOUNT}:user/sre-oncall"}' ;;
  *"ecr describe-repositories"*)
    echo '{"repositories":[{"repositoryName":"payments-api","repositoryUri":"${HOST}/payments-api"}]}' ;;
  *"ecr describe-images"*)
    echo '{"imageDetails":[{"repositoryName":"payments-api","imageTags":["1.4.2"]}]}' ;;
  *"--version"*)
    echo "aws-cli/2.17.0 Python/3.11.9 Linux/x86_64" ;;
  *)
    echo "This command is not available in this environment: aws \$*" >&2; exit 1 ;;
esac
EOF
chmod +x /usr/local/bin/aws


step "pull helper images (registry, httpd, nginx)" "Downloading images"
# --- helper images ---
# Docker Hub rate-limits anonymous pulls, and Killercoda IPs are shared,
# so try public mirrors of the official images first, with retries.
pull_first() {  # $1 = extra pull flags ("" for none), rest = candidate refs
  local flags=$1 ref i; shift
  for ref in "$@"; do
    for i in 1 2 3; do
      echo "[$(date +%T)] pulling $ref (attempt $i)" >&2
      if $CTR images pull $flags "$ref" >/dev/null 2>&1; then
        echo "[$(date +%T)] pulled $ref" >&2
        echo "  pulled $ref" >> "$TIMING"
        echo "$ref"; return 0
      fi
      echo "  pull failed: $ref (attempt $i)" >> "$TIMING"
      sleep $((i * 3))
    done
  done
  echo "could not pull any of: $*" >&2
  return 1
}
REGISTRY_IMG=$(pull_first "" \
  public.ecr.aws/docker/library/registry:2 \
  mirror.gcr.io/library/registry:2 \
  docker.io/library/registry:2)
HTTPD_IMG=$(pull_first "" \
  public.ecr.aws/docker/library/httpd:2-alpine \
  mirror.gcr.io/library/httpd:2-alpine \
  docker.io/library/httpd:2-alpine)
SRC_IMAGE=$(pull_first "--all-platforms" \
  public.ecr.aws/docker/library/nginx:1.27-alpine \
  mirror.gcr.io/library/nginx:1.27-alpine \
  docker.io/library/nginx:1.27-alpine)
echo "using images: $REGISTRY_IMG $HTTPD_IMG $SRC_IMAGE"

step "generate tokens and htpasswd" "Generating credentials"
# --- ECR-style tokens (base64 of a JSON with an expiration) ---
make_token() {
  local payload
  payload=$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n')
  echo -n "{\"payload\":\"${payload}\",\"datakey\":\"AQEBAHhm0YaISJeRtJm5n1G6uqeekXuoXXPe5UFce9Rq8\",\"version\":\"2\",\"type\":\"DATA_KEY\",\"expiration\":$1}" | base64 | tr -d '\n'
}
NOW=$(date +%s)
OLD_TOKEN=$(make_token $((NOW - 26*3600)))   # expired ~1 day ago
NEW_TOKEN=$(make_token $((NOW + 12*3600)))   # valid for 12h, like real ECR
echo -n "$NEW_TOKEN" > .token
chmod 600 .token

# --- htpasswd generated in a container (no apache2-utils on the host) ---
$CTR run --rm "$HTTPD_IMG" htpasswd-gen \
  /usr/local/apache2/bin/htpasswd -Bbn AWS "$NEW_TOKEN" > htpasswd

step "generate CA and TLS certificate" "Generating certificates"
# --- TLS: own CA + certificate for the ECR hostname ---
openssl genrsa -out ca.key 2048
openssl req -x509 -new -key ca.key -days 30 -subj "/CN=Mock ECR CA" -out ca.crt
openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -subj "/CN=${HOST}" -out tls.csr
printf "subjectAltName=DNS:%s\n" "$HOST" > san.ext
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile san.ext -out tls.crt

step "start fake ECR registry container" "Starting services"
# --- registry as a container ---
cat > config.yml <<EOF
version: 0.1
storage:
  filesystem:
    rootdirectory: ${DIR}/data
http:
  addr: 0.0.0.0:443
  tls:
    certificate: ${DIR}/tls.crt
    key: ${DIR}/tls.key
auth:
  htpasswd:
    realm: ecr
    path: ${DIR}/htpasswd
EOF

$CTR run -d --net-host \
  --mount "type=bind,src=${DIR},dst=${DIR},options=rbind:rw" \
  "$REGISTRY_IMG" registry \
  /bin/registry serve "${DIR}/config.yml"

step "configure nodes (hosts + CA trust)" "Configuring nodes"
# --- per-node setup: DNS + CA trust ---
# Preferred: containerd hosts.toml (distro-agnostic, no restart needed).
# Fallback: system CA store (Debian/Ubuntu or RHEL) + containerd restart.
cat > node-setup.sh <<'NODE'
#!/bin/bash
set -euo pipefail
HOST=$1; CP_IP=$2; CA=$3
grep -q "$HOST" /etc/hosts || echo "$CP_IP $HOST" >> /etc/hosts
CONFIG_PATH=$(containerd config dump 2>/dev/null \
  | awk -F'"' '/^[[:space:]]*config_path[[:space:]]*=/ && $2!="" {print $2; exit}')
if [ -n "$CONFIG_PATH" ]; then
  mkdir -p "$CONFIG_PATH/$HOST"
  cp "$CA" "$CONFIG_PATH/$HOST/ca.crt"
  cat > "$CONFIG_PATH/$HOST/hosts.toml" <<TOML
server = "https://$HOST"

[host."https://$HOST"]
  capabilities = ["pull", "resolve"]
  ca = "$CONFIG_PATH/$HOST/ca.crt"
TOML
  echo "CA trusted via hosts.toml in $CONFIG_PATH"
elif command -v update-ca-certificates >/dev/null; then
  cp "$CA" /usr/local/share/ca-certificates/mock-ecr.crt
  update-ca-certificates
  systemctl restart containerd
  echo "CA trusted via update-ca-certificates"
elif command -v update-ca-trust >/dev/null; then
  cp "$CA" /etc/pki/ca-trust/source/anchors/mock-ecr.crt
  update-ca-trust
  systemctl restart containerd
  echo "CA trusted via update-ca-trust"
else
  echo "no method available to trust the CA" >&2
  exit 1
fi
NODE
chmod +x node-setup.sh

./node-setup.sh "$HOST" "$CP_IP" "${DIR}/ca.crt"
$SCP node-setup.sh ca.crt ${WORKER}:/tmp/
$SSH $WORKER "bash /tmp/node-setup.sh '$HOST' '$CP_IP' /tmp/ca.crt && rm -f /tmp/node-setup.sh /tmp/ca.crt"

step "wait for registry and nodes Ready" "Waiting for the cluster"
until curl -ks -o /dev/null "https://${HOST}/v2/"; do sleep 1; done
until kubectl get nodes >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=Ready nodes --all --timeout=180s

step "push image to fake ECR" "Publishing application image"
# --- push the image to the "ECR" using ctr itself ---
$CTR images tag "$SRC_IMAGE" "$IMAGE"
# containerd v2 requires --local with --skip-verify; older ctr has no --local
$CTR images push --local -k --user "AWS:${NEW_TOKEN}" "$IMAGE" >/dev/null \
  || $CTR images push -k --user "AWS:${NEW_TOKEN}" "$IMAGE" >/dev/null
$CTR images rm "$IMAGE" "$SRC_IMAGE" >/dev/null

step "pre-pull image on both nodes" "Preparing nodes"
# --- pre-pull on the nodes via CRI (this is why the worker "works") ---
crictl pull --creds "AWS:${NEW_TOKEN}" "$IMAGE"
$SSH $WORKER "crictl pull --creds 'AWS:${NEW_TOKEN}' '$IMAGE'"

step "create namespace, secret and deployments" "Deploying applications"
# --- broken workload ---
kubectl create namespace payments
kubectl create secret docker-registry ecr-registry -n payments \
  --docker-server="$HOST" --docker-username=AWS --docker-password="$OLD_TOKEN"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-worker
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels: {app: payments-worker}
  template:
    metadata:
      labels: {app: payments-worker}
    spec:
      imagePullSecrets: [{name: ecr-registry}]
      containers:
        - name: worker
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels: {app: payments-api}
  template:
    metadata:
      labels: {app: payments-api}
    spec:
      imagePullSecrets: [{name: ecr-registry}]
      containers:
        - name: api
          image: ${IMAGE}
          imagePullPolicy: Always
          ports: [{containerPort: 80}]
EOF

step "finalize" "Finishing up"
echo "[$(date +%T)] done  (0s) finalize" >> "$TIMING"
echo "[$(date +%T)] TOTAL $(( $(date +%s) - SETUP_START ))s" >> "$TIMING"
echo "Ready" > /tmp/.setup-progress
touch /tmp/.setup-done