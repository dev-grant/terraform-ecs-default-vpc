#!/bin/sh -e

#Usage: CONTAINER_VERSION=docker_container_version [create|update]

for f in ./service_creation/*; do
  # TODO integrate this sed command
  sed < $f/td.tpl.json -e "s,@@version@@, ," > $f/TASKDEF.json
  aws ecs register-task-definition --cli-input-json file://$f/TASKDEF.json > $f/REGISTERED_TASKDEF.json
  TASKDEFINITION_ARN=$( < $f/REGISTERED_TASKDEF.json jq -r .taskDefinition.taskDefinitionArn )
  rm $f/TASKDEF.json $f/REGISTERED_TASKDEF.json

  sed "s,@@TASKDEFINITION_ARN@@,$TASKDEFINITION_ARN," < $f/service-$1.json > $f/SERVICEDEF.json
  aws ecs $1-service --cli-input-json file://$f/SERVICEDEF.json | tee $f/SERVICE_DEPLOYED.json
  rm $f/SERVICEDEF.json
done