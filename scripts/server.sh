#!/usr/bin/env bash

echo "Running server.sh"

adminUsername=$1
adminPassword=$2
stackName=$4

echo "Got the parameters:"
echo adminUsername \'$adminUsername\'
echo adminPassword \'$adminPassword\'
echo stackName \'$stackName\'

#######################################################"
############## Install Couchbase Server ###############"
#######################################################"
echo "Installing Couchbase Server..."

curl -O http://packages.couchbase.com/releases/couchbase-release/couchbase-release-1.0-4-amd64.deb
dpkg -i couchbase-release-1.0-4-amd64.deb
apt-get update
apt-get install -y awscli couchbase-server-community

#######################################################"
############ Turn Off Transparent Hugepages ###########"
#######################################################"
echo "Turning off transparent hugepages..."

echo "#!/bin/bash
### BEGIN INIT INFO
# Provides:          disable-thp
# Required-Start:    $local_fs
# Required-Stop:
# X-Start-Before:    couchbase-server
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Disable THP
# Description:       disables Transparent Huge Pages (THP) on boot
### END INIT INFO
echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled
echo 'never' > /sys/kernel/mm/transparent_hugepage/defrag
" > /etc/init.d/disable-thp
chmod 755 /etc/init.d/disable-thp
/etc/init.d/disable-thp start
update-rc.d disable-thp defaults

#######################################################
################# Set Swappiness to 0 #################
#######################################################
echo "Setting swappiness to 0..."

sysctl vm.swappiness=0
echo "
# Required for Couchbase
vm.swappiness = 0
" >> /etc/sysctl.conf

source util.sh
formatDataDisk

apt-get -y install jq

if [ -z "$6" ]
then
  echo "This node is part of the autoscaling group that contains the rally point."
  rallyPrivateIP=`getRallyPrivateIP`
else
  rallyAutoScalingGroup=$6
  echo "This node is not the rally point and not part of the autoscaling group that contains the rally point."
  echo rallyAutoScalingGroup \'$rallyAutoScalingGroup\'
  rallyPrivateIP=`getRallyPrivateIP ${rallyAutoScalingGroup}`
fi

region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
  | jq '.region'  \
  | sed 's/^"\(.*\)"$/\1/' )

instanceID=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
  | jq '.instanceId' \
  | sed 's/^"\(.*\)"$/\1/' )

nodePrivateIP=`curl http://169.254.169.254/latest/meta-data/local-ipv4`

echo "Using the settings:"
echo adminUsername \'$adminUsername\'
echo adminPassword \'$adminPassword\'
echo stackName \'$stackName\'
echo rallyPrivateIP \'$rallyPrivateIP\'
echo region \'$region\'
echo instanceID \'$instanceID\'
echo nodePrivateIP \'$nodePrivateIP\'

if [[ ${rallyPrivateIP} == ${nodePrivateIP} ]]
then
  aws ec2 create-tags \
    --region ${region} \
    --resources ${instanceID} \
    --tags Key=Name,Value=${stackName}-ServerRally
else
  aws ec2 create-tags \
    --region ${region} \
    --resources ${instanceID} \
    --tags Key=Name,Value=${stackName}-Server
fi

cd /opt/couchbase/bin/

echo "Running couchbase-cli node-init"
output=""
while [[ ! $output =~ "SUCCESS" ]]
do
  output=`./couchbase-cli node-init \
    --cluster=$nodePrivateIP \
    --node-init-hostname=$nodePrivateIP \
    --node-init-data-path=/mnt/datadisk/data \
    --node-init-index-path=/mnt/datadisk/index \
    --node-init-analytics-path=/mnt/datadisk/analytics \
    --user=$adminUsername \
    --pass=$adminPassword`
  echo node-init output \'$output\'
  sleep 10
done

if [[ $rallyPrivateIP == $nodePrivateIP ]]
then
  totalRAM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  dataRAM=$((60 * $totalRAM / 100000))
  indexRAM=$((15 * $totalRAM / 100000))
  analyticsRAM=$((10 * $totalRAM / 100000))

  echo "Running couchbase-cli cluster-init"
  ./couchbase-cli cluster-init \
    --cluster=$nodePrivateIP \
    --cluster-username=$adminUsername \
    --cluster-password=$adminPassword \
    --cluster-ramsize=$dataRAM \
    --cluster-index-ramsize=$indexRAM \
    --cluster-analytics-ramsize=$analyticsRAM \
    --services=index,data,query,analytics
else
  echo "Running couchbase-cli server-add"
  output=""
  while [[ $output != "Server $nodePrivateIP:8091 added" && ! $output =~ "Node is already part of cluster." ]]
  do
    output=`./couchbase-cli server-add \
      --cluster=$rallyPrivateIP \
      --user=$adminUsername \
      --pass=$adminPassword \
      --server-add=$nodePrivateIP \
      --server-add-username=$adminUsername \
      --server-add-password=$adminPassword \
      --services=index,data,query,analytics
    echo server-add output \'$output\'
    sleep 10
  done

  echo "Running couchbase-cli rebalance"
  output=""
  while [[ ! $output =~ "SUCCESS" ]]
  do
    output=`./couchbase-cli rebalance \
    --cluster=$rallyPrivateIP \
    --user=$adminUsername \
    --pass=$adminPassword`
    echo rebalance output \'$output\'
    sleep 10
  done

fi
