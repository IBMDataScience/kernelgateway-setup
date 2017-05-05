#!/bin/bash
args="$@"
echo "$@"
KGUser=kernelgateway
function createSparkUser {
  /tmp/install_kg_emr_cluster_script.sh --createUser $1
}

function downloadClusterScript {
  echo "Downloading install_kg_emr_cluster_script.sh script to /tmp"
  wget https://raw.githubusercontent.com/IBMDataScience/kernelgateway-setup/master/install_kg_emr_cluster_script.sh
  chmod +x /tmp/install_kg_emr_cluster_script.sh
}

function executeClusterScript {
  sudo su $KGUser -c "exec /tmp/install_kg_emr_cluster_script.sh $args"
}

IS_MASTER=false
if grep isMaster /mnt/var/lib/info/instance.json | grep true;
then
  IS_MASTER=true
fi

if [ "$IS_MASTER" = true ]; then
  downloadClusterScript
  createSparkUser $KGUser
  executeClusterScript
fi
