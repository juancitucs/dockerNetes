#!/bin/bash

STACK_NAME=wp_stack

echo "Desplegando stack: $STACK_NAME"
sudo docker stack deploy -c wordpress-stack.yml $STACK_NAME

echo "Verifica con: docker stack services $STACK_NAME"
