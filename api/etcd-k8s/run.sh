#!/bin/bash

IFS=,
PEERS=($OTHER_HOSTS)
MEMBERS=''
GOOD_MEMBER=''
INITIAL_CLUSTER_STATE=${INITIAL_CLUSTER_STATE:-new}
DATA_DIR='/mnt/etcd/data'
APISERVER=$KUBERNETES_PORT_443_TCP_ADDR
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
CONFIGMAP_NAME=${CONFIGMAP_NAME:-$NAME}

echo "Waiting for 5 seconds for dns to catch up..."

sleep 5

ETCD1_IP=$(host etcd1 | awk 'NR==1{print $4}')
ETCD2_IP=$(host etcd2 | awk 'NR==1{print $4}')
ETCD3_IP=$(host etcd3 | awk 'NR==1{print $4}')

INITIAL_SVC_IP=$(host $NAME | awk 'NR==1{print $4}')
LISTEN_IP=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)

if [ "$INITIAL_CLUSTER_STATE" = "existing" ]; then
  echo "Based on the configmap, it appears this cluster was already bootstrapped..."
  echo "Rebuilding."

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

else
  echo "New etcd Cluster detected!"
  curl -XPATCH -H "Content-Type: application/merge-patch+json" -d '{ "data": {"initialclusterstate": "existing" } }' https://$APISERVER:443/api/v1/namespaces/$NAMESPACE/configmaps/$NAME --header "Authorization: Bearer $TOKEN" --insecure
fi

etcd \
  -name $NAME \
  --data-dir $DATA_DIR \
  -listen-peer-urls http://$LISTEN_IP:2380 \
  -listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 \
  -advertise-client-urls http://$LISTEN_IP:2379,http://$LISTEN_IP:4001 \
  -initial-advertise-peer-urls http://$INITIAL_SVC_IP:2380 \
  -initial-cluster etcd1=http://$ETCD1_IP:2380,etcd2=http://$ETCD2_IP:2380,etcd3=http://$ETCD3_IP:2380 \
  -initial-cluster-state $INITIAL_CLUSTER_STATE
