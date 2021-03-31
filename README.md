# docker-swarm-seaweedfs-bootstrap
Docker Swarm compliant SeaweedFS Bootstraping Mechanism
# Usage
```
docker stack deploy -c stack.yml stack-name
```
The magic happens in the ```entrypoint.sh``` file which dynmically deploys all requirements for a fully functional SeaweedFS cluster as well as a Docker Volume Pluggin on each node in the Swarm.