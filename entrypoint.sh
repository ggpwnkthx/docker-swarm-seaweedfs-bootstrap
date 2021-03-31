#!/bin/bash
DIR_PREFIX=${DIR_PREFIX:="/srv"}

# Helper functions
log() { 
    echo "$@" 1>&2 &
}
# Generates a random base64 string
## $1 = Length
rand64() {
    if [ -z "$1" ]; then length=16; else length=$1; fi
    cat < /dev/urandom | base64 | tr -d '\n' | tr -d '/+' | head -c"$length"
}
randfile() {
    tmp=/tmp/$(rand64 8)
    if [ -f "$tmp" ]; then randfile "$@"; return; fi
    touch "$tmp"
    echo "$tmp"
}
in_array() {
    found=1
    for x in ${@:2}; do if [ "$1" = "$x" ]; then found=0; break; fi; done
    return $found
}

# Docker functions
config_create() { 
    cat - | data_create config "$1" 
}
config_get_id() { 
    data_get_id config "$1"
}
config_get_name() { 
    data_get_name config "$1"
}
data_create() {
    data=$(cat -)
    name=$THIS_STACK_NAMESPACE"_"$2
    id=$(docker "$1" inspect "$name" --format '{{.ID}}' 2>/dev/null)
    if [ -z "$id" ]; then
        log "Creating $1 $name"
        id=$(echo "$data" | docker "$1" create --label "$STACK_NAMESPACE_LABEL" "$name" -)
    fi
    echo "$id"
}
data_get_id() { 
    docker "$1" inspect "$2" --format '{{.ID}}' 2>/dev/null
}
data_get_name() { 
    docker "$1" inspect "$2" --format '{{.Spec.Name}}' 2>/dev/null
}
mount_attach() {
    if ! in_array "$1" $(service_get_mount_sources "$3"); then
        log "Mounting $1:$2 on service $(service_get_name "$3")"
        docker service update --mount-add type=bind,source="$1",target="$2" "$3" >/dev/null
    fi
}
network_attach() {
    id=$(network_get_id "$1")
    if ! in_array "$id" $(service_get_network_ids "$2"); then
        log "Attaching network $(network_get_name "$1") to service $(service_get_name "$2")"
        aliases=""
        for a in ${@:3}; do
            aliases="$aliases,alias=$a";
        done
        docker service update --network-add name="$1""$aliases" "$2" >/dev/null
    fi
}
network_create_overlay() {
    name=$1
    id=$(docker network inspect "$name" --format '{{.Id}}' 2>/dev/null)
    if [ -z "$id" ]; then
        log "Creating network $name"
        id=$( \
            docker network create \
                --attachable \
                --driver overlay \
                --label "$STACK_NAMESPACE_LABEL" \
                --opt encrypted=true \
                "$name" \
        )
    fi
    echo "$id"
}

network_get_id() { 
    docker network inspect "$1" --format '{{.Id}}' 2>/dev/null
}
network_get_name() {
    docker network inspect "$1" --format '{{.Name}}' 2>/dev/null
}
secret_create() { 
    cat - | data_create secret "$1"
}
secret_get_id() {
    data_get_id secret "$1"
}
secret_get_name() {
    data_get_name secret "$1"
}
service_get_id() {
    docker service inspect "$1" --format '{{.ID}}' 2>/dev/null
}
service_get_name() {
    docker service inspect "$1" --format '{{.Spec.Name}}' 2>/dev/null
}
service_get_mount_sources() {
    docker service inspect "$1" --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{.Source}} {{end}}' 2>/dev/null
}
service_get_secret_ids() {
    docker service inspect "$1" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretID}} {{end}}' 2>/dev/null
}
service_get_network_ids() {
    docker service inspect "$1" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' 2>/dev/null
}

