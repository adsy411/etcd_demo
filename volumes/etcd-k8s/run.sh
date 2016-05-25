#!/bin/bash

IFS=,
PEERS=($OTHER_HOSTS)
MEMBERS=''
GOOD_MEMBER=''
INITIAL_CLUSTER_STATE=new
WAL_DIR='/mnt/etcd/wal'
DATA_DIR='/mnt/etcd/data'

echo "Waiting for 5 seconds for dns to catch up..."

sleep 5

ETCD1_IP=$(host etcd1 | awk 'NR==1{print $4}')
ETCD2_IP=$(host etcd2 | awk 'NR==1{print $4}')
ETCD3_IP=$(host etcd3 | awk 'NR==1{print $4}')

INITIAL_SVC_IP=$(host $NAME | awk 'NR==1{print $4}')
LISTEN_IP=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)

if [ "$(ls -A $WAL_DIR)" ]; then
  echo "WAL directory not empty! This node has already been initalized!"
  echo "Cleaning directory, and re-adding to cluster!"
  rm -rf $WAL_DIR/*
  rm -rf $DATA_DIR

  for host in "${!PEERS[@]}"; do
    POTENTIAL_MEMBERS=$(curl -s -f http://${PEERS[$host]}:2379/v2/members)
    if [[ $? == 0 ]]; then
      MEMBERS=$POTENTIAL_MEMBERS
      GOOD_MEMBER=${PEERS[$host]}
      break
    fi
  done
  echo "Current members: $POTENTIAL_MEMBERS"
  check_for_membership=$(echo $POTENTIAL_MEMBERS | grep $NAME)

  if [[ $? == 0 ]]; then
    echo "Found self, $NAME, in current cluster. Removing member."
    id_to_eject=$(echo "$POTENTIAL_MEMBERS" | jq --raw-output ".members[]|select(.name == \"$NAME\").id")
    echo "id_to_eject: $id_to_eject"
    curl -f -s "http://$GOOD_MEMBER:2379/v2/members/$id_to_eject" -XDELETE
  fi

  echo "Adding self back!"
  curl -f -s "http://$GOOD_MEMBER:2379/v2/members/" -H "Content-Type: application/json" -d "{\"peerURLs\": [\"http://$INITIAL_SVC_IP:2380\"], \"name\": \"$NAME\"}" -XPOST
  INITIAL_CLUSTER_STATE="existing"

else
  echo "WAL directory empty! Continuing on!"
fi

mkdir -p $WAL_DIR $DATA_DIR

etcd \
  -name $NAME \
  --wal-dir $WAL_DIR \
  --data-dir $DATA_DIR \
  -listen-peer-urls http://$LISTEN_IP:2380 \
  -listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 \
  -advertise-client-urls http://$LISTEN_IP:2379,http://$LISTEN_IP:4001 \
  -initial-advertise-peer-urls http://$INITIAL_SVC_IP:2380 \
  -initial-cluster etcd1=http://$ETCD1_IP:2380,etcd2=http://$ETCD2_IP:2380,etcd3=http://$ETCD3_IP:2380 \
  -initial-cluster-state $INITIAL_CLUSTER_STATE
