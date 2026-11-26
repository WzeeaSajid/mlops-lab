#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
export DISPLAY=:99
if [[ "$1" == initial ]]; then Xvfb :99 -screen 0 1600x1000x24 >/tmp/xvfb.log 2>&1 &
sleep 1
fi
capture() {
  local n=$1 rows=$2
  local cmdfile="/tmp/cmd-$n.sh" marker="/tmp/done-$n"
  cat > "$cmdfile"
  xterm -T "Lab screenshot $n" -geometry "112x${rows}" -fa 'DejaVu Sans Mono' -fs 13 -bg '#11202a' -fg white -e bash -c 'bash -ev "$1"; result=$?; echo "$result" > "$2"; sleep 300' bash "$cmdfile" "$marker" &
  local term=$!
  for i in $(seq 1 180); do [[ -f "$marker" ]] && break; sleep 1; done
  test "$(cat "$marker")" = 0
  import -window "Lab screenshot $n" "evidence/$n.png"
  kill "$term" || true
}
wait_revision() {
 local sha=$1
 for i in $(seq 1 240); do
  if (( i % 6 == 1 )); then kubectl annotate app wine-classifier -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null; fi
  live=$(kubectl -n argocd get app wine-classifier -o json)
  if jq -e --arg sha "$sha" '.status.sync.revision==$sha and .status.sync.status=="Synced" and .status.health.status=="Healthy"' <<<"$live" >/dev/null; then return; fi
  sleep 5
 done
 kubectl describe app wine-classifier -n argocd
 return 1
}
port_forward() {
 port_pid=$(cat /tmp/port-worker 2>/dev/null || true)
 if [[ -n "${port_pid:-}" ]]; then kill "$port_pid" 2>/dev/null || true; wait "$port_pid" || true; fi
 kubectl port-forward svc/wine-classifier -n ml-serving 8001:8000 >/tmp/model-forward.log 2>&1 &
 port_pid=$!
 echo "$port_pid" >/tmp/port-worker
 curl --retry 25 --retry-connrefused --retry-delay 1 -fsS http://localhost:8001/health
}
case "$1" in
initial)
repo=https://github.com/WzeeaSajid/mlops-gitops-config.git
git clone "$repo" config
# Build the local image from the model artifact produced by the passing baseline run.
gh run download 45857011587 --repo WzeeaSajid/mlops-lab --name model --dir model
docker build -t wine-classifier:local --build-arg GIT_SHA=local .
docker run -d --name wine -p 8000:8000 wine-classifier:local
curl --retry 30 --retry-connrefused --retry-delay 2 -fsS http://localhost:8000/health
capture 11 38 <<'COMMAND'
docker ps --filter name=wine --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
curl -fsS http://localhost:8000/model-info | jq .
COMMAND
docker rm -f wine
minikube start --driver=docker --cpus=2 --memory=4096
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null
kubectl -n argocd rollout status deploy/argocd-server --timeout=6m
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=6m
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=6m
kubectl apply -f config/argocd/application.yaml
kubectl -n argocd port-forward svc/argocd-server 8443:443 >/tmp/argo-forward.log 2>&1 &
wait_revision "d39bf891a21fbb3622171d33b173bd4815688bec"
port_forward
python evidence-ui.py 19
capture 20 12 <<'COMMAND'
curl -fsS http://localhost:8001/model-info | jq '{git_sha,n_estimators,model_version}'
curl -fsS -H 'Content-Type: application/json' -d '{"features":[13.2,1.78,2.14,11.2,100,2.65,2.76,0.26,1.28,4.38,1.05,3.4,1050]}' http://localhost:8001/predict
echo
COMMAND
;;
release)
echo "READY_FOR_RELEASE"
# Observe the freshly pushed config release. The branch update occurs outside this job.
for i in $(seq 1 220); do
 release=$(git -C config ls-remote origin refs/heads/main | cut -f1)
 [[ "$release" != "d39bf891a21fbb3622171d33b173bd4815688bec" ]] && break
 sleep 5
done
test "$release" != "d39bf891a21fbb3622171d33b173bd4815688bec"
wait_revision "$release"
port_forward
python evidence-ui.py 21
capture 22 12 <<'COMMAND'
curl -fsS http://localhost:8001/model-info | jq '{model_name,model_version,git_sha,n_estimators,max_depth}'
COMMAND
capture 23 14 <<'COMMAND'
kubectl scale deployment wine-classifier -n ml-serving --replicas=5
kubectl get deployment wine-classifier -n ml-serving -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas
kubectl wait --for=jsonpath='{.spec.replicas}'=2 deployment/wine-classifier -n ml-serving --timeout=150s
kubectl get deployment wine-classifier -n ml-serving -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas
COMMAND

echo "$release" > /tmp/release-revision
;;
rollback)
release=$(cat /tmp/release-revision)
echo "READY_FOR_REVERT"
for i in $(seq 1 220); do
 revert=$(git -C config ls-remote origin refs/heads/main | cut -f1)
 [[ "$revert" != "$release" ]] && break
 sleep 5
done
test "$revert" != "$release"
wait_revision "$revert"
port_forward
git -C config pull --ff-only
capture 24 12 <<'COMMAND'
git -C config log --oneline -3
curl -fsS http://localhost:8001/model-info | jq '{git_sha,n_estimators,model_version}'
COMMAND

;;
esac