# Swarm helper functions
swarm_mkdir() {
    for dir in ${@:2}; do
        log "Creating $1 directory $dir"
        if [ "$dirs" = "" ]; then
            dirs="/mnt/root$dir"
        else
            dirs="$dirs /mnt/root$dir"
        fi
    done
    case "$1" in
        "global") constraint="" ;;
        "managers") constraint="--constraint \"node.role==manager\"" ;;
        "workers") constraint="--constraint \"node.role==worker\"" ;;
        *) constraint="--constraint \"node.id==$1\"" ;;
    esac
    service_id=$( \
        docker service create $constraint \
            --label "$STACK_NAMESPACE_LABEL" \
            --mode "global-job" \
            --mount "type=bind,source=/,destination=/mnt/root" \
            alpine:3 \
                sh -c "mkdir -p $dirs" \
    )
    docker service rm $(echo "$service_id" | head -n 1) >/dev/null
}
swarm_install_plugin() {
    case "$1" in
        "global") constraint="" ;;
        "managers") constraint="--constraint \"node.role==manager\"" ;;
        "workers") constraint="--constraint \"node.role==worker\"" ;;
        *) constraint="--constraint \"node.id==$1\"" ;;
    esac
    
    read -r -d '' INSTALL_PLUGIN_CONFIG_DATA <<EOF
#!/bin/sh
if [ "\$(docker plugin inspect \$1)" = "[]" ]; then
    docker plugin install --grant-all-permissions \$1
fi
EOF
    INSTALL_PLUGIN_CONFIG_ID=$(echo "$INSTALL_PLUGIN_CONFIG_DATA" | config_create install_plugin)
    
    log "Installing Plugin $2"
    service_id=$( \
        docker service create $constraint \
            --config "source=$(config_get_name $INSTALL_PLUGIN_CONFIG_ID),target=/bin/entrypoint.sh,mode=700" \
            --entrypoint "/bin/entrypoint.sh" \
            --label "$STACK_NAMESPACE_LABEL" \
            --mode "global-job" \
            --mount "type=bind,source=/var/run/docker.sock,destination=/var/run/docker.sock" \
            ggpwnkthx/docker-cli $2 \
    )
    docker service rm $(echo "$service_id" | head -n 1) >/dev/null
}

if [ ! -S /var/run/docker.sock ]; then 
    log "Cannot access Docker socket"
    exit 1
fi

MANAGER_NODE_IDS=$(docker node ls --format '{{.ID}}' --filter "role=manager")
MANAGER_NODE_COUNT=$(echo "$MANAGER_NODE_IDS" | wc -l)
if [ $MANAGER_NODE_COUNT -lt 3 ]; then
    log "Must have at least 3 manager nodes"
    exit 1
fi

cpuset=$(basename "$(cat /proc/1/cpuset)")
if [ "$cpuset" != "/" ]; then
    THIS_CONTAINER_ID=$cpuset
else
    cpuset=$(basename "$(head /proc/1/cgroup | grep cpuset)")
    if ! echo "$cpuset" | grep -q cpuset; then
        THIS_CONTAINER_ID=$cpuset
    fi
fi
if [ -z "$THIS_CONTAINER_ID" ]; then
    echo "ERROR: Not a container."
    exit 1
fi
while [ -z "$THIS_CONTAINER_IMAGE" ]; do
    THIS_CONTAINER_IMAGE=$(docker inspect "$THIS_CONTAINER_ID" --format '{{.Config.Image}}' | awk -F@ '{print $1}')
done
while [ -z "$THIS_STACK_NAMESPACE" ]; do
    THIS_STACK_NAMESPACE=$(docker inspect "$THIS_CONTAINER_ID" --format '{{ index .Config.Labels "com.docker.stack.namespace" }}')
done
while [ -z "$THIS_SERVICE_ID" ]; do
    THIS_SERVICE_ID=$(docker inspect "$THIS_CONTAINER_ID" --format '{{ index .Config.Labels "com.docker.swarm.service.id" }}')
done
while [ -z "$THIS_SERVICE_NAME" ]; do
    THIS_SERVICE_NAME=$(service_get_name "$THIS_SERVICE_ID")
done
STACK_NAMESPACE_LABEL="com.docker.stack.namespace=$THIS_STACK_NAMESPACE"

