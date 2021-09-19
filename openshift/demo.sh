#!/bin/bash

set -e -u -o pipefail

function find_pod() {
  local labelled=$1
  local proj=$2

  echo $(oc get pods -n $proj -l $labelled -o name --no-headers | head -n 1)
}

function pod_ready() {
  local pod=$1
  local proj=$2

  statusline=$(oc get $pod -n $proj --no-headers)
  ready=$(echo $statusline | awk '{print $2}')

  echo "${ready%%/*}"
}

function watch_deploy() {
  local dc=$1
  local proj=$2

  counter=0
  pod=$(find_pod deploymentconfig=$dc $proj)
  while [[ "$pod" == "" ]]
  do
    echo "*** Looking for a pod for $dc in $proj"
    sleep 5

    counter=$((counter + 1))
    [[ $counter -gt 15 ]] && echo "*** Gave up looking for pod $pod for $dc in project $proj after 75 seconds" && break

    pod=$(find_pod deploymentconfig=$dc $proj)
  done

  counter=0
  while [ $(pod_ready $pod $proj) -lt 1 ]
  do
    echo "*** Waiting for $pod in $proj to be ready"
    sleep 5
    counter=$((counter + 1))
    [[ $counter -gt 20 ]] && echo "*** Gave up waiting for pod $pod in project $proj after 400 seconds" && break
  done

  echo "Done watching $dc in $proj"
}

function deploy_apps() {
  local prefix=$1
  local namespace=$2
  local app_name=$3

  oc new-app -f krb5-server-deploy.yaml -p NAME="$prefix" -n $namespace
  oc new-app -f example-client-deploy.yaml -p PREFIX="$prefix" -p KDC_SERVER="$prefix" -n $namespace

  # wait for Pods to start and be running
  watch_deploy $prefix $namespace
  watch_deploy "${prefix}-${app_name}" $namespace
}

function get_admin_password() {
  local prefix=$1

  server_pod=$(oc get pods -l deploymentconfig="$prefix" -o name)
  admin_pwd=$(oc logs -c kdc $server_pod | head -n 1 | sed 's/.*Your\ KDC\ password\ is\ //')
  echo $admin_pwd
}

function create_auth() {
  local prefix=$1
  local app_name=$2
  local admin_pwd=$3

  app_pod=$(oc get pods -l deploymentconfig="${prefix}-${app_name}" -o name)
  principal=$(oc set env $app_pod --list | grep OPTIONS | grep -o "[a-z]*\@[A-Z\.]*")
  realm=$(echo $principal | sed 's/[a-z]*\@//')

  # create principal
  dev_null=$(echo $admin_pwd | oc rsh -c kinit-sidecar $app_pod kadmin -r $realm -p admin/admin@$realm -q "addprinc -pw redhat -requires_preauth $principal")

  # create keytab
  dev_null=$(echo $admin_pwd | oc rsh -c kinit-sidecar $app_pod kadmin -r $realm -p admin/admin@$realm -q "ktadd $principal")

  echo $app_pod
}

function main() {
  local prefix=$1
  local app_name=$2
  local namespace=$3

  oc new-project $namespace
  deploy_apps $prefix $namespace $app_name

  admin_pwd=$(get_admin_password $prefix)
  app_pod=$(create_auth $prefix $app_name $admin_pwd)

  # tail app logs
  cat <<-EOF
############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployment.

  Then run the following to see if the app is authenticated:
  oc logs -f $app_pod -c $app_name -n $namespace

  To destroy this demo, run:
  $0 -d $namespace

############################################################################
############################################################################
EOF
}

function destroy() {
  oc delete project $1
}

usage() { echo "$0 usage:" && grep ".)\ #" $0 | sed 's/ #//' ; exit 0; }

rand_name=$(openssl rand -hex 4)

prefix='test'
app_name='example-app'
namespace=''
must_delete=0
must_create=0

while getopts ":hcs:p:a:n:d:" arg; do
  case $arg in
    c) # Create demo.
      must_create=1
      ;;
    p) # Specify prefix.
      prefix=$OPTARG
      ;;
    a) # Specify app name.
      app_name=$OPTARG
      ;;
    n) # Specify namespace.
      namespace=$OPTARG
      ;;
    d) # Specify namespace to delete.
      must_delete=1
      namespace=$OPTARG
      ;;
    s) # Specify strength, either 45 or 90.
      strength=${OPTARG}
      [ $strength -eq 45 -o $strength -eq 90 ] \
        && echo "Strength is $strength." \
        || echo "Strength needs to be either 45 or 90, $strength found instead."
      ;;
    h | *) # Display help.
      usage
      exit 0
      ;;
  esac
done

# [ $# -eq 0 ] && usage
if [ $must_delete -eq 1 ]; then
  if [ -z $namespace ]; then
    echo 'Please supply namespace to delete'
    exit 0
  fi
  destroy $namespace
  exit 0
fi

if [ $must_create -eq 1 ]; then
  # Set namespace if not set
  if [ -z "${namespace}" ]; then
    namespace="krb-ex-$rand_name"
  fi
  main $prefix $app_name $namespace
  exit 0
fi

usage

# main $prefix $app_name $namespace
