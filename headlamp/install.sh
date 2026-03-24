#!/bin/bash
# Installs Headlamp Kubernetes dashboard
## Usage: ./install.sh [kubeconfig]

if [ $# -ge 1 ] ; then
  export KUBECONFIG=$1
fi

NS=headlamp

echo Create namespace $NS
kubectl create namespace $NS

function installing_headlamp() {
  echo Updating helm repos
  helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
  helm repo update

  echo Installing Headlamp
  helm -n $NS install headlamp headlamp/headlamp \
  --version 0.39.0 \
  -f values.yaml

  echo Installed Headlamp
  echo "  Access: kubectl -n $NS port-forward svc/headlamp 8080:80"
  return 0
}

# set commands for error handling.
set -e
set -o errexit   ## set -e : exit the script if any statement returns a non-true return value
set -o nounset   ## set -u : exit the script if you try to use an uninitialised variable
set -o errtrace  # trace ERR through 'time command' and other functions
set -o pipefail  # trace ERR through pipes
installing_headlamp   # calling function