# etcd
## Network
ETCD_NETWORK_ID=$(network_create_overlay $THIS_STACK_NAMESPACE"_"etcd)
## Service
ETCD_SERVICE_NAME=$THIS_STACK_NAMESPACE"_etcd"
ETCD_SERVICE_ID=$(service_get_id "$ETCD_SERVICE_NAME")
for id in $MANAGER_NODE_IDS; do
    ETCD_CONTAINER_HOSTNAME="etcd_$id"
    if [ -z "$ETCD_INITIAL_CLUSTER" ]; then 
        ETCD_INITIAL_CLUSTER="$ETCD_CONTAINER_HOSTNAME=http://$ETCD_CONTAINER_HOSTNAME:2380";
        ETCD_ADDRESSES="http://$ETCD_CONTAINER_HOSTNAME:2379"
    else 
        ETCD_INITIAL_CLUSTER="$ETCD_INITIAL_CLUSTER,$ETCD_CONTAINER_HOSTNAME=http://$ETCD_CONTAINER_HOSTNAME:2380";
        ETCD_ADDRESSES="$ETCD_ADDRESSES,http://$ETCD_CONTAINER_HOSTNAME:2379"
    fi
done
### Check for existing cluster database
if [ -z "$(docker volume ls -f name=$ETCD_SERVICE_NAME -q)" ]; 
then ETCD_INITIAL_CLUSTER_STATE="new";
else ETCD_INITIAL_CLUSTER_STATE="existing";
fi
ETCD_CONTAINER_HOSTNAME="etcd_{{.Node.ID}}"
if [ -z "$ETCD_SERVICE_ID" ]; then
    log "Creating service $ETCD_SERVICE_NAME"
    docker service create \
        --constraint "node.role==manager" \
        --env "ALLOW_NONE_AUTHENTICATION=yes" \
        --env "ETCD_ADVERTISE_CLIENT_URLS=http://$ETCD_CONTAINER_HOSTNAME:2379" \
        --env "ETCD_INITIAL_ADVERTISE_PEER_URLS=http://$ETCD_CONTAINER_HOSTNAME:2380" \
        --env "ETCD_INITIAL_CLUSTER=$ETCD_INITIAL_CLUSTER" \
        --env "ETCD_INITIAL_CLUSTER_STATE=$ETCD_INITIAL_CLUSTER_STATE" \
        --env "ETCD_INITIAL_CLUSTER_TOKEN=$THIS_STACK_NAMESPACE" \
        --env "ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379" \
        --env "ETCD_LISTEN_METRICS_URLS=http://0.0.0.0:2381" \
        --env "ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380" \
        --env "ETCD_NAME=$ETCD_CONTAINER_HOSTNAME" \
        --hostname "$ETCD_CONTAINER_HOSTNAME" \
        --label "$STACK_NAMESPACE_LABEL" \
        --mode "global" \
        --mount "type=volume,source=$ETCD_SERVICE_NAME,destination=/bitnami/etcd/data,volume-label=$STACK_NAMESPACE_LABEL" \
        --network "name=$(network_get_name $ETCD_NETWORK_ID),alias=etcd" \
        --name "$ETCD_SERVICE_NAME" \
        --restart-condition "any" \
        bitnami/etcd >/dev/null
fi

# SeaweedFS
SEAWEEDFS_MASTER_PORT=${SEAWEEDFS_MASTER_PORT:="9333"}
SEAWEEDFS_FILER_PORT=${SEAWEEDFS_FILER_PORT:="8888"}
SEAWEEDFS_VOLUME_PORT=${SEAWEEDFS_VOLUME_PORT:="8080"}
## Entrypoint
read -r -d '' SEAWEEDFS_CONFIG_DATA <<EOF
#!/bin/sh
ARGS="\$@"
case \$1 in
    "filer") ARGS="\$ARGS -ip=\$(hostname)" ;;
    "master") ARGS="\$ARGS -ip=\$(hostname)" ;;
    "volume") ARGS="\$ARGS -ip=\$(hostname) -publicUrl=\$WEED_PUBLIC_URL:$SEAWEEDFS_VOLUME_PORT" ;;
esac
/entrypoint.sh \$ARGS
EOF
SEAWEEDFS_CONFIG_ID=$(echo "$SEAWEEDFS_CONFIG_DATA" | config_create seaweedfs)
## Network
SEAWEEDFS_NETWORK_ID=$(network_create_overlay $THIS_STACK_NAMESPACE"_"seaweedfs)
## Service | Master
for id in $MANAGER_NODE_IDS; do
    container_hostname="seaweedfs_master_"$id
    if [ -z "$SEAWEEDFS_MASTER_CLUSTER" ]; then 
        SEAWEEDFS_MASTER_CLUSTER="$container_hostname:$SEAWEEDFS_MASTER_PORT"
        SEAWEEDFS_FILER_CLUSTER="$container_hostname:$SEAWEEDFS_FILER_PORT"
    else
        SEAWEEDFS_MASTER_CLUSTER="$SEAWEEDFS_MASTER_CLUSTER,$container_hostname:$SEAWEEDFS_MASTER_PORT"
        SEAWEEDFS_FILER_CLUSTER="$SEAWEEDFS_FILER_CLUSTER,$container_hostname:$SEAWEEDFS_FILER_PORT"
    fi
done
SEAWEEDFS_MASTER_SERVICE_NAME=$THIS_STACK_NAMESPACE"_seaweedfs-master"
SEAWEEDFS_MASTER_SERVICE_ID=$(service_get_id "$SEAWEEDFS_MASTER_SERVICE_NAME")
if [ -z "$SEAWEEDFS_MASTER_SERVICE_ID" ]; then
    log "Creating service $SEAWEEDFS_MASTER_SERVICE_NAME"
    docker service create \
        --config "source=$(config_get_name $SEAWEEDFS_CONFIG_ID),target=/bin/entrypoint.sh,mode=700" \
        --constraint "node.role==manager" \
        --entrypoint "/bin/entrypoint.sh" \
        --env "WEED_MASTER_FILER_DEFAULT=filer:$SEAWEEDFS_FILER_PORT" \
        --env "WEED_MASTER_SEQUENCER_TYPE=raft" \
        --hostname "seaweedfs_master_{{.Node.ID}}" \
        --label "$STACK_NAMESPACE_LABEL" \
        --mode "global" \
        --mount "type=volume,source=$SEAWEEDFS_MASTER_SERVICE_NAME,destination=/data,volume-label=$STACK_NAMESPACE_LABEL" \
        --name "$SEAWEEDFS_MASTER_SERVICE_NAME" \
        --network "name=$(network_get_name $SEAWEEDFS_NETWORK_ID),alias=master" \
        --network "name=$(network_get_name $ETCD_NETWORK_ID)" \
        --restart-condition "any" \
        chrislusf/seaweedfs:latest \
            master \
            -mdir=/data \
            -peers="$SEAWEEDFS_MASTER_CLUSTER" \
            -port="$SEAWEEDFS_MASTER_PORT" >/dev/null
fi
## Service | Volume
SEAWEEDFS_VOLUME_SERVICE_NAME=$THIS_STACK_NAMESPACE"_seaweedfs-volume"
SEAWEEDFS_VOLUME_SERVICE_ID=$(service_get_id "$SEAWEEDFS_VOLUME_SERVICE_NAME")
if [ -z "$SEAWEEDFS_VOLUME_SERVICE_ID" ]; then
    log "Creating service $SEAWEEDFS_VOLUME_SERVICE_NAME"
    docker service create \
        --config "source=$(config_get_name $SEAWEEDFS_CONFIG_ID),target=/bin/entrypoint.sh,mode=700" \
        --constraint "node.role==manager" \
        --entrypoint "/bin/entrypoint.sh" \
        --env "WEED_PUBLIC_URL={{.Node.Hostname}}" \
        --hostname "seaweedfs_volume_{{.Node.ID}}" \
        --label "$STACK_NAMESPACE_LABEL" \
        --mode "global" \
        --mount "type=volume,source=$SEAWEEDFS_VOLUME_SERVICE_NAME,destination=/data,volume-label=$STACK_NAMESPACE_LABEL" \
        --name "$SEAWEEDFS_VOLUME_SERVICE_NAME" \
        --network "name=$(network_get_name $SEAWEEDFS_NETWORK_ID)" \
        --restart-condition "any" \
        chrislusf/seaweedfs:latest \
            volume \
            -mserver="$SEAWEEDFS_MASTER_CLUSTER" \
            -port="$SEAWEEDFS_VOLUME_PORT" >/dev/null
fi
## Service | Filer
SEAWEEDFS_FILER_SERVICE_NAME=$THIS_STACK_NAMESPACE"_seaweedfs-filer"
SEAWEEDFS_FILER_SERVICE_ID=$(service_get_id "$SEAWEEDFS_FILER_SERVICE_NAME")
if [ -z "$SEAWEEDFS_FILER_SERVICE_ID" ]; then
    log "Creating service $SEAWEEDFS_FILER_SERVICE_NAME"
    docker service create \
        --config "source=$(config_get_name $SEAWEEDFS_CONFIG_ID),target=/bin/entrypoint.sh,mode=700" \
        --constraint "node.role==manager" \
        --entrypoint "/bin/entrypoint.sh" \
        --env "WEED_LEVELDB2_ENABLED=false" \
        --env "WEED_ETCD_ENABLED=true" \
        --env "WEED_ETCD_SERVERS=etcd:2379" \
        --hostname "seaweedfs_filer_{{.Node.ID}}" \
        --label "$STACK_NAMESPACE_LABEL" \
        --mode "global" \
        --mount "type=volume,source=$SEAWEEDFS_FILER_SERVICE_NAME,destination=/data,volume-label=$STACK_NAMESPACE_LABEL" \
        --name "$SEAWEEDFS_FILER_SERVICE_NAME" \
        --network "name=$(network_get_name $SEAWEEDFS_NETWORK_ID),alias=filer" \
        --network "name=$(network_get_name $ETCD_NETWORK_ID)" \
        --restart-condition "any" \
        chrislusf/seaweedfs:latest \
            filer \
            -master="$SEAWEEDFS_MASTER_CLUSTER" \
            -peers="$SEAWEEDFS_FILER_CLUSTER" \
            -port="$SEAWEEDFS_FILER_PORT" >/dev/null
fi
## Service | proxet
SEAWEEDFS_SOCKET_PATH=/var/lib/docker/plugins/seaweedfs/$THIS_STACK_NAMESPACE
swarm_mkdir global $SEAWEEDFS_SOCKET_PATH
SEAWEEDFS_PROXET_SERVICE_NAME=$THIS_STACK_NAMESPACE"_seaweedfs-proxet"
SEAWEEDFS_PROXET_SERVICE_ID=$(service_get_id "$SEAWEEDFS_PROXET_SERVICE_NAME")
if [ -z "$SEAWEEDFS_PROXET_SERVICE_ID" ]; then
    log "Creating service $SEAWEEDFS_PROXET_SERVICE_NAME"
    docker service create \
        --label "$STACK_NAMESPACE_LABEL" \
        --mode "global" \
        --mount "type=bind,source=$SEAWEEDFS_SOCKET_PATH,destination=$SEAWEEDFS_SOCKET_PATH" \
        --name "$SEAWEEDFS_PROXET_SERVICE_NAME" \
        --network "name=$(network_get_name $SEAWEEDFS_NETWORK_ID)" \
        --restart-condition "any" \
        ggpwnkthx/go-proxet \
            unix,$SEAWEEDFS_SOCKET_PATH/http.sock tcp,filer:$SEAWEEDFS_FILER_PORT \
            unix,$SEAWEEDFS_SOCKET_PATH/grpc.sock tcp,filer:$(($SEAWEEDFS_FILER_PORT + 10000)) >/dev/null
fi

swarm_install_plugin global ggpwnkthx/docker-plugin-volume-seaweedfs