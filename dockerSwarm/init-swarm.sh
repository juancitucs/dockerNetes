#!/bin/bash
# Solo se ejecuta en el nodo MANAGER

echo "Inicializando Swarm..."
docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')

echo "Obteniendo token de worker..."
docker swarm join-token worker

echo "Puedes unir tus nodos workers con ese token en ellos"
